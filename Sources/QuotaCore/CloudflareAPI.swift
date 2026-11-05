import Foundation

public enum CloudflareAPIError: Error, Equatable, LocalizedError {
    case invalidResponse
    case httpStatus(Int)
    case api([String])
    case emptyAccountList
    case incompleteUsage

    public var errorDescription: String? {
        switch self {
        case .invalidResponse:
            L10n.text(.invalidResponse)
        case .httpStatus(let code):
            L10n.format(.httpFailed, code)
        case .api(let messages):
            messages.joined(separator: L10n.text(.messageSeparator))
        case .emptyAccountList:
            L10n.text(.emptyAccountList)
        case .incompleteUsage:
            L10n.text(.incompleteUsage)
        }
    }
}

public struct CloudflareAPI: Sendable {
    public static let restBase = URL(string: "https://api.cloudflare.com/client/v4")!
    public static let graphqlURL = restBase.appendingPathComponent("graphql")

    public var session: URLSession
    public var restBase: URL
    public var graphqlURL: URL
    public var language: AppLanguage

    public init(
        session: URLSession = .shared,
        restBase: URL = CloudflareAPI.restBase,
        graphqlURL: URL = CloudflareAPI.graphqlURL,
        language: AppLanguage = .system
    ) {
        self.session = session
        self.restBase = restBase
        self.graphqlURL = graphqlURL
        self.language = language
    }

    public func listAccounts(token: String) async throws -> [CloudflareAccount] {
        let data = try await get(url: restBase.appendingPathComponent("accounts"), token: token)
        let decoded = try JSONDecoder().decode(RESTEnvelope<[CloudflareAccount]>.self, from: data)
        if let messages = decoded.failureMessages(language: language) {
            throw CloudflareAPIError.api(messages)
        }
        return decoded.result ?? []
    }

    /// Fills an empty account ID from the token. A token that sees several accounts needs one chosen by hand.
    public func resolveAccountID(_ existing: String, token: String) async throws -> String {
        let trimmed = existing.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            return trimmed
        }
        let accounts = try await listAccounts(token: token)
        guard let only = accounts.first, accounts.count == 1 else {
            if accounts.isEmpty {
                throw CloudflareAPIError.emptyAccountList
            }
            throw CloudflareAPIError.api([L10n.text(.multipleAccounts, language: language)])
        }
        return only.id
    }

    public func usage(
        accountID: String,
        token: String,
        from start: Date,
        until end: Date
    ) async throws -> (requests: Int, scripts: [ScriptUsage]) {
        // Match the second precision used by ISO8601DateFormatter for every window boundary.
        var pending = [(
            start: Date(timeIntervalSince1970: floor(start.timeIntervalSince1970)),
            end: Date(timeIntervalSince1970: floor(end.timeIntervalSince1970))
        )]
        var completeGroups: [InvocationGroup] = []
        var queryCount = 0
        while let window = pending.popLast() {
            guard queryCount < Self.maximumUsageQueries else { throw CloudflareAPIError.incompleteUsage }
            queryCount += 1
            let data = try await post(
                url: graphqlURL,
                token: token,
                body: Self.usageRequest(accountID: accountID, from: window.start, until: window.end)
            )
            let decoded = try JSONDecoder().decode(GraphQLEnvelope.self, from: data)
            if let messages = decoded.failureMessages(language: language) { throw CloudflareAPIError.api(messages) }
            guard let accounts = decoded.data?.viewer?.accounts, accounts.count == 1,
                  let account = accounts.first,
                  let workers = account.workersInvocationsAdaptive,
                  let pages = account.pagesFunctionsInvocationsAdaptiveGroups,
                  (workers + pages).allSatisfy({ $0.sum?.requests != nil }) else {
                throw CloudflareAPIError.invalidResponse
            }
            if workers.count < Self.workersGroupLimit, pages.count < Self.pagesGroupLimit {
                completeGroups.append(contentsOf: workers)
                completeGroups.append(contentsOf: pages)
                continue
            }
            // Discard the whole full-page response. Re-query both datasets in disjoint,
            // half-open time windows using the existing datetime_geq / datetime_lt filters.
            let midpoint = Date(timeIntervalSince1970: floor(
                window.start.timeIntervalSince1970 + window.end.timeIntervalSince(window.start) / 2
            ))
            guard midpoint > window.start, midpoint < window.end else {
                throw CloudflareAPIError.incompleteUsage
            }
            pending.append((start: midpoint, end: window.end))
            pending.append((start: window.start, end: midpoint))
        }
        return UsageAggregator.total(from: completeGroups)
    }

    static func usageRequest(accountID: String, from start: Date, until end: Date) -> GraphQLRequest {
        GraphQLRequest(
            query: usageQuery,
            variables: GraphQLVariables(
                accountTag: accountID,
                start: isoTimestamp(start),
                end: isoTimestamp(end)
            )
        )
    }

    static let workersGroupLimit = 10_000
    static let pagesGroupLimit = 1_000
    static let maximumUsageQueries = 31

    static let usageQuery = """
    query WorkersUsage($accountTag: String!, $start: Time!, $end: Time!) {
      viewer {
        accounts(filter: { accountTag: $accountTag }) {
          workersInvocationsAdaptive(
            limit: \(workersGroupLimit)
            filter: { datetime_geq: $start, datetime_lt: $end }
          ) {
            sum { requests }
            dimensions { scriptName }
          }
          pagesFunctionsInvocationsAdaptiveGroups(
            limit: \(pagesGroupLimit)
            filter: { datetime_geq: $start, datetime_lt: $end }
          ) {
            sum { requests }
            dimensions { scriptName }
          }
        }
      }
    }
    """

    private static func isoTimestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    private func get(url: URL, token: String) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return try await send(request)
    }

    private func post<Body: Encodable>(url: URL, token: String, body: Body) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        return try await send(request)
    }

    private func send(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw CloudflareAPIError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw CloudflareAPIError.httpStatus(http.statusCode)
        }
        return data
    }
}

