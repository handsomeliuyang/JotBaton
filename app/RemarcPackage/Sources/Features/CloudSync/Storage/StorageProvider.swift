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
    func readData(at url: URL) throws -> Data
    func writeData(_ data: Data, to url: URL, onlyIfMissing: Bool) throws
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
}
