import CoreLocalization
import CorePlatform
import Darwin
import Foundation

package enum StorageProviderKind: String, CaseIterable, Codable, Sendable, Identifiable {
    case iCloud
    case localFolder

    package var id: String { rawValue }
}

package enum SyncFileAvailability: Equatable, Sendable {
    case ready
    case downloading
    case missing
}

package struct SyncBlobEntry: Equatable, Sendable {
    package let digest: String
    package let createdAt: Date?

    package init(digest: String, createdAt: Date?) {
        self.digest = digest
        self.createdAt = createdAt
    }
}

/// Abstracts where `sync-v3` device files and content-addressed blobs live,
/// so the merge engine and coordinator stay identical across iCloud Drive,
/// Google Drive (FileProvider), Syncthing, and other local sync folders.
package protocol StorageProvider: Sendable {
    var kind: StorageProviderKind { get }
    var supportsSystemCloudSettings: Bool { get }
    func connect(createIfMissing: Bool, verifyWriteAccess: Bool) throws -> URL
    func exists(_ url: URL) -> Bool
    func availability(_ url: URL) -> SyncFileAvailability
    func listDevices(_ layout: SyncLayout) throws -> [UUID]
    func listBlobs(_ layout: SyncLayout) throws -> [SyncBlobEntry]
    func readData(at url: URL) throws -> Data
    func writeData(_ data: Data, to url: URL, onlyIfMissing: Bool) throws
    func deleteItem(at url: URL) throws
    /// `nil` when the underlying storage does not report cloud upload state
    /// (for example Syncthing or an ordinary local folder). Throws on a
    /// provider-reported upload error (such as quota or network failure).
    func uploadState(_ url: URL) throws -> Bool?
}

/// Snapshot of a file's cloud/FileProvider status, decoupled from Foundation
/// I/O so both iCloud placeholders and Google Drive FileProvider dataless
/// states can be evaluated and unit-tested deterministically.
package struct CloudItemState: Equatable, Sendable {
    package let exists: Bool
    package let hasICloudPlaceholder: Bool
    package let isUbiquitous: Bool
    package let downloadingStatus: URLUbiquitousItemDownloadingStatus?
    package let isDownloading: Bool
    package let isDataless: Bool
    package let isUploaded: Bool?
    package let uploadingError: NSError?

    package init(exists: Bool, hasICloudPlaceholder: Bool = false, isUbiquitous: Bool = false,
                 downloadingStatus: URLUbiquitousItemDownloadingStatus? = nil,
                 isDownloading: Bool = false, isDataless: Bool = false,
                 isUploaded: Bool? = nil, uploadingError: NSError? = nil) {
        self.exists = exists
        self.hasICloudPlaceholder = hasICloudPlaceholder
        self.isUbiquitous = isUbiquitous
        self.downloadingStatus = downloadingStatus
        self.isDownloading = isDownloading
        self.isDataless = isDataless
        self.isUploaded = isUploaded
        self.uploadingError = uploadingError
    }
}

