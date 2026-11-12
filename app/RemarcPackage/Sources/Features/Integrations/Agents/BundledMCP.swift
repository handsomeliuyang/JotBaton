import CorePlatform
import Foundation

package enum BundledMCP {
    package static func nodePath() async -> String? {
        await ShellResolver.resolveBinaryPath("node")
    }

    package static var mcpServerPath: String? {
        ScriptInstaller.resolvedPath(source: "mcp/vendor/remarc-mcp.js", bundleName: "remarc-mcp", bundleExt: "js")
    }

    package static var bundledSkillURL: URL? {
        Bundle.main.url(forResource: "remarc-skill", withExtension: "md")
    }
}
