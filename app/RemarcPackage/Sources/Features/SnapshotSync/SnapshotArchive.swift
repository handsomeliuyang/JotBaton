import CoreLocalization
import FeatureComments
import Foundation
import CryptoKit

package struct SnapshotVersion: Codable, Identifiable, Equatable, Sendable {
    package let formatVersion: Int
    package let id: UUID
    package let deviceID: UUID
    package let deviceName: String
    package let createdAt: Date
    package let commentCount: Int
    package let imageCount: Int
    package let contentHash: String
    package let archiveHash: String
    package var archiveName: String = ""
    /// Content time travels with the data. Archive creation and download times
    /// are deliberately not used as substitutes for older snapshots.
    package var contentModifiedAt: Date? = nil

    package var shortID: String { String(id.uuidString.prefix(8)) }
}

package struct SnapshotReceipt: Codable, Sendable {
    package init(version: SnapshotVersion, contentHash: String, appliedAt: Date? = nil, localUpdatedAt: Date? = nil) {
        self.version = version; self.contentHash = contentHash
        self.appliedAt = appliedAt; self.localUpdatedAt = localUpdatedAt
    }
    package let version: SnapshotVersion
    /// This Mac's encoded fingerprint; the source OS may spell JSON numbers
    /// differently without changing their decoded values.
    package let contentHash: String
    package var appliedAt: Date? = nil
    package var localUpdatedAt: Date? = nil
}

package enum SnapshotError: LocalizedError {
    case message(String)
    case underlying(String, NSError)
    case waitingForDownload
    package var errorDescription: String? {
        switch self {
        case .message(let message), .underlying(let message, _): return message
        case .waitingForDownload: return L10n.tr("iCloud is downloading this data. Your local tasks are kept. Check again shortly.")
        }
    }
}

