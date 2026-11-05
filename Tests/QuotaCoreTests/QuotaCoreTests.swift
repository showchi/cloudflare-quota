import Foundation
import XCTest
@testable import QuotaCore

final class UsageMathTests: XCTestCase {
    func testUTCDayResetsAtNextMidnight() {
        let formatter = ISO8601DateFormatter()
        let afternoon = formatter.date(from: "2026-11-03T15:30:00Z")!
        let bounds = UsageMath.utcDayBounds(containing: afternoon)
        XCTAssertEqual(bounds.start, formatter.date(from: "2026-11-03T00:00:00Z"))
        XCTAssertEqual(bounds.end, formatter.date(from: "2026-11-04T00:00:00Z"))
    }

    func testSuggestsAccountWithMostRemainingUnderThreshold() {
        let calm = account("calm", requests: 10_000, limit: 100_000, threshold: 0.75)
        let busy = account("busy", requests: 70_000, limit: 100_000, threshold: 0.75)
        let hot = account("hot", requests: 80_000, limit: 100_000, threshold: 0.75)
        let disabled = account("off", requests: 0, limit: 100_000, threshold: 0.75, enabled: false)
        let failed = account("bad", requests: 0, limit: 100_000, threshold: 0.75, error: "token")

        let suggested = UsageMath.suggestedAccount(in: [busy, hot, calm, disabled, failed])
        XCTAssertEqual(suggested?.config.name, "calm")
    }

    func testNoSuggestionWhenEveryAccountIsPastTheSwitchLine() {
        let hot = account("hot", requests: 75_000, limit: 100_000, threshold: 0.75)
        XCTAssertNil(UsageMath.suggestedAccount(in: [hot]))
        XCTAssertFalse(UsageMath.isUsable(config: hot.config, usage: hot.usage))
    }

    func testThresholdIsExclusive() {
        let under = account("under", requests: 74_999, limit: 100_000, threshold: 0.75)
        XCTAssertTrue(UsageMath.isUsable(config: under.config, usage: under.usage))
    }

    func testMenuTitleUsesFullestEnabledAccount() {
        let low = account("low", requests: 10_000, limit: 100_000, threshold: 0.75)
        let high = account("high", requests: 72_400, limit: 100_000, threshold: 0.75)
        XCTAssertEqual(UsageMath.menuTitle(for: [low, high]), "72%")
    }

    func testMenuTitleShowsBangWhenAFetchFailed() {
        let failed = account("bad", requests: 0, limit: 100_000, threshold: 0.75, error: "no")
        XCTAssertEqual(UsageMath.menuTitle(for: [failed]), "!")
        XCTAssertEqual(UsageMath.menuTitle(for: []), "Quota")
    }

    func testStatusCarriesResetAndSuggestion() {
        let now = ISO8601DateFormatter().date(from: "2026-11-03T15:30:00Z")!
        let snap = account("calm", requests: 1_000, limit: 100_000, threshold: 0.75)
        let status = UsageMath.status(accounts: [snap], now: now)
        XCTAssertEqual(status.suggestedAccountID, snap.config.id)
        XCTAssertEqual(status.resetsAt, ISO8601DateFormatter().date(from: "2026-11-04T00:00:00Z"))
    }

    private func account(
        _ name: String,
        requests: Int,
        limit: Int,
        threshold: Double,
        enabled: Bool = true,
        error: String? = nil
    ) -> AccountSnapshot {
        let config = AccountConfig(
            name: name,
            accountID: "acc-\(name)",
            dailyLimit: limit,
            switchThreshold: threshold,
            enabled: enabled
        )
        let usage = AccountUsage(
            accountID: config.id,
            requests: requests,
            fetchedAt: Date(timeIntervalSince1970: 0),
            error: error
        )
        return AccountSnapshot(config: config, usage: usage)
    }
}

