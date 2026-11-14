import CoreLocalization
import Foundation

public enum MenuBarIndicator: Equatable, Sendable {
    case none
    case count(Int)
    case dot
}


public enum MenuBarIndicatorStyle: String, CaseIterable, Sendable {
    case count
    case dot
    case off

    public var label: String {
        switch self {
        case .count: return L10n.tr("Count")
        case .dot: return L10n.tr("Dot")
        case .off: return L10n.tr("Off")
        }
    }

    /// Nothing is shown at zero in any style.
    public func indicator(forCommentCount count: Int) -> MenuBarIndicator {
        guard count > 0 else { return .none }
        switch self {
        case .count: return .count(count)
        case .dot: return .dot
        case .off: return .none
        }
    }
}
