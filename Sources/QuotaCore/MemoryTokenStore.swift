import Foundation

public final class MemoryTokenStore: TokenStoring, @unchecked Sendable {
    private var tokens: [UUID: String] = [:]

    public init(_ tokens: [UUID: String] = [:]) {
        self.tokens = tokens
    }

    public func token(for accountID: UUID) throws -> String? {
        tokens[accountID]
    }

    public func save(token: String, for accountID: UUID) throws {
        tokens[accountID] = token
    }

    public func deleteToken(for accountID: UUID) throws {
        tokens.removeValue(forKey: accountID)
    }
}
