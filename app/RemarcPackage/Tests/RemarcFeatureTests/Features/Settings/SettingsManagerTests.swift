@testable import FeatureSettings
@testable import RemarcFeature
import XCTest

@MainActor
final class SettingsManagerTests: XCTestCase {

    // MARK: - Menu bar indicator

    func testNothingIsShownAtZeroInAnyStyle() {
        for style in MenuBarIndicatorStyle.allCases {
            XCTAssertEqual(style.indicator(forCommentCount: 0), .none)
        }
    }

    func testEachStyleReportsUnresolvedTasksItsOwnWay() {
        XCTAssertEqual(MenuBarIndicatorStyle.count.indicator(forCommentCount: 42), .count(42))
        XCTAssertEqual(MenuBarIndicatorStyle.dot.indicator(forCommentCount: 42), .dot)
        XCTAssertEqual(MenuBarIndicatorStyle.off.indicator(forCommentCount: 42), .none)
    }

    func testMenuBarIndicatorDefaultsToTheHistoricalCountBadge() {
        let suiteName = "remarc.settings-tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        XCTAssertNil(defaults.string(forKey: "menuBarIndicatorStyle"))
        let style = defaults.string(forKey: "menuBarIndicatorStyle")
            .flatMap(MenuBarIndicatorStyle.init(rawValue:)) ?? .count
        XCTAssertEqual(style, .count)
    }
}
