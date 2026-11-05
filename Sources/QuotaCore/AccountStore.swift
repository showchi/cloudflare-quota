import Foundation

public enum AppLanguage: String, Codable, Equatable, Sendable, CaseIterable {
    case system
    case chinese = "zh"
    case english = "en"

    public func resolved(preferredLanguages: [String] = Locale.preferredLanguages) -> AppLanguage {
        guard self == .system else { return self }
        guard let first = preferredLanguages.first else { return .english }
        let code = Locale(identifier: first).language.languageCode?.identifier ?? first
        return code == "zh" ? .chinese : .english
    }
}

public enum AppAppearance: String, Codable, Equatable, Sendable, CaseIterable {
    case system
    case light
    case dark
}

public struct StoredAccounts: Codable, Equatable, Sendable {
    public var accounts: [AccountConfig]
    public var showMenuBar: Bool
    public var refreshMinutes: Int
    public var language: AppLanguage
    public var appearance: AppAppearance

    public init(
        accounts: [AccountConfig] = [],
        showMenuBar: Bool = true,
        refreshMinutes: Int = 10,
        language: AppLanguage = .system,
        appearance: AppAppearance = .system
    ) {
        self.accounts = accounts
        self.showMenuBar = showMenuBar
        self.refreshMinutes = refreshMinutes
        self.language = language
        self.appearance = appearance
    }

    private enum CodingKeys: String, CodingKey {
        case accounts, showMenuBar, refreshMinutes, language, appearance
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        accounts = try values.decodeIfPresent([AccountConfig].self, forKey: .accounts) ?? []
        showMenuBar = try values.decodeIfPresent(Bool.self, forKey: .showMenuBar) ?? true
        refreshMinutes = try values.decodeIfPresent(Int.self, forKey: .refreshMinutes) ?? 10
        language = try values.decodeIfPresent(AppLanguage.self, forKey: .language) ?? .system
        appearance = try values.decodeIfPresent(AppAppearance.self, forKey: .appearance) ?? .system
    }
}

public protocol TokenStoring: Sendable {
    func token(for accountID: UUID) throws -> String?
    func save(token: String, for accountID: UUID) throws
    func deleteToken(for accountID: UUID) throws
}

public struct AccountStore {
    public var fileURL: URL
    public var tokens: any TokenStoring
    public var encoder: JSONEncoder
    public var decoder: JSONDecoder
    // Internal fault-injection boundary for process-interruption regression tests.
    var accountChangeCheckpoint: ((AccountChangeStage) throws -> Void)?

    public init(fileURL: URL, tokens: any TokenStoring) {
        self.fileURL = fileURL
        self.tokens = tokens
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    public static func defaultFileURL(fileManager: FileManager = .default) -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base
            .appendingPathComponent("CloudflareQuota", isDirectory: true)
            .appendingPathComponent("accounts.json")
    }

    public func load() throws -> StoredAccounts {
        try recoverPendingAccountChange(language: languageInAccountFile() ?? .system)
        guard let data = try accountData() else { return StoredAccounts() }
        return try validatedAccounts(from: data)
    }

    private func languageInAccountFile() -> AppLanguage? {
        guard let data = try? accountData(),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = object["language"] as? String,
              let language = AppLanguage(rawValue: raw) else { return nil }
        return language
    }

    func accountData() throws -> Data? {
        do { return try Data(contentsOf: fileURL) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return nil }
    }

    func validatedAccounts(from data: Data) throws -> StoredAccounts {
        let accounts = try decoder.decode(StoredAccounts.self, from: data)
        try accounts.validate()
        return accounts
    }

    public func save(_ stored: StoredAccounts) throws {
        try recoverPendingAccountChange(language: stored.language)
        try stored.validate()
        try writeAccountData(encoder.encode(stored))
    }

    func writeAccountData(_ data: Data) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
    }
}

public enum StatusFile {
    public static func defaultURL(fileManager: FileManager = .default) -> URL {
        fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".cloudflare-quota", isDirectory: true)
            .appendingPathComponent("status.json")
    }

    public static func write(_ status: QuotaStatus, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(status)
        try data.write(to: url, options: .atomic)
    }
}

public struct AccountConfigurationError: Error, LocalizedError {
    public var message: String
    public var errorDescription: String? { message }
}

extension StoredAccounts {
    func validate() throws {
        let language = self.language
        guard (1...120).contains(refreshMinutes) else {
            throw AccountConfigurationError(message: L10n.text(.refreshIntervalInvalid, language: language))
        }
        guard Set(accounts.map(\.id)).count == accounts.count else {
            throw AccountConfigurationError(message: L10n.text(.duplicateAccountID, language: language))
        }
        for account in accounts {
            guard !account.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  account.dailyLimit > 0,
                  account.switchThreshold.isFinite,
                  (0.01...0.99).contains(account.switchThreshold) else {
                throw AccountConfigurationError(message: L10n.text(.invalidAccountFields, language: language))
            }
        }
    }
}
