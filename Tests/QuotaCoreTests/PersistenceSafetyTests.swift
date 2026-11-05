import Foundation
import Darwin
import XCTest
@testable import QuotaCore

final class PersistenceSafetyTests: XCTestCase {
    func testInaccessibleTokenFileNeverBecomesAnEmptyStore() throws {
        guard geteuid() != 0 else { throw XCTSkip("Requires an unprivileged user") }
        let directory = temporaryDirectory()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            try? FileManager.default.removeItem(at: directory)
        }
        let store = FileTokenStore(fileURL: directory.appendingPathComponent("tokens.json"))
        let first = UUID(), second = UUID()
        try store.save(token: "first", for: first)
        try store.save(token: "second", for: second)
        let original = try Data(contentsOf: store.fileURL)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: directory.path)
        XCTAssertThrowsError(try store.token(for: first))
        XCTAssertThrowsError(try store.save(token: "replacement", for: first))
        XCTAssertThrowsError(try store.deleteToken(for: first))
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        XCTAssertEqual(try Data(contentsOf: store.fileURL), original)
        XCTAssertEqual(try store.token(for: second), "second")
    }

    func testCorruptTokensAreNotOverwritten() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = FileTokenStore(fileURL: directory.appendingPathComponent("tokens.json"))
        let original = Data("{broken".utf8)
        try original.write(to: store.fileURL)
        XCTAssertThrowsError(try store.save(token: "new", for: UUID()))
        XCTAssertEqual(try Data(contentsOf: store.fileURL), original)
    }

    func testInvalidConfigurationIsRejectedBeforeLoadingOrSaving() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = AccountStore(fileURL: directory.appendingPathComponent("accounts.json"), tokens: MemoryTokenStore())
        let account = AccountConfig(name: "home", accountID: "acc")
        var invalid = [StoredAccounts(refreshMinutes: Int.max), StoredAccounts(refreshMinutes: 0), StoredAccounts(accounts: [account, account])]
        for name in ["", " \n"] {
            var bad = account
            bad.name = name
            invalid.append(StoredAccounts(accounts: [bad]))
        }
        for limit in [0, -1] {
            var bad = account
            bad.dailyLimit = limit
            invalid.append(StoredAccounts(accounts: [bad]))
        }
        for threshold in [0.0, 1.0, 1e300, -0.5] {
            var bad = account
            bad.switchThreshold = threshold
            invalid.append(StoredAccounts(accounts: [bad]))
        }
        for candidate in invalid {
            let bytes = try store.encoder.encode(candidate)
            try bytes.write(to: store.fileURL)
            XCTAssertThrowsError(try store.load())
            XCTAssertThrowsError(try store.save(candidate))
            XCTAssertEqual(try Data(contentsOf: store.fileURL), bytes)
        }
        for threshold in [Double.nan, .infinity, -.infinity] {
            var bad = account
            bad.switchThreshold = threshold
            XCTAssertThrowsError(try store.save(StoredAccounts(accounts: [bad])))
        }
        try store.save(StoredAccounts(accounts: [account], refreshMinutes: 120))
        XCTAssertEqual(try store.load().accounts, [account])
    }

    func testRestartRecoversAtEveryAccountChangeCheckpoint() throws {
        struct Interrupted: Error {}
        for isNew in [false, true] {
            for stage in AccountChangeStage.allCases {
                let directory = temporaryDirectory()
                defer { try? FileManager.default.removeItem(at: directory) }
                let tokens = FileTokenStore(fileURL: directory.appendingPathComponent("tokens.json"))
                let account = AccountConfig(name: "old", accountID: "old-id")
                var store = AccountStore(fileURL: directory.appendingPathComponent("accounts.json"), tokens: tokens)
                let previous = StoredAccounts(accounts: isNew ? [] : [account])
                try store.save(previous)
                if !isNew { try tokens.save(token: "old-token", for: account.id) }
                var nextAccount = account
                nextAccount.accountID = "new-id"
                let next = StoredAccounts(accounts: [nextAccount])
                store.accountChangeCheckpoint = { checkpoint in
                    if checkpoint == stage { throw Interrupted() }
                }
                XCTAssertThrowsError(try store.saveAccountChange(next, accountID: account.id, token: "new-token"))
                let mode = try FileManager.default.attributesOfItem(atPath: store.pendingAccountChangeURL.path)[.posixPermissions] as? NSNumber
                XCTAssertEqual(mode?.intValue, 0o600)
                // A fresh instance must repair both files before exposing configuration.
                let restarted = AccountStore(fileURL: store.fileURL, tokens: tokens)
                let committed = stage == .committed
                XCTAssertEqual(try restarted.load(), committed ? next : previous)
                XCTAssertEqual(try tokens.token(for: account.id), committed ? "new-token" : (isNew ? nil : "old-token"))
                XCTAssertFalse(FileManager.default.fileExists(atPath: store.pendingAccountChangeURL.path))
                XCTAssertEqual(try restarted.load(), committed ? next : previous)
            }
        }
    }

    func testInterruptedFirstSaveRestoresMissingConfiguration() throws {
        struct Interrupted: Error {}
        for stage in AccountChangeStage.allCases {
            let directory = temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let tokens = FileTokenStore(fileURL: directory.appendingPathComponent("tokens.json"))
            var store = AccountStore(fileURL: directory.appendingPathComponent("accounts.json"), tokens: tokens)
            let account = AccountConfig(name: "new", accountID: "acc")
            let next = StoredAccounts(accounts: [account])
            store.accountChangeCheckpoint = { if $0 == stage { throw Interrupted() } }
            XCTAssertThrowsError(try store.saveAccountChange(next, accountID: account.id, token: "new-token"))
            let restarted = AccountStore(fileURL: store.fileURL, tokens: tokens)
            XCTAssertEqual(try restarted.load(), stage == .committed ? next : StoredAccounts())
            XCTAssertEqual(FileManager.default.fileExists(atPath: store.fileURL.path), stage == .committed)
            XCTAssertEqual(try tokens.token(for: account.id), stage == .committed ? "new-token" : nil)
        }
    }

    func testFailedRecoveryRetainsRecordAndCanRetry() throws {
        guard geteuid() != 0 else { throw XCTSkip("Requires an unprivileged user") }
        struct Interrupted: Error {}
        for inaccessible in ["directory", "token"] {
            let directory = temporaryDirectory()
            let tokens = FileTokenStore(fileURL: directory.appendingPathComponent("tokens.json"))
            defer {
                try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
                try? FileManager.default.removeItem(at: directory)
            }
            var store = AccountStore(fileURL: directory.appendingPathComponent("accounts.json"), tokens: tokens)
            let account = AccountConfig(name: "old", accountID: "old-id")
            let previous = StoredAccounts(accounts: [account])
            try store.save(previous)
            try tokens.save(token: "old-token", for: account.id)
            var changed = account
            changed.accountID = "new-id"
            store.accountChangeCheckpoint = { if $0 == .configurationWritten { throw Interrupted() } }
            XCTAssertThrowsError(try store.saveAccountChange(StoredAccounts(accounts: [changed]), accountID: account.id, token: "new-token"))
            let path = inaccessible == "directory" ? directory.path : tokens.fileURL.path
            try FileManager.default.setAttributes([.posixPermissions: inaccessible == "directory" ? 0o500 : 0], ofItemAtPath: path)
            let restarted = AccountStore(fileURL: store.fileURL, tokens: tokens)
            XCTAssertThrowsError(try restarted.load())
            XCTAssertTrue(FileManager.default.fileExists(atPath: store.pendingAccountChangeURL.path))
            try FileManager.default.setAttributes([.posixPermissions: inaccessible == "directory" ? 0o700 : 0o600], ofItemAtPath: path)
            XCTAssertEqual(try restarted.load(), previous)
            XCTAssertEqual(try tokens.token(for: account.id), "old-token")
            XCTAssertFalse(FileManager.default.fileExists(atPath: store.pendingAccountChangeURL.path))
        }
    }

    func testTokenWriteErrorRollsBackBeforeReturningFailure() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let account = AccountConfig(name: "old", accountID: "old-id")
        let tokens = PartiallyFailingTokenStore(id: account.id)
        let store = AccountStore(fileURL: directory.appendingPathComponent("accounts.json"), tokens: tokens)
        let previous = StoredAccounts(accounts: [account])
        try store.save(previous)
        let original = try Data(contentsOf: store.fileURL)
        var changed = account
        changed.accountID = "new-id"
        XCTAssertThrowsError(try store.saveAccountChange(StoredAccounts(accounts: [changed]), accountID: account.id, token: "new-token"))
        XCTAssertEqual(try tokens.token(for: account.id), "old-token")
        XCTAssertEqual(try Data(contentsOf: store.fileURL), original)
        XCTAssertEqual(try store.load(), previous)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.pendingAccountChangeURL.path))
    }

    func testCorruptRecoveryRecordBlocksWritesWithoutChangingSecrets() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let tokens = FileTokenStore(fileURL: directory.appendingPathComponent("tokens.json"))
        let store = AccountStore(fileURL: directory.appendingPathComponent("accounts.json"), tokens: tokens)
        let account = AccountConfig(name: "old", accountID: "old-id")
        try store.save(StoredAccounts(accounts: [account]))
        try tokens.save(token: "old-token", for: account.id)
        let before = try Data(contentsOf: store.fileURL)
        try Data("{broken".utf8).write(to: store.pendingAccountChangeURL)
        XCTAssertThrowsError(try store.load())
        XCTAssertThrowsError(try store.save(StoredAccounts()))
        XCTAssertEqual(try Data(contentsOf: store.fileURL), before)
        XCTAssertEqual(try tokens.token(for: account.id), "old-token")
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }
}

private final class PartiallyFailingTokenStore: TokenStoring, @unchecked Sendable {
    let id: UUID
    private var value: String? = "old-token"
    init(id: UUID) { self.id = id }
    func token(for accountID: UUID) throws -> String? { accountID == id ? value : nil }
    func save(token: String, for accountID: UUID) throws {
        value = token
        if token == "new-token" { throw CocoaError(.fileWriteUnknown) }
    }
    func deleteToken(for accountID: UUID) throws { value = nil }
}
