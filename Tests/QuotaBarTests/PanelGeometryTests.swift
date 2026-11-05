import Foundation
import XCTest
@testable import QuotaBar

final class PanelGeometryTests: XCTestCase {
    func testOversizedPanelRemainsWithinSmallAndOffsetScreens() {
        for screen in [CGRect(x: 0, y: 0, width: 1024, height: 700), CGRect(x: -1920, y: 300, width: 1920, height: 1080)] {
            let frame = PanelGeometry.frame(for: CGSize(width: 340, height: 4000), anchoredTo: CGRect(x: screen.maxX - 5, y: screen.maxY, width: 20, height: 20), within: screen)
            XCTAssertTrue(screen.contains(frame))
            XCTAssertEqual(frame.height, screen.height - 8)
        }
    }

    func testAccountListStaysAtEightRowsUntilTheScreenLimit() {
        XCTAssertEqual(MenuPanelLayout.accountListHeight, 486)
        XCTAssertEqual(MenuPanelLayout.accountListHeight(maximumPanelHeight: 800), 486)
        XCTAssertEqual(MenuPanelLayout.accountListHeight(maximumPanelHeight: 500), 368)
    }

    func testNormalPanelStaysBelowItsStatusItem() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let anchor = CGRect(x: 600, y: 880, width: 30, height: 20)
        let frame = PanelGeometry.frame(for: CGSize(width: 340, height: 400), anchoredTo: anchor, within: screen)
        XCTAssertEqual(frame.midX, anchor.midX)
        XCTAssertEqual(frame.maxY, anchor.minY - 4)
    }
}
