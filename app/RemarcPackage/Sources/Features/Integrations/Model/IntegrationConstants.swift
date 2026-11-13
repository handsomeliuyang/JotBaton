import CorePlatform
import Foundation

public enum IntegrationConstants {
    public static let chromeExtensionURL = URL(string: "https://remarc.app/chrome-extension")!
    public static let webSocketPort: UInt16 = AppIdentity.current.webSocketPort
    public static let webSocketHost = "127.0.0.1"
}
