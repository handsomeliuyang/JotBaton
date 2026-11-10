import Foundation

enum SnapshotDisk {
    static func versions(in directory: URL) throws -> [SnapshotVersion] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: directory.path) else {
            throw SnapshotError.message(L10n.tr("\(AppIdentity.current.cloudDisplayPath) is unavailable. Check iCloud Drive and retry the connection."))
        }
        return try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .compactMap { entry -> SnapshotVersion? in
                var name = entry.lastPathComponent
                if name.hasPrefix("."), name.hasSuffix(".json.icloud") {
                    name = String(name.dropFirst().dropLast(7))
                }
                guard name.hasSuffix(".json"), UUID(uuidString: String(name.dropLast(5))) != nil else { return nil }
                let url = directory.appendingPathComponent(name)
                let data = try coordinatedRead(url)
                guard data.count < 1_000_000 else { throw SnapshotError.message(L10n.tr("A snapshot description is too large.")) }
                let version = try JSONDecoder().decode(SnapshotVersion.self, from: data)
                guard version.id.uuidString == String(name.dropLast(5)), version.formatVersion == 1 else {
                    throw SnapshotError.message(L10n.tr("A snapshot uses an unsupported format. Update Remarc before continuing."))
                }
                return version
            }.sorted { a, b in a.createdAt == b.createdAt ? a.id.uuidString > b.id.uuidString : a.createdAt > b.createdAt }
    }

    /// Heads, rather than timestamps, distinguish the next version from an
    /// accidental fork. Timestamps only order the list shown to the user.
    static func heads(_ versions: [SnapshotVersion]) -> [SnapshotVersion] {
        let parents = Set(versions.compactMap(\.parentID) + versions.flatMap { $0.supersededIDs ?? [] })
        return versions.filter { !parents.contains($0.id) }
    }

    static func ensureDownloaded(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey, .ubiquitousItemDownloadingErrorKey])
        if let error = values.ubiquitousItemDownloadingError { throw error }
        if values.isUbiquitousItem == true, values.ubiquitousItemDownloadingStatus != .current {
            try FileManager.default.startDownloadingUbiquitousItem(at: url)
            throw SnapshotError.waitingForDownload
        }
    }

    static func coordinatedRead(_ url: URL) throws -> Data {
        try ensureDownloaded(url)
        return try coordinate(url, writing: false) { try Data(contentsOf: $0, options: .mappedIfSafe) }
    }

    static func download(_ version: SnapshotVersion, from directory: URL, to local: URL) throws {
        let source = directory.appendingPathComponent("\(version.id).zip")
        try ensureDownloaded(source)
        try coordinate(source, writing: false) { url in
            try FileManager.default.copyItem(at: url, to: local)
        }
    }

    static func publish(_ version: SnapshotVersion, from local: URL, to directory: URL) throws {
        guard try SnapshotArchive.fileDigest(local) == version.archiveHash else {
            throw SnapshotError.message(L10n.tr("The saved local snapshot failed verification. Your tasks are kept; review the local snapshot files before retrying."))
        }
        let archive = directory.appendingPathComponent("\(version.id).zip")
        try coordinate(archive, writing: true) { target in
            if FileManager.default.fileExists(atPath: target.path) {
                guard try SnapshotArchive.fileDigest(target) == version.archiveHash else {
                    throw SnapshotError.message(L10n.tr("The existing cloud snapshot has different contents. It has not been overwritten."))
                }
            } else {
                // A crash must not leave a partially copied final archive that
                // makes every retry fail. Data.atomic publishes by rename.
                try Data(contentsOf: local, options: .mappedIfSafe).write(to: target, options: .atomic)
            }
        }
        // The index is the commit marker. Arrival order is still arbitrary on
        // another Mac, so apply always downloads and verifies the archive.
        let manifest = directory.appendingPathComponent("\(version.id).json")
        try coordinate(manifest, writing: true) { target in
            if FileManager.default.fileExists(atPath: target.path) {
                guard try JSONDecoder().decode(SnapshotVersion.self, from: Data(contentsOf: target)) == version else {
                    throw SnapshotError.message(L10n.tr("The cloud version description differs from this snapshot. It has not been overwritten."))
                }
            } else {
                try SnapshotArchive.encode(version).write(to: target, options: .atomic)
            }
        }
    }

    enum UploadState: Sendable, Equatable { case uploaded, uploading, unknown }
    struct UploadEvidence {
        let isCloudItem: Bool?
        let isUploaded: Bool?
        let error: NSError?
    }

    static func uploadState(from evidence: [UploadEvidence]) throws -> UploadState {
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

    static func uploadState(_ version: SnapshotVersion, in directory: URL) throws -> UploadState {
        var evidence: [UploadEvidence] = []
        for suffix in ["zip", "json"] {
            let values = try directory.appendingPathComponent("\(version.id).\(suffix)").resourceValues(
                forKeys: [.isUbiquitousItemKey, .ubiquitousItemIsUploadedKey, .ubiquitousItemUploadingErrorKey])
            evidence.append(UploadEvidence(isCloudItem: values.isUbiquitousItem,
                isUploaded: values.ubiquitousItemIsUploaded, error: values.ubiquitousItemUploadingError))
        }
        return try uploadState(from: evidence)
    }

    struct TransferEvidence {
        var isCloudItem: Bool? = nil
        var isUploaded: Bool? = nil
        var isUploading: Bool? = nil
        var isDownloading: Bool? = nil
        var isCurrent: Bool? = nil
        var hasError = false
        var isMissing = false
    }

    static func transferState(from evidence: [TransferEvidence]) -> SnapshotCloudTransfer {
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

    static func transferFileNames(versions: [SnapshotVersion], pending: SnapshotVersion?, discoveredNames: [String]) -> Set<String> {
        let knownIDs = Set(versions.map(\.id))
        var ids = Set(heads(versions).map(\.id))
        if let pending { ids.insert(pending.id) }
        for name in discoveredNames {
            let name = normalizedCloudName(name)
            let ext = (name as NSString).pathExtension
            guard ext == "json" || ext == "zip",
                  let id = UUID(uuidString: (name as NSString).deletingPathExtension), !knownIDs.contains(id) else { continue }
            ids.insert(id)
        }
        // Include both files even when the other Mac's manifest or archive
        // hasn't arrived yet. Historical snapshots do not block current data.
        return Set(ids.flatMap { ["\($0).json", "\($0).zip"] })
    }

    static func transferState(in directory: URL, versions: [SnapshotVersion], pending: SnapshotVersion?) throws -> SnapshotCloudTransfer {
        let keys: Set<URLResourceKey> = [.isUbiquitousItemKey, .ubiquitousItemIsUploadedKey,
            .ubiquitousItemIsUploadingKey, .ubiquitousItemIsDownloadingKey, .ubiquitousItemDownloadingStatusKey,
            .ubiquitousItemUploadingErrorKey, .ubiquitousItemDownloadingErrorKey]
        let entries = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        let names = Set(entries.map { normalizedCloudName($0.lastPathComponent) })
        let files = transferFileNames(versions: versions, pending: pending, discoveredNames: Array(names))
        let evidence = try files.map { name -> TransferEvidence in
            guard names.contains(name) else { return TransferEvidence(isMissing: true) }
            // Read the logical URL, not the .icloud placeholder's attributes.
            let url = directory.appendingPathComponent(name)
            do {
                let values = try url.resourceValues(forKeys: keys)
                return TransferEvidence(isCloudItem: values.isUbiquitousItem, isUploaded: values.ubiquitousItemIsUploaded,
                    isUploading: values.ubiquitousItemIsUploading, isDownloading: values.ubiquitousItemIsDownloading,
                    isCurrent: values.ubiquitousItemDownloadingStatus.map { $0 == .current },
                    hasError: values.ubiquitousItemUploadingError != nil || values.ubiquitousItemDownloadingError != nil)
            } catch let error as NSError where error.domain == NSCocoaErrorDomain && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code) {
                return TransferEvidence(isMissing: true)
            }
        }
        return transferState(from: evidence)
    }

    private static func normalizedCloudName(_ name: String) -> String {
        if name.hasPrefix("."), name.hasSuffix(".icloud") { return String(name.dropFirst().dropLast(7)) }
        return name
    }

    private static func coordinate<T>(_ url: URL, writing: Bool, _ body: (URL) throws -> T) throws -> T {
        let coordinator = NSFileCoordinator()
        var error: NSError?
        var result: Result<T, Error>?
        if writing {
            coordinator.coordinate(writingItemAt: url, options: [], error: &error) { target in
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

enum SnapshotReplacement {
    static func commit(_ replacement: AppState, expected: AppState, fileURL: URL) throws {
        try DocumentLock.withLock(fileURL) {
            guard case .decoded(let current) = DocumentRead.read(fileURL), current == expected else {
                throw SnapshotError.message(L10n.tr("An integration changed local data. Nothing was replaced. Please try again."))
            }
            try SnapshotArchive.encode(replacement).write(to: fileURL, options: .atomic)
        }
    }
}
