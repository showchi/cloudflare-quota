import AppKit
import Foundation
import Darwin
import Observation
import QuotaCore

struct AccountDraft: Identifiable, Equatable, Sendable {
    var id: UUID
    var isNew: Bool
    var name: String
    var accountID: String
    var token: String
    var dailyLimit: Int
    var switchPercent: Int
    var enabled: Bool
}

@MainActor
@Observable
final class AppModel {
    var stored: StoredAccounts
    var usages: [UUID: AccountUsage] = [:]
    var isRefreshing = false
    var draft: AccountDraft?
    var alertMessage: String?
    private(set) var configurationLoadError: String?
    private(set) var statusPublicationError: String?

    private let store: AccountStore
    private let api: CloudflareAPI
    private let statusURL: URL
    private let statusWriter: (QuotaStatus, URL) throws -> Void
    private let statusRetrySleep: (Duration) async throws -> Void
    private var statusRetryTask: Task<Void, Never>?
    private var statusRetryVersion = 0
    private var statusRetriesEnabled = true
    private var timer: Task<Void, Never>?
    private var automaticRefreshStarted = false
    private var timerVersion = 0
    private let currentDate: () -> Date
    private let sleep: (Duration) async throws -> Void
    private var configurationVersion = 0
    private var refreshPending = false
    private var usageDay: Date?
    private var credentialRecoveryErrors: [UUID: String] = [:]
    var onMenuTitleChange: (() -> Void)?