final class FileTokenStoreTests: XCTestCase {
    func testExistingSharedDirectoryIsTightenedAndReplacementStaysPrivate() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        let store = FileTokenStore(fileURL: directory.appendingPathComponent("tokens.json"))
        let id = UUID()
        for value in ["first", "replacement"] {
            try store.save(token: value, for: id)
            XCTAssertEqual(try store.token(for: id), value)
            let fileMode = try FileManager.default.attributesOfItem(atPath: store.fileURL.path)[.posixPermissions] as? NSNumber
            let directoryMode = try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber
            XCTAssertEqual(fileMode?.intValue, 0o600)
            XCTAssertEqual(directoryMode?.intValue, 0o700)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["tokens.json"])
        }
    }

    func testRoundTripIsOwnerReadableOnly() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = FileTokenStore(fileURL: directory.appendingPathComponent("tokens.json"))
        let id = UUID()
        try store.save(token: "secret", for: id)
        XCTAssertEqual(try store.token(for: id), "secret")
        try store.deleteToken(for: id)
        XCTAssertNil(try store.token(for: id))

        try store.save(token: "again", for: id)
        let mode = try FileManager.default.attributesOfItem(atPath: store.fileURL.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.uint16Value, 0o600)
    }
}

final class UsageAggregatorTests: XCTestCase {
    func testSumsRequestsAndGroupsScripts() {
        let groups = [
            InvocationGroup(sum: InvocationSum(requests: 10), dimensions: InvocationDimensions(scriptName: "pages")),
            InvocationGroup(sum: InvocationSum(requests: 5), dimensions: InvocationDimensions(scriptName: "api")),
            InvocationGroup(sum: InvocationSum(requests: 2), dimensions: InvocationDimensions(scriptName: "pages")),
            InvocationGroup(sum: InvocationSum(requests: 1), dimensions: InvocationDimensions(scriptName: nil)),
        ]
        let total = UsageAggregator.total(from: groups)
        XCTAssertEqual(total.requests, 18)
        XCTAssertEqual(total.scripts, [
            ScriptUsage(scriptName: "pages", requests: 12),
            ScriptUsage(scriptName: "api", requests: 5),
        ])
    }
}

final class CloudflareAPITests: XCTestCase {
    override func tearDown() {
        StubURLProtocol.responder = nil
        super.tearDown()
    }

