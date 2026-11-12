import CoreLocalization
import Foundation

public enum ClaudeCodeSessionEndBehavior: String, CaseIterable, Sendable {
    case autoDelete
    case keep
    case moveUnresolved

    public var label: String {
        switch self {
        case .autoDelete: L10n.tr("Delete session")
        case .keep: L10n.tr("Keep session")
        case .moveUnresolved: L10n.tr("Move unresolved to Inbox")
        }
    }
}
