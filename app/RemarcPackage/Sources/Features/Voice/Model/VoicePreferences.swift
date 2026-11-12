import CoreLocalization
import Foundation

public enum AutoSaveDelay: String, CaseIterable, Sendable {
    case oneSecond
    case onePointFiveSeconds
    case twoSeconds
    case threeSeconds
    case fourSeconds
    case fiveSeconds

    public var label: String {
        switch self {
        case .oneSecond: return L10n.tr("1s")
        case .onePointFiveSeconds: return L10n.tr("1.5s")
        case .twoSeconds: return L10n.tr("2s")
        case .threeSeconds: return L10n.tr("3s")
        case .fourSeconds: return L10n.tr("4s")
        case .fiveSeconds: return L10n.tr("5s")
        }
    }

    public var duration: TimeInterval {
        switch self {
        case .oneSecond: return 1.0
        case .onePointFiveSeconds: return 1.5
        case .twoSeconds: return 2.0
        case .threeSeconds: return 3.0
        case .fourSeconds: return 4.0
        case .fiveSeconds: return 5.0
        }
    }
}