/// Shared cloud/FileProvider status inspection used by both iCloud Drive and
/// macOS FileProvider-backed folders (such as Google Drive for Desktop under
/// `~/Library/CloudStorage/GoogleDrive-*`, OneDrive, and Dropbox).
package enum CloudFileStatus {
    package static func iCloudPlaceholder(for url: URL) -> URL {
        url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).icloud")
    }

    /// Checks the APFS `SF_DATALESS` flag via `lstat`, which inspects metadata
    /// without triggering synchronous FileProvider materialization (Apple TN3150).
    package static func isDataless(_ url: URL) -> Bool {
        var st = stat()
        guard lstat(url.path, &st) == 0 else { return false }
        return (st.st_flags & UInt32(SF_DATALESS)) != 0
    }

    package static func inspect(_ url: URL, checksICloudPlaceholder: Bool) -> CloudItemState {
        let fm = FileManager.default
        let exists = fm.fileExists(atPath: url.path)
        let hasPlaceholder = !exists && checksICloudPlaceholder
            && fm.fileExists(atPath: iCloudPlaceholder(for: url).path)
        guard exists else {
            return CloudItemState(exists: false, hasICloudPlaceholder: hasPlaceholder)
        }
        let keys: Set<URLResourceKey> = [
            .isUbiquitousItemKey,
            .ubiquitousItemDownloadingStatusKey,
            .ubiquitousItemIsDownloadingKey,
            .ubiquitousItemIsUploadedKey,
            .ubiquitousItemUploadingErrorKey,
        ]
        let values = try? url.resourceValues(forKeys: keys)
        return CloudItemState(
            exists: true,
            hasICloudPlaceholder: false,
            isUbiquitous: values?.isUbiquitousItem == true,
            downloadingStatus: values?.ubiquitousItemDownloadingStatus,
            isDownloading: values?.ubiquitousItemIsDownloading == true,
            isDataless: isDataless(url),
            isUploaded: values?.ubiquitousItemIsUploaded,
            uploadingError: values?.ubiquitousItemUploadingError as NSError?
        )
    }

    /// Evaluates whether a file is readable locally. Requests an asynchronous
    /// download whenever a newer or unmaterialized version is only in the cloud
    /// (covering both iCloud `.icloud` placeholders and FileProvider dataless
    /// placeholders used by Google Drive for Desktop).
    package static func availability(for state: CloudItemState, startDownload: () -> Void) -> SyncFileAvailability {
        guard state.exists else {
            guard state.hasICloudPlaceholder else { return .missing }
            startDownload()
            return .downloading
        }
        if state.isUbiquitous {
            if let status = state.downloadingStatus {
                if status != .current { startDownload() }
                if status == .notDownloaded { return .downloading }
            } else if state.isDownloading {
                return .downloading
            }
        }
        if state.isDataless {
            startDownload()
            return .downloading
        }
        return .ready
    }

    package static func availability(_ url: URL, checksICloudPlaceholder: Bool) -> SyncFileAvailability {
        let state = inspect(url, checksICloudPlaceholder: checksICloudPlaceholder)
        return availability(for: state) {
            try? FileManager.default.startDownloadingUbiquitousItem(at: url)
        }
    }

    /// Evaluates FileProvider / iCloud upload state. Returns `nil` for plain
    /// local folders (e.g. Syncthing) where the OS does not track cloud uploads.
    package static func uploadState(for state: CloudItemState) throws -> Bool? {
        guard state.isUbiquitous else { return nil }
        if state.isUploaded == true { return true }
        if let error = state.uploadingError { throw error }
        return state.isUploaded
    }

    package static func uploadState(_ url: URL) throws -> Bool? {
        try uploadState(for: inspect(url, checksICloudPlaceholder: false))
    }

    package static func isMissingFileError(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain && nsError.code == NSFileNoSuchFileError { return true }
        if nsError.domain == NSPOSIXErrorDomain && nsError.code == Int(ENOENT) { return true }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
            return isMissingFileError(underlying)
        }
        return false
    }

    package static func deleteCoordinated(_ url: URL) throws {
        do {
            try SyncIO.coordinate(url, writing: true, deleting: true) { target in
                do {
                    try FileManager.default.removeItem(at: target)
                } catch where isMissingFileError(error) {
                    return
                }
            }
        } catch where isMissingFileError(error) {
            return
        }
    }

    /// Scans `blobs/` using metadata keys only (no FileProvider materialization).
    /// Takes `max(creationDate, contentModificationDate)` so preserved old mtimes
    /// or newly copied blobs both respect the grace period conservatively.
    package static func listBlobs(in directory: URL, includeICloudPlaceholders: Bool) throws -> [SyncBlobEntry] {
        let keys: [URLResourceKey] = [
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .creationDateKey,
            .contentModificationDateKey,
        ]
        let urls: [URL]
        do {
            urls = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys)
        } catch where isMissingFileError(error) {
            return []
        }
        var entriesByDigest: [String: SyncBlobEntry] = [:]
        for url in urls {
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isSymbolicLink != true,
                  values.isRegularFile == true else { continue }
            var name = url.lastPathComponent
            if includeICloudPlaceholders, name.hasPrefix("."), name.hasSuffix(".icloud") {
                name = String(name.dropFirst().dropLast(7))
            } else if name.hasPrefix(".") {
                continue
            }
            guard name.hasSuffix(".blob") else { continue }
            let digest = String(name.dropLast(5))
            guard SyncAssets.isValidBlobDigest(digest) else { continue }
            let timestamp = [values.creationDate, values.contentModificationDate].compactMap { $0 }.max()
            if let existing = entriesByDigest[digest] {
                let mergedDate: Date?
                switch (existing.createdAt, timestamp) {
                case let (lhs?, rhs?): mergedDate = max(lhs, rhs)
                case (nil, _), (_, nil): mergedDate = nil
                }
                entriesByDigest[digest] = SyncBlobEntry(digest: digest, createdAt: mergedDate)
            } else {
                entriesByDigest[digest] = SyncBlobEntry(digest: digest, createdAt: timestamp)
            }
        }
        return entriesByDigest.values.sorted { $0.digest < $1.digest }
    }
}
