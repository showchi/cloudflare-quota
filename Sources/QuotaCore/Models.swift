import Foundation

public struct AccountConfig: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    /// Cloudflare account ID. Empty until the token resolves it.
    public var accountID: String
    public var dailyLimit: Int
    /// Switch away once displayed usage reaches this fraction of the daily limit.
    public var switchThreshold: Double
    public var enabled: Bool

    public init(
        id: UUID = UUID(),
        name: String,
        accountID: String = "",
        dailyLimit: Int = UsageMath.defaultDailyLimit,
        switchThreshold: Double = UsageMath.defaultSwitchThreshold,
        enabled: Bool = true
    ) {
        self.id = id
        self.name = name
        self.accountID = accountID
        self.dailyLimit = dailyLimit
        self.switchThreshold = switchThreshold
        self.enabled = enabled
    }
}

public struct ScriptUsage: Codable, Equatable, Sendable {
    public var scriptName: String
    public var requests: Int

    public init(scriptName: String, requests: Int) {
        self.scriptName = scriptName
        self.requests = requests
    }
}

public struct AccountUsage: Codable, Equatable, Sendable, Identifiable {
    public var accountID: UUID
    public var requests: Int
    public var scripts: [ScriptUsage]
    public var fetchedAt: Date
    public var error: String?

    public var id: UUID { accountID }

    public init(
        accountID: UUID,
        requests: Int,
        scripts: [ScriptUsage] = [],
        fetchedAt: Date,
        error: String? = nil
    ) {
        self.accountID = accountID
        self.requests = requests
        self.scripts = scripts
        self.fetchedAt = fetchedAt
        self.error = error
    }

    public static func failed(accountID: UUID, message: String, at date: Date) -> AccountUsage {
        AccountUsage(accountID: accountID, requests: 0, fetchedAt: date, error: message)
    }
}

public struct AccountSnapshot: Codable, Equatable, Sendable, Identifiable {
    public var config: AccountConfig
    public var usage: AccountUsage?

    public var id: UUID { config.id }

    public init(config: AccountConfig, usage: AccountUsage? = nil) {
        self.config = config
        self.usage = usage
    }
}

public struct QuotaStatus: Codable, Equatable, Sendable {
    public var generatedAt: Date
    public var resetsAt: Date
    /// Enabled account with the most remaining requests. Nil when none are usable.
    public var suggestedAccountID: UUID?
    public var accounts: [AccountSnapshot]

    public init(
        generatedAt: Date,
        resetsAt: Date,
        suggestedAccountID: UUID?,
        accounts: [AccountSnapshot]
    ) {
        self.generatedAt = generatedAt
        self.resetsAt = resetsAt
        self.suggestedAccountID = suggestedAccountID
        self.accounts = accounts
    }
}
