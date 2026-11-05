import Foundation
import Darwin

/// Secret contents are written only after the exclusive temporary file has private permissions.
enum PrivateFile {
    static func write(_ data: Data, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        guard let permissions = attributes[.posixPermissions] as? NSNumber else {
            throw CocoaError(.fileReadUnknown)
        }
        // Remove access for other users without granting the owner new write permissions.
        try FileManager.default.setAttributes([.posixPermissions: permissions.intValue & 0o700], ofItemAtPath: directory.path)
        var template = Array(directory.appendingPathComponent(".private.XXXXXX").path.utf8CString)
        let descriptor = mkstemp(&template)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let path = String(decoding: template.dropLast().map { UInt8(bitPattern: $0) }, as: UTF8.self)
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer {
            try? handle.close()
            unlink(path)
        }
        guard fchmod(descriptor, 0o600) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        try handle.write(contentsOf: data)
        try handle.synchronize()
        try handle.close()
        guard rename(path, url.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}
