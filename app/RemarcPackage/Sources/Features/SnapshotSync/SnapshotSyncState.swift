import CoreLocalization
import Foundation

package enum SnapshotCloudTransfer: Equatable, Sendable {
    case unknown, empty, uploading, downloading, transferring, waiting, ready, failed

    package var title: String {
        switch self {
        case .unknown: return L10n.tr("Not confirmed")
        case .empty: return L10n.tr("Nothing published yet")
        case .uploading: return L10n.tr("Uploading…")
        case .downloading: return L10n.tr("Downloading…")
        case .transferring: return L10n.tr("Uploading and downloading…")
        case .waiting: return L10n.tr("Waiting for iCloud")
        case .ready: return L10n.tr("Ready on this Mac")
        case .failed: return L10n.tr("Transfer failed")
        }
    }
    package var isActive: Bool { self == .uploading || self == .downloading || self == .transferring }
    package var blocksReplacement: Bool { isActive || self == .waiting || self == .failed }
}

package struct SnapshotSyncIssue: Codable, Equatable, Sendable {
    package enum Kind: String, Codable, Sendable { case permission, cloudUnavailable, quota, unavailable, review, other }
    package enum Stage: String, Codable, Sendable { case connection, checking, preparing, publishing, uploadConfirmation, applying, localRecord, receipt }
    package let kind: Kind
    package let stage: Stage
    package let message: String
    package let codes: [String]
    package let date: Date
    package let versionID: UUID?

    package var needsAuthorization: Bool { kind == .permission }
    package var needsICloudSettings: Bool { kind == .cloudUnavailable || kind == .quota || kind == .unavailable }
    package var isWarning: Bool { (stage == .uploadConfirmation && kind != .permission && kind != .quota) || kind == .review }
    package var diagnostic: String {
        // Error userInfo can contain paths, account identifiers, and file data.
        // Store only domains/codes, the operation, date, and snapshot identifier.
        "Stage: \(stage.rawValue)\nTime: \(date.formatted(date: .numeric, time: .standard))\nVersion: \(versionID?.uuidString ?? "none")\nErrors: \(codes.joined(separator: " → "))"
    }

    package static func make(_ error: Error, stage: Stage, versionID: UUID? = nil) -> Self {
        var errors: [NSError] = []
        var next = error as NSError
        if let wrapped = error as? SnapshotError, case .underlying(_, let underlying) = wrapped { next = underlying }
        for _ in 0..<5 {
            errors.append(next)
            guard let underlying = next.userInfo[NSUnderlyingErrorKey] as? NSError else { break }
            next = underlying
        }
        func contains(_ domain: String, _ codes: [Int]) -> Bool {
            errors.contains { $0.domain == domain && codes.contains($0.code) }
        }
        let kind: Kind
        let message: String
        if stage == .localRecord || stage == .receipt {
            kind = .other
            message = "Sync progress could not be saved on this Mac. Your tasks and snapshot files are kept."
        } else if contains(NSCocoaErrorDomain, [NSFileReadNoPermissionError, NSFileWriteNoPermissionError]) || contains(NSPOSIXErrorDomain, [Int(EACCES), Int(EPERM)]) {
            kind = .permission
            message = "JotBaton cannot access the snapshot files."
        } else if contains(NSCocoaErrorDomain, [NSUbiquitousFileNotUploadedDueToQuotaError]) || contains("NSFileProviderErrorDomain", [-1003]) {
            kind = .quota
            message = "iCloud storage is full. Upload is not confirmed."
        } else if contains(NSCocoaErrorDomain, [NSUbiquitousFileUbiquityServerNotAvailable]) || contains("NSFileProviderErrorDomain", [-1000, -1004]) || errors.contains(where: { $0.domain == NSURLErrorDomain }) {
            kind = .cloudUnavailable
            message = "iCloud could not confirm the upload or connection."
        } else if stage == .connection {
            kind = .unavailable
            message = error.localizedDescription
        } else {
            kind = .other
            message = stage == .uploadConfirmation ? "The snapshot is saved, but iCloud upload could not be confirmed." : error.localizedDescription
        }
        return Self(kind: kind, stage: stage, message: message,
                    codes: errors.map { "\($0.domain) (\($0.code))" }, date: Date(), versionID: versionID)
    }
}

package struct SnapshotPublication: Codable, Equatable, Sendable {
    package enum Phase: String, Codable, Sendable { case awaitingUpload, unconfirmed, confirmed }
    package let version: SnapshotVersion
    package var phase: Phase
    package var confirmedAt: Date?
    package var previousID: UUID? = nil
    package var currentCommitted = false
    package var cleanupNames: [String] = []
    package var isPending: Bool { phase != .confirmed }
}

