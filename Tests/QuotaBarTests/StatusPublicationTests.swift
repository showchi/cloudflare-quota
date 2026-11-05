import Foundation
import Darwin
import XCTest
@testable import QuotaCore
@testable import QuotaBar

final class StatusPublicationTests: XCTestCase {
    @MainActor
    func testFreshRecommendationIsRemovedAfterDeleteDisableEditOrFailedRefresh() async throws {
        for action in ["delete", "disable", "edit", "failed-refresh"] {
            let root = temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let account = AccountConfig(name: "home", accountID: "acc")
            let tokens = MemoryTokenStore([account.id: "original-token"])
            let store = AccountStore(fileURL: root.appendingPathComponent("accounts.json"), tokens: tokens)
            try store.save(StoredAccounts(accounts: [account], language: .chinese))
            let statusURL = root.appendingPathComponent("status.json")
            let now = ISO8601DateFormatter().date(from: "2026-11-05T09:00:00Z")!
            var calls = 0
            var networkFails = false
            PublicationURLProtocol.respond = {
                calls += 1
                return networkFails ? (403, Data()) : (200, Self.usageBody)
            }
            let sleeper = PublicationSleeper()
            var attempts = 0
            var writesFail = false
            let model = AppModel(store: store, api: makeAPI(), statusURL: statusURL, currentDate: { now }, statusWriter: { status, url in
                attempts += 1
                if writesFail { throw CocoaError(.fileWriteOutOfSpace) }
                try StatusFile.write(status, to: url)
            }, statusRetrySleep: { await sleeper.sleep($0) })
            defer { model.stop(); sleeper.finishAll(); PublicationURLProtocol.respond = nil }
            await model.refresh()
            let original = try readStatus(statusURL)
            XCTAssertEqual(original.suggestedAccountID, account.id)
            XCTAssertEqual(original.generatedAt, now)
            XCTAssertGreaterThan(original.resetsAt, now)
            writesFail = true
            switch action {
            case "delete": model.delete(account.id)
            case "disable": model.setEnabled(false, id: account.id)
            case "edit":
                model.draft = AccountDraft(id: account.id, isNew: false, name: "edited", accountID: "new-id", token: "", dailyLimit: 100_000, switchPercent: 75, enabled: false)
                model.saveDraft()
            default:
                networkFails = true
                await model.refresh()
                XCTAssertNotNil(model.usages[account.id]?.error)
            }
            if action == "disable" || action == "edit" {
                await waitUntil { attempts >= 3 && !model.isRefreshing }
            }
            await waitUntil { sleeper.delays.count == 1 }
            XCTAssertFalse(FileManager.default.fileExists(atPath: statusURL.path), action)
            XCTAssertNil(model.suggestedAccountID, action)
            XCTAssertNotNil(model.statusPublicationError, action)
            XCTAssertEqual(model.menuTitle, "!")
            let persisted = try store.load()
            if action == "delete" {
                XCTAssertTrue(persisted.accounts.isEmpty)
                XCTAssertNil(try tokens.token(for: account.id))
            } else {
                XCTAssertEqual(try tokens.token(for: account.id), "original-token")
                if action == "disable" || action == "edit" {
                    XCTAssertFalse(persisted.accounts[0].enabled)
                }
                if action == "edit" { XCTAssertEqual(persisted.accounts[0].accountID, "new-id") }
            }
            XCTAssertEqual(calls, action == "failed-refresh" ? 2 : 1)
        }
    }

