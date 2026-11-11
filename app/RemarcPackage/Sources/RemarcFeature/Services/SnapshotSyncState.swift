import Foundation

enum SnapshotCloudTransfer: Equatable, Sendable {
    case unknown, empty, uploading, downloading, transferring, waiting, ready, failed

    var title: String {
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
    var isActive: Bool { self == .uploading || self == .downloading || self == .transferring }
    var blocksReplacement: Bool { isActive || self == .waiting || self == .failed }
}

struct SnapshotSyncIssue: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case permission, cloudUnavailable, quota, unavailable, review, other }
    enum Stage: String, Codable, Sendable { case connection, checking, preparing, publishing, uploadConfirmation, applying, localRecord, receipt }
    let kind: Kind
    let stage: Stage
    let message: String
    let codes: [String]
    let date: Date
    let versionID: UUID?

    var needsAuthorization: Bool { kind == .permission }
    var needsICloudSettings: Bool { kind == .cloudUnavailable || kind == .quota || kind == .unavailable }
    var isWarning: Bool { (stage == .uploadConfirmation && kind != .permission && kind != .quota) || kind == .review }
    var diagnostic: String {
        // Error userInfo can contain paths, account identifiers, and file data.
        // Store only domains/codes, the operation, date, and snapshot identifier.
        "Stage: \(stage.rawValue)\nTime: \(date.formatted(date: .numeric, time: .standard))\nVersion: \(versionID?.uuidString ?? "none")\nErrors: \(codes.joined(separator: " → "))"
    }

    static func make(_ error: Error, stage: Stage, versionID: UUID? = nil) -> Self {
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
            message = "Remarc cannot access the snapshot files."
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

struct SnapshotPublication: Codable, Equatable, Sendable {
    enum Phase: String, Codable, Sendable { case awaitingUpload, unconfirmed, confirmed }
    let version: SnapshotVersion
    var phase: Phase
    var confirmedAt: Date?
    var previousID: UUID? = nil
    var currentCommitted = false
    var cleanupNames: [String] = []
    var isPending: Bool { phase != .confirmed }
}

struct SnapshotSyncRecord: Codable, Sendable {
    var publication: SnapshotPublication?
    var issue: SnapshotSyncIssue?
    var contentStamp: SnapshotContentStamp?
    var lastAppliedAt: Date?
}

struct SnapshotContentStamp: Codable, Equatable, Sendable {
    let contentHash: String
    let modifiedAt: Date?

    static func tracking(hash: String, saved: Self?, adopted: Self?, observedLive: Bool, now: Date) -> Self {
        // Initial discovery is not a data edit. Offline edits with no recorded
        // content clock stay unknown instead of being dated at the next check.
        if !observedLive {
            if let adopted, adopted.contentHash == hash { return adopted }
            if let saved, saved.contentHash == hash { return saved }
            return Self(contentHash: hash, modifiedAt: nil)
        }
        if let saved, saved.contentHash == hash { return saved }
        return Self(contentHash: hash, modifiedAt: now)
    }
}

enum SnapshotComparison: Equatable {
    case same, publish, receive, choose

    static func compare(localHash: String?, localTime: Date?, cloud: SnapshotVersion?,
                        baselineID: UUID?, localEdits: Bool, multipleCloudHeads: Bool,
                        baselineHash: String? = nil) -> Self {
        if multipleCloudHeads { return .choose }
        guard let cloud else { return .publish }
        if localHash == cloud.contentHash { return .same }
        // An applied cross-OS snapshot has a source fingerprint and a local
        // fingerprint. Only the exact applied version can use this baseline.
        if baselineID == cloud.id, let localHash, localHash == baselineHash { return .same }
        let cloudChanged = baselineID != cloud.id
        if localEdits && cloudChanged { return .choose }
        if localEdits && !cloudChanged { return .publish }
        if !localEdits && cloudChanged { return .receive }
        if let localTime, let remoteTime = cloud.contentModifiedAt {
            if localTime > remoteTime { return .publish }
            if remoteTime > localTime { return .receive }
        }
        // Equal/missing times cannot safely order different content.
        return .choose
    }
}

enum SnapshotSyncStore {
    static func load(from root: URL) throws -> SnapshotSyncRecord {
        let url = root.appendingPathComponent("snapshot-sync-v2.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return SnapshotSyncRecord() }
        return try JSONDecoder().decode(SnapshotSyncRecord.self, from: Data(contentsOf: url))
    }
    static func save(_ record: SnapshotSyncRecord, to root: URL) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try SnapshotArchive.encode(record).write(to: root.appendingPathComponent("snapshot-sync-v2.json"), options: .atomic)
    }
}
