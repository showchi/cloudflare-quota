import AppKit
import XCTest
@testable import QuotaBar

final class AppActivationTests: XCTestCase {
    @MainActor
    func testClosingLastInputWindowRestoresAccessoryAndReopenRestoresRegular() throws {
        guard !NSScreen.screens.isEmpty else { throw XCTSkip("Requires a WindowServer session") }
        let application = NSApplication.shared
        let original = application.activationPolicy()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 120, height: 80), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer {
            window.orderOut(nil)
            application.setActivationPolicy(original)
        }
        AppActivation.becomeRegular()
        window.orderFront(nil)
        AppActivation.restoreAccessoryIfNoInputWindows()
        XCTAssertEqual(application.activationPolicy(), .regular)
        window.close()
        AppActivation.restoreAccessoryIfNoInputWindows()
        XCTAssertEqual(application.activationPolicy(), .accessory)
        AppActivation.becomeRegular()
        window.orderFront(nil)
        XCTAssertEqual(application.activationPolicy(), .regular)
    }
}