/// An immutable, complete snapshot. Archive entries are read individually with
/// unzip -p; no archive-supplied path or symlink is ever extracted onto disk.
package enum SnapshotArchive {
    package struct Prepared: Sendable {
        package var state: AppState
        package var files: [String: Data]
        package var hash: String
    }

    package static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    package static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    package static func prepare(_ original: AppState, root: URL) throws -> Prepared {
        var state = original
        state.unknownFields.removeValue(forKey: "_snapshotReceipt")
        state.unknownFields.removeValue(forKey: "_snapshotContentStamp")
        state.unknownFields.removeValue(forKey: "_snapshotUndo")
        state.unknownFields.removeValue(forKey: "_snapshotDataUpdatedAt")
        // Selection and live agent delivery belong to this Mac. They must not
        // make a snapshot dirty or wake a process when a snapshot is applied.
        state.activeSessionID = nil
        for index in state.sessions.indices {
            state.sessions[index].claudeCodeSessionId = nil
            state.sessions[index].emptySince = nil
        }
        for index in state.comments.indices { state.comments[index].wakeRequestedAt = nil }
        var files: [String: Data] = [:]
        var paths: [String: String] = [:]
        func image(_ path: String, required: Bool) throws -> String {
            if let mapped = paths[path] {
                if required && files[String(mapped.dropFirst(7))] == nil {
                    throw SnapshotError.message(L10n.tr("A referenced image is unavailable. Restore the file before publishing."))
                }
                return mapped
            }
            let url = path.hasPrefix("/") ? URL(fileURLWithPath: path) : root.appendingPathComponent(path)
            let bytes: Data
            do { bytes = try Data(contentsOf: url, options: .mappedIfSafe) }
            catch {
                if required { throw SnapshotError.message(L10n.tr("An image is unavailable: \(url.lastPathComponent). Restore the file before publishing.")) }
                // Legacy history and cleanup retries may reference missing images.
                let missing = path.hasPrefix("images/") && validEntry("files/" + String(path.dropFirst(7)))
                    ? path : "images/\(assetID(Data(path.utf8))).png"
                paths[path] = missing
                return missing
            }
            let stem = url.deletingPathExtension()
            let base = try optionalData(stem.appendingPathExtension("base.png"))
            let marks = try optionalData(stem.appendingPathExtension("marks.json"))
            var identity = Data(digest(bytes).utf8)
            if let base { identity.append(Data(("base:" + digest(base)).utf8)) }
            if let marks { identity.append(Data(("marks:" + digest(marks)).utf8)) }
            let name = assetID(identity)
            files["\(name).png"] = bytes
            if let base { files["\(name).base.png"] = base }
            if let marks { files["\(name).marks.json"] = marks }
            let mapped = "images/\(name).png"
            paths[path] = mapped
            return mapped
        }
        for index in state.comments.indices {
            let required = !state.comments[index].isDeleted
            if let path = state.comments[index].type.imagePath {
                state.comments[index].type = .screenshot(imagePath: try image(path, required: required))
            }
            state.comments[index].attachments = try state.comments[index].attachments.map { try image($0, required: required) }
        }
        // Orphans are retained for history cleanup, never allowed to carry an
        // absolute path from another computer into the local deletion code.
        for index in state.orphanedImages.indices {
            let orphan = state.orphanedImages[index]
            state.orphanedImages[index] = OrphanedImage(id: orphan.id,
                path: try image(orphan.path, required: false), deletedAt: orphan.deletedAt)
        }
        let inventory = files.mapValues(digest)
        var identity = try encode(state)
        identity.append(try encode(inventory))
        return Prepared(state: state, files: files, hash: digest(identity))
    }

    private static func optionalData(_ url: URL) throws -> Data? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try Data(contentsOf: url, options: .mappedIfSafe)
    }

    private static func assetID(_ data: Data) -> String {
        let h = digest(data)
        return "\(h.prefix(8))-\(h.dropFirst(8).prefix(4))-\(h.dropFirst(12).prefix(4))-\(h.dropFirst(16).prefix(4))-\(h.dropFirst(20).prefix(12))".uppercased()
    }

    package static func filename(date: Date, deviceName: String, id: UUID, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ssZ"
        let name = String(deviceName.unicodeScalars.map {
            CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" ? String($0) : "-"
        }.joined().prefix(40))
        return "\(formatter.string(from: date))_\(name.isEmpty ? "Mac" : name)_\(id.uuidString.prefix(8)).zip"
    }

    package static func validArchiveName(_ name: String) -> Bool {
        name.range(of: #"^\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2}[+-]\d{4}_[\p{L}\p{N}_-]{1,40}_[A-F0-9]{8}\.zip$"#,
                   options: .regularExpression) != nil
    }

    package static func create(_ prepared: Prepared, in directory: URL, deviceID: UUID,
                       deviceName: String, contentModifiedAt: Date? = nil) throws -> SnapshotVersion {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let stage = fm.temporaryDirectory.appendingPathComponent("remarc-snapshot-\(UUID())")
        try fm.createDirectory(at: stage.appendingPathComponent("files"), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: stage) }
        try encode(prepared.state).write(to: stage.appendingPathComponent("state.json"), options: .atomic)
        try encode(prepared.files.mapValues(digest)).write(to: stage.appendingPathComponent("inventory.json"), options: .atomic)
        for (name, bytes) in prepared.files {
            guard validEntry("files/\(name)") else { throw SnapshotError.message(L10n.tr("Invalid snapshot image filename.")) }
            try bytes.write(to: stage.appendingPathComponent("files/\(name)"))
        }
        let id = UUID()
        let createdAt = Date()
        let archiveName = filename(date: createdAt, deviceName: deviceName, id: id)
        let zip = directory.appendingPathComponent(archiveName)
        guard !fm.fileExists(atPath: zip.path) else {
            throw SnapshotError.message(L10n.tr("The existing cloud snapshot has different contents. It has not been overwritten."))
        }
        do {
            _ = try command("/usr/bin/ditto", ["-c", "-k", "--norsrc", stage.path, zip.path])
            var version = SnapshotVersion(formatVersion: 2, id: id,
                deviceID: deviceID, deviceName: deviceName, createdAt: createdAt,
                commentCount: prepared.state.comments.filter { !$0.isDeleted }.count,
                imageCount: prepared.files.keys.filter { $0.hasSuffix(".png") && !$0.hasSuffix(".base.png") }.count,
                contentHash: prepared.hash, archiveHash: try fileDigest(zip))
            version.archiveName = archiveName
            version.contentModifiedAt = contentModifiedAt
            return version
        } catch {
            try? fm.removeItem(at: zip)
            throw error
        }
    }

    package static func read(_ version: SnapshotVersion, archive: URL) throws -> Prepared {
        guard version.formatVersion == 2 else { throw SnapshotError.message(L10n.tr("This snapshot requires a newer version of JotBaton.")) }
        guard try fileDigest(archive) == version.archiveHash else { throw SnapshotError.message(L10n.tr("Snapshot verification failed. Your local data has not been changed.")) }
        let entries = String(decoding: try command("/usr/bin/unzip", ["-Z1", archive.path], limit: 8_000_000), as: UTF8.self)
            .split(separator: "\n").map(String.init)
        guard Set(entries).count == entries.count, entries.count < 50_000,
              entries.allSatisfy({ $0 == "state.json" || $0 == "inventory.json" || $0 == "files/" || validEntry($0) }) else {
            throw SnapshotError.message(L10n.tr("The snapshot contains invalid file entries."))
        }
        let stateData = try command("/usr/bin/unzip", ["-p", archive.path, "state.json"], limit: 64_000_000)
        let inventoryData = try command("/usr/bin/unzip", ["-p", archive.path, "inventory.json"], limit: 8_000_000)
        // Hash the exact JSON bytes written by the publishing Mac.
        // JSONEncoder.sortedKeys does not canonicalize floating-point spelling
        // across Foundation versions (notably Ventura and newer macOS).
        var sourceIdentity = stateData
        sourceIdentity.append(inventoryData)
        guard digest(sourceIdentity) == version.contentHash else { throw SnapshotError.message(L10n.tr("Snapshot content verification failed.")) }
        let inventory = try JSONDecoder().decode([String: String].self, from: inventoryData)
        var state = try JSONDecoder().decode(AppState.self, from: stateData)
        guard Set(entries.filter { !$0.hasSuffix("/") }) == Set(["state.json", "inventory.json"] + inventory.keys.map { "files/\($0)" }) else {
            throw SnapshotError.message(L10n.tr("The snapshot file inventory is incomplete."))
        }
        var files: [String: Data] = [:]
        var total = 0
        for (name, hash) in inventory {
            guard validEntry("files/\(name)") else { throw SnapshotError.message(L10n.tr("Invalid image path in snapshot.")) }
            let bytes = try command("/usr/bin/unzip", ["-p", archive.path, "files/\(name)"], limit: 200_000_000)
            total += bytes.count
            guard total <= 2_000_000_000, digest(bytes) == hash else { throw SnapshotError.message(L10n.tr("Snapshot image verification failed.")) }
            files[name] = bytes
        }
        func validPath(_ path: String, required: Bool) -> Bool {
            path.hasPrefix("images/") && validEntry("files/" + String(path.dropFirst(7)))
                && (!required || files[String(path.dropFirst(7))] != nil)
        }
        guard state.comments.allSatisfy({ comment in
            (comment.type.imagePath.map { validPath($0, required: !comment.isDeleted) } ?? true)
                && comment.attachments.allSatisfy { validPath($0, required: !comment.isDeleted) }
        }), state.orphanedImages.allSatisfy({ validPath($0.path, required: false) }),
        Set(state.comments.map(\.id)).count == state.comments.count,
        Set(state.sessions.map(\.id)).count == state.sessions.count else {
            throw SnapshotError.message(L10n.tr("The snapshot contains invalid task references."))
        }
        state.activeSessionID = nil
        for index in state.sessions.indices {
            state.sessions[index].claudeCodeSessionId = nil
            state.sessions[index].emptySince = nil
        }
        for index in state.comments.indices { state.comments[index].wakeRequestedAt = nil }
        var identity = try encode(state)
        identity.append(try encode(inventory))
        // Keep the source hash in version metadata, and track local edits with
        // the receiving Mac's encoding, just as prepare() does after install.
        return Prepared(state: state, files: files, hash: digest(identity))
    }

    private static func validEntry(_ entry: String) -> Bool {
        guard entry.hasPrefix("files/") else { return false }
        let name = String(entry.dropFirst(6))
        for suffix in [".base.png", ".marks.json", ".png"] where name.hasSuffix(suffix) {
            return UUID(uuidString: String(name.dropLast(suffix.count))) != nil
        }
        return false
    }

    package static func fileDigest(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let bytes = try handle.read(upToCount: 1_048_576), !bytes.isEmpty { hash.update(data: bytes) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    package static func installFiles(_ prepared: Prepared, root: URL) throws -> Prepared {
        let images = root.appendingPathComponent("images", isDirectory: true)
        try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
        guard try images.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
            throw SnapshotError.message(L10n.tr("The local images folder must not be a symbolic link."))
        }
        // Imported screenshots can subsequently be edited in place. Give every
        // family a fresh local filename so restoring an older version never
        // overwrites a currently referenced image before the document commit.
        var mapping: [String: String] = [:]
        for name in prepared.files.keys where name.hasSuffix(".png") && !name.hasSuffix(".base.png") {
            mapping[String(name.dropLast(4))] = UUID().uuidString
        }
        for (name, bytes) in prepared.files {
            guard validEntry("files/\(name)") else { throw SnapshotError.message(L10n.tr("Invalid image filename.")) }
            let prefix = String(name.prefix(36))
            guard let localName = mapping[prefix] else { throw SnapshotError.message(L10n.tr("An editing file has no primary image.")) }
            let target = images.appendingPathComponent(localName + name.dropFirst(36))
            guard !FileManager.default.fileExists(atPath: target.path) else { throw SnapshotError.message(L10n.tr("Could not allocate a local image filename. Please retry.")) }
            try bytes.write(to: target, options: .atomic)
        }
        func localPath(_ path: String) -> String {
            let name = String(path.dropFirst(7))
            guard let local = mapping[String(name.prefix(36))] else { return path }
            return "images/\(local).png"
        }
        var result = prepared
        for index in result.state.comments.indices {
            if let path = result.state.comments[index].type.imagePath {
                result.state.comments[index].type = .screenshot(imagePath: localPath(path))
            }
            result.state.comments[index].attachments = result.state.comments[index].attachments.map(localPath)
        }
        result.state.orphanedImages = result.state.orphanedImages.map { OrphanedImage(id: $0.id, path: localPath($0.path), deletedAt: $0.deletedAt) }
        return result
    }

    private static func command(_ executable: String, _ arguments: [String], limit: Int = 1_048_576) throws -> Data {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        var output = Data()
        do {
            while let bytes = try pipe.fileHandleForReading.read(upToCount: 65_536), !bytes.isEmpty {
                guard output.count + bytes.count <= limit else {
                    process.terminate()
                    throw SnapshotError.message(L10n.tr("The snapshot exceeds the supported size limit."))
                }
                output.append(bytes)
            }
        } catch {
            if process.isRunning { process.terminate() }
            try? pipe.fileHandleForReading.close()
            process.waitUntilExit()
            throw error
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw SnapshotError.message(L10n.tr("Could not read or create the snapshot archive.")) }
        return output
    }
}
