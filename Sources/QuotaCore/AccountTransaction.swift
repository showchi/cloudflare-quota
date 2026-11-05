import Foundation

enum AccountChangeStage: CaseIterable {
    case prepared, tokenWritten, configurationWritten, committed
}

private struct AccountChangeRecord: Codable {
    var previousConfiguration: Data?
    var nextConfiguration: Data
    var accountID: UUID
    var previousToken: String?
    var nextToken: String
    var committed: Bool
}

public enum AccountTransactionError: Error, LocalizedError {
    case recoveryFailed(String, AppLanguage)

    public var errorDescription: String? {
        switch self {
        case .recoveryFailed(let message, let language):
            L10n.format(.recoveryFailed, message, language: language)
        }
    }
}

extension AccountStore {
    var pendingAccountChangeURL: URL {
        fileURL.deletingLastPathComponent().appendingPathComponent(".\(fileURL.lastPathComponent).pending")
    }

    /// Returns a cleanup warning only after both configuration and credentials have committed.
    @discardableResult
    public func saveAccountChange(_ next: StoredAccounts, accountID: UUID, token: String?) throws -> String? {
        try recoverPendingAccountChange(language: next.language)
        try next.validate()
        guard let token else {
            try save(next)
            return nil
        }
        guard next.accounts.contains(where: { $0.id == accountID }), !token.isEmpty else {
            throw AccountConfigurationError(message: L10n.text(.invalidTransaction, language: next.language))
        }
        let previous = try accountData()
        if let previous { _ = try validatedAccounts(from: previous) }
        var record = AccountChangeRecord(
            previousConfiguration: previous,
            nextConfiguration: try encoder.encode(next),
            accountID: accountID,
            previousToken: try tokens.token(for: accountID),
            nextToken: token,
            committed: false
        )
        try PrivateFile.write(JSONEncoder().encode(record), to: pendingAccountChangeURL)
        try accountChangeCheckpoint?(.prepared)
        do { try tokens.save(token: token, for: accountID) }
        catch { try abortAccountChange(after: error, language: next.language) }
        try accountChangeCheckpoint?(.tokenWritten)
        do { try writeAccountData(record.nextConfiguration) }
        catch { try abortAccountChange(after: error, language: next.language) }
        try accountChangeCheckpoint?(.configurationWritten)
        record.committed = true
        do { try PrivateFile.write(JSONEncoder().encode(record), to: pendingAccountChangeURL) }
        catch { try abortAccountChange(after: error, language: next.language) }
        try accountChangeCheckpoint?(.committed)
        do { try FileManager.default.removeItem(at: pendingAccountChangeURL) }
        catch { return L10n.format(.pendingCleanupFailed, error.localizedDescription, language: next.language) }
        return nil
    }

    private func abortAccountChange(after originalError: Error, language: AppLanguage) throws -> Never {
        do { try recoverPendingAccountChange(language: language) }
        catch { throw AccountTransactionError.recoveryFailed(error.localizedDescription, language) }
        throw originalError
    }

    func recoverPendingAccountChange(language: AppLanguage = .system) throws {
        let data: Data
        do { data = try Data(contentsOf: pendingAccountChangeURL) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return }
        let record = try JSONDecoder().decode(AccountChangeRecord.self, from: data)
        // Validate the whole record before changing either file. Corruption must fail closed.
        let next = try validatedAccounts(from: record.nextConfiguration)
        guard next.accounts.contains(where: { $0.id == record.accountID }), !record.nextToken.isEmpty else {
            throw AccountConfigurationError(message: L10n.text(.invalidRecoveryRecord, language: language))
        }
        if let previous = record.previousConfiguration { _ = try validatedAccounts(from: previous) }
        let target = record.committed ? record.nextConfiguration : record.previousConfiguration
        if try accountData() != target {
            if let target { try writeAccountData(target) }
            else { try FileManager.default.removeItem(at: fileURL) }
        }
        let token = record.committed ? record.nextToken : record.previousToken
        if let token { try tokens.save(token: token, for: record.accountID) }
        else { try tokens.deleteToken(for: record.accountID) }
        try FileManager.default.removeItem(at: pendingAccountChangeURL)
    }
}