    init(
        store: AccountStore,
        api: CloudflareAPI = CloudflareAPI(),
        statusURL: URL = StatusFile.defaultURL(),
        currentDate: @escaping () -> Date = { Date() },
        sleep: @escaping (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        statusWriter: @escaping (QuotaStatus, URL) throws -> Void = { try StatusFile.write($0, to: $1) },
        statusRetrySleep: @escaping (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.store = store
        self.api = api
        self.statusURL = statusURL
        self.statusWriter = statusWriter
        self.statusRetrySleep = statusRetrySleep
        self.currentDate = currentDate
        self.sleep = sleep
        do {
            stored = try store.load()
        } catch {
            stored = StoredAccounts()
            let message = L10n.format(.configurationUnreadable, error.localizedDescription)
            configurationLoadError = message
            alertMessage = message
            writeStatus()
        }
    }

    convenience init() {
        self.init(
            store: AccountStore(
                fileURL: AccountStore.defaultFileURL(),
                tokens: FileTokenStore(fileURL: FileTokenStore.defaultFileURL())
            )
        )
    }

    var snapshots: [AccountSnapshot] {
        snapshots(at: currentDate())
    }

    private func snapshots(at date: Date) -> [AccountSnapshot] {
        let isCurrentDay = usageDay == UsageMath.utcDayBounds(containing: date).start
        return stored.accounts.map {
            AccountSnapshot(config: $0, usage: isCurrentDay && credentialRecoveryErrors[$0.id] == nil ? usages[$0.id] : nil)
        }
    }

    private func invalidateExpiredUsage(at date: Date) {
        guard !usages.isEmpty,
              usageDay != UsageMath.utcDayBounds(containing: date).start else { return }
        usages.removeAll()
        usageDay = nil
        writeStatus(at: date)
        onMenuTitleChange?()
    }

    var menuTitle: String {
        if configurationLoadError != nil || statusPublicationError != nil || stored.accounts.contains(where: {
            $0.enabled && credentialRecoveryErrors[$0.id] != nil
        }) { return "!" }
        return UsageMath.menuTitle(for: snapshots)
    }

    var suggestedAccountID: UUID? {
        UsageMath.suggestedAccount(in: snapshots)?.config.id
    }

    var resetsAt: Date {
        UsageMath.utcDayBounds(containing: currentDate()).end
    }

    func start() {
        guard !automaticRefreshStarted else { return }
        automaticRefreshStarted = true
        statusRetriesEnabled = true
        if statusPublicationError != nil { scheduleStatusRetry() }
        Task { [weak self] in await self?.refresh() }
    }

    func stop() {
        automaticRefreshStarted = false
        timerVersion += 1
        timer?.cancel()
        timer = nil
        statusRetriesEnabled = false
        cancelStatusRetry()
    }

    private func scheduleNextRefresh() {
        timerVersion += 1
        timer?.cancel()
        timer = nil
        guard automaticRefreshStarted else { return }
        let version = timerVersion
        let now = currentDate()
        let untilMidnight = UsageMath.utcDayBounds(containing: now).end.timeIntervalSince(now)
        let delay = Duration.seconds(min(Double(min(120, max(1, stored.refreshMinutes))) * 60, untilMidnight))
        let sleep = self.sleep
        timer = Task { [weak self] in
            do { try await sleep(delay) } catch { return }
            guard !Task.isCancelled, let self,
                  self.automaticRefreshStarted, self.timerVersion == version else { return }
            // Keep network work outside the cancellable waiting task.
            Task { [weak self] in await self?.refresh() }
        }
    }

    func refresh() async {
        if configurationLoadError != nil {
            writeStatus()
            scheduleNextRefresh()
            return
        }
        invalidateExpiredUsage(at: currentDate())
        if isRefreshing {
            refreshPending = true
            return
        }
        isRefreshing = true
        defer {
            isRefreshing = false
            scheduleNextRefresh()
        }

        repeat {
            refreshPending = false
            await refreshCurrentConfiguration()
        } while refreshPending
    }

    private func refreshCurrentConfiguration() async {
        let version = configurationVersion
        let configs = stored.accounts
        let api = CloudflareAPI(session: api.session, restBase: api.restBase, graphqlURL: api.graphqlURL, language: stored.language)
        var next: [UUID: AccountUsage] = [:]
        var resolvedIDs: [UUID: String] = [:]
        let now = currentDate()
        let bounds = UsageMath.utcDayBounds(containing: now)

        for config in configs where config.enabled {
            do {
                if let message = credentialRecoveryErrors[config.id] {
                    throw ValidationError(message)
                }
                guard let token = try store.tokens.token(for: config.id), !token.isEmpty else {
                    throw ValidationError(L10n.text(.missingToken, language: stored.language))
                }
                let accountID = try await api.resolveAccountID(config.accountID, token: token)
                if accountID != config.accountID {
                    resolvedIDs[config.id] = accountID
                }
                let usage = try await api.usage(
                    accountID: accountID,
                    token: token,
                    from: bounds.start,
                    until: bounds.end
                )
                next[config.id] = AccountUsage(
                    accountID: config.id,
                    requests: usage.requests,
                    scripts: usage.scripts,
                    fetchedAt: currentDate()
                )
            } catch {
                next[config.id] = .failed(accountID: config.id, message: error.localizedDescription, at: now)
            }
        }

        let committedAt = currentDate()
        guard version == configurationVersion,
              UsageMath.utcDayBounds(containing: committedAt).start == bounds.start else {
            refreshPending = true
            return
        }
        if !resolvedIDs.isEmpty {
            var updated = stored
            for index in updated.accounts.indices {
                if let accountID = resolvedIDs[updated.accounts[index].id] {
                    updated.accounts[index].accountID = accountID
                }
            }
            if persist(updated) { stored = updated }
        }
        usages = next
        usageDay = bounds.start
        writeStatus(at: committedAt)
        onMenuTitleChange?()
    }

    func beginAdd() {
        AppActivation.becomeRegular()
        draft = AccountDraft(
            id: UUID(),
            isNew: true,
            name: "",
            accountID: "",
            token: "",
            dailyLimit: UsageMath.defaultDailyLimit,
            switchPercent: Int(UsageMath.defaultSwitchThreshold * 100),
            enabled: true
        )
    }

    func beginEdit(_ config: AccountConfig) {
        AppActivation.becomeRegular()
        draft = AccountDraft(
            id: config.id,
            isNew: false,
            name: config.name,
            accountID: config.accountID,
            token: "",
            dailyLimit: config.dailyLimit,
            switchPercent: Int((config.switchThreshold * 100).rounded()),
            enabled: config.enabled
        )
    }

    func saveDraft() {
        guard allowConfigurationWrite() else { return }
        guard var draft else { return }
        draft.name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        draft.accountID = draft.accountID.trimmingCharacters(in: .whitespacesAndNewlines)
        let token = draft.token.trimmingCharacters(in: .whitespacesAndNewlines)
        let language = stored.language
        guard !draft.name.isEmpty else {
            showOperationAlert(L10n.text(.nameRequired, language: language))
            return
        }
        guard draft.dailyLimit > 0 else {
            showOperationAlert(L10n.text(.dailyLimitInvalid, language: language))
            return
        }
        guard (1...99).contains(draft.switchPercent) else {
            showOperationAlert(L10n.text(.thresholdInvalid, language: language))
            return
        }
        if draft.isNew && token.isEmpty {
            showOperationAlert(L10n.text(.tokenRequired, language: language))
            return
        }
        let config = AccountConfig(
            id: draft.id,
            name: draft.name,
            accountID: draft.accountID,
            dailyLimit: draft.dailyLimit,
            switchThreshold: Double(draft.switchPercent) / 100,
            enabled: draft.enabled
        )
        var next = stored
        if let index = next.accounts.firstIndex(where: { $0.id == config.id }) {
            next.accounts[index] = config
        } else {
            next.accounts.append(config)
        }
        let cleanupWarning: String?
        do {
            cleanupWarning = try store.saveAccountChange(next, accountID: config.id, token: token.isEmpty ? nil : token)
        } catch {
            let message = L10n.format(.configurationNotSaved, error.localizedDescription, language: stored.language)
            if error is AccountTransactionError {
                credentialRecoveryErrors[config.id] = message
                configurationChanged(invalidating: config.id)
            }
            showOperationAlert(message)
            return
        }
        stored = next
        credentialRecoveryErrors[config.id] = nil
        self.draft = nil
        showOperationAlert(cleanupWarning)
        configurationChanged(invalidating: config.id)
        Task { await refresh() }
    }

    func delete(_ id: UUID) {
        guard allowConfigurationWrite() else { return }
        guard stored.accounts.contains(where: { $0.id == id }) else { return }
        var next = stored
        next.accounts.removeAll { $0.id == id }
        guard persist(next) else { return }
        stored = next
        credentialRecoveryErrors[id] = nil
        configurationChanged(invalidating: id)
        do {
            try store.tokens.deleteToken(for: id)
        } catch {
            showOperationAlert(L10n.format(.tokenCleanupFailed, error.localizedDescription, language: stored.language))
        }
    }

    func setEnabled(_ enabled: Bool, id: UUID) {
        guard allowConfigurationWrite() else { return }
        guard let index = stored.accounts.firstIndex(where: { $0.id == id }) else { return }
        guard stored.accounts[index].enabled != enabled else { return }
        var next = stored
        next.accounts[index].enabled = enabled
        guard persist(next) else { return }
        stored = next
        configurationChanged(invalidating: id)
        Task { await refresh() }
    }

    func setLanguage(_ language: AppLanguage) {
        guard allowConfigurationWrite(), stored.language != language else { return }
        var next = stored
        next.language = language
        guard persist(next) else { return }
        stored = next
    }

    func setAppearance(_ appearance: AppAppearance) {
        guard allowConfigurationWrite(), stored.appearance != appearance else { return }
        var next = stored
        next.appearance = appearance
        guard persist(next) else { return }
        stored = next
        AppAppearanceController.apply(appearance)
    }

    func setShowMenuBar(_ shown: Bool) {
        guard allowConfigurationWrite() else { return }
        guard stored.showMenuBar != shown else { return }
        var next = stored
        next.showMenuBar = shown
        guard persist(next) else { return }
        stored = next
        onMenuTitleChange?()
    }

    func setRefreshMinutes(_ minutes: Int) {
        guard allowConfigurationWrite() else { return }
        let minutes = min(120, max(1, minutes))
        guard minutes != stored.refreshMinutes else { return }
        var next = stored
        next.refreshMinutes = minutes
        guard persist(next) else { return }
        stored = next
        if !isRefreshing { scheduleNextRefresh() }
    }

    private func configurationChanged(invalidating id: UUID) {
        configurationVersion += 1
        usages[id] = nil
        if isRefreshing { refreshPending = true }
        writeStatus()
        onMenuTitleChange?()
    }

    private func allowConfigurationWrite() -> Bool {
        guard let configurationLoadError else { return true }
        showOperationAlert(configurationLoadError)
        return false
    }

    @discardableResult
    private func persist(_ next: StoredAccounts? = nil) -> Bool {
        guard allowConfigurationWrite() else { return false }
        do {
            try store.save(next ?? stored)
            return true
        } catch {
            showOperationAlert(L10n.format(.configurationNotSaved, error.localizedDescription, language: stored.language))
            return false
        }
    }

    private func showOperationAlert(_ message: String?) {
        let messages = [message, statusPublicationError].compactMap { $0 }
        alertMessage = messages.isEmpty ? nil : messages.joined(separator: "\n")
    }

    private func setStatusPublicationError(_ message: String?) {
        let previous = statusPublicationError
        guard previous != message else { return }
        statusPublicationError = message
        if let previous, let alert = alertMessage {
            if alert == previous { alertMessage = nil }
            else if alert.hasSuffix("\n" + previous) {
                alertMessage = String(alert.dropLast(previous.count + 1))
            }
        }
        if let message {
            alertMessage = [alertMessage, message].compactMap { $0 }.joined(separator: "\n")
        }
        onMenuTitleChange?()
    }

    private func cancelStatusRetry() {
        statusRetryVersion += 1
        statusRetryTask?.cancel()
        statusRetryTask = nil
    }

    private func scheduleStatusRetry() {
        guard statusRetriesEnabled, statusRetryTask == nil else { return }
        let version = statusRetryVersion
        let sleep = statusRetrySleep
        statusRetryTask = Task { [weak self] in
            defer { self?.finishStatusRetry(version: version) }
            var seconds = 1
            while !Task.isCancelled {
                guard self?.statusRetryVersion == version else { return }
                do { try await sleep(.seconds(seconds)) } catch { return }
                guard !Task.isCancelled,
                      self?.retryStatusPublication(version: version) == true else { return }
                seconds = min(60, seconds * 2)
            }
        }
    }

    private func finishStatusRetry(version: Int) {
        if version == statusRetryVersion { statusRetryTask = nil }
    }

    private func retryStatusPublication(version: Int) -> Bool {
        guard statusRetriesEnabled, statusRetryVersion == version,
              statusPublicationError != nil else { return false }
        // Rebuild from the current configuration, usage, and UTC day; never replay an old status.
        writeStatus()
        return statusRetriesEnabled && statusRetryVersion == version && statusPublicationError != nil
    }

    private func writeStatus(at date: Date? = nil) {
        let now = date ?? currentDate()
        let accounts = configurationLoadError == nil ? snapshots(at: now) : []
        let status = UsageMath.status(accounts: accounts, now: now)
        do {
            try statusWriter(status, statusURL)
            cancelStatusRetry()
            setStatusPublicationError(nil)
        } catch {
            let writeError = error
            // unlink cannot recursively delete a directory if this path is unexpected.
            let result = unlink(statusURL.path)
            let removalCode = errno
            let message: String
            if result == 0 || removalCode == ENOENT {
                message = L10n.format(.statusNotWritten, writeError.localizedDescription, language: stored.language)
            } else {
                let removalError = POSIXError(POSIXErrorCode(rawValue: removalCode) ?? .EIO)
                message = L10n.format(.statusInvalidationFailed, writeError.localizedDescription, removalError.localizedDescription, language: stored.language)
            }
            setStatusPublicationError(message)
            scheduleStatusRetry()
        }
    }

}

struct ValidationError: LocalizedError {
    var message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? { message }
}
