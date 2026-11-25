import CoreLocalization
import CorePlatform
import Foundation

/// Validation and path resolution for user-selected sync folders (Google Drive
/// for Desktop, Syncthing, Dropbox, OneDrive, NAS, or any local synced folder).
package enum LocalFolderLocation {
    package struct Facts: Sendable {
        package let isDirectory: Bool
        package let isSymbolicLink: Bool

        package init(isDirectory: Bool, isSymbolicLink: Bool) {
            self.isDirectory = isDirectory
            self.isSymbolicLink = isSymbolicLink
        }
    }

    package static func inspect(_ url: URL) throws -> Facts {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        return Facts(isDirectory: values.isDirectory == true, isSymbolicLink: values.isSymbolicLink == true)
    }

    package static func cloudStorageRoot(in home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent("Library/CloudStorage", isDirectory: true)
    }

    /// Detects whether a folder lives under macOS FileProvider CloudStorage
    /// for Google Drive (`~/Library/CloudStorage/GoogleDrive-*`).
    package static func isGoogleDriveFolder(_ url: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
        let storageRoot = cloudStorageRoot(in: home).standardizedFileURL.resolvingSymlinksInPath().path
        let candidate = url.standardizedFileURL.resolvingSymlinksInPath().path
        guard candidate.hasPrefix(storageRoot + "/") else { return false }
        let remainder = candidate.dropFirst(storageRoot.count + 1)
        let firstComponent = remainder.split(separator: "/", maxSplits: 1).first.map(String.init) ?? ""
        return firstComponent.lowercased().hasPrefix("googledrive-")
    }

    /// Detects whether a folder lives inside macOS FileProvider `~/Library/CloudStorage/`.
    package static func isCloudStorageFolder(_ url: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
        let storageRoot = cloudStorageRoot(in: home).standardizedFileURL.resolvingSymlinksInPath().path
        let candidate = url.standardizedFileURL.resolvingSymlinksInPath().path
        return candidate == storageRoot || candidate.hasPrefix(storageRoot + "/")
    }

    /// Returns Google Drive roots mounted on this Mac under `~/Library/CloudStorage/GoogleDrive-*`,
    /// preferring each drive's `My Drive` (or localized `我的云端硬盘`) folder when present.
    package static func detectedGoogleDriveFolders(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [URL] {
        let fm = FileManager.default
        let storage = cloudStorageRoot(in: home)
        guard let entries = try? fm.contentsOfDirectory(at: storage, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                                                        options: [.skipsHiddenFiles]) else { return [] }
        return entries.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            .compactMap { entry in
                guard entry.lastPathComponent.lowercased().hasPrefix("googledrive-") else { return nil }
                guard let values = try? entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                      values.isDirectory == true, values.isSymbolicLink != true else { return nil }
                for driveName in ["My Drive", "我的云端硬盘"] {
                    let drive = entry.appendingPathComponent(driveName, isDirectory: true)
                    if let driveValues = try? drive.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                       driveValues.isDirectory == true, driveValues.isSymbolicLink != true {
                        return drive
                    }
                }
                return entry
            }
    }

    /// Shortens paths under the user's home directory with `~` for display.
    package static func displayPath(for url: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> String {
        let path = url.standardizedFileURL.path
        let homePath = home.standardizedFileURL.path
        if path == homePath { return "~" }
        if path.hasPrefix(homePath + "/") { return "~" + path.dropFirst(homePath.count) }
        return path
    }

    /// Validates a user-selected base directory and resolves the channel-isolated
    /// folder (`<base>/JotBaton` for Production, `<base>/JotBaton Dev` for Dev).
    /// If the user already selected a directory named `JotBaton` (or `JotBaton Dev`
    /// matching the current channel), that directory is used directly.
    package static func resolveSyncFolder(base: URL, channel: AppIdentity = .current,
                                          home: URL = FileManager.default.homeDirectoryForCurrentUser,
                                          appSupportRoot: URL = remarcAppSupportURL,
                                          inspect: (URL) throws -> Facts = inspect) throws -> URL {
        if let baseFacts = try? inspect(base), baseFacts.isSymbolicLink {
            throw CloudSyncError.message(L10n.tr("The sync folder must be a regular folder. A file or symbolic link cannot be used for sync."))
        }
        let resolvedBase = base.standardizedFileURL.resolvingSymlinksInPath()
        let iCloudRoot = CloudSyncLocation.root(in: home).standardizedFileURL.resolvingSymlinksInPath()
        if isSameOrDescendant(resolvedBase, of: iCloudRoot) {
            throw CloudSyncError.message(L10n.tr("Use the built-in iCloud Drive option instead of selecting iCloud Drive as a local folder."))
        }
        let forbiddenLocalRoots = [
            appSupportRoot,
            AppIdentity.production.appSupportURL(in: home),
            AppIdentity.development.appSupportURL(in: home),
        ].map { $0.standardizedFileURL.resolvingSymlinksInPath() }
        if forbiddenLocalRoots.contains(where: { isSameOrDescendant(resolvedBase, of: $0) }) {
            throw CloudSyncError.message(L10n.tr("Choose a folder outside JotBaton's local application data folder."))
        }
        let otherChannel: AppIdentity = channel == .production ? .development : .production
        if resolvedBase.lastPathComponent == otherChannel.cloudDirectoryName {
            throw CloudSyncError.message(L10n.tr("Cannot use the \(otherChannel.cloudDirectoryName) folder for \(channel.displayName). Choose another folder or \(channel.cloudDirectoryName)."))
        }
        if resolvedBase.lastPathComponent == channel.cloudDirectoryName {
            return base.standardizedFileURL
        }
        return channel.cloudURL(in: base.standardizedFileURL)
    }

    package static func connect(base: URL?, createIfMissing: Bool = false, verifyWriteAccess: Bool = false,
                                channel: AppIdentity = .current,
                                home: URL = FileManager.default.homeDirectoryForCurrentUser,
                                appSupportRoot: URL = remarcAppSupportURL,
                                inspect: (URL) throws -> Facts = inspect) throws -> URL {
        guard let base else {
            throw CloudSyncError.message(L10n.tr("Choose a sync folder to start syncing."))
        }
        let fm = FileManager.default
        let baseFacts: Facts
        do { baseFacts = try inspect(base) }
        catch {
            throw CloudSyncError.underlying(L10n.tr("The selected sync folder is unavailable. Reconnect the drive or choose another folder."), error as NSError)
        }
        guard baseFacts.isDirectory, !baseFacts.isSymbolicLink else {
            throw CloudSyncError.message(L10n.tr("The sync folder must be a regular folder. A file or symbolic link cannot be used for sync."))
        }
        let folder = try resolveSyncFolder(base: base, channel: channel, home: home,
                                           appSupportRoot: appSupportRoot, inspect: inspect)
        if folder.standardizedFileURL.path != base.standardizedFileURL.path,
           createIfMissing, !fm.fileExists(atPath: folder.path) {
            try fm.createDirectory(at: folder, withIntermediateDirectories: false)
        }
        let folderFacts: Facts
        do { folderFacts = try inspect(folder) }
        catch {
            throw CloudSyncError.underlying(L10n.tr("The sync folder is unavailable. Retry after the drive finishes loading, or choose another folder."), error as NSError)
        }
        guard folderFacts.isDirectory, !folderFacts.isSymbolicLink else {
            throw CloudSyncError.message(L10n.tr("The sync folder must be a regular folder. A file or symbolic link cannot be used for sync."))
        }
        if createIfMissing || verifyWriteAccess {
            let probe = folder.appendingPathComponent(".remarc-write-test-\(UUID())")
            defer { try? fm.removeItem(at: probe) }
            do { try Data().write(to: probe, options: .withoutOverwriting) }
            catch { throw CloudSyncError.underlying(L10n.tr("JotBaton cannot write to the selected sync folder. Authorize access or choose another folder."), error as NSError) }
        }
        return folder
    }

    private static func isSameOrDescendant(_ candidate: URL, of ancestor: URL) -> Bool {
        let candidatePath = candidate.path
        let ancestorPath = ancestor.path
        return candidatePath == ancestorPath || candidatePath.hasPrefix(ancestorPath + "/")
    }
}

/// Sync backend backed by any user-chosen local folder.
///
/// Works seamlessly with both:
/// - **Google Drive for Desktop** (and OneDrive/Dropbox) under macOS FileProvider
///   (`~/Library/CloudStorage/`): uses `NSFileCoordinator`, inspects FileProvider
///   ubiquitous + APFS `SF_DATALESS` states for non-blocking downloads, and reads
///   provider-reported upload status/errors.
/// - **Syncthing** and ordinary synced folders: reads/writes atomically, ignores
///   temporary/conflict sidecars (only matching `<UUID>.json`), and never stalls
///   waiting for cloud upload flags that local folders do not expose.
package struct LocalFolderStorageProvider: StorageProvider {
    package let kind: StorageProviderKind = .localFolder
    package let supportsSystemCloudSettings = false

    private let base: URL?
    private let channel: AppIdentity
    private let home: URL
    private let appSupportRoot: URL
    private let inspectLocation: @Sendable (URL) throws -> LocalFolderLocation.Facts

    package init(base: URL?, channel: AppIdentity = .current,
                 home: URL = FileManager.default.homeDirectoryForCurrentUser,
                 appSupportRoot: URL = remarcAppSupportURL,
                 inspect: @escaping @Sendable (URL) throws -> LocalFolderLocation.Facts = { try LocalFolderLocation.inspect($0) }) {
        self.base = base
        self.channel = channel
        self.home = home
        self.appSupportRoot = appSupportRoot
        self.inspectLocation = inspect
    }

    package func connect(createIfMissing: Bool, verifyWriteAccess: Bool) throws -> URL {
        try LocalFolderLocation.connect(base: base, createIfMissing: createIfMissing,
                                        verifyWriteAccess: verifyWriteAccess, channel: channel,
                                        home: home, appSupportRoot: appSupportRoot, inspect: inspectLocation)
    }

    package func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    package func availability(_ url: URL) -> SyncFileAvailability {
        CloudFileStatus.availability(url, checksICloudPlaceholder: false)
    }

    package func listDevices(_ layout: SyncLayout) throws -> [UUID] {
        try FileManager.default.contentsOfDirectory(atPath: layout.devices.path).compactMap { name in
            guard !name.hasPrefix("."), name.hasSuffix(".json") else { return nil }
            return UUID(uuidString: String(name.dropLast(5)))
        }
    }

    package func listBlobs(_ layout: SyncLayout) throws -> [SyncBlobEntry] {
        try CloudFileStatus.listBlobs(in: layout.blobs, includeICloudPlaceholders: false)
    }

    package func readData(at url: URL) throws -> Data {
        try SyncIO.coordinate(url, writing: false) { try Data(contentsOf: $0, options: .mappedIfSafe) }
    }

    package func writeData(_ data: Data, to url: URL, onlyIfMissing: Bool) throws {
        try SyncIO.coordinate(url, writing: true) { target in
            if onlyIfMissing, FileManager.default.fileExists(atPath: target.path) { return }
            try data.write(to: target, options: .atomic)
        }
    }

    package func deleteItem(at url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try CloudFileStatus.deleteCoordinated(url)
    }

    package func uploadState(_ url: URL) throws -> Bool? {
        try CloudFileStatus.uploadState(url)
    }
}
