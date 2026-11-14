import CoreLocalization
import CorePlatform
import CryptoKit
import FeatureComments
import Foundation

package enum SyncIO {
    /// Stable bytes for digests and files: keys are always sorted.
    package static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    package static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    package static func fileDigest(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let bytes = try handle.read(upToCount: 1_048_576), !bytes.isEmpty { hash.update(data: bytes) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// iCloud requires file coordination; a coordinated read also downloads.
    package static func coordinate<T>(_ url: URL, writing: Bool, deleting: Bool = false, _ body: (URL) throws -> T) throws -> T {
        let coordinator = NSFileCoordinator()
        var error: NSError?
        var result: Result<T, Error>?
        if writing {
            coordinator.coordinate(writingItemAt: url, options: deleting ? .forDeleting : [], error: &error) { target in
                result = Result { try body(target) }
            }
        } else {
            coordinator.coordinate(readingItemAt: url, options: [], error: &error) { target in
                result = Result { try body(target) }
            }
        }
        if let error { throw error }
        guard let result else { throw CloudSyncError.message(L10n.tr("Could not access the iCloud sync folder.")) }
        return try result.get()
    }
}

/// What one Mac publishes: its merged document without device-local state, and
/// the content digest of every image file that document references. Each Mac
/// writes only its own file, so iCloud never has to resolve a write conflict.
package struct SyncDeviceFile: Codable, Equatable, Sendable {
    package static let currentFormat = 3
    package var formatVersion = SyncDeviceFile.currentFormat
    package var deviceID: UUID
    package var deviceName: String
    package var writtenAt: Date
    package var state: AppState
    /// `images/<UUID>.<suffix>` → SHA-256 of that file's bytes.
    package var assets: [String: String]

    package init(deviceID: UUID, deviceName: String, writtenAt: Date, state: AppState, assets: [String: String]) {
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.writtenAt = writtenAt
        self.state = state
        self.assets = assets
    }

    /// Identity of the published content, independent of when it was written.
    package var contentDigest: String {
        var identity = (try? SyncIO.encode(state)) ?? Data()
        identity.append((try? SyncIO.encode(assets)) ?? Data())
        identity.append(Data(deviceName.utf8))
        return SyncIO.digest(identity)
    }
}

/// Selection, empty-session clocks, orphan bookkeeping, legacy agent pairing and
/// document keys from other builds belong to this Mac. They never leave it and
/// never count as edits.
package enum SyncProjection {
    package static func make(_ state: AppState) -> AppState {
        var projection = AppState(sessions: state.sessions, comments: state.comments, activeSessionID: nil,
                                  totalCommentsCreated: state.totalCommentsCreated, orphanedImages: [], unknownFields: [:])
        for index in projection.sessions.indices {
            projection.sessions[index].emptySince = nil
            projection.sessions[index].unknownFields.removeValue(forKey: "claudeCodeSessionId")
        }
        return projection
    }
}

package struct SyncLayout: Sendable {
    package let root: URL

    package init(folder: URL) {
        root = folder.appendingPathComponent("sync-v3", isDirectory: true)
    }

    package var devices: URL { root.appendingPathComponent("devices", isDirectory: true) }
    package var blobs: URL { root.appendingPathComponent("blobs", isDirectory: true) }
    package func deviceFile(_ id: UUID) -> URL { devices.appendingPathComponent("\(id.uuidString).json") }
    package func blob(_ digest: String) -> URL { blobs.appendingPathComponent("\(digest).blob") }

    /// Only these children of the app's own iCloud folder are ever created.
    package func prepare() throws {
        for directory in [root, devices, blobs] where !FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        }
    }
}

package enum SyncCloud {
    package enum Availability: Equatable, Sendable { case ready, downloading, missing }

    package enum LoadResult: Equatable, Sendable {
        case file(SyncDeviceFile)
        /// Not on this Mac yet. A download has been requested.
        case waiting
        /// Written by a newer JotBaton; this build must not merge it.
        case newerFormat(deviceName: String)
        case invalid
    }

    private struct Header: Decodable {
        let formatVersion: Int
        let deviceID: UUID
        let deviceName: String
    }

    private static func placeholder(for url: URL) -> URL {
        url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).icloud")
    }

    package static func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path) || FileManager.default.fileExists(atPath: placeholder(for: url).path)
    }

    /// Requests a download whenever the newest bytes are not local. An older
    /// downloaded version still counts as readable: merging a stale copy is safe,
    /// and refusing it is exactly how sync used to stall.
    package static func availability(_ url: URL) -> Availability {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else {
            guard fm.fileExists(atPath: placeholder(for: url).path) else { return .missing }
            try? fm.startDownloadingUbiquitousItem(at: url)
            return .downloading
        }
        guard let values = try? url.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]),
              values.isUbiquitousItem == true, let status = values.ubiquitousItemDownloadingStatus else { return .ready }
        if status != .current { try? fm.startDownloadingUbiquitousItem(at: url) }
        return status == .notDownloaded ? .downloading : .ready
    }

    /// Device identifiers present in the cloud folder, including evicted ones.
    package static func listDevices(_ layout: SyncLayout) throws -> [UUID] {
        try FileManager.default.contentsOfDirectory(atPath: layout.devices.path).compactMap { name in
            var name = name
            if name.hasPrefix("."), name.hasSuffix(".icloud") { name = String(name.dropFirst().dropLast(7)) }
            guard name.hasSuffix(".json") else { return nil }
            return UUID(uuidString: String(name.dropLast(5)))
        }
    }

    package static func load(_ id: UUID, layout: SyncLayout) -> LoadResult {
        let url = layout.deviceFile(id)
        switch availability(url) {
        case .missing: return .invalid
        case .downloading: return .waiting
        case .ready: break
        }
        do {
            let data = try SyncIO.coordinate(url, writing: false) { try Data(contentsOf: $0, options: .mappedIfSafe) }
            guard data.count < 128_000_000 else { return .invalid }
            let header = try JSONDecoder().decode(Header.self, from: data)
            guard header.deviceID == id else { return .invalid }
            guard header.formatVersion <= SyncDeviceFile.currentFormat else { return .newerFormat(deviceName: header.deviceName) }
            let file = try JSONDecoder().decode(SyncDeviceFile.self, from: data)
            guard Set(file.state.comments.map(\.id)).count == file.state.comments.count,
                  Set(file.state.sessions.map(\.id)).count == file.state.sessions.count else { return .invalid }
            return .file(file)
        } catch {
            return .invalid
        }
    }

    package static func write(_ file: SyncDeviceFile, layout: SyncLayout) throws {
        let data = try SyncIO.encode(file)
        try SyncIO.coordinate(layout.deviceFile(file.deviceID), writing: true) { target in
            try data.write(to: target, options: .atomic)
        }
    }

    /// Snapshot files from the retired manual flow (`current.json`, timestamped
    /// archives, and the older per-UUID layout). Only direct children of the
    /// app's own folder are considered; `sync-v3` is never touched.
    package static func removeLegacySnapshots(in folder: URL) throws {
        let archive = #"^\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2}[+-]\d{4}_[\p{L}\p{N}_-]{1,40}_[A-F0-9]{8}\.zip$"#
        for entry in try FileManager.default.contentsOfDirectory(atPath: folder.path) {
            var name = entry
            if name.hasPrefix("."), name.hasSuffix(".icloud") { name = String(name.dropFirst().dropLast(7)) }
            let stem = (name as NSString).deletingPathExtension
            let ext = (name as NSString).pathExtension
            let legacy = name == "current.json"
                || name.range(of: archive, options: .regularExpression) != nil
                || (["json", "zip"].contains(ext) && UUID(uuidString: stem) != nil)
            guard legacy else { continue }
            try SyncIO.coordinate(folder.appendingPathComponent(name), writing: true, deleting: true) { target in
                if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
            }
            let placeholder = folder.appendingPathComponent(".\(name).icloud")
            if FileManager.default.fileExists(atPath: placeholder.path) { try? FileManager.default.removeItem(at: placeholder) }
        }
    }

    /// nil when the provider does not report upload state. A reported upload
    /// failure (quota, server) is thrown so it can be shown, not waited on.
    package static func uploadState(_ url: URL) throws -> Bool? {
        guard let values = try? url.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemIsUploadedKey, .ubiquitousItemUploadingErrorKey]),
              values.isUbiquitousItem == true else { return nil }
        if values.ubiquitousItemIsUploaded == true { return true }
        if let error = values.ubiquitousItemUploadingError { throw error }
        return values.ubiquitousItemIsUploaded
    }
}

