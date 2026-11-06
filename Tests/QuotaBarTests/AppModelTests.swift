import XCTest
import Darwin
@testable import QuotaCore
@testable import QuotaBar

final class AppModelTests: XCTestCase {
    @MainActor
    func testFailedAccountSaveKeepsDraftAndRestoresCredentials() async throws {
        guard geteuid() != 0 else { throw XCTSkip("Permission failure requires an unprivileged user") }
        for isNew in [false, true] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer {
                try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
                try? FileManager.default.removeItem(at: directory)
            }
            let account = AccountConfig(name: "old", accountID: "old-id", enabled: false)
            let tokens = MemoryTokenStore(isNew ? [:] : [account.id: "old-token"])
            let store = AccountStore(fileURL: directory.appendingPathComponent("accounts.json"), tokens: tokens)
            let original = StoredAccounts(accounts: isNew ? [] : [account], language: .chinese)
            try store.save(original)
            let statusURL = directory.appendingPathComponent("status.json")
            let statusData = Data("unchanged status".utf8)
            try statusData.write(to: statusURL)
            let model = AppModel(store: store, statusURL: statusURL)
            let draft = AccountDraft(id: account.id, isNew: isNew, name: "new", accountID: "new-id", token: "new-token", dailyLimit: 100_000, switchPercent: 75, enabled: false)
            model.draft = draft
            let usage = AccountUsage(accountID: account.id, requests: 12, fetchedAt: Date())
            model.usages[account.id] = usage
            var notifications = 0
            model.onMenuTitleChange = { notifications += 1 }
            try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
            model.saveDraft()
            await Task.yield()
            XCTAssertEqual(model.draft, draft)
            XCTAssertEqual(model.stored, original)
            XCTAssertEqual(try store.load(), original)
            XCTAssertEqual(try tokens.token(for: account.id), isNew ? nil : "old-token")
            XCTAssertEqual(model.usages[account.id], usage)
            XCTAssertEqual(try Data(contentsOf: statusURL), statusData)
            XCTAssertEqual(notifications, 0)
            XCTAssertTrue(model.alertMessage?.contains("配置没有保存") == true)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            model.saveDraft()
            await waitUntil { model.usages.isEmpty }
            XCTAssertNil(model.draft)
            XCTAssertEqual(try store.load().accounts.first?.accountID, "new-id")
            XCTAssertEqual(try tokens.token(for: account.id), "new-token")
        }
    }

    @MainActor
    func testFailedCredentialRollbackIsReportedAndDraftRemainsOpen() async throws {
        guard geteuid() != 0 else { throw XCTSkip("Permission failure requires an unprivileged user") }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            try? FileManager.default.removeItem(at: directory)
        }
        let account = AccountConfig(name: "old", accountID: "old-id", enabled: true)
        let tokens = DeleteCheckingTokenStore(id: account.id)
        var store = AccountStore(fileURL: directory.appendingPathComponent("accounts.json"), tokens: tokens)
        try store.save(StoredAccounts(accounts: [account], language: .chinese))
        store.accountChangeCheckpoint = { stage in
            if stage == .tokenWritten {
                try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
            }
        }
        let model = AppModel(store: store, statusURL: directory.appendingPathComponent("status.json"))
        model.draft = AccountDraft(id: account.id, isNew: false, name: "new", accountID: "new-id", token: "new-token", dailyLimit: 100_000, switchPercent: 75, enabled: false)
        tokens.failRestoration = true
        model.saveDraft()
        XCTAssertNotNil(model.draft)
        XCTAssertTrue(model.alertMessage?.contains("恢复失败") == true)
        XCTAssertEqual(try store.decoder.decode(StoredAccounts.self, from: Data(contentsOf: store.fileURL)).accounts.first?.accountID, "old-id")
        XCTAssertThrowsError(try store.load())
        await model.refresh()
        XCTAssertNil(model.suggestedAccountID)
        XCTAssertEqual(model.menuTitle, "!")
        XCTAssertTrue(model.usages[account.id]?.error?.contains("恢复失败") == true)
    }

    @MainActor
    func testSuccessfulSavePreservesStatusWriteError() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let account = AccountConfig(name: "old", accountID: "acc", enabled: false)
        let store = AccountStore(fileURL: directory.appendingPathComponent("accounts.json"), tokens: MemoryTokenStore())
        try store.save(StoredAccounts(accounts: [account], language: .chinese))
        // A directory cannot be replaced with the status JSON file.
        let model = AppModel(store: store, statusURL: directory)
        defer { model.stop() }
        model.draft = AccountDraft(id: account.id, isNew: false, name: "new", accountID: "acc", token: "", dailyLimit: 100_000, switchPercent: 75, enabled: false)
        model.saveDraft()
        XCTAssertNil(model.draft)
        XCTAssertEqual(try store.load().accounts.first?.name, "new")
        XCTAssertNotNil(model.statusPublicationError)
        XCTAssertEqual(model.alertMessage, model.statusPublicationError)
        XCTAssertTrue(model.statusPublicationError?.contains("无法使旧推荐失效") == true)
        for _ in 0..<20 { await Task.yield() }
    }

    @MainActor
    func testFailedSettingsSavePreservesStateAndTimer() async throws {
        guard geteuid() != 0 else { throw XCTSkip("Permission failure requires an unprivileged user") }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            try? FileManager.default.removeItem(at: directory)
        }
        let account = AccountConfig(name: "home", accountID: "acc", enabled: false)
        let store = AccountStore(fileURL: directory.appendingPathComponent("accounts.json"), tokens: MemoryTokenStore())
        let original = StoredAccounts(accounts: [account], language: .chinese)
        try store.save(original)
        let sleeper = ControlledSleeper()
        let statusURL = directory.appendingPathComponent("status.json")
        let model = AppModel(store: store, statusURL: statusURL, currentDate: { Date(timeIntervalSince1970: 0) }, sleep: { try await sleeper.sleep($0) })
        defer { model.stop(); sleeper.finishAll() }
        model.start()
        await waitUntil { sleeper.delays.count == 1 }
        let status = try Data(contentsOf: statusURL)
        var notifications = 0
        model.onMenuTitleChange = { notifications += 1 }
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        model.setEnabled(true, id: account.id)
        model.setShowMenuBar(false)
        model.setRefreshMinutes(1)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(model.stored, original)
        XCTAssertEqual(try store.load(), original)
        XCTAssertEqual(try Data(contentsOf: statusURL), status)
        XCTAssertEqual(notifications, 0)
        XCTAssertEqual(sleeper.delays, [.seconds(600)])
        XCTAssertTrue(model.alertMessage?.contains("配置没有保存") == true)
    }

    @MainActor
    func testDeletePreservesAccountAndTokenWhenSavingFails() throws {
        guard geteuid() != 0 else { throw XCTSkip("Permission failure requires an unprivileged user") }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            try? FileManager.default.removeItem(at: directory)
        }
        let account = AccountConfig(name: "home", accountID: "acc")
        let tokens = MemoryTokenStore([account.id: "original-token"])
        let store = AccountStore(fileURL: directory.appendingPathComponent("accounts.json"), tokens: tokens)
        let original = StoredAccounts(accounts: [account], language: .chinese)
        try store.save(original)
        let originalFile = try Data(contentsOf: store.fileURL)
        let statusURL = directory.appendingPathComponent("status.json")
        let originalStatus = Data("unchanged status".utf8)
        try originalStatus.write(to: statusURL)
        let model = AppModel(store: store, statusURL: statusURL)
        let usage = AccountUsage(accountID: account.id, requests: 123, fetchedAt: Date())
        model.usages[account.id] = usage
        var notifications = 0
        model.onMenuTitleChange = { notifications += 1 }
        // Config reads remain possible, but atomic replacement is denied; tokens remain writable.
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        model.delete(account.id)
        XCTAssertEqual(model.stored, original)
        XCTAssertEqual(model.usages[account.id], usage)
        XCTAssertEqual(try tokens.token(for: account.id), "original-token")
        XCTAssertEqual(try Data(contentsOf: store.fileURL), originalFile)
        XCTAssertEqual(try Data(contentsOf: statusURL), originalStatus)
        XCTAssertEqual(notifications, 0)
        XCTAssertTrue(model.alertMessage?.contains("配置没有保存") == true)
        XCTAssertEqual(AppModel(store: store, statusURL: statusURL).stored, original)
    }

    @MainActor
    func testDeleteSavesConfigurationBeforeTokenCleanupAndReportsCleanupFailure() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let account = AccountConfig(name: "home", accountID: "acc")
        let tokens = DeleteCheckingTokenStore(id: account.id)
        let fileURL = directory.appendingPathComponent("accounts.json")
        let store = AccountStore(fileURL: fileURL, tokens: tokens)
        try store.save(StoredAccounts(accounts: [account], language: .chinese))
        let model = AppModel(store: store, statusURL: directory.appendingPathComponent("status.json"))
        tokens.beforeDelete = {
            let reader = AccountStore(fileURL: fileURL, tokens: MemoryTokenStore())
            XCTAssertTrue(try reader.load().accounts.isEmpty)
        }
        tokens.failDeletion = true
        model.delete(account.id)
        XCTAssertTrue(model.stored.accounts.isEmpty)
        XCTAssertTrue(try store.load().accounts.isEmpty)
        XCTAssertTrue(tokens.attemptedDeletion)
        XCTAssertEqual(try tokens.token(for: account.id), "original-token")
        XCTAssertTrue(model.alertMessage?.contains("Token 清理失败") == true)
    }

    @MainActor
    func testCorruptConfigurationBlocksWritesUntilSuccessfulRestart() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("accounts.json")
        let original = Data("{corrupt configuration".utf8)
        try original.write(to: fileURL)
        let id = UUID()
        let tokens = MemoryTokenStore([id: "original-token"])
        let store = AccountStore(fileURL: fileURL, tokens: tokens)
        let statusURL = directory.appendingPathComponent("status.json")
        let previousDate = ISO8601DateFormatter().date(from: "2026-11-04T23:59:00Z")!
        let now = previousDate.addingTimeInterval(120)
        let snapshot = AccountSnapshot(
            config: AccountConfig(id: id, name: "previous", accountID: "old"),
            usage: AccountUsage(accountID: id, requests: 10, fetchedAt: previousDate)
        )
        let previousStatus = UsageMath.status(accounts: [snapshot], now: previousDate)
        XCTAssertEqual(previousStatus.suggestedAccountID, id)
        try StatusFile.write(previousStatus, to: statusURL)
        let model = AppModel(store: store, statusURL: statusURL, currentDate: { now })
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let invalidated = try decoder.decode(QuotaStatus.self, from: Data(contentsOf: statusURL))
        XCTAssertNil(invalidated.suggestedAccountID)
        XCTAssertTrue(invalidated.accounts.isEmpty)
        XCTAssertEqual(invalidated.generatedAt, now)
        XCTAssertEqual(invalidated.resetsAt, UsageMath.utcDayBounds(containing: now).end)
        XCTAssertNotNil(model.configurationLoadError)
        XCTAssertNotNil(model.alertMessage)
        XCTAssertEqual(model.menuTitle, "!")
        let defaults = model.stored
        model.alertMessage = nil
        model.setRefreshMinutes(1)
        model.setShowMenuBar(false)
        model.delete(id)
        model.setEnabled(false, id: id)
        let draftID = UUID()
        model.draft = AccountDraft(id: draftID, isNew: true, name: "new", accountID: "new", token: "new-token", dailyLimit: 100_000, switchPercent: 75, enabled: true)
        model.saveDraft()
        await model.refresh()
        XCTAssertEqual(model.stored, defaults)
        XCTAssertNotNil(model.alertMessage)
        XCTAssertEqual(try Data(contentsOf: fileURL), original)
        XCTAssertEqual(try decoder.decode(QuotaStatus.self, from: Data(contentsOf: statusURL)), invalidated)
        XCTAssertEqual(try tokens.token(for: id), "original-token")
        XCTAssertNil(try tokens.token(for: draftID))
        // Recovery requires a successful load; dismissing the alert cannot unlock writes.
        let account = AccountConfig(id: id, name: "recovered", accountID: "acc")
        try store.save(StoredAccounts(accounts: [account]))
        let recovered = AppModel(store: store, statusURL: statusURL)
        XCTAssertNil(recovered.configurationLoadError)
        recovered.setRefreshMinutes(1)
        XCTAssertEqual(try store.load().accounts, [account])
        XCTAssertEqual(try store.load().refreshMinutes, 1)
    }

    @MainActor
    func testIntervalChangeReplacesExistingWait() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AccountStore(fileURL: directory.appendingPathComponent("accounts.json"), tokens: MemoryTokenStore())
        try store.save(StoredAccounts(refreshMinutes: 120))
        let sleeper = ControlledSleeper()
        let model = AppModel(store: store, statusURL: directory.appendingPathComponent("status.json"), currentDate: { Date(timeIntervalSince1970: 0) }, sleep: { try await sleeper.sleep($0) })
        defer { model.stop(); sleeper.finishAll() }
        var commits = 0
        model.onMenuTitleChange = { commits += 1 }
        model.start()
        model.start()
        await waitUntil { sleeper.delays.count == 1 }
        XCTAssertEqual(sleeper.delays, [.seconds(7200)])
        model.setRefreshMinutes(1)
        await waitUntil { sleeper.delays.count == 2 }
        XCTAssertEqual(sleeper.delays.last, .seconds(60))
        XCTAssertEqual(try store.load().refreshMinutes, 1)
        model.setRefreshMinutes(1)
        sleeper.finish(0) // Even a cancelled wait completing late must not refresh.
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(commits, 1)
        XCTAssertEqual(sleeper.delays.count, 2)
        sleeper.finish(1)
        await waitUntil { sleeper.delays.count == 3 }
        XCTAssertEqual(commits, 2)
        model.setRefreshMinutes(120)
        await waitUntil { sleeper.delays.count == 4 }
        XCTAssertEqual(sleeper.delays.last, .seconds(7200))
    }

    @MainActor
    func testMidnightDiscardsOldWindowAndCommitsNewDay() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let tokens = MemoryTokenStore()
        let store = AccountStore(fileURL: directory.appendingPathComponent("accounts.json"), tokens: tokens)
        let config = AccountConfig(name: "home", accountID: "acc")
        try tokens.save(token: "token", for: config.id)
        try store.save(StoredAccounts(accounts: [config], refreshMinutes: 120))
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [ModelURLProtocol.self]
        var now = ISO8601DateFormatter().date(from: "2026-11-03T23:59:59Z")!
        let midnight = ISO8601DateFormatter().date(from: "2026-11-04T00:00:00Z")!
        let statusURL = directory.appendingPathComponent("status.json")
        let sleeper = ControlledSleeper()
        let model = AppModel(store: store, api: CloudflareAPI(session: URLSession(configuration: sessionConfig)), statusURL: statusURL, currentDate: { now }, sleep: { try await sleeper.sleep($0) })
        var windows: [String] = []
        var commits = 0
        model.onMenuTitleChange = { commits += 1 }
        ModelURLProtocol.respond = { request in
            let body = Self.requestBody(request)
            let json = try! JSONSerialization.jsonObject(with: body) as! [String: Any]
            let variables = json["variables"] as! [String: String]
            windows.append(variables["start"]!)
            if windows.count == 1 {
                now = midnight
                model.setRefreshMinutes(1) // Changing the interval must not cancel this fetch.
            } else {
                XCTAssertNil(model.usages[config.id])
                XCTAssertEqual(commits, 0)
                XCTAssertFalse(FileManager.default.fileExists(atPath: statusURL.path))
            }
            let count = windows.count == 1 ? 100_000 : 12
            return "{\"data\":{\"viewer\":{\"accounts\":[{\"workersInvocationsAdaptive\":[{\"sum\":{\"requests\":\(count)}}],\"pagesFunctionsInvocationsAdaptiveGroups\":[]}]}}}"
        }
        defer { model.stop(); sleeper.finishAll(); ModelURLProtocol.respond = nil }
        model.start()
        await waitUntil { sleeper.delays.count == 1 }
        XCTAssertEqual(windows, ["2026-11-03T00:00:00Z", "2026-11-04T00:00:00Z"])
        XCTAssertEqual(sleeper.delays, [.seconds(60)])
        XCTAssertEqual(commits, 1)
        XCTAssertEqual(model.usages[config.id]?.requests, 12)
        XCTAssertEqual(model.lastRefreshedAt, midnight)
        XCTAssertEqual(model.suggestedAccountID, config.id)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let status = try decoder.decode(QuotaStatus.self, from: Data(contentsOf: statusURL))
        XCTAssertEqual(status.generatedAt, midnight)
        XCTAssertEqual(status.resetsAt, midnight.addingTimeInterval(86_400))
        XCTAssertEqual(status.accounts.first?.usage?.requests, 12)
        XCTAssertEqual(status.suggestedAccountID, config.id)
    }

    @MainActor
    func testCachedUsageExpiresAtMidnightBeforeRefreshCompletes() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let tokens = MemoryTokenStore()
        let store = AccountStore(fileURL: directory.appendingPathComponent("accounts.json"), tokens: tokens)
        let account = AccountConfig(name: "home", accountID: "acc")
        let other = AccountConfig(name: "other", accountID: "other", enabled: false)
        try tokens.save(token: "token", for: account.id)
        try store.save(StoredAccounts(accounts: [account, other], refreshMinutes: 120))
        let session = URLSessionConfiguration.ephemeral
        session.protocolClasses = [ModelURLProtocol.self]
        var now = ISO8601DateFormatter().date(from: "2026-11-03T23:59:00Z")!
        let sleeper = ControlledSleeper()
        let statusURL = directory.appendingPathComponent("status.json")
        let model = AppModel(store: store, api: CloudflareAPI(session: URLSession(configuration: session)), statusURL: statusURL, currentDate: { now }, sleep: { try await sleeper.sleep($0) })
        var requests = 0
        ModelURLProtocol.respond = { _ in
            requests += 1
            if requests == 2 {
                XCTAssertTrue(model.usages.isEmpty)
                XCTAssertTrue(model.snapshots.allSatisfy { $0.usage == nil })
                XCTAssertNil(model.suggestedAccountID)
                XCTAssertEqual(model.menuTitle, "—")
            }
            return #"{"data":{"viewer":{"accounts":[{"workersInvocationsAdaptive":[{"sum":{"requests":12}}],"pagesFunctionsInvocationsAdaptiveGroups":[]}]}}}"#
        }
        defer { model.stop(); sleeper.finishAll(); ModelURLProtocol.respond = nil }
        model.start()
        await waitUntil { sleeper.delays.count == 1 }
        XCTAssertEqual(sleeper.delays, [.seconds(60)])
        XCTAssertEqual(model.suggestedAccountID, account.id)
        now = now.addingTimeInterval(60)
        // A late timer must not allow old data into reads or an unrelated configuration write.
        XCTAssertNil(model.suggestedAccountID)
        XCTAssertTrue(model.snapshots.allSatisfy { $0.usage == nil })
        model.delete(other.id)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let status = try decoder.decode(QuotaStatus.self, from: Data(contentsOf: statusURL))
        XCTAssertNil(status.suggestedAccountID)
        XCTAssertNil(status.accounts.first?.usage)
        sleeper.finish(0)
        await waitUntil { sleeper.delays.count == 2 }
        XCTAssertEqual(requests, 2)
        XCTAssertEqual(model.suggestedAccountID, account.id)
        XCTAssertEqual(sleeper.delays.last, .seconds(7200))
    }

    @MainActor
    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<1000 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(1))
        }
        XCTFail("Timed out waiting for asynchronous work")
    }

    private static func requestBody(_ request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(contentsOf: buffer.prefix(count))
        }
        return data
    }

    @MainActor
    func testConfigurationChangeDiscardsResolvedIDAndRefreshesAgain() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let tokens = MemoryTokenStore()
        let store = AccountStore(fileURL: directory.appendingPathComponent("accounts.json"), tokens: tokens)
        let config = AccountConfig(name: "original", accountID: "")
        try tokens.save(token: "old-token", for: config.id)
        try store.save(StoredAccounts(accounts: [config]))
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [ModelURLProtocol.self]
        let model = AppModel(store: store, api: CloudflareAPI(session: URLSession(configuration: sessionConfig)), statusURL: directory.appendingPathComponent("status.json"))
        var usageCalls = 0
        var notifications = 0
        model.onMenuTitleChange = { notifications += 1 }
        ModelURLProtocol.respond = { request in
            if request.url!.path.hasSuffix("accounts") {
                return #"{"success":true,"result":[{"id":"old-id","name":"Old"}]}"#
            }
            usageCalls += 1
            if usageCalls == 1 {
                model.beginEdit(config)
                model.draft?.accountID = "new-id"
                model.draft?.token = "new-token"
                model.saveDraft()
                XCTAssertNil(model.suggestedAccountID)
            } else {
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer new-token")
            }
            let count = usageCalls == 1 ? 999 : 12
            return "{\"data\":{\"viewer\":{\"accounts\":[{\"workersInvocationsAdaptive\":[{\"sum\":{\"requests\":\(count)}}],\"pagesFunctionsInvocationsAdaptiveGroups\":[]}]}}}"
        }
        defer { ModelURLProtocol.respond = nil }
        await model.refresh()
        XCTAssertEqual(usageCalls, 2)
        XCTAssertEqual(model.stored.accounts.first?.accountID, "new-id")
        XCTAssertEqual(model.usages[config.id]?.requests, 12)
        XCTAssertEqual(try store.load().accounts.first?.accountID, "new-id")
        let previousNotifications = notifications
        model.delete(config.id)
        XCTAssertEqual(notifications, previousNotifications + 1)
        XCTAssertEqual(model.menuTitle, "Quota")
        XCTAssertNil(model.suggestedAccountID)
    }
}