public struct CloudflareAccount: Codable, Equatable, Sendable {
    public var id: String
    public var name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

struct RESTEnvelope<Result: Decodable>: Decodable {
    var success: Bool
    var errors: [APIMessage]?
    var result: Result?

    func failureMessages(language: AppLanguage) -> [String]? {
        guard !success else { return nil }
        let messages = (errors ?? []).map(\.text).filter { !$0.isEmpty }
        return messages.isEmpty ? [L10n.text(.apiFailed, language: language)] : messages
    }
}

struct APIMessage: Decodable {
    var code: Int?
    var message: String?

    var text: String {
        if let code, let message, !message.isEmpty {
            return "\(message)（\(code)）"
        }
        return message ?? ""
    }
}

struct GraphQLRequest: Encodable {
    var query: String
    var variables: GraphQLVariables
}

struct GraphQLVariables: Encodable, Equatable {
    var accountTag: String
    var start: String
    var end: String
}

struct GraphQLEnvelope: Decodable {
    var data: GraphQLData?
    var errors: [GraphQLError]?

    func failureMessages(language: AppLanguage) -> [String]? {
        guard let errors, !errors.isEmpty else { return nil }
        let messages = errors.map(\.message).filter { !$0.isEmpty }
        return messages.isEmpty ? [L10n.text(.graphqlFailed, language: language)] : messages
    }
}

struct GraphQLError: Decodable {
    var message: String
}

struct GraphQLData: Decodable {
    var viewer: GraphQLViewer?
}

struct GraphQLViewer: Decodable {
    var accounts: [GraphQLAccount]?
}

struct GraphQLAccount: Decodable {
    var workersInvocationsAdaptive: [InvocationGroup]?
    /// Pages Functions analytics. Script names alone do not identify duplicate invocations.
    var pagesFunctionsInvocationsAdaptiveGroups: [InvocationGroup]?
}

struct InvocationGroup: Decodable, Equatable {
    var sum: InvocationSum?
    var dimensions: InvocationDimensions?
}

struct InvocationSum: Decodable, Equatable {
    var requests: Int?
}

struct InvocationDimensions: Decodable, Equatable {
    var scriptName: String?
}

enum UsageAggregator {
    static func total(from groups: [InvocationGroup]) -> (requests: Int, scripts: [ScriptUsage]) {
        var requests = 0
        var byScript: [String: Int] = [:]
        for group in groups {
            let count = group.sum?.requests ?? 0
            requests += count
            let name = group.dimensions?.scriptName ?? ""
            if !name.isEmpty {
                byScript[name, default: 0] += count
            }
        }
        let scripts = byScript
            .map { ScriptUsage(scriptName: $0.key, requests: $0.value) }
            .sorted { lhs, rhs in
                if lhs.requests == rhs.requests {
                    return lhs.scriptName < rhs.scriptName
                }
                return lhs.requests > rhs.requests
            }
        return (requests, scripts)
    }
}
