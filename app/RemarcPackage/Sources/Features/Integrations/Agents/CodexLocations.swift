import Foundation

package enum CodexLocations {
    package static var home: URL {
        home(environment: ProcessInfo.processInfo.environment)
    }

    package static var skillPath: URL {
        home.appending(path: "skills/remarc/SKILL.md")
    }

    package static var configPath: URL {
        home.appending(path: "config.toml")
    }

    package static func home(environment: [String: String]) -> URL {
        if let custom = environment["CODEX_HOME"], !custom.isEmpty {
            return URL(fileURLWithPath: (custom as NSString).expandingTildeInPath)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appending(path: ".codex")
    }
}
