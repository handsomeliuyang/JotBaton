import Foundation
import CryptoKit

struct SnapshotVersion: Codable, Identifiable, Equatable, Sendable {
    let formatVersion: Int
    let id: UUID
    let parentID: UUID?
    let deviceID: UUID
    let deviceName: String
    let createdAt: Date
    let commentCount: Int
    let imageCount: Int
    let contentHash: String
    let archiveHash: String
    var supersededIDs: [UUID]? = nil
    /// Content time travels with the data. Archive creation and download times
    /// are deliberately not used as substitutes for older snapshots.
    var contentModifiedAt: Date? = nil

    var shortID: String { String(id.uuidString.prefix(8)) }
}

struct SnapshotReceipt: Codable, Sendable {
    let version: SnapshotVersion
    let contentHash: String
    var appliedAt: Date? = nil
}

enum SnapshotError: LocalizedError {
    case message(String)
    case underlying(String, NSError)
    case waitingForDownload
    var errorDescription: String? {
        switch self {
        case .message(let message), .underlying(let message, _): return message
        case .waitingForDownload: return "iCloud is downloading this data. Your local tasks are kept. Check again shortly."
        }
    }
}

/// An immutable, complete snapshot. Archive entries are read individually with
/// unzip -p; no archive-supplied path or symlink is ever extracted onto disk.
enum SnapshotArchive {
    struct Prepared: Sendable {
        var state: AppState
        var files: [String: Data]
        var hash: String
    }

    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func prepare(_ original: AppState, root: URL) throws -> Prepared {
        var state = original
        state.unknownFields.removeValue(forKey: "_snapshotReceipt")
        state.unknownFields.removeValue(forKey: "_snapshotContentStamp")
        // Selection and live agent delivery belong to this Mac. They must not
        // make a snapshot dirty or wake a process when a snapshot is applied.
        state.activeSessionID = nil
        for index in state.sessions.indices { state.sessions[index].claudeCodeSessionId = nil }
        for index in state.comments.indices { state.comments[index].wakeRequestedAt = nil }
        var files: [String: Data] = [:]
        var paths: [String: String] = [:]
        func image(_ path: String, required: Bool) throws -> String {
            if let mapped = paths[path] {
                if required && files[String(mapped.dropFirst(7))] == nil {
                    throw SnapshotError.message("A referenced image is unavailable. Restore the file before publishing.")
                }
                return mapped
            }
            let url = path.hasPrefix("/") ? URL(fileURLWithPath: path) : root.appendingPathComponent(path)
            let bytes: Data
            do { bytes = try Data(contentsOf: url, options: .mappedIfSafe) }
            catch {
                if required { throw SnapshotError.message("An image is unavailable: \(url.lastPathComponent). Restore the file before publishing.") }
                // Deleted history may outlive its image retention period.
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

    static func create(_ prepared: Prepared, in directory: URL, deviceID: UUID,
                       deviceName: String, parentID: UUID?, supersededIDs: [UUID] = [],
                       contentModifiedAt: Date? = nil) throws -> SnapshotVersion {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let stage = fm.temporaryDirectory.appendingPathComponent("remarc-snapshot-\(UUID())")
        try fm.createDirectory(at: stage.appendingPathComponent("files"), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: stage) }
        try encode(prepared.state).write(to: stage.appendingPathComponent("state.json"), options: .atomic)
        try encode(prepared.files.mapValues(digest)).write(to: stage.appendingPathComponent("inventory.json"), options: .atomic)
        for (name, bytes) in prepared.files {
            guard validEntry("files/\(name)") else { throw SnapshotError.message("Invalid snapshot image filename.") }
            try bytes.write(to: stage.appendingPathComponent("files/\(name)"))
        }
        let id = UUID()
        let zip = directory.appendingPathComponent("\(id).zip")
        do {
            _ = try command("/usr/bin/ditto", ["-c", "-k", "--norsrc", stage.path, zip.path])
            var version = SnapshotVersion(formatVersion: 1, id: id, parentID: parentID,
                deviceID: deviceID, deviceName: deviceName, createdAt: Date(),
                commentCount: prepared.state.comments.filter { !$0.isDeleted }.count,
                imageCount: prepared.files.keys.filter { $0.hasSuffix(".png") && !$0.hasSuffix(".base.png") }.count,
                contentHash: prepared.hash, archiveHash: try fileDigest(zip))
            if !supersededIDs.isEmpty { version.supersededIDs = supersededIDs }
            version.contentModifiedAt = contentModifiedAt
            try encode(version).write(to: directory.appendingPathComponent("\(id).json"), options: .atomic)
            return version
        } catch {
            try? fm.removeItem(at: zip)
            throw error
        }
    }

    static func read(_ version: SnapshotVersion, archive: URL) throws -> Prepared {
        guard version.formatVersion == 1 else { throw SnapshotError.message("This snapshot requires a newer version of Remarc.") }
        guard try fileDigest(archive) == version.archiveHash else { throw SnapshotError.message("Snapshot verification failed. Your local data has not been changed.") }
        let entries = String(decoding: try command("/usr/bin/unzip", ["-Z1", archive.path], limit: 8_000_000), as: UTF8.self)
            .split(separator: "\n").map(String.init)
        guard Set(entries).count == entries.count, entries.count < 50_000,
              entries.allSatisfy({ $0 == "state.json" || $0 == "inventory.json" || $0 == "files/" || validEntry($0) }) else {
            throw SnapshotError.message("The snapshot contains invalid file entries.")
        }
        let stateData = try command("/usr/bin/unzip", ["-p", archive.path, "state.json"], limit: 64_000_000)
        let inventory = try JSONDecoder().decode([String: String].self, from:
            command("/usr/bin/unzip", ["-p", archive.path, "inventory.json"], limit: 8_000_000))
        var state = try JSONDecoder().decode(AppState.self, from: stateData)
        guard Set(entries.filter { !$0.hasSuffix("/") }) == Set(["state.json", "inventory.json"] + inventory.keys.map { "files/\($0)" }) else {
            throw SnapshotError.message("The snapshot file inventory is incomplete.")
        }
        var files: [String: Data] = [:]
        var total = 0
        for (name, hash) in inventory {
            guard validEntry("files/\(name)") else { throw SnapshotError.message("Invalid image path in snapshot.") }
            let bytes = try command("/usr/bin/unzip", ["-p", archive.path, "files/\(name)"], limit: 200_000_000)
            total += bytes.count
            guard total <= 2_000_000_000, digest(bytes) == hash else { throw SnapshotError.message("Snapshot image verification failed.") }
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
            throw SnapshotError.message("The snapshot contains invalid task references.")
        }
        state.activeSessionID = nil
        for index in state.sessions.indices { state.sessions[index].claudeCodeSessionId = nil }
        for index in state.comments.indices { state.comments[index].wakeRequestedAt = nil }
        var identity = try encode(state)
        identity.append(try encode(inventory))
        guard digest(identity) == version.contentHash else { throw SnapshotError.message("Snapshot content verification failed.") }
        return Prepared(state: state, files: files, hash: version.contentHash)
    }

    private static func validEntry(_ entry: String) -> Bool {
        guard entry.hasPrefix("files/") else { return false }
        let name = String(entry.dropFirst(6))
        for suffix in [".base.png", ".marks.json", ".png"] where name.hasSuffix(suffix) {
            return UUID(uuidString: String(name.dropLast(suffix.count))) != nil
        }
        return false
    }

    static func fileDigest(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let bytes = try handle.read(upToCount: 1_048_576), !bytes.isEmpty { hash.update(data: bytes) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func installFiles(_ prepared: Prepared, root: URL) throws -> Prepared {
        let images = root.appendingPathComponent("images", isDirectory: true)
        try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
        guard try images.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
            throw SnapshotError.message("The local images folder must not be a symbolic link.")
        }
        // Imported screenshots can subsequently be edited in place. Give every
        // family a fresh local filename so restoring an older version never
        // overwrites a currently referenced image before the document commit.
        var mapping: [String: String] = [:]
        for name in prepared.files.keys where name.hasSuffix(".png") && !name.hasSuffix(".base.png") {
            mapping[String(name.dropLast(4))] = UUID().uuidString
        }
        for (name, bytes) in prepared.files {
            guard validEntry("files/\(name)") else { throw SnapshotError.message("Invalid image filename.") }
            let prefix = String(name.prefix(36))
            guard let localName = mapping[prefix] else { throw SnapshotError.message("An editing file has no primary image.") }
            let target = images.appendingPathComponent(localName + name.dropFirst(36))
            guard !FileManager.default.fileExists(atPath: target.path) else { throw SnapshotError.message("Could not allocate a local image filename. Please retry.") }
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
                    throw SnapshotError.message("The snapshot exceeds the supported size limit.")
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
        guard process.terminationStatus == 0 else { throw SnapshotError.message("Could not read or create the snapshot archive.") }
        return output
    }
}
