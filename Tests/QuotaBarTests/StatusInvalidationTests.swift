import Foundation
import Darwin
import XCTest
@testable import QuotaCore
@testable import QuotaBar

final class StatusInvalidationTests: XCTestCase {
    @MainActor
    func testTransactionRecoveryFailureAlsoInvalidatesExportedRecommendation() async throws {
        guard geteuid() != 0 else { throw XCTSkip("Requires an unprivileged user") }
        struct Interrupted: Error {}
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let tokens = FileTokenStore(fileURL: root.appendingPathComponent("tokens.json"))
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tokens.fileURL.path)
            try? FileManager.default.removeItem(at: root)
        }
        var store = AccountStore(fileURL: root.appendingPathComponent("accounts.json"), tokens: tokens)
        let account = AccountConfig(name: "old", accountID: "old-id")
        let previous = StoredAccounts(accounts: [account])
        try store.save(previous)
        try tokens.save(token: "old-token", for: account.id)
        var changed = account
        changed.accountID = "new-id"
        store.accountChangeCheckpoint = { if $0 == .configurationWritten { throw Interrupted() } }
        XCTAssertThrowsError(try store.saveAccountChange(StoredAccounts(accounts: [changed]), accountID: account.id, token: "new-token"))
        let record = try Data(contentsOf: store.pendingAccountChangeURL)
        let tokenBytes = try Data(contentsOf: tokens.fileURL)
        let now = ISO8601DateFormatter().date(from: "2026-11-05T00:01:00Z")!
        let statusURL = root.appendingPathComponent("status.json")
        try seedRecommendedStatus(at: statusURL, id: account.id, date: now.addingTimeInterval(-120))
        // Configuration rollback succeeds, but restoring the token cannot read this file.
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: tokens.fileURL.path)
        let model = AppModel(store: store, statusURL: statusURL, currentDate: { now })
        XCTAssertNotNil(model.configurationLoadError)
        let configurationAfterRecoveryAttempt = try Data(contentsOf: store.fileURL)
        await model.refresh()
        let invalidated = try readStatus(statusURL)
        XCTAssertNil(invalidated.suggestedAccountID)
        XCTAssertTrue(invalidated.accounts.isEmpty)
        XCTAssertEqual(invalidated.generatedAt, now)
        XCTAssertEqual(invalidated.resetsAt, UsageMath.utcDayBounds(containing: now).end)
        XCTAssertEqual(try Data(contentsOf: store.pendingAccountChangeURL), record)
        XCTAssertEqual(try Data(contentsOf: store.fileURL), configurationAfterRecoveryAttempt)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tokens.fileURL.path)
        XCTAssertEqual(try Data(contentsOf: tokens.fileURL), tokenBytes)
        XCTAssertEqual(try store.load(), previous)
        XCTAssertEqual(try tokens.token(for: account.id), "old-token")
    }

    @MainActor
    func testStatusWriteFailureRemovesOldFileWithoutHidingLoadError() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fileURL = root.appendingPathComponent("accounts.json")
        let original = Data("{broken".utf8)
        try original.write(to: fileURL)
        let id = UUID()
        let tokens = MemoryTokenStore([id: "original-token"])
        let store = AccountStore(fileURL: fileURL, tokens: tokens)
        let statusURL = root.appendingPathComponent("status.json")
        try seedRecommendedStatus(at: statusURL, id: id, date: Date())
        let model = AppModel(store: store, statusURL: statusURL, statusWriter: { _, _ in
            throw CocoaError(.fileWriteOutOfSpace)
        })
        defer { model.stop() }
        XCTAssertFalse(FileManager.default.fileExists(atPath: statusURL.path))
        XCTAssertNotNil(model.configurationLoadError)
        let alert = try XCTUnwrap(model.alertMessage)
        XCTAssertTrue(alert.hasPrefix(model.configurationLoadError! + "\n"))
        XCTAssertTrue(alert.contains(try XCTUnwrap(model.statusPublicationError)))
        await model.refresh() // An already absent file is also a safe invalidation result.
        XCTAssertEqual(model.alertMessage, alert)
        XCTAssertEqual(try Data(contentsOf: fileURL), original)
        XCTAssertEqual(try tokens.token(for: id), "original-token")
    }

    @MainActor
    func testFailedWriteAndRemovalAreReportedThenRetriedAutomatically() async throws {
        guard geteuid() != 0 else { throw XCTSkip("Requires an unprivileged user") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let statusDirectory = root.appendingPathComponent("status")
        try FileManager.default.createDirectory(at: statusDirectory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: statusDirectory.path)
            try? FileManager.default.removeItem(at: root)
        }
        let fileURL = root.appendingPathComponent("accounts.json")
        let original = Data("{broken".utf8)
        try original.write(to: fileURL)
        let store = AccountStore(fileURL: fileURL, tokens: MemoryTokenStore())
        let statusURL = statusDirectory.appendingPathComponent("status.json")
        var now = ISO8601DateFormatter().date(from: "2026-11-05T00:01:00Z")!
        try seedRecommendedStatus(at: statusURL, id: UUID(), date: now.addingTimeInterval(-120))
        let previousStatus = try Data(contentsOf: statusURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: statusDirectory.path)
        let sleeper = StatusRetrySleeper()
        let statusSleeper = StatusRetrySleeper()
        var writesEnabled = false
        var attempts = 0
        let model = AppModel(store: store, statusURL: statusURL, currentDate: { now }, sleep: { await sleeper.sleep($0) }, statusWriter: { status, url in
            attempts += 1
            if !writesEnabled { throw CocoaError(.fileWriteOutOfSpace) }
            try StatusFile.write(status, to: url)
        }, statusRetrySleep: { await statusSleeper.sleep($0) })
        defer { model.stop(); sleeper.finishAll(); statusSleeper.finishAll() }
        let loadError = try XCTUnwrap(model.configurationLoadError)
        let invalidationMessage = L10n.text(.statusInvalidationFailed, language: model.stored.language).components(separatedBy: "%@")[0]
        XCTAssertTrue(model.alertMessage?.hasPrefix(loadError + "\n") == true)
        XCTAssertTrue(model.alertMessage?.contains(invalidationMessage) == true)
        model.start()
        await waitUntil { sleeper.delays.count == 1 }
        XCTAssertEqual(try Data(contentsOf: statusURL), previousStatus)
        XCTAssertEqual(attempts, 2)
        // Restore access and cross another UTC midnight before the pending retry wakes.
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: statusDirectory.path)
        now = now.addingTimeInterval(86_400)
        writesEnabled = true
        sleeper.finish(0)
        await waitUntil { sleeper.delays.count == 2 }
        let status = try readStatus(statusURL)
        XCTAssertNil(status.suggestedAccountID)
        XCTAssertTrue(status.accounts.isEmpty)
        XCTAssertEqual(status.generatedAt, now)
        XCTAssertEqual(status.resetsAt, UsageMath.utcDayBounds(containing: now).end)
        XCTAssertEqual(attempts, 3)
        XCTAssertEqual(model.alertMessage, loadError)
        XCTAssertEqual(model.menuTitle, "!")
        XCTAssertFalse(model.isRefreshing)
        XCTAssertEqual(try Data(contentsOf: fileURL), original)
    }

    @MainActor
    func testInvalidationNeverRecursivelyDeletesADirectory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let statusURL = root.appendingPathComponent("status.json")
        try FileManager.default.createDirectory(at: statusURL, withIntermediateDirectories: true)
        let marker = statusURL.appendingPathComponent("keep.txt")
        let markerData = Data("preserve directory contents".utf8)
        try markerData.write(to: marker)
        let fileURL = root.appendingPathComponent("accounts.json")
        try Data("{broken".utf8).write(to: fileURL)
        let model = AppModel(store: AccountStore(fileURL: fileURL, tokens: MemoryTokenStore()), statusURL: statusURL)
        defer { model.stop() }
        XCTAssertNotNil(model.configurationLoadError)
        XCTAssertNotEqual(model.alertMessage, model.configurationLoadError)
        XCTAssertTrue(model.alertMessage?.hasPrefix(model.configurationLoadError! + "\n") == true)
        XCTAssertEqual(try Data(contentsOf: marker), markerData)
    }

    private func seedRecommendedStatus(at url: URL, id: UUID, date: Date) throws {
        let snapshot = AccountSnapshot(
            config: AccountConfig(id: id, name: "previous", accountID: "old-id"),
            usage: AccountUsage(accountID: id, requests: 10, fetchedAt: date)
        )
        let status = UsageMath.status(accounts: [snapshot], now: date)
        XCTAssertEqual(status.suggestedAccountID, id)
        try StatusFile.write(status, to: url)
    }

    private func readStatus(_ url: URL) throws -> QuotaStatus {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(QuotaStatus.self, from: Data(contentsOf: url))
    }

    @MainActor
    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<1000 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(1))
        }
        XCTFail("Timed out waiting for status invalidation retry")
    }
}

@MainActor
private final class StatusRetrySleeper {
    var delays: [Duration] = []
    private var continuations: [Int: CheckedContinuation<Void, Never>] = [:]
    func sleep(_ duration: Duration) async {
        let index = delays.count
        delays.append(duration)
        await withCheckedContinuation { continuations[index] = $0 }
    }
    func finish(_ index: Int) { continuations.removeValue(forKey: index)?.resume() }
    func finishAll() {
        let pending = Array(continuations.values)
        continuations.removeAll()
        for continuation in pending { continuation.resume() }
    }
}
