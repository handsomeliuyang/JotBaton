import CoreLocalization
import Foundation

public enum WidgetCorner: String, CaseIterable, Sendable {
    case bottomRight
    case bottomLeft
    case topRight
    case topLeft
}


public enum TooltipPosition: String, CaseIterable, Sendable {
    case above
    case below

    public var label: String {
        switch self {
        case .above: return L10n.tr("Above selection")
        case .below: return L10n.tr("Below selection")
        }
    }
}


public enum SelectionDetectionMode: String, CaseIterable, Sendable {
    case auto
    case hotkeyOnly

    public var label: String {
        switch self {
        case .auto: return L10n.tr("Auto-detect + Hotkey")
        case .hotkeyOnly: return L10n.tr("Hotkey Only")
        }
    }
}