    func testResolveAccountIDUsesTheOnlyVisibleAccount() async throws {
        StubURLProtocol.responder = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret")
            let body = """
            {"success":true,"errors":[],"result":[{"id":"abc123","name":"Home"}]}
            """
            return (200, Data(body.utf8))
        }
        let api = makeAPI()
        let id = try await api.resolveAccountID("", token: "secret")
        XCTAssertEqual(id, "abc123")
    }

    func testResolveAccountIDKeepsAProvidedIDWithoutCallingTheNetwork() async throws {
        StubURLProtocol.responder = { _ in
            XCTFail("should not request")
            return (500, Data())
        }
        let id = try await makeAPI().resolveAccountID("  given  ", token: "secret")
        XCTAssertEqual(id, "given")
    }

    func testResolveAccountIDRequiresAChoiceWhenTheTokenSeesSeveralAccounts() async {
        StubURLProtocol.responder = { _ in
            let body = """
            {"success":true,"errors":[],"result":[{"id":"a","name":"A"},{"id":"b","name":"B"}]}
            """
            return (200, Data(body.utf8))
        }
        do {
            _ = try await makeAPI().resolveAccountID("", token: "secret")
            XCTFail("expected an error")
        } catch let error as CloudflareAPIError {
            XCTAssertEqual(error, .api([L10n.text(.multipleAccounts, language: .chinese)]))
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testUsageRequestUsesTheUTCDayWindow() {
        let start = ISO8601DateFormatter().date(from: "2026-11-03T00:00:00Z")!
        let end = ISO8601DateFormatter().date(from: "2026-11-04T00:00:00Z")!
        let request = CloudflareAPI.usageRequest(accountID: "acc", from: start, until: end)
        XCTAssertEqual(request.variables.accountTag, "acc")
        XCTAssertEqual(request.variables.start, "2026-11-03T00:00:00Z")
        XCTAssertEqual(request.variables.end, "2026-11-04T00:00:00Z")
        XCTAssertTrue(request.query.contains("workersInvocationsAdaptive"))
    }

    func testUsageSumsWorkersAndPagesFunctions() async throws {
        StubURLProtocol.responder = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret")
            let body = """
            {"data":{"viewer":{"accounts":[{
              "workersInvocationsAdaptive":[
                {"sum":{"requests":40},"dimensions":{"scriptName":"api"}},
                {"sum":{"requests":60},"dimensions":{"scriptName":"web"}}
              ],
              "pagesFunctionsInvocationsAdaptiveGroups":[
                {"sum":{"requests":15},"dimensions":{"scriptName":"pages-worker--1-production"}}
              ]
            }]}}}
            """
            return (200, Data(body.utf8))
        }
        let start = ISO8601DateFormatter().date(from: "2026-11-03T00:00:00Z")!
        let end = ISO8601DateFormatter().date(from: "2026-11-04T00:00:00Z")!
        let usage = try await makeAPI().usage(accountID: "acc", token: "secret", from: start, until: end)
        XCTAssertEqual(usage.requests, 115)
        XCTAssertEqual(usage.scripts.map(\.scriptName), ["web", "api", "pages-worker--1-production"])
    }

    func testUsageRejectsMissingAccountOrUsageData() async {
        let bodies = [
            "{}",
            #"{"data":{"viewer":{"accounts":[]}}}"#,
            #"{"data":{"viewer":{"accounts":[{}]}}}"#,
            #"{"data":{"viewer":{"accounts":[{"workersInvocationsAdaptive":[],"pagesFunctionsInvocationsAdaptiveGroups":[{"sum":{}}]}]}}}"#
        ]
        for body in bodies {
            StubURLProtocol.responder = { _ in (200, Data(body.utf8)) }
            do {
                _ = try await makeAPI().usage(accountID: "acc", token: "secret", from: Date(), until: Date())
                XCTFail("Missing data must fail: \(body)")
            } catch {
                XCTAssertEqual(error as? CloudflareAPIError, .invalidResponse)
            }
        }
    }

    func testUsageAcceptsEmptyDatasetsAsZero() async throws {
        StubURLProtocol.responder = { _ in
            (200, Data(#"{"data":{"viewer":{"accounts":[{"workersInvocationsAdaptive":[],"pagesFunctionsInvocationsAdaptiveGroups":[]}]}}}"#.utf8))
        }
        let usage = try await makeAPI().usage(accountID: "acc", token: "secret", from: Date(), until: Date())
        XCTAssertEqual(usage.requests, 0)
        XCTAssertTrue(usage.scripts.isEmpty)
    }

    func testUsageRejectsSaturatedDatasetsButAcceptsBelowLimit() async throws {
        for (workers, pages, incomplete) in [
            (CloudflareAPI.workersGroupLimit, 0, true),
            (0, CloudflareAPI.pagesGroupLimit, true),
            (CloudflareAPI.workersGroupLimit - 1, CloudflareAPI.pagesGroupLimit - 1, false)
        ] {
            let group: [String: Any] = ["sum": ["requests": 1]]
            let body = try JSONSerialization.data(withJSONObject: ["data": ["viewer": ["accounts": [[
                "workersInvocationsAdaptive": Array(repeating: group, count: workers),
                "pagesFunctionsInvocationsAdaptiveGroups": Array(repeating: group, count: pages)
            ]]]]])
            StubURLProtocol.responder = { _ in (200, body) }
            do {
                let usage = try await makeAPI().usage(accountID: "acc", token: "secret", from: Date(), until: Date())
                XCTAssertFalse(incomplete)
                XCTAssertEqual(usage.requests, workers + pages)
            } catch {
                XCTAssertTrue(incomplete)
                XCTAssertEqual(error as? CloudflareAPIError, .incompleteUsage)
            }
        }
    }

    func testUsageReportsGraphQLErrors() async {
        StubURLProtocol.responder = { _ in
            let body = """
            {"data":null,"errors":[{"message":"auth failed"}]}
            """
            return (200, Data(body.utf8))
        }
        do {
            _ = try await makeAPI().usage(
                accountID: "acc",
                token: "secret",
                from: Date(),
                until: Date()
            )
            XCTFail("expected an error")
        } catch let error as CloudflareAPIError {
            XCTAssertEqual(error, .api(["auth failed"]))
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testHTTPFailure() async {
        StubURLProtocol.responder = { _ in (403, Data("no".utf8)) }
        do {
            _ = try await makeAPI().listAccounts(token: "secret")
            XCTFail("expected an error")
        } catch let error as CloudflareAPIError {
            XCTAssertEqual(error, .httpStatus(403))
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    private func makeAPI() -> CloudflareAPI {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return CloudflareAPI(
            session: URLSession(configuration: configuration),
            restBase: URL(string: "https://example.test/client/v4")!,
            graphqlURL: URL(string: "https://example.test/client/v4/graphql")!,
            language: .chinese
        )
    }
}

final class AccountStoreTests: XCTestCase {
    func testRoundTripsAccountsWithoutTokens() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let tokens = MemoryTokenStore()
        let store = AccountStore(
            fileURL: directory.appendingPathComponent("accounts.json"),
            tokens: tokens
        )
        let account = AccountConfig(name: "home", accountID: "abc", dailyLimit: 50_000, switchThreshold: 0.8)
        try tokens.save(token: "secret", for: account.id)
        try store.save(StoredAccounts(accounts: [account], showMenuBar: false, refreshMinutes: 15))

        let loaded = try store.load()
        XCTAssertEqual(loaded.accounts, [account])
        XCTAssertFalse(loaded.showMenuBar)
        XCTAssertEqual(loaded.refreshMinutes, 15)
        XCTAssertEqual(try tokens.token(for: account.id), "secret")
        let file = try String(contentsOf: store.fileURL, encoding: .utf8)
        XCTAssertFalse(file.contains("secret"))

        try tokens.deleteToken(for: account.id)
        XCTAssertNil(try tokens.token(for: account.id))
    }

    func testExistingUnreadableConfigurationDoesNotLoadDefaults() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = AccountStore(fileURL: directory, tokens: MemoryTokenStore())
        XCTAssertThrowsError(try store.load())
    }

    func testStoredPreferencesDecodeWhenOlderFilesOmitThem() throws {
        let json = """
        {"accounts":[],"refreshMinutes":10,"showMenuBar":true}
        """
        let decoded = try JSONDecoder().decode(StoredAccounts.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.language, .system)
        XCTAssertEqual(decoded.appearance, .system)
    }

    func testSystemLanguageFollowsThePreferredLanguage() {
        XCTAssertEqual(AppLanguage.system.resolved(preferredLanguages: ["zh-Hans-CN", "en-US"]), .chinese)
        XCTAssertEqual(AppLanguage.system.resolved(preferredLanguages: ["en-US", "zh-Hans-US"]), .english)
        XCTAssertEqual(AppLanguage.system.resolved(preferredLanguages: ["en", "zh-Hans"]), .english)
        XCTAssertEqual(AppLanguage.system.resolved(preferredLanguages: []), .english)
        XCTAssertEqual(AppLanguage.english.resolved(preferredLanguages: ["zh-Hans-CN"]), .english)
        XCTAssertEqual(AppLanguage.chinese.resolved(preferredLanguages: ["en-US"]), .chinese)
    }

    func testMissingFileLoadsDefaults() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("accounts.json")
        let store = AccountStore(fileURL: url, tokens: MemoryTokenStore())
        let loaded = try store.load()
        XCTAssertTrue(loaded.accounts.isEmpty)
        XCTAssertTrue(loaded.showMenuBar)
    }

    func testStatusFileRoundTrip() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("status.json")
        let now = ISO8601DateFormatter().date(from: "2026-11-03T15:30:00Z")!
        let snap = AccountSnapshot(
            config: AccountConfig(name: "home", accountID: "abc"),
            usage: AccountUsage(accountID: UUID(), requests: 12, fetchedAt: now)
        )
        var status = UsageMath.status(accounts: [snap], now: now)
        status = QuotaStatus(
            generatedAt: now,
            resetsAt: status.resetsAt,
            suggestedAccountID: snap.config.id,
            accounts: [snap]
        )
        try StatusFile.write(status, to: url)
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let loaded = try decoder.decode(QuotaStatus.self, from: data)
        XCTAssertEqual(loaded.suggestedAccountID, snap.config.id)
        XCTAssertEqual(loaded.accounts.first?.usage?.requests, 12)
    }
}

final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var responder: ((URLRequest) throws -> (Int, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let responder = Self.responder else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (status, data) = try responder(request)
            let response = HTTPURLResponse(
                url: request.url ?? URL(string: "https://example.test")!,
                statusCode: status,
                httpVersion: nil,
                headerFields: nil
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
