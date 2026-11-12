import CorePlatform
import Foundation

public enum IntegrationConstants {
    public static let claudeCodeMarkerDirectory: String = "/tmp"
    public static let claudeCodeMarkerPrefix: String = AppIdentity.current.isDevelopment ? "remarc-dev-claude-" : "remarc-claude-"
    public static let claudeCodeMarkerSuffix: String = ".marker"
    public static func claudeCodeMarkerPath(for claudeSessionId: String) -> String {
        "\(claudeCodeMarkerDirectory)/\(claudeCodeMarkerPrefix)\(claudeSessionId)\(claudeCodeMarkerSuffix)"
    }
    public static let chromeExtensionURL = URL(string: "https://remarc.app/chrome-extension")!
    public static let webSocketPort: UInt16 = AppIdentity.current.webSocketPort
    public static let webSocketHost = "127.0.0.1"
}