package struct SnapshotSyncRecord: Codable, Sendable {
    package var publication: SnapshotPublication?
    package var issue: SnapshotSyncIssue?
    package var contentStamp: SnapshotContentStamp?
    package var lastAppliedAt: Date?
}

package struct SnapshotContentStamp: Codable, Equatable, Sendable {
    package init(contentHash: String, modifiedAt: Date?) { self.contentHash = contentHash; self.modifiedAt = modifiedAt }
    package let contentHash: String
    package let modifiedAt: Date?

}

package enum SnapshotComparison: Equatable {
    case same, publish, receive, choose

    package static func compare(localTime: Date?, cloud: SnapshotVersion?, baselineID: UUID?,
                        baselineLocalTime: Date?, baselineCloudTime: Date?) -> Self {
        guard let cloud else { return .publish }
        let cloudTime = cloud.contentModifiedAt ?? cloud.createdAt
        guard let localTime else { return .choose }
        // A new archive ID alone does not make matching content clocks newer.
        if localTime == cloud.contentModifiedAt { return .same }
        guard let baselineID, let baselineLocalTime else {
            return localTime == cloudTime ? .same : .choose
        }
        let localChanged = localTime != baselineLocalTime
        let cloudChanged = cloud.id != baselineID || cloudTime != baselineCloudTime
        switch (localChanged, cloudChanged) {
        case (false, false): return .same
        case (true, false): return .publish
        case (false, true): return .receive
        case (true, true): return .choose
        }
    }

}

package enum SnapshotSyncStore {
    package static func load(from root: URL) throws -> SnapshotSyncRecord {
        let url = root.appendingPathComponent("snapshot-sync-v2.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return SnapshotSyncRecord() }
        return try JSONDecoder().decode(SnapshotSyncRecord.self, from: Data(contentsOf: url))
    }
    package static func save(_ record: SnapshotSyncRecord, to root: URL) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try SnapshotArchive.encode(record).write(to: root.appendingPathComponent("snapshot-sync-v2.json"), options: .atomic)
    }
}

/// Shared by the UI and operation entry points. Unknown or stale state is not actionable.
package struct SnapshotActionAvailability {
    package let canPublish: Bool
    package let canApply: Bool

    package init(enabled: Bool, busy: Bool, connected: Bool, checked: Bool,
         localReady: Bool, hasIssue: Bool, pending: Bool,
         transfer: SnapshotCloudTransfer, comparison: SnapshotComparison, hasCloud: Bool) {
        let ready = enabled && !busy && connected && checked && localReady
            && !hasIssue && !pending && !transfer.blocksReplacement && transfer != .unknown
        canPublish = ready && (!hasCloud || comparison == .publish || comparison == .choose)
        canApply = ready && hasCloud && (comparison == .receive || comparison == .choose)
    }
}

/// Presentation distinguishes missing history from edits on both devices.
package enum SnapshotGuidance: Equatable {
    case current, backup, restore, setup, conflict

    package init(comparison: SnapshotComparison, hasBaseline: Bool) {
        switch comparison {
        case .same: self = .current
        case .publish: self = .backup
        case .receive: self = .restore
        case .choose: self = hasBaseline ? .conflict : .setup
        }
    }

    package var title: String {
        switch self {
        case .current: return L10n.tr("Everything is backed up")
        case .backup: return L10n.tr("You have changes to back up")
        case .restore: return L10n.tr("A newer cloud backup is available")
        case .setup: return L10n.tr("Choose your starting data")
        case .conflict: return L10n.tr("Both devices have made changes")
        }
    }
    package var explanation: String {
        switch self {
        case .current: return L10n.tr("This Mac’s data is backed up. No action needed.")
        case .backup: return L10n.tr("Back up this Mac’s latest changes to iCloud.")
        case .restore: return L10n.tr("Another Mac updated the backup. Restore it to use those changes here.")
        case .setup: return L10n.tr("This Mac has not synced with this backup yet. Choose which data you want to keep using.")
        case .conflict: return L10n.tr("Both this Mac and the cloud backup changed since the last sync. Changes have not been merged.")
        }
    }
}

/// Reopening the main interface is the only automatic refresh trigger.
package enum SnapshotRefreshPolicy {
    package static func shouldCheckOnShow(wasVisible: Bool, enabled: Bool, busy: Bool, reviewing: Bool) -> Bool {
        !wasVisible && enabled && !busy && !reviewing
    }
}