/// This Mac's sync bookkeeping. Nothing here is required to recover data: losing
/// it only means the next merge has no base and resolves every difference by time.
package struct SyncRecord: Codable, Sendable {
    package var publishedDigest: String?
    package var publishedAt: Date?
    package var lastSuccessAt: Date?
    package var conflicts: [SyncConflict] = []
    /// Retired manual-snapshot files were removed from iCloud after this Mac's
    /// first successful publish.
    package var removedLegacySnapshots = false

    package init() {}

    package init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        publishedDigest = try container.decodeIfPresent(String.self, forKey: .publishedDigest)
        publishedAt = try container.decodeIfPresent(Date.self, forKey: .publishedAt)
        lastSuccessAt = try container.decodeIfPresent(Date.self, forKey: .lastSuccessAt)
        conflicts = try container.decodeIfPresent([SyncConflict].self, forKey: .conflicts) ?? []
        removedLegacySnapshots = try container.decodeIfPresent(Bool.self, forKey: .removedLegacySnapshots) ?? false
    }
}

package enum SyncLocalStore {
    package static let restorePointLimit = 10

    package static func directory(in root: URL) -> URL { root.appendingPathComponent("sync-v3", isDirectory: true) }
    private static func record(in root: URL) -> URL { directory(in: root).appendingPathComponent("record.json") }
    private static func digests(in root: URL) -> URL { directory(in: root).appendingPathComponent("asset-digests.json") }
    private static func bases(in root: URL) -> URL { directory(in: root).appendingPathComponent("base", isDirectory: true) }
    private static func restorePoints(in root: URL) -> URL { directory(in: root).appendingPathComponent("restore-points", isDirectory: true) }

    private static func save<T: Encodable>(_ value: T, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try SyncIO.encode(value).write(to: url, options: .atomic)
    }

    private static func load<T: Decodable>(_ type: T.Type, from url: URL) throws -> T? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(type, from: Data(contentsOf: url))
    }

    /// Bookkeeping left by the retired manual snapshot flow. Everything lives in
    /// this app's own Application Support folder.
    package static func removeLegacySnapshotFiles(in root: URL) {
        for name in ["snapshot-sync-v2.json", "snapshot-sync-state.json", "snapshot-rollback", "snapshot-outbox", "snapshot-backups"] {
            let url = root.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path) { try? FileManager.default.removeItem(at: url) }
        }
    }

    package static func loadRecord(in root: URL) throws -> SyncRecord { try load(SyncRecord.self, from: record(in: root)) ?? SyncRecord() }
    package static func saveRecord(_ value: SyncRecord, in root: URL) throws { try save(value, to: record(in: root)) }

    package static func loadDigests(in root: URL) -> [String: SyncAssets.CachedDigest] {
        (try? load([String: SyncAssets.CachedDigest].self, from: digests(in: root))) ?? [:]
    }
    package static func saveDigests(_ value: [String: SyncAssets.CachedDigest], in root: URL) throws { try save(value, to: digests(in: root)) }

    /// The copy of a device's file this Mac last merged: the three-way base.
    package static func loadBase(_ id: UUID, in root: URL) -> SyncDeviceFile? {
        try? load(SyncDeviceFile.self, from: bases(in: root).appendingPathComponent("\(id.uuidString).json"))
    }
    package static func saveBase(_ file: SyncDeviceFile, in root: URL) throws {
        try save(file, to: bases(in: root).appendingPathComponent("\(file.deviceID.uuidString).json"))
    }

    /// The complete local document before a merge changed it, newest kept last.
    package static func saveRestorePoint(_ state: AppState, at date: Date = Date(), in root: URL) throws {
        let directory = restorePoints(in: root)
        let name = "\(Int64(date.timeIntervalSince1970 * 1000)).json"
        try save(state, to: directory.appendingPathComponent(name))
        let files = try restorePointFiles(in: root)
        for file in files.dropLast(restorePointLimit) { try? FileManager.default.removeItem(at: file) }
    }

    package static func hasRestorePoint(in root: URL) -> Bool {
        !((try? restorePointFiles(in: root)) ?? []).isEmpty
    }

    package static func latestRestorePoint(in root: URL) throws -> (url: URL, state: AppState)? {
        guard let url = try restorePointFiles(in: root).last,
              let state = try load(AppState.self, from: url) else { return nil }
        return (url, state)
    }

    private static func restorePointFiles(in root: URL) throws -> [URL] {
        let directory = restorePoints(in: root)
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" && Int64($0.deletingPathExtension().lastPathComponent) != nil }
            .sorted { Int64($0.deletingPathExtension().lastPathComponent)! < Int64($1.deletingPathExtension().lastPathComponent)! }
    }
}
