import CoreLocalization
import Foundation

/// Why sync needs the user. Each case is shown as a persistent banner in the
/// main window, where edits happen, and as a badge on the menu bar icon.
package enum SyncAttention: Equatable, Sendable {
    case issue(CloudSyncIssue)
    case newerFormat(deviceName: String)
    case stuckDownload(count: Int)
    case unsynced(since: Date)
    case conflicts(count: Int)
}

package enum SyncHealth: Equatable, Sendable {
    case off
    case ok
    case syncing
    case waiting(count: Int)
    case attention(SyncAttention)

    package static let stuckDownloadDelay: TimeInterval = 5 * 60
    package static let unsyncedDelay: TimeInterval = 10 * 60

    package var needsAttention: Bool {
        if case .attention = self { return true }
        return false
    }

    /// Short waits are normal for iCloud and stay quiet. Only a wait long enough
    /// to risk editing on stale data, or a problem the user must fix, escalates.
    package static func evaluate(enabled: Bool, syncing: Bool, issue: CloudSyncIssue?, newerFormatDevice: String?,
                                 waitingCount: Int, waitingSince: Date?, unsyncedSince: Date?,
                                 conflictCount: Int, now: Date) -> SyncHealth {
        guard enabled else { return .off }
        if let issue { return .attention(.issue(issue)) }
        if let newerFormatDevice { return .attention(.newerFormat(deviceName: newerFormatDevice)) }
        if waitingCount > 0, let waitingSince, now.timeIntervalSince(waitingSince) >= stuckDownloadDelay {
            return .attention(.stuckDownload(count: waitingCount))
        }
        if let unsyncedSince, now.timeIntervalSince(unsyncedSince) >= unsyncedDelay {
            return .attention(.unsynced(since: unsyncedSince))
        }
        if conflictCount > 0 { return .attention(.conflicts(count: conflictCount)) }
        if syncing { return .syncing }
        if waitingCount > 0 { return .waiting(count: waitingCount) }
        return .ok
    }

    package var title: String {
        switch self {
        case .off: return L10n.tr("iCloud sync is off")
        case .ok: return L10n.tr("Synced")
        case .syncing: return L10n.tr("Syncing…")
        case .waiting(let count): return L10n.tr("Downloading \(count) files from iCloud")
        case .attention(let attention):
            switch attention {
            case .issue: return L10n.tr("iCloud sync is not working")
            case .newerFormat: return L10n.tr("Update JotBaton to keep syncing")
            case .stuckDownload: return L10n.tr("iCloud has not delivered the latest data")
            case .unsynced: return L10n.tr("Recent changes are not in iCloud yet")
            case .conflicts(let count): return L10n.tr("\(count) tasks were edited on two Macs")
            }
        }
    }

    package var explanation: String? {
        guard case .attention(let attention) = self else { return nil }
        switch attention {
        case .issue(let issue): return L10n.lookup(issue.message)
        case .newerFormat(let name):
            return L10n.tr("\(name) uses a newer version of JotBaton. Changes from that Mac are not applied until this Mac is updated.")
        case .stuckDownload:
            return L10n.tr("Edits made now may conflict with another Mac. They are kept and merged when the download finishes.")
        case .unsynced:
            return L10n.tr("Other Macs do not have these changes yet. They stay on this Mac and upload automatically.")
        case .conflicts:
            return L10n.tr("The newer edit was kept on every Mac. Review the other version if needed.")
        }
    }
}
