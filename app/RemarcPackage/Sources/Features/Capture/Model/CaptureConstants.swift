import Foundation

public enum CaptureConstants {
    public static let selectionPollInterval: TimeInterval = 0.2
    public static let tooltipShowDelay: TimeInterval = 0.15
    public static let tooltipTimeout: TimeInterval = 5.0
    public static let tooltipFadeInDuration: TimeInterval = 0.12
    public static let tooltipFadeOutDuration: TimeInterval = 0.15
    public static let tooltipCornerRadius: CGFloat = 8
    public static let chromiumBundleIDs: Set<String> = [
        "com.google.Chrome",
        "com.google.Chrome.canary",
        "company.thebrowser.Browser",   // Arc
        "com.brave.Browser",
        "com.microsoft.edgemac",
        "com.vivaldi.Vivaldi",
        "com.operasoftware.Opera",
    ]
}
