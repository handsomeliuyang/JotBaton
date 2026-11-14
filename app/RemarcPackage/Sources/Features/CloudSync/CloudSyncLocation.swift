import CoreLocalization
import CorePlatform
import Foundation

/// A convention for the non-sandboxed app's ordinary iCloud Drive folder.
/// Never bootstrap the CloudDocs root: an ordinary local directory at that
/// path must not be mistaken for an active cloud provider.
package enum CloudSyncLocation {
    package struct Facts: Sendable {
        let isDirectory: Bool
        let isCloudItem: Bool
        let isSymbolicLink: Bool
    }

    package static var driveRoot: URL {
        root(in: FileManager.default.homeDirectoryForCurrentUser)
    }

    package static func root(in home: URL) -> URL {
        home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
    }

    package static func inspect(_ url: URL) throws -> Facts {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isUbiquitousItemKey, .isSymbolicLinkKey])
        return Facts(isDirectory: values.isDirectory == true,
                     isCloudItem: values.isUbiquitousItem == true,
                     isSymbolicLink: values.isSymbolicLink == true)
    }

    package static func connect(root: URL = driveRoot, createIfMissing: Bool = false, verifyWriteAccess: Bool = false,
                        channel: AppIdentity = .current, inspect: (URL) throws -> Facts = inspect) throws -> URL {
        let fm = FileManager.default
        let rootFacts: Facts
        do { rootFacts = try inspect(root) }
        catch {
            throw CloudSyncError.underlying(L10n.tr("iCloud Drive is unavailable. Enable it in System Settings, or authorize access and retry."), error as NSError)
        }
        guard rootFacts.isDirectory, rootFacts.isCloudItem else {
            throw CloudSyncError.message(L10n.tr("An active iCloud Drive could not be verified. Enable iCloud Drive in System Settings and retry."))
        }
        let folder = channel.cloudURL(in: root)
        if createIfMissing, !fm.fileExists(atPath: folder.path) {
            // Only this child may be created, after explicit user consent.
            try fm.createDirectory(at: folder, withIntermediateDirectories: false)
        }
        let facts: Facts
        do { facts = try inspect(folder) }
        catch {
            throw CloudSyncError.underlying(L10n.tr("\(channel.cloudDisplayPath) is unavailable. Retry after iCloud finishes loading, or turn sync off and on again to set up the folder."), error as NSError)
        }
        guard facts.isDirectory, !facts.isSymbolicLink else {
            throw CloudSyncError.message(L10n.tr("\(channel.cloudDisplayPath) must be a regular folder. A file or symbolic link cannot be used for sync."))
        }
        if createIfMissing || verifyWriteAccess {
            let probe = folder.appendingPathComponent(".remarc-write-test-\(UUID())")
            defer { try? fm.removeItem(at: probe) }
            do { try Data().write(to: probe, options: .withoutOverwriting) }
            catch { throw CloudSyncError.underlying(L10n.tr("JotBaton cannot write to \(channel.cloudDisplayPath). Authorize access and retry."), error as NSError) }
        }
        return folder
    }

    package static func isAuthorizationLocation(_ url: URL, root: URL = driveRoot, channel: AppIdentity = .current) -> Bool {
        let selected = url.standardizedFileURL.resolvingSymlinksInPath()
        let drive = root.standardizedFileURL.resolvingSymlinksInPath()
        return selected.path == drive.path || selected.path == channel.cloudURL(in: drive).path
    }
}
