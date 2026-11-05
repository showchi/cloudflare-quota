import Foundation
import XCTest
@testable import QuotaCore

final class CloudflareUsageWindowTests: XCTestCase {
    private let start = ISO8601DateFormatter().date(from: "2026-11-03T00:00:00Z")!
    private let end = ISO8601DateFormatter().date(from: "2026-11-04T00:00:00Z")!

    override func tearDown() {
        StubURLProtocol.responder = nil
        super.tearDown()
    }

    func testFullPageRequeriesDisjointWindowsAndMergesOnlyCompleteParts() async throws {
        for count in [CloudflareAPI.pagesGroupLimit, CloudflareAPI.pagesGroupLimit + 1] {
            var windows: [String] = []
            StubURLProtocol.responder = { request in
                let variables = try Self.variables(request)
                let from = variables["start"]!, until = variables["end"]!
                windows.append("\(from)..\(until)")
                let workerCount: Int, range: Range<Int>
                if from == "2026-11-03T00:00:00Z", until == "2026-11-04T00:00:00Z" {
                    workerCount = 100
                    range = 0..<CloudflareAPI.pagesGroupLimit
                } else if from == "2026-11-03T00:00:00Z", until == "2026-11-03T12:00:00Z" {
                    workerCount = 40
                    range = 0..<(count / 2)
                } else {
                    XCTAssertEqual(from, "2026-11-03T12:00:00Z")
                    XCTAssertEqual(until, "2026-11-04T00:00:00Z")
                    workerCount = 60
                    range = (count / 2)..<count
                }
                return (200, try Self.response(workers: [Self.group("worker", workerCount)], pages: range.map { Self.group("page-\($0)", 1) }))
            }
            let usage = try await makeAPI().usage(accountID: "acc", token: "secret", from: start, until: end)
            XCTAssertEqual(windows, [
                "2026-11-03T00:00:00Z..2026-11-04T00:00:00Z",
                "2026-11-03T00:00:00Z..2026-11-03T12:00:00Z",
                "2026-11-03T12:00:00Z..2026-11-04T00:00:00Z"
            ])
            XCTAssertEqual(usage.requests, count + 100)
            XCTAssertEqual(usage.scripts.count, count + 1)
            XCTAssertEqual(usage.scripts.first(where: { $0.scriptName == "worker" })?.requests, 100)
        }
    }

    func testLaterWindowFailureDoesNotReturnEarlierPartialTotals() async throws {
        var calls = 0
        StubURLProtocol.responder = { _ in
            calls += 1
            if calls == 1 {
                return (200, try Self.response(workers: [], pages: Array(repeating: Self.group("page", 1), count: CloudflareAPI.pagesGroupLimit)))
            }
            if calls == 2 { return (200, try Self.response(workers: [Self.group("worker", 20)], pages: [])) }
            return (200, try Self.response(workers: [Self.group("worker", 30)], pages: nil, error: "Pages unavailable"))
        }
        do {
            _ = try await makeAPI().usage(accountID: "acc", token: "secret", from: start, until: end)
            XCTFail("An incomplete total must not be returned")
        } catch {
            XCTAssertEqual(error as? CloudflareAPIError, .api(["Pages unavailable"]))
        }
        XCTAssertEqual(calls, 3)
    }

    func testUsageWindowQueryBudgetIsBounded() async throws {
        var calls = 0
        StubURLProtocol.responder = { request in
            calls += 1
            let variables = try Self.variables(request)
            let formatter = ISO8601DateFormatter()
            let duration = formatter.date(from: variables["end"]!)!.timeIntervalSince(formatter.date(from: variables["start"]!)!)
            let count = duration > 3600 ? CloudflareAPI.pagesGroupLimit : 500
            return (200, try Self.response(workers: [], pages: (0..<count).map { Self.group("page-\($0)", 1) }))
        }
        do {
            _ = try await makeAPI().usage(accountID: "acc", token: "secret", from: start, until: end)
            XCTFail("Budget exhaustion must not return a partial total")
        } catch {
            XCTAssertEqual(error as? CloudflareAPIError, .incompleteUsage)
        }
        XCTAssertEqual(calls, CloudflareAPI.maximumUsageQueries)
    }

    func testFullOneSecondWindowFailsWithoutRetryLoop() async throws {
        var calls = 0
        StubURLProtocol.responder = { _ in
            calls += 1
            return (200, try Self.response(workers: [], pages: Array(repeating: Self.group("page", 1), count: CloudflareAPI.pagesGroupLimit)))
        }
        do {
            _ = try await makeAPI().usage(accountID: "acc", token: "secret", from: start, until: start.addingTimeInterval(1))
            XCTFail("A full minimal window cannot be proven complete")
        } catch {
            XCTAssertEqual(error as? CloudflareAPIError, .incompleteUsage)
        }
        XCTAssertEqual(calls, 1)
    }

    func testEitherDatasetFailureDoesNotUseTheOtherAsCompleteUsage() async throws {
        for workersFail in [false, true] {
            StubURLProtocol.responder = { _ in
                (200, try Self.response(
                    workers: workersFail ? nil : [Self.group("worker", 20_000)],
                    pages: workersFail ? [Self.group("page", 20_000)] : nil,
                    error: "dataset unavailable"
                ))
            }
            do {
                _ = try await makeAPI().usage(accountID: "acc", token: "secret", from: start, until: end)
                XCTFail("Missing usage could contain the remaining quota")
            } catch {
                XCTAssertEqual(error as? CloudflareAPIError, .api(["dataset unavailable"]))
            }
        }
    }

    func testErrorWithEmptyMessageStillPreventsSuccessfulUsage() async throws {
        StubURLProtocol.responder = { _ in
            (200, try Self.response(workers: [Self.group("worker", 1)], pages: [], error: ""))
        }
        do {
            _ = try await makeAPI().usage(accountID: "acc", token: "secret", from: start, until: end)
            XCTFail("An error must not be ignored because its message is empty")
        } catch {
            XCTAssertEqual(error as? CloudflareAPIError, .api([L10n.text(.graphqlFailed, language: .chinese)]))
        }
    }

    private static func group(_ name: String, _ requests: Int) -> [String: Any] {
        ["sum": ["requests": requests], "dimensions": ["scriptName": name]]
    }

    private static func response(workers: [[String: Any]]?, pages: [[String: Any]]?, error: String? = nil) throws -> Data {
        var account: [String: Any] = [:]
        if let workers { account["workersInvocationsAdaptive"] = workers }
        else { account["workersInvocationsAdaptive"] = NSNull() }
        if let pages { account["pagesFunctionsInvocationsAdaptiveGroups"] = pages }
        else { account["pagesFunctionsInvocationsAdaptiveGroups"] = NSNull() }
        var body: [String: Any] = ["data": ["viewer": ["accounts": [account]]]]
        if let error { body["errors"] = [["message": error]] }
        return try JSONSerialization.data(withJSONObject: body)
    }

    private static func variables(_ request: URLRequest) throws -> [String: String] {
        let data: Data
        if let body = request.httpBody { data = body }
        else {
            let stream = try XCTUnwrap(request.httpBodyStream)
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            var body = Data()
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                body.append(contentsOf: buffer.prefix(count))
            }
            data = body
        }
        let body = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        return body["variables"] as! [String: String]
    }

    private func makeAPI() -> CloudflareAPI {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return CloudflareAPI(session: URLSession(configuration: configuration), graphqlURL: URL(string: "https://example.test/graphql")!, language: .chinese)
    }
}
