@testable import FeatureUpdates
@testable import RemarcFeature
import Foundation
import Testing

@Suite("GitHub release updates")
struct GitHubReleaseTests {
    private let os = OperatingSystemVersion(majorVersion: 14, minorVersion: 0, patchVersion: 0)

    private func fixture(tag: String = "v1.2.28", draft: Bool = false, prerelease: Bool = false,
                         assetPrefix: String = "https://github.com/handsomeliuyang/Remarc/releases/download/",
                         assets: [String] = ["Remarc-Apple-Silicon-arm64.dmg", "Remarc-Ventura-x86_64.zip"]) throws -> GitHubRelease {
        let object: [String: Any] = [
            "tag_name": tag, "html_url": "https://github.com/handsomeliuyang/Remarc/releases/tag/" + tag,
            "draft": draft, "prerelease": prerelease,
            "assets": assets.map { ["name": $0, "state": "uploaded", "size": 100,
                                    "browser_download_url": assetPrefix + tag + "/" + $0] as [String: Any] }
        ]
        return try JSONDecoder().decode(GitHubRelease.self, from: JSONSerialization.data(withJSONObject: object))
    }

    @Test("Selects native installers and supports Intel Ventura")
    func installers() throws {
        let release = try fixture()
        let arm = try #require(try release.update(installedVersion: "1.2.27", architecture: "arm64", os: os))
        #expect(arm.version == "1.2.28")
        #expect(arm.downloadURL.lastPathComponent == "Remarc-Apple-Silicon-arm64.dmg")
        let intel = try #require(try release.update(installedVersion: "1.2.27", architecture: "x86_64",
            os: OperatingSystemVersion(majorVersion: 13, minorVersion: 7, patchVersion: 8)))
        #expect(intel.downloadURL.lastPathComponent == "Remarc-Ventura-x86_64.zip")
        #expect(throws: (any Error).self) {
            try release.update(installedVersion: "1.2.27", architecture: "arm64",
                os: OperatingSystemVersion(majorVersion: 13, minorVersion: 7, patchVersion: 8))
        }
    }

    @Test("Compares version numbers numerically and never offers a downgrade")
    func versions() throws {
        let release = try fixture(tag: "v1.2.10")
        #expect(try release.update(installedVersion: "1.2.9", architecture: "arm64", os: os) != nil)
        #expect(try release.update(installedVersion: "1.2.10", architecture: "arm64", os: os) == nil)
        #expect(try release.update(installedVersion: "1.2.27", architecture: "arm64", os: os) == nil)
        #expect(try fixture(tag: "v1.3.0").update(installedVersion: "1.2.99", architecture: "arm64", os: os) != nil)
    }

    @Test("Rejects malformed versions, drafts and prereleases")
    func invalidReleases() throws {
        for tag in ["v1.2", "v01.2.28", "v1.2.28-beta", "v1.2.28\n", "v1.2.99999999999999999999999999"] {
            let release = try fixture(tag: tag)
            #expect(throws: (any Error).self) { try release.update(installedVersion: "1.2.27", architecture: "arm64", os: os) }
        }
        for release in [try fixture(draft: true), try fixture(prerelease: true)] {
            #expect(throws: (any Error).self) { try release.update(installedVersion: "1.2.27", architecture: "arm64", os: os) }
        }
    }

    @Test("Refuses missing, duplicate, cross-repository and insecure download links")
    func invalidAssets() throws {
        let filename = "Remarc-Apple-Silicon-arm64.dmg"
        let releases = [
            try fixture(assets: []), try fixture(assets: [filename, filename]),
            try fixture(assetPrefix: "https://github.com/other/Remarc/releases/download/"),
            try fixture(assetPrefix: "http://github.com/handsomeliuyang/Remarc/releases/download/"),
            try fixture(assetPrefix: "https://github.com.evil.example/handsomeliuyang/Remarc/releases/download/")
        ]
        for release in releases {
            #expect(throws: (any Error).self) { try release.update(installedVersion: "1.2.27", architecture: "arm64", os: os) }
        }
    }

    @Test("HTTP failures and invalid JSON cannot be reported as up to date")
    func responseFailures() throws {
        for status in [403, 404, 429, 500] {
            let response = try #require(HTTPURLResponse(url: GitHubRelease.latestURL, statusCode: status, httpVersion: nil, headerFields: nil))
            #expect(throws: (any Error).self) { try GitHubRelease.decode(Data("{}".utf8), response: response) }
        }
        let response = try #require(HTTPURLResponse(url: GitHubRelease.latestURL, statusCode: 200, httpVersion: nil, headerFields: nil))
        #expect(throws: (any Error).self) { try GitHubRelease.decode(Data("not JSON".utf8), response: response) }
        #expect(throws: (any Error).self) { try GitHubRelease.decode(Data(repeating: 32, count: 2_000_001), response: response) }
    }
}
