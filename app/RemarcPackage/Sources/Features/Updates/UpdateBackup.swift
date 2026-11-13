import CorePlatform
import Foundation

/// Keep completed backups immutable; a partial copy is never advertised as recoverable.
package enum UpdateBackup {
    package enum Failure: Error { case wrongChannel, invalidApplication, symbolicLink }

    @discardableResult
    package static func create(app: URL, home: URL, identity: AppIdentity) throws -> URL {
        guard identity == .production else { throw Failure.wrongChannel }
        let fm = FileManager.default
        let info = app.appendingPathComponent("Contents/Info.plist")
        guard let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: info), format: nil) as? [String: Any],
              plist["CFBundleIdentifier"] as? String == identity.bundleIdentifier else { throw Failure.invalidApplication }
        let root = home.appendingPathComponent("Library/Application Support/Remarc Update Backups", isDirectory: true)
        let data = identity.appSupportURL(in: home)
        for url in [app, root, data] {
            if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                throw Failure.symbolicLink
            }
        }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let id = UUID().uuidString
        let pending = root.appendingPathComponent(".pending-" + id, isDirectory: true)
        let completed = root.appendingPathComponent("Before-" + id, isDirectory: true)
        try fm.createDirectory(at: pending, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        do {
            try fm.copyItem(at: app, to: pending.appendingPathComponent("Remarc.app"))
            if fm.fileExists(atPath: data.path) {
                // Share the comment document's cross-process lock with other document writers.
                try DocumentLock.withLock(data.appendingPathComponent("comments.json")) {
                    let target = pending.appendingPathComponent("user-data", isDirectory: true)
                    try fm.createDirectory(at: target, withIntermediateDirectories: false)
                    for item in try fm.contentsOfDirectory(at: data, includingPropertiesForKeys: nil) {
                        // Never restore a copied lock as though its owner were still holding it.
                        guard !item.lastPathComponent.hasSuffix(".lock") else { continue }
                        try fm.copyItem(at: item, to: target.appendingPathComponent(item.lastPathComponent))
                    }
                }
            }
            try fm.moveItem(at: pending, to: completed)
            return completed
        } catch {
            try? fm.removeItem(at: pending)
            throw error
        }
    }
}
