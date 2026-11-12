@testable import FeatureComments
@testable import RemarcFeature
import XCTest

final class WebContextPrivacyTests: XCTestCase {
    func testDisablingEveryMetadataCategoryDropsContext() {
        let context = WebContext(componentName: "Editor", filePath: "Editor.swift", pageUrl: "https://example.com")
        let choices = WebContextPrivacy(react: false, styles: false, accessibility: false,
                                        layout: false, identity: false, hyperframes: false)
        XCTAssertNil(context.filtered(using: choices))
    }

    func testExplicitChoicesPreserveIdentityWithoutLeakingReactMetadata() throws {
        let context = WebContext(componentName: "Editor", filePath: "Editor.swift", pageUrl: "https://example.com")
        let choices = WebContextPrivacy(react: false, styles: false, accessibility: false,
                                        layout: false, identity: true, hyperframes: false)
        let filtered = try XCTUnwrap(context.filtered(using: choices))
        XCTAssertEqual(filtered.pageUrl, "https://example.com")
        XCTAssertNil(filtered.componentName)
        XCTAssertNil(filtered.filePath)
        XCTAssertEqual(context.componentName, "Editor")
    }
}
