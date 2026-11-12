import CoreLocalization
import FeatureComments
import Foundation

/// The document itself names the committed undo payload. Publishing that pointer
/// in the same atomic write as the replacement keeps crash recovery unambiguous.
package enum SnapshotRollbackStore {
    package static let key = "_snapshotUndo"

    package static func directory(in root: URL) -> URL {
        root.appendingPathComponent("snapshot-rollback", isDirectory: true)
    }

    package static func prepareDirectory(in root: URL) throws -> URL {
        let url = directory(in: root)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        guard try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
            throw SnapshotError.message(L10n.tr("Could not access the snapshot folder."))
        }
        return url
    }

    package static func version(in state: AppState) -> SnapshotVersion? {
        guard let value = state.unknownFields[key],
              let data = try? SnapshotArchive.encode(value),
              let version = try? JSONDecoder().decode(SnapshotVersion.self, from: data),
              (try? SnapshotDisk.validate(version)) != nil else { return nil }
        return version
    }

    package static func set(_ version: SnapshotVersion?, in state: inout AppState) throws {
        if let version {
            try SnapshotDisk.validate(version)
            state.unknownFields[key] = try JSONDecoder().decode(JSONValue.self, from: SnapshotArchive.encode(version))
        } else {
            state.unknownFields.removeValue(forKey: key)
        }
    }

    package static func cleanup(in root: URL, keeping version: SnapshotVersion?) throws {
        let directory = directory(in: root)
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        guard try directory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
            throw SnapshotError.message(L10n.tr("Could not access the snapshot folder."))
        }
        for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        where file.lastPathComponent != version?.archiveName && SnapshotArchive.validArchiveName(file.lastPathComponent) {
            try FileManager.default.removeItem(at: file)
        }
    }

    /// Called only after a new current copy has been confirmed in iCloud.
    package static func removeLegacyCaches(in root: URL) throws {
        for name in ["snapshot-outbox", "snapshot-backups"] {
            let directory = root.appendingPathComponent(name, isDirectory: true)
            guard FileManager.default.fileExists(atPath: directory.path),
                  try directory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { continue }
            for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
                let ext = file.pathExtension
                guard ["json", "zip"].contains(ext), UUID(uuidString: file.deletingPathExtension().lastPathComponent) != nil else { continue }
                try FileManager.default.removeItem(at: file)
            }
            if try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty {
                try FileManager.default.removeItem(at: directory)
            }
        }
        let oldRecord = root.appendingPathComponent("snapshot-sync-state.json")
        if FileManager.default.fileExists(atPath: oldRecord.path) { try FileManager.default.removeItem(at: oldRecord) }
    }
}
