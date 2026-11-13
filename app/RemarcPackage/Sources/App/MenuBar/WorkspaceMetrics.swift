import Foundation

public enum WorkspaceMetrics {
    public static let viewerWidth: CGFloat = 800
    public static let viewerHeight: CGFloat = 550
    public static let cardTimestampRefreshInterval: TimeInterval = 60
    public static let commentPaneWidth: CGFloat = 380
    public static let sessionSidebarWidth: CGFloat = 160
    public static let paneDividerWidth: CGFloat = 1
    public static let popoverWidth = sessionSidebarWidth + paneDividerWidth + commentPaneWidth
    public static let popoverMinHeight: CGFloat = 440
    public static let popoverHeight: CGFloat = 560
    public static let cardCornerRadius: CGFloat = 10
    public static let editorWidth: CGFloat = 440
    public static let popoverArrowWidth: CGFloat = 20
    public static let popoverArrowHeight: CGFloat = 10
    public static let popoverGap: CGFloat = 7
}
