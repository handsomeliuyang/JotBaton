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

    /// - Parameter hidesCountAtZero: only consulted for `.count`. The dot is
    ///   binary by definition and `.off` draws nothing either way.
    public func indicator(forCommentCount count: Int, hidesCountAtZero: Bool) -> MenuBarIndicator {
        switch self {
        case .count: return (count > 0 || !hidesCountAtZero) ? .count(count) : .none
        case .dot: return count > 0 ? .dot : .none
        case .off: return .none
        }
    }
}