    @MainActor
    func testRetryUsesLatestAccountStateAndDateWithoutFetchingCloudflare() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = AccountConfig(name: "first", accountID: "one")
        let second = AccountConfig(name: "second", accountID: "two")
        let tokens = MemoryTokenStore([first.id: "first-token", second.id: "second-token"])
        let store = AccountStore(fileURL: root.appendingPathComponent("accounts.json"), tokens: tokens)
        try store.save(StoredAccounts(accounts: [first, second]))
        let statusURL = root.appendingPathComponent("status.json")
        var now = ISO8601DateFormatter().date(from: "2026-11-05T09:00:00Z")!
        var calls = 0
        PublicationURLProtocol.respond = { calls += 1; return (200, Self.usageBody) }
        let sleeper = PublicationSleeper()
        var writesFail = false
        var attempts = 0
        let model = AppModel(store: store, api: makeAPI(), statusURL: statusURL, currentDate: { now }, statusWriter: { status, url in
            attempts += 1
            if writesFail { throw CocoaError(.fileWriteOutOfSpace) }
            try StatusFile.write(status, to: url)
        }, statusRetrySleep: { await sleeper.sleep($0) })
        defer { model.stop(); sleeper.finishAll(); PublicationURLProtocol.respond = nil }
        await model.refresh()
        XCTAssertEqual(calls, 2)
        writesFail = true
        model.delete(first.id) // The failed candidate would still recommend the second account.
        await waitUntil { sleeper.delays.count == 1 }
        model.setEnabled(false, id: second.id)
        await waitUntil { attempts >= 4 && !model.isRefreshing }
        let requestsBeforeRetry = calls
        now = now.addingTimeInterval(86_400)
        writesFail = false
        sleeper.finish(0)
        await waitUntil { model.statusPublicationError == nil }
        let published = try readStatus(statusURL)
        XCTAssertNil(published.suggestedAccountID)
        XCTAssertEqual(published.generatedAt, now)
        XCTAssertEqual(published.resetsAt, UsageMath.utcDayBounds(containing: now).end)
        XCTAssertEqual(published.accounts.map(\.config.id), [second.id])
        XCTAssertFalse(published.accounts[0].config.enabled)
        XCTAssertEqual(calls, requestsBeforeRetry)
        XCTAssertEqual(try store.load().accounts, model.stored.accounts)
    }

    @MainActor
    func testRetriesBackOffAndStopRejectsLateWakeup() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AccountStore(fileURL: root.appendingPathComponent("accounts.json"), tokens: MemoryTokenStore())
        let sleeper = PublicationSleeper()
        var attempts = 0
        let model = AppModel(store: store, statusURL: root.appendingPathComponent("status.json"), statusWriter: { _, _ in
            attempts += 1
            throw CocoaError(.fileWriteOutOfSpace)
        }, statusRetrySleep: { await sleeper.sleep($0) })
        defer { model.stop(); sleeper.finishAll() }
        await model.refresh()
        await waitUntil { sleeper.delays.count == 1 }
        for index in 0..<7 {
            sleeper.finish(index)
            await waitUntil { sleeper.delays.count == index + 2 }
        }
        XCTAssertEqual(sleeper.delays, [1, 2, 4, 8, 16, 32, 60, 60].map { .seconds($0) })
        let beforeStop = attempts
        model.stop()
        sleeper.finish(7)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(attempts, beforeStop)
        XCTAssertEqual(sleeper.delays.count, 8)
    }

    @MainActor
    func testSuccessfulPublicationCancelsRetryAndClearsPersistentWarning() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AccountStore(fileURL: root.appendingPathComponent("accounts.json"), tokens: MemoryTokenStore())
        let sleeper = PublicationSleeper()
        var attempts = 0
        var writesFail = true
        let model = AppModel(store: store, statusURL: root.appendingPathComponent("status.json"), statusWriter: { status, url in
            attempts += 1
            if writesFail { throw CocoaError(.fileWriteOutOfSpace) }
            try StatusFile.write(status, to: url)
        }, statusRetrySleep: { await sleeper.sleep($0) })
        defer { model.stop(); sleeper.finishAll() }
        await model.refresh()
        await waitUntil { sleeper.delays.count == 1 }
        model.alertMessage = nil // Acknowledging the dialog must not hide the persistent error.
        XCTAssertNotNil(model.statusPublicationError)
        XCTAssertEqual(model.menuTitle, "!")
        writesFail = false
        await model.refresh()
        XCTAssertNil(model.statusPublicationError)
        XCTAssertNil(model.alertMessage)
        XCTAssertEqual(model.menuTitle, "Quota")
        let successfulAttempts = attempts
        sleeper.finish(0)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(attempts, successfulAttempts)
        XCTAssertEqual(sleeper.delays.count, 1)
    }

    @MainActor
    func testPendingRetryDoesNotRetainModelOrPublishAfterDeallocation() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AccountStore(fileURL: root.appendingPathComponent("accounts.json"), tokens: MemoryTokenStore())
        let sleeper = PublicationSleeper()
        defer { sleeper.finishAll() }
        var attempts = 0
        var model: AppModel? = AppModel(store: store, statusURL: root.appendingPathComponent("status.json"), statusWriter: { _, _ in
            attempts += 1
            throw CocoaError(.fileWriteOutOfSpace)
        }, statusRetrySleep: { await sleeper.sleep($0) })
        await model?.refresh()
        await waitUntil { sleeper.delays.count == 1 }
        weak var reference = model
        model = nil
        XCTAssertNil(reference)
        let previousAttempts = attempts
        sleeper.finish(0)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(attempts, previousAttempts)
    }

    @MainActor
    func testRemovalFailureIsNotHiddenByTokenCleanupFailure() async throws {
        guard geteuid() != 0 else { throw XCTSkip("Requires an unprivileged user") }
        let root = temporaryDirectory()
        let statusDirectory = root.appendingPathComponent("status")
        try FileManager.default.createDirectory(at: statusDirectory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: statusDirectory.path)
            try? FileManager.default.removeItem(at: root)
        }
        let account = AccountConfig(name: "home", accountID: "acc")
        let tokens = CleanupFailingPublicationTokens(id: account.id)
        let store = AccountStore(fileURL: root.appendingPathComponent("accounts.json"), tokens: tokens)
        try store.save(StoredAccounts(accounts: [account], language: .chinese))
        let statusURL = statusDirectory.appendingPathComponent("status.json")
        let now = Date()
        let snapshot = AccountSnapshot(config: account, usage: AccountUsage(accountID: account.id, requests: 10, fetchedAt: now))
        try StatusFile.write(UsageMath.status(accounts: [snapshot], now: now), to: statusURL)
        let original = try Data(contentsOf: statusURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: statusDirectory.path)
        let sleeper = PublicationSleeper()
        var writesFail = true
        let model = AppModel(store: store, statusURL: statusURL, statusWriter: { status, url in
            if writesFail { throw CocoaError(.fileWriteOutOfSpace) }
            try StatusFile.write(status, to: url)
        }, statusRetrySleep: { await sleeper.sleep($0) })
        defer { model.stop(); sleeper.finishAll() }
        model.delete(account.id)
        await waitUntil { sleeper.delays.count == 1 }
        XCTAssertTrue(try store.load().accounts.isEmpty)
        XCTAssertEqual(try Data(contentsOf: statusURL), original)
        let publicationError = try XCTUnwrap(model.statusPublicationError)
        XCTAssertTrue(publicationError.contains("无法使旧推荐失效"))
        XCTAssertTrue(model.alertMessage?.contains("Token 清理失败") == true)
        XCTAssertTrue(model.alertMessage?.contains(publicationError) == true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: statusDirectory.path)
        writesFail = false
        sleeper.finish(0)
        await waitUntil { model.statusPublicationError == nil }
        XCTAssertNil(try readStatus(statusURL).suggestedAccountID)
        XCTAssertTrue(model.alertMessage?.contains("Token 清理失败") == true)
        XCTAssertFalse(model.alertMessage?.contains(publicationError) == true)
    }

    private static let usageBody = Data(#"{"data":{"viewer":{"accounts":[{"workersInvocationsAdaptive":[{"sum":{"requests":10},"dimensions":{"scriptName":"worker"}}],"pagesFunctionsInvocationsAdaptiveGroups":[]}]}}}"#.utf8)

    private func makeAPI() -> CloudflareAPI {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PublicationURLProtocol.self]
        return CloudflareAPI(session: URLSession(configuration: configuration), graphqlURL: URL(string: "https://example.test/graphql")!)
    }
    private func temporaryDirectory() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }
    private func readStatus(_ url: URL) throws -> QuotaStatus {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(QuotaStatus.self, from: Data(contentsOf: url))
    }
    @MainActor private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<1000 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(1))
        }
        XCTFail("Timed out waiting for status publication")
    }
}

@MainActor
private final class PublicationSleeper {
    var delays: [Duration] = []
    private var pending: [Int: CheckedContinuation<Void, Never>] = [:]
    func sleep(_ duration: Duration) async {
        let index = delays.count
        delays.append(duration)
        await withCheckedContinuation { pending[index] = $0 }
    }
    func finish(_ index: Int) { pending.removeValue(forKey: index)?.resume() }
    func finishAll() {
        let continuations = Array(pending.values)
        pending.removeAll()
        for continuation in continuations { continuation.resume() }
    }
}

private final class PublicationURLProtocol: URLProtocol, @unchecked Sendable {
    @MainActor static var respond: (() -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Task { @MainActor in
            guard let respond = Self.respond else {
                client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                return
            }
            let (code, data) = respond()
            let response = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {}
}

private final class CleanupFailingPublicationTokens: TokenStoring, @unchecked Sendable {
    let id: UUID
    init(id: UUID) { self.id = id }
    func token(for accountID: UUID) throws -> String? { accountID == id ? "original-token" : nil }
    func save(token: String, for accountID: UUID) throws {}
    func deleteToken(for accountID: UUID) throws { throw CocoaError(.fileWriteNoPermission) }
}