private final class ModelURLProtocol: URLProtocol, @unchecked Sendable {
    @MainActor static var respond: ((URLRequest) -> String)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Task { @MainActor in
            let body = Self.respond!(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {}
}

@MainActor
private final class ControlledSleeper {
    var delays: [Duration] = []
    private var continuations: [Int: CheckedContinuation<Void, Never>] = [:]

    func sleep(_ duration: Duration) async throws {
        let index = delays.count
        delays.append(duration)
        await withCheckedContinuation { continuations[index] = $0 }
    }

    func finish(_ index: Int) {
        continuations.removeValue(forKey: index)?.resume()
    }

    func finishAll() {
        let pending = Array(continuations.values)
        continuations.removeAll()
        for continuation in pending { continuation.resume() }
    }
}

private final class DeleteCheckingTokenStore: TokenStoring, @unchecked Sendable {
    private let id: UUID
    private var value: String? = "original-token"
    var beforeDelete: (() throws -> Void)?
    var failDeletion = false
    var failRestoration = false
    var attemptedDeletion = false

    init(id: UUID) { self.id = id }
    func token(for accountID: UUID) throws -> String? { accountID == id ? value : nil }
    func save(token: String, for accountID: UUID) throws {
        if failRestoration && token == "original-token" { throw CocoaError(.fileWriteNoPermission) }
        value = token
    }
    func deleteToken(for accountID: UUID) throws {
        attemptedDeletion = true
        try beforeDelete?()
        if failDeletion { throw CocoaError(.fileWriteNoPermission) }
        value = nil
    }
}
