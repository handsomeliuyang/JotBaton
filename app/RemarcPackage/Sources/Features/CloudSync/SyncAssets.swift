import CoreLocalization
import FeatureComments
import Foundation

/// Image files travel as content-addressed blobs: each distinct file is uploaded
/// once and never rewritten, and a document refers to it by its local path,
/// which is a capture UUID and therefore the same on every Mac.
package enum SyncAssets {
    package struct CachedDigest: Codable, Equatable, Sendable {
        let size: Int
        let modified: Date
        let digest: String
    }

    private static let suffixes = [".base.png", ".marks.json", ".png"]

    /// The only paths sync reads or writes: `images/<UUID>` plus a known suffix.
    package static func isValidPath(_ path: String) -> Bool {
        guard path.hasPrefix("images/") else { return false }
        let name = String(path.dropFirst(7))
        for suffix in suffixes where name.hasSuffix(suffix) {
            return UUID(uuidString: String(name.dropLast(suffix.count))) != nil
        }
        return false
    }

    /// Every file of every image the document references: the rendered PNG and,
    /// for annotated screenshots, the editable base image and marks.
    package static func files(referencedBy state: AppState) -> Set<String> {
        var files = Set<String>()
        for comment in state.comments {
            for path in comment.attachments + [comment.type.imagePath].compactMap({ $0 })
            where isValidPath(path) && path.hasSuffix(".png") && !path.hasSuffix(".base.png") {
                let stem = String(path.dropLast(4))
                files.formUnion([path, stem + ".base.png", stem + ".marks.json"])
            }
        }
        return files
    }

    /// Digests of the referenced files present on this Mac. Unchanged files reuse
    /// the cached digest, so a sync pass does not reread every screenshot.
    package static func manifest(for state: AppState, root: URL, cache: inout [String: CachedDigest]) -> [String: String] {
        var manifest: [String: String] = [:]
        for path in files(referencedBy: state) {
            let url = root.appendingPathComponent(path)
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]),
                  values.isRegularFile == true, let size = values.fileSize, let modified = values.contentModificationDate else { continue }
            if let cached = cache[path], cached.size == size, cached.modified == modified {
                manifest[path] = cached.digest
            } else if let digest = try? SyncIO.fileDigest(url) {
                cache[path] = CachedDigest(size: size, modified: modified, digest: digest)
                manifest[path] = digest
            }
        }
        cache = cache.filter { manifest[$0.key] != nil }
        return manifest
    }

    /// Uploads blobs other Macs do not have yet. Existing blobs are never touched.
    package static func upload(_ manifest: [String: String], root: URL, layout: SyncLayout) throws {
        for (path, digest) in manifest where !SyncCloud.exists(layout.blob(digest)) {
            let data = try Data(contentsOf: root.appendingPathComponent(path), options: .mappedIfSafe)
            // Edited since it was hashed: the next pass publishes the new bytes.
            guard SyncIO.digest(data) == digest else { continue }
            try SyncIO.coordinate(layout.blob(digest), writing: true) { target in
                if !FileManager.default.fileExists(atPath: target.path) { try data.write(to: target, options: .atomic) }
            }
        }
    }

    /// Which files to take from the other Mac, by the same rule as document
    /// fields. Annotating a screenshot rewrites bytes without changing the path,
    /// so file contents need their own three-way decision.
    package static func plan(local: [String: String], remote: [String: String], base: [String: String]?,
                             referenced: Set<String>, localWinsTie: Bool) -> [String: String] {
        var plan: [String: String] = [:]
        for (path, theirs) in remote where referenced.contains(path) && isValidPath(path) {
            guard let mine = local[path] else { plan[path] = theirs; continue }
            guard mine != theirs else { continue }
            let localChanged = base?[path] != mine
            let remoteChanged = base?[path] != theirs
            if !localChanged || (remoteChanged && !localWinsTie) { plan[path] = theirs }
        }
        return plan
    }

    /// Installs planned files whose blobs are on this Mac and returns the paths
    /// still waiting for iCloud. A missing image never fails a merge.
    package static func install(_ plan: [String: String], root: URL, layout: SyncLayout) throws -> Set<String> {
        guard !plan.isEmpty else { return [] }
        let images = root.appendingPathComponent("images", isDirectory: true)
        try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
        guard try images.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
            throw CloudSyncError.message(L10n.tr("The local images folder must not be a symbolic link."))
        }
        var waiting = Set<String>()
        for (path, digest) in plan where isValidPath(path) {
            let blob = layout.blob(digest)
            guard SyncCloud.availability(blob) == .ready else { waiting.insert(path); continue }
            let data = try SyncIO.coordinate(blob, writing: false) { try Data(contentsOf: $0, options: .mappedIfSafe) }
            guard SyncIO.digest(data) == digest else { waiting.insert(path); continue }
            try data.write(to: root.appendingPathComponent(path), options: .atomic)
        }
        return waiting
    }

    /// Absolute paths from older builds cannot travel between Macs. Copies each
    /// such image family into the images folder and returns old → new paths.
    package static func localizeLegacyPaths(in state: AppState, root: URL) throws -> [String: String] {
        let fm = FileManager.default
        var mapping: [String: String] = [:]
        for comment in state.comments {
            for path in comment.attachments + [comment.type.imagePath].compactMap({ $0 })
            where path.hasPrefix("/") && mapping[path] == nil && fm.fileExists(atPath: path) {
                let name = UUID().uuidString
                let source = URL(fileURLWithPath: path).deletingPathExtension()
                let images = root.appendingPathComponent("images", isDirectory: true)
                try fm.createDirectory(at: images, withIntermediateDirectories: true)
                try fm.copyItem(at: URL(fileURLWithPath: path), to: images.appendingPathComponent("\(name).png"))
                for suffix in ["base.png", "marks.json"] {
                    let sidecar = source.appendingPathExtension(suffix)
                    if fm.fileExists(atPath: sidecar.path) {
                        try fm.copyItem(at: sidecar, to: images.appendingPathComponent("\(name).\(suffix)"))
                    }
                }
                mapping[path] = "images/\(name).png"
            }
        }
        return mapping
    }

    package static func applying(_ mapping: [String: String], to state: AppState) -> AppState {
        guard !mapping.isEmpty else { return state }
        var state = state
        for index in state.comments.indices {
            if let path = state.comments[index].type.imagePath, let mapped = mapping[path] {
                state.comments[index].type = .screenshot(imagePath: mapped)
            }
            state.comments[index].attachments = state.comments[index].attachments.map { mapping[$0] ?? $0 }
        }
        return state
    }
}
