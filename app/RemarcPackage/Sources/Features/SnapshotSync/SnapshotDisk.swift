import CoreLocalization
import CorePlatform
import FeatureComments
import Foundation

/// One immutable payload and a small current.json commit marker. No version history.
package enum SnapshotDisk {
    package static let currentName = "current.json"

    package static func current(in directory: URL) throws -> SnapshotVersion? {
        let fm = FileManager.default
        let url = directory.appendingPathComponent(currentName)
        guard fm.fileExists(atPath: directory.path) else {
            throw SnapshotError.message(L10n.tr("The iCloud data folder is unavailable."))
        }
        if !fm.fileExists(atPath: url.path) {
            if fm.fileExists(atPath: directory.appendingPathComponent(".current.json.icloud").path) {
                try? fm.startDownloadingUbiquitousItem(at: url)
                throw SnapshotError.waitingForDownload
            }
            return nil
        }
        let data = try coordinatedRead(url)
        guard data.count < 1_000_000 else { throw SnapshotError.message(L10n.tr("A snapshot description is too large.")) }
        let version = try JSONDecoder().decode(SnapshotVersion.self, from: data)
        try validate(version)
        return version
    }

    package static func validate(_ version: SnapshotVersion) throws {
        guard version.formatVersion == 2, SnapshotArchive.validArchiveName(version.archiveName),
              version.archiveName.hasSuffix("_\(version.id.uuidString.prefix(8)).zip"),
              version.archiveHash.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil else {
            throw SnapshotError.message(L10n.tr("This cloud data uses an unsupported format."))
        }
    }

    package static func ensureDownloaded(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey, .ubiquitousItemDownloadingErrorKey])
        if let error = values.ubiquitousItemDownloadingError { throw error }
        if values.isUbiquitousItem == true, values.ubiquitousItemDownloadingStatus != .current {
            try FileManager.default.startDownloadingUbiquitousItem(at: url)
            throw SnapshotError.waitingForDownload
        }
    }

    package static func coordinatedRead(_ url: URL) throws -> Data {
        try ensureDownloaded(url)
        return try coordinate(url, writing: false) { try Data(contentsOf: $0, options: .mappedIfSafe) }
    }

    package static func download(_ version: SnapshotVersion, from directory: URL, to local: URL) throws {
        try validate(version)
        let source = directory.appendingPathComponent(version.archiveName)
        try ensureDownloaded(source)
        try coordinate(source, writing: false) { try FileManager.default.copyItem(at: $0, to: local) }
    }

    package static func stageArchive(_ version: SnapshotVersion, from local: URL, to directory: URL) throws {
        try validate(version)
        guard try SnapshotArchive.fileDigest(local) == version.archiveHash else {
            throw SnapshotError.message(L10n.tr("The generated data failed verification. Your local tasks are kept."))
        }
        let archive = directory.appendingPathComponent(version.archiveName)
        try coordinate(archive, writing: true) { target in
            if FileManager.default.fileExists(atPath: target.path) {
                guard try SnapshotArchive.fileDigest(target) == version.archiveHash else {
                    throw SnapshotError.message(L10n.tr("The existing cloud snapshot has different contents. It has not been overwritten."))
                }
            } else {
                try Data(contentsOf: local, options: .mappedIfSafe).write(to: target, options: .atomic)
            }
        }
    }

    /// Only called after the payload's upload is confirmed. A concurrent publish
    /// must be reviewed rather than silently overwritten by a stale dialog.
    package static func commitCurrent(_ version: SnapshotVersion, replacing expectedID: UUID?, in directory: URL) throws {
        try validate(version)
        try coordinate(directory.appendingPathComponent(currentName), writing: true) { target in
            let existing: SnapshotVersion?
            if FileManager.default.fileExists(atPath: target.path) {
                existing = try JSONDecoder().decode(SnapshotVersion.self, from: Data(contentsOf: target))
            } else { existing = nil }
            if existing?.id == version.id { return }
            guard existing?.id == expectedID else {
                throw SnapshotError.message(L10n.tr("Cloud data changed while publishing. Check again before replacing it."))
            }
            try SnapshotArchive.encode(version).write(to: target, options: .atomic)
        }
    }

    /// Capture a bounded deletion list before publishing. Do not remove another
    /// Mac's newly staged payload while it is still being uploaded.
    package static func cleanupCandidates(in directory: URL, current: SnapshotVersion?, abandoned: SnapshotVersion?, now: Date = Date()) throws -> [String] {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])
            .compactMap { url in
                let name = normalizedCloudName(url.lastPathComponent)
                let stem = (name as NSString).deletingPathExtension
                let ext = (name as NSString).pathExtension
                if ["json", "zip"].contains(ext), UUID(uuidString: stem) != nil { return name }
                guard SnapshotArchive.validArchiveName(name) else { return nil }
                if name == current?.archiveName || name == abandoned?.archiveName { return name }
                if let date = try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                   now.timeIntervalSince(date) > 86400 { return name }
                return nil
            }
    }

    package static func cleanup(_ names: [String], keeping version: SnapshotVersion, in directory: URL) throws {
        guard try current(in: directory)?.id == version.id else { return }
        for name in Set(names) where name != version.archiveName && name != currentName {
            let stem = (name as NSString).deletingPathExtension
            let ext = (name as NSString).pathExtension
            guard SnapshotArchive.validArchiveName(name) || (["json", "zip"].contains(ext) && UUID(uuidString: stem) != nil) else { continue }
            guard try current(in: directory)?.id == version.id else { return }
            let url = directory.appendingPathComponent(name)
            try coordinate(url, writing: true, deleting: true) { target in
                if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
                let placeholder = target.deletingLastPathComponent().appendingPathComponent(".\(name).icloud")
                if FileManager.default.fileExists(atPath: placeholder.path) { try FileManager.default.removeItem(at: placeholder) }
            }
        }
    }

    package enum UploadState: Sendable, Equatable { case uploaded, uploading, unknown }
    package struct UploadEvidence {
        let isCloudItem: Bool?
        let isUploaded: Bool?
        let error: NSError?
    }

    package static func uploadState(from evidence: [UploadEvidence]) throws -> UploadState {
        guard evidence.count == 2 else { return .unknown }
        // Providers can retain a stale error after completing an upload. A
        // positive confirmation for BOTH archive and manifest takes priority.
        if evidence.allSatisfy({ $0.isCloudItem == true && $0.isUploaded == true }) { return .uploaded }
        for item in evidence where item.isUploaded != true {
            if let error = item.error { throw error }
        }
        if evidence.contains(where: { $0.isCloudItem != true || $0.isUploaded == nil }) { return .unknown }
        return .uploading
    }

    package static func archiveUploadState(_ version: SnapshotVersion, in directory: URL) throws -> UploadState {
        let evidence = try uploadEvidence(directory.appendingPathComponent(version.archiveName))
        return try uploadState(from: [evidence, evidence])
    }

    package static func uploadState(_ version: SnapshotVersion, in directory: URL) throws -> UploadState {
        try uploadState(from: [uploadEvidence(directory.appendingPathComponent(version.archiveName)),
                              uploadEvidence(directory.appendingPathComponent(currentName))])
    }

    private static func uploadEvidence(_ url: URL) throws -> UploadEvidence {
        let values = try url.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemIsUploadedKey, .ubiquitousItemUploadingErrorKey])
        return UploadEvidence(isCloudItem: values.isUbiquitousItem, isUploaded: values.ubiquitousItemIsUploaded,
                              error: values.ubiquitousItemUploadingError)
    }

    package struct TransferEvidence {
        var isCloudItem: Bool? = nil
        var isUploaded: Bool? = nil
        var isUploading: Bool? = nil
        var isDownloading: Bool? = nil
        var isCurrent: Bool? = nil
        var hasError = false
        var isMissing = false
    }

    package static func transferState(from evidence: [TransferEvidence]) -> SnapshotCloudTransfer {
        guard !evidence.isEmpty else { return .empty }
        // Completed files may retain an old provider error. A directory's own
        // timestamp or upload flag is never evidence that its contents arrived.
        if evidence.contains(where: { $0.hasError && !($0.isUploaded == true && $0.isCurrent == true) }) { return .failed }
        let uploading = evidence.contains { $0.isUploading == true }
        let downloading = evidence.contains { $0.isDownloading == true }
        if uploading && downloading { return .transferring }
        if uploading { return .uploading }
        if downloading { return .downloading }
        if evidence.contains(where: { $0.isMissing }) { return .waiting }
        if evidence.contains(where: { $0.isCloudItem != true }) { return .unknown }
        if evidence.contains(where: { $0.isUploaded == false || $0.isCurrent == false }) { return .waiting }
        if evidence.count.isMultiple(of: 2), evidence.allSatisfy({ $0.isUploaded == true && $0.isCurrent == true }) { return .ready }
        return .unknown
    }

    package static func transferState(in directory: URL, version: SnapshotVersion?) throws -> SnapshotCloudTransfer {
        guard let version else { return .empty }
        let keys: Set<URLResourceKey> = [.isUbiquitousItemKey, .ubiquitousItemIsUploadedKey,
            .ubiquitousItemIsUploadingKey, .ubiquitousItemIsDownloadingKey, .ubiquitousItemDownloadingStatusKey,
            .ubiquitousItemUploadingErrorKey, .ubiquitousItemDownloadingErrorKey]
        let evidence = try [currentName, version.archiveName].map { name -> TransferEvidence in
            let url = directory.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: url.path) else { return TransferEvidence(isMissing: true) }
            let values = try url.resourceValues(forKeys: keys)
            return TransferEvidence(isCloudItem: values.isUbiquitousItem, isUploaded: values.ubiquitousItemIsUploaded,
                isUploading: values.ubiquitousItemIsUploading, isDownloading: values.ubiquitousItemIsDownloading,
                isCurrent: values.ubiquitousItemDownloadingStatus.map { $0 == .current },
                hasError: values.ubiquitousItemUploadingError != nil || values.ubiquitousItemDownloadingError != nil)
        }
        return transferState(from: evidence)
    }

    private static func normalizedCloudName(_ name: String) -> String {
        if name.hasPrefix("."), name.hasSuffix(".icloud") { return String(name.dropFirst().dropLast(7)) }
        return name
    }

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
        guard let result else { throw SnapshotError.message(L10n.tr("Could not access the snapshot folder.")) }
        return try result.get()
    }
}

package enum SnapshotReplacement {
    package static func commit(_ replacement: AppState, expected: AppState, fileURL: URL) throws {
        try DocumentLock.withLock(fileURL) {
            guard case .decoded(let current) = DocumentRead.read(fileURL), current == expected else {
                throw SnapshotError.message(L10n.tr("An integration changed local data. Nothing was replaced. Please try again."))
            }
            try SnapshotArchive.encode(replacement).write(to: fileURL, options: .atomic)
        }
    }
}
