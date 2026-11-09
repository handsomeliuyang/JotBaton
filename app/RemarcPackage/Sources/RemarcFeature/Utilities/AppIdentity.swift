import Foundation

/// The installed app's identity, independent of optimization and DEBUG flags.
/// SwiftPM tests default to production; tests can exercise either channel explicitly.
public enum AppIdentity: String, Sendable, CaseIterable {
    case production
    case development

    public static let current = AppIdentity(bundleIdentifier: Bundle.main.bundleIdentifier)

    public init(bundleIdentifier: String?) {
        self = bundleIdentifier == "com.metepolat.Remarc.dev" ? .development : .production
    }

    public var isDevelopment: Bool { self == .development }
    public var bundleIdentifier: String { isDevelopment ? "com.metepolat.Remarc.dev" : "com.metepolat.Remarc" }
    public var displayName: String { isDevelopment ? "Remarc Dev" : "Remarc" }
    public var directoryName: String { displayName }
    public var urlScheme: String { isDevelopment ? "remarc-dev" : "remarc" }
    public var reloadNotification: String { bundleIdentifier + ".reload" }
    public var webSocketPort: UInt16 { isDevelopment ? 9275 : 9274 }
    public var integrationName: String { isDevelopment ? "remarc-dev" : "remarc" }
    public var appIconName: String { isDevelopment ? "AppIconDev" : "AppIcon" }
    public var menuBarIconName: String { isDevelopment ? "MenuBarIconDev" : "MenuBarIcon" }
    public var cloudDisplayPath: String { "iCloud Drive/" + directoryName }

    public func appSupportURL(in home: URL) -> URL {
        home.appendingPathComponent("Library/Application Support", isDirectory: true)
            .appendingPathComponent(directoryName, isDirectory: true)
    }

    public func cloudURL(in drive: URL) -> URL {
        drive.appendingPathComponent(directoryName, isDirectory: true)
    }
}
