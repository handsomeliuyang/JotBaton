@testable import RemarcFeature
import Foundation
import XCTest

final class ThirdPartyNoticesTests: XCTestCase {
    private var packageRoot: URL {
        RepositoryPaths.package()
    }

    private var repositoryRoot: URL {
        packageRoot
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    func testBundledNoticeMatchesCanonicalNoticeByteForByte() throws {
        let canonicalURL = repositoryRoot.appendingPathComponent("THIRD-PARTY-NOTICES.md")
        let bundledURL = packageRoot
            .appendingPathComponent("Sources/App/Resources/THIRD-PARTY-NOTICES.md")

        let canonical = try Data(contentsOf: canonicalURL)
        let bundled = try Data(contentsOf: bundledURL)

        XCTAssertEqual(
            bundled,
            canonical,
            "Update the canonical notice and bundled resource copy together."
        )
    }

    func testNoticeCoversEveryResolvedSwiftPackageRevision() throws {
        let notice = try canonicalNotice()
        let resolvedURL = packageRoot.appendingPathComponent("Package.resolved")
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: resolvedURL)) as? [String: Any]
        )
        let pins = try XCTUnwrap(object["pins"] as? [[String: Any]])

        for pin in pins {
            let identity = try XCTUnwrap(pin["identity"] as? String)
            let state = try XCTUnwrap(pin["state"] as? [String: Any])
            let revision = try XCTUnwrap(state["revision"] as? String)

            XCTAssertTrue(
                notice.contains(revision),
                "THIRD-PARTY-NOTICES.md is missing resolved revision for \(identity)."
            )
        }
    }

    private func canonicalNotice() throws -> String {
        let url = repositoryRoot.appendingPathComponent("THIRD-PARTY-NOTICES.md")
        return try String(contentsOf: url, encoding: .utf8)
    }
}
