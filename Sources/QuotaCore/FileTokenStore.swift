import Foundation

/// Tokens live in a 0600 file. The login keychain ties "Always Allow" to the
/// app's code signature, and this app is ad-hoc signed, so that choice is forgotten
/// on every launch.
public struct FileTokenStore: TokenStoring {
    public var fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public static func defaultFileURL(fileManager: FileManager = .default) -> URL {
        AccountStore.defaultFileURL(fileManager: fileManager)
            .deletingLastPathComponent()
            .appendingPathComponent("tokens.json")
    }

    public func token(for accountID: UUID) throws -> String? {
        try read()[accountID.uuidString]
    }

    public func save(token: String, for accountID: UUID) throws {
        var tokens = try read()
        tokens[accountID.uuidString] = token
        try write(tokens)
    }

    public func deleteToken(for accountID: UUID) throws {
        var tokens = try read()
        tokens.removeValue(forKey: accountID.uuidString)
        try write(tokens)
    }

    private func read() throws -> [String: String] {
        do {
            let data = try Data(contentsOf: fileURL)
            return try JSONDecoder().decode([String: String].self, from: data)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return [:]
        }
    }

    private func write(_ tokens: [String: String]) throws {
        try PrivateFile.write(JSONEncoder().encode(tokens), to: fileURL)
    }
}
