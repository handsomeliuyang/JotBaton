import CoreLocalization
import Foundation

public enum InactiveSessionCleanupInterval: String, CaseIterable, Sendable {
    case after30Minutes, after1Hour, after2Hours, after4Hours, after6Hours, after12Hours, after24Hours

    public var label: String {
        switch self {
        case .after30Minutes: L10n.tr("30 min")
        case .after1Hour:     L10n.tr("1 hour")
        case .after2Hours:    L10n.tr("2 hours")
        case .after4Hours:    L10n.tr("4 hours")
        case .after6Hours:    L10n.tr("6 hours")
        case .after12Hours:   L10n.tr("12 hours")
        case .after24Hours:   L10n.tr("24 hours")
        }
    }

    public var interval: TimeInterval {
        switch self {
        case .after30Minutes: 30 * 60
        case .after1Hour:     60 * 60
        case .after2Hours:    2 * 60 * 60
        case .after4Hours:    4 * 60 * 60
        case .after6Hours:    6 * 60 * 60
        case .after12Hours:   12 * 60 * 60
        case .after24Hours:   24 * 60 * 60
        }
    }
}


public enum ResolvedCommentDeletion: String, CaseIterable, Sendable {
    case never, immediately, after15Minutes, after1Hour, after1Day

    public var label: String {
        switch self {
        case .never: L10n.tr("Never")
        case .immediately: L10n.tr("Immediately")
        case .after15Minutes: L10n.tr("After 15 min")
        case .after1Hour: L10n.tr("After 1 hour")
        case .after1Day: L10n.tr("After 1 day")
        }
    }

    public var interval: TimeInterval? {
        switch self {
        case .never: nil
        case .immediately: 0
        case .after15Minutes: 15 * 60
        case .after1Hour: 60 * 60
        case .after1Day: 24 * 60 * 60
        }
    }
}
