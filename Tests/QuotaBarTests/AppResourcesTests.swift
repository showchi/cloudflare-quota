import Foundation
import XCTest
@testable import QuotaBar

final class AppResourcesTests: XCTestCase {
    func testPackagedResourcesDoNotUseDevelopmentFallback() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("Cloudflare Quota.app")
        let contents = app.appendingPathComponent("Contents")
        let resources = contents.appendingPathComponent("Resources")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        let plist: [String: String] = ["CFBundleIdentifier": "test.quota.resources", "CFBundlePackageType": "APPL", "CFBundleExecutable": "QuotaBar"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: contents.appendingPathComponent("Info.plist"))
        let source = try XCTUnwrap(AppResources.bundle())
        let target = resources.appendingPathComponent("cloudflare-quota_QuotaBar.bundle")
        try FileManager.default.copyItem(at: source.bundleURL, to: target)
        let main = try XCTUnwrap(Bundle(url: app))
        var usedFallback = false
        let loaded = AppResources.bundle(main: main) {
            usedFallback = true
            return source
        }
        XCTAssertFalse(usedFallback)
        XCTAssertEqual(loaded?.bundleURL.path, target.path)
        XCTAssertNotNil(loaded?.url(forResource: "MenuTemplate", withExtension: "png"))
    }

    func testMissingPackagedResourcesNeverFallBackToBuildDirectory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("Empty.app")
        let contents = app.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "test.quota.empty", "CFBundlePackageType": "APPL"], format: .xml, options: 0).write(to: contents.appendingPathComponent("Info.plist"))
        let main = try XCTUnwrap(Bundle(url: app))
        var usedFallback = false
        XCTAssertNil(AppResources.bundle(main: main) {
            usedFallback = true
            return Bundle.main
        })
        XCTAssertFalse(usedFallback)
    }
}
