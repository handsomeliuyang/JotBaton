import Foundation

/// Pure release selection policy, shared by both macOS deployment profiles.
struct GitHubRelease: Decodable, Sendable {
    static let latestURL = URL(string: "https://api.github.com/repos/handsomeliuyang/Remarc/releases/latest")!
    private static let releasePath = "/handsomeliuyang/Remarc/releases/"

    let tagName: String
    let htmlURL: URL
    let draft: Bool
    let prerelease: Bool
    let assets: [Asset]

    struct Asset: Decodable, Sendable {
        let name: String
        let state: String
        let size: Int
        let browserDownloadURL: URL
        enum CodingKeys: String, CodingKey {
            case name, state, size
            case browserDownloadURL = "browser_download_url"
        }
    }

    struct Candidate: Equatable, Sendable {
        let version: String
        let releaseURL: URL
        let downloadURL: URL
    }

    enum CodingKeys: String, CodingKey {
        case draft, prerelease, assets
        case tagName = "tag_name"
        case htmlURL = "html_url"
    }

    enum UpdateError: LocalizedError {
        case invalidResponse, unavailable, noRelease, missingPackage, unsupportedSystem
        var errorDescription: String? {
            switch self {
            case .invalidResponse: return "GitHub returned an invalid release."
            case .unavailable: return "GitHub is unavailable or its request limit was reached. Try again later."
            case .noRelease: return "No published GitHub release is available."
            case .missingPackage: return "The GitHub release has no compatible installer."
            case .unsupportedSystem: return "This release does not support this Mac."
            }
        }
    }

    static func decode(_ data: Data, response: URLResponse) throws -> GitHubRelease {
        guard let response = response as? HTTPURLResponse else { throw UpdateError.invalidResponse }
        if response.statusCode == 403 || response.statusCode == 429 { throw UpdateError.unavailable }
        if response.statusCode == 404 { throw UpdateError.noRelease }
        guard response.statusCode == 200, data.count <= 2_000_000 else { throw UpdateError.invalidResponse }
        return try JSONDecoder().decode(GitHubRelease.self, from: data)
    }

    func update(installedVersion: String, architecture: String, os: OperatingSystemVersion) throws -> Candidate? {
        let version = tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName
        guard !draft, !prerelease,
              let remote = Self.versionParts(version), let local = Self.versionParts(installedVersion),
              Self.validURL(htmlURL, path: Self.releasePath + "tag/" + tagName) else {
            throw UpdateError.invalidResponse
        }
        guard local.lexicographicallyPrecedes(remote) else { return nil }
        let filename: String
        switch architecture {
        case "arm64" where os.majorVersion >= 14: filename = "Remarc-Apple-Silicon-arm64.dmg"
        case "x86_64" where os.majorVersion >= 13: filename = "Remarc-Ventura-x86_64.zip"
        default: throw UpdateError.unsupportedSystem
        }
        let matching = assets.filter { $0.name == filename && $0.state == "uploaded" && $0.size > 0 }
        guard matching.count == 1, let asset = matching.first,
              Self.validURL(asset.browserDownloadURL, path: Self.releasePath + "download/" + tagName + "/" + filename) else {
            throw UpdateError.missingPackage
        }
        return Candidate(version: version, releaseURL: htmlURL, downloadURL: asset.browserDownloadURL)
    }

    private static func versionParts(_ value: String) -> [Int]? {
        let fields = value.split(separator: ".", omittingEmptySubsequences: false)
        guard fields.count == 3 else { return nil }
        var result: [Int] = []
        for field in fields {
            guard !field.isEmpty, field.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
                  let number = Int(field), String(number) == field else { return nil }
            result.append(number)
        }
        return result
    }

    private static func validURL(_ url: URL, path: String) -> Bool {
        url.scheme == "https" && url.host == "github.com" && url.port == nil &&
        url.user == nil && url.password == nil && url.query == nil && url.fragment == nil && url.path == path
    }
}
