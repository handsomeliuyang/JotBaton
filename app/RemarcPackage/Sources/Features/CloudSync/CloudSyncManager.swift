import CoreLocalization
import CorePlatform
import Darwin
import FeatureComments
import AppKit
import Combine

package struct SyncDeviceSummary: Identifiable, Equatable, Sendable {
    package let id: UUID
    package let name: String
    package let updatedAt: Date?
    package let isWaiting: Bool
    package let needsNewerApp: Bool
}

/// Keeps this Mac's document merged with every other Mac's published file,
/// without user action. One pass runs at a time; requests that arrive during a
/// pass coalesce into a single follow-up pass.
///
/// A pass: connect through the selected `StorageProvider`, pull and merge each
/// device file (requesting downloads for cloud placeholders and moving on rather
/// than blocking), install images, then publish this Mac's merged document.
/// Local data never depends on the sync provider being ready.
@MainActor
package final class CloudSyncManager: ObservableObject {
    private enum Keys {
        // Shared with the manual snapshot flow, so Macs that opted in keep syncing.
        static let enabled = "snapshotICloudEnabled"
        static let deviceName = "snapshotDeviceName"
        static let deviceID = "snapshotDeviceID"
        static let bookmark = "snapshotICloudAccessBookmark"
        static let providerKind = "syncStorageProviderKind"
        static let localFolderBookmark = "syncLocalFolderBookmark"
        static let localFolderPath = "syncLocalFolderPath"
    }

    private struct WatchedDirectory: Equatable {
        let path: String
        let dev: dev_t
        let ino: ino_t
    }

    private static let periodicInterval: TimeInterval = 180
    private static let downloadGrace: Duration = .seconds(10)

    private let documents: any CloudSyncDocumentStore
    private let root: URL
    private let defaults: UserDefaults
    private let channel: AppIdentity
    private let home: URL
    private let iCloudConnectOverride: (@Sendable (Bool) throws -> URL)?
    private let providerOverride: (@Sendable (StorageProviderKind, URL?) -> any StorageProvider)?
    private let imagesDidChange: @MainActor (Set<String>) -> Void
    private let nowProvider: @Sendable () -> Date
    private let blobGracePeriod: TimeInterval
    private let blobCleanupInterval: TimeInterval
    private var generation = 0
    package let deviceID: UUID
    @Published package private(set) var isEnabled: Bool
    @Published package private(set) var providerKind: StorageProviderKind
    @Published package private(set) var localFolderBase: URL?
    @Published package var deviceName: String {
        didSet {
            defaults.set(deviceName, forKey: Keys.deviceName)
            if oldValue != deviceName { requestSync(after: 2) }
        }
    }
    @Published package private(set) var isSyncing = false
    @Published package private(set) var folder: URL?
    @Published package private(set) var issue: CloudSyncIssue?
    @Published package private(set) var devices: [SyncDeviceSummary] = []
    @Published package private(set) var conflicts: [SyncConflict] = []
    @Published package private(set) var lastSuccessAt: Date?
    @Published package private(set) var waitingCount = 0
    @Published package private(set) var waitingSince: Date?
    @Published package private(set) var unsyncedSince: Date?
    @Published package private(set) var canUndoLastSync = false
    /// Re-evaluates the time-based health thresholds while nothing else changes.
    @Published private var clock = Date()

    private var record: SyncRecord
    private var digestCache: [String: SyncAssets.CachedDigest]
    private var needsSetup = false
    private var rerunRequested = false
    private var restorePointSaved = false
    private var lastAttemptAt: Date?
    private var scheduled: Task<Void, Never>?
    private var followUp: Task<Void, Never>?
    private var followUpDelay: TimeInterval = 5
    private var scopedICloudFolder: URL?
    private var scopedLocalFolder: URL?
    private var watcher: DispatchSourceFileSystemObject?
    private var watchedDirectory: WatchedDirectory?
    private var cancellables = Set<AnyCancellable>()

    package var health: SyncHealth {
        SyncHealth.evaluate(enabled: isEnabled, syncing: isSyncing, issue: issue,
                            newerFormatDevice: devices.first(where: { $0.needsNewerApp })?.name,
                            waitingCount: waitingCount, waitingSince: waitingSince, unsyncedSince: unsyncedSince,
                            conflictCount: conflicts.count, now: clock)
    }

    package var isGoogleDriveSelected: Bool {
        providerKind == .localFolder
            && localFolderBase.map { LocalFolderLocation.isGoogleDriveFolder($0, home: home) } == true
    }

    package var providerDisplayName: String {
        switch providerKind {
        case .iCloud: return "iCloud Drive"
        case .localFolder: return isGoogleDriveSelected ? "Google Drive" : L10n.tr("Local Folder")
        }
    }

    package var providerShortName: String {
        switch providerKind {
        case .iCloud: return "iCloud"
        case .localFolder: return isGoogleDriveSelected ? "Google Drive" : L10n.tr("Sync Folder")
        }
    }

    package var targetDisplayPath: String {
        switch providerKind {
        case .iCloud:
            return channel.cloudDisplayPath
        case .localFolder:
            guard let base = localFolderBase else { return "" }
            if let resolved = try? LocalFolderLocation.resolveSyncFolder(base: base, channel: channel,
                                                                         home: home, appSupportRoot: root) {
                return LocalFolderLocation.displayPath(for: resolved, home: home)
            }
            return LocalFolderLocation.displayPath(for: base, home: home)
        }
    }

    package var healthTitle: String {
        health.title(providerKind: providerKind, providerName: providerShortName)
    }

    package var detectedGoogleDriveFolders: [URL] {
        LocalFolderLocation.detectedGoogleDriveFolders(home: home)
    }

    package var canEnableCurrentProvider: Bool {
        providerKind == .iCloud || localFolderBase != nil
    }

    package init(documents: any CloudSyncDocumentStore, root: URL = remarcAppSupportURL,
                 defaults: UserDefaults = .standard,
                 channel: AppIdentity = .current,
                 home: URL = FileManager.default.homeDirectoryForCurrentUser,
                 connect: (@Sendable (Bool) throws -> URL)? = nil,
                 providerFactory: (@Sendable (StorageProviderKind, URL?) -> any StorageProvider)? = nil,
                 imagesDidChange: @escaping @MainActor (Set<String>) -> Void = { _ in },
                 now: @escaping @Sendable () -> Date = Date.init,
                 blobGracePeriod: TimeInterval = SyncAssets.blobGracePeriod,
                 blobCleanupInterval: TimeInterval = SyncAssets.blobCleanupInterval) {
        self.documents = documents
        self.root = root
        self.defaults = defaults
        self.channel = channel
        self.home = home
        self.iCloudConnectOverride = connect
        self.providerOverride = providerFactory
        self.imagesDidChange = imagesDidChange
        self.nowProvider = now
        self.blobGracePeriod = blobGracePeriod
        self.blobCleanupInterval = blobCleanupInterval
        isEnabled = defaults.bool(forKey: Keys.enabled)
        providerKind = defaults.string(forKey: Keys.providerKind).flatMap(StorageProviderKind.init(rawValue:)) ?? .iCloud
        deviceName = defaults.string(forKey: Keys.deviceName) ?? Host.current().localizedName ?? "This Mac"
        let id: UUID
        if let raw = defaults.string(forKey: Keys.deviceID), let saved = UUID(uuidString: raw) { id = saved }
        else { id = UUID(); defaults.set(id.uuidString, forKey: Keys.deviceID) }
        deviceID = id
        record = (try? SyncLocalStore.loadRecord(in: root)) ?? SyncRecord()
        digestCache = SyncLocalStore.loadDigests(in: root)
        conflicts = record.conflicts
        lastSuccessAt = record.lastSuccessAt
        canUndoLastSync = SyncLocalStore.hasRestorePoint(in: root)
        needsSetup = isEnabled

        if let bookmark = defaults.data(forKey: Keys.bookmark) {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI], bookmarkDataIsStale: &stale),
               CloudSyncLocation.isAuthorizationLocation(url, root: CloudSyncLocation.root(in: home), channel: channel) {
                if url.startAccessingSecurityScopedResource() { scopedICloudFolder = url }
                if stale, let fresh = try? url.bookmarkData(options: .withSecurityScope) { defaults.set(fresh, forKey: Keys.bookmark) }
            }
        }
        localFolderBase = Self.restoreLocalFolder(from: defaults, startAccess: isEnabled && providerKind == .localFolder,
                                                  scopedFolder: &scopedLocalFolder)

        documents.statePublisher
            // Notifications are not necessarily edits. Seed deduplication with
            // the initial shared state before dropping it; otherwise the first
            // unchanged save would still start another pass. Local selection
            // and housekeeping metadata must not reset the debounce either.
            .map { SyncProjection.make($0) }
            .removeDuplicates()
            .dropFirst()
            .debounce(for: .seconds(3), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in Task { @MainActor [weak self] in self?.requestSync() } }
            .store(in: &cancellables)
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)
            .sink { [weak self] _ in Task { @MainActor [weak self] in self?.requestSync(after: 5) } }
            .store(in: &cancellables)
        Task { [weak self] in
            while true {
                try? await Task.sleep(for: .seconds(60))
                guard let self else { return }
                self.clock = Date()
                if Date().timeIntervalSince(self.lastAttemptAt ?? .distantPast) >= CloudSyncManager.periodicInterval {
                    self.requestSync()
                }
            }
        }
        if isEnabled { requestSync(after: 1) }
    }

    // MARK: - Provider & Entry points

    package func selectProvider(_ kind: StorageProviderKind) {
        guard kind != providerKind else { return }
        stopActiveSyncActivity()
        providerKind = kind
        defaults.set(kind.rawValue, forKey: Keys.providerKind)
        resetSyncStateForProviderSwitch()
        if isEnabled {
            if kind == .localFolder && localFolderBase == nil {
                isEnabled = false
                defaults.set(false, forKey: Keys.enabled)
                stopLocalSecurityScope()
            } else {
                activateCurrentSecurityScope()
                needsSetup = true
                requestSync()
            }
        }
    }

    package func setLocalFolder(_ url: URL, storeBookmark: Bool = true) throws {
        let normalized = url.standardizedFileURL
        _ = try LocalFolderLocation.resolveSyncFolder(base: normalized, channel: channel,
                                                      home: home, appSupportRoot: root)
        let changed = providerKind != .localFolder
            || localFolderBase?.standardizedFileURL.path != normalized.path

        if storeBookmark {
            if let bookmark = try? normalized.bookmarkData(options: .withSecurityScope) {
                defaults.set(bookmark, forKey: Keys.localFolderBookmark)
            } else {
                defaults.removeObject(forKey: Keys.localFolderBookmark)
            }
        }
        defaults.set(normalized.path, forKey: Keys.localFolderPath)

        stopLocalSecurityScope()
        if isEnabled, normalized.startAccessingSecurityScopedResource() {
            scopedLocalFolder = normalized
        }

        if changed {
            stopActiveSyncActivity()
            resetSyncStateForProviderSwitch()
        }
        providerKind = .localFolder
        defaults.set(StorageProviderKind.localFolder.rawValue, forKey: Keys.providerKind)
        localFolderBase = normalized
        issue = nil
        needsSetup = true
        if isEnabled { requestSync() }
    }

    @discardableResult
    package func chooseLocalFolder(initialDirectory: URL? = nil) async -> Bool {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = initialDirectory ?? localFolderBase ?? detectedGoogleDriveFolders.first ?? home
        panel.message = L10n.tr("Choose a folder synced by Google Drive, Syncthing, or another tool. JotBaton stores sync files inside its \(channel.cloudDirectoryName) folder.")
        panel.prompt = L10n.tr("Choose Folder")
        guard await panel.begin() == .OK, let url = panel.url else { return false }
        do {
            try setLocalFolder(url)
            return true
        } catch {
            issue = .make(error, stage: .connection, providerKind: .localFolder)
            return false
        }
    }

    package func enable() {
        if providerKind == .localFolder && localFolderBase == nil {
            issue = .make(CloudSyncError.message(L10n.tr("Choose a sync folder to start syncing.")),
                          stage: .connection, providerKind: .localFolder)
            return
        }
        isEnabled = true
        defaults.set(true, forKey: Keys.enabled)
        activateCurrentSecurityScope()
        needsSetup = true
        requestSync()
    }

    package func disable() {
        isEnabled = false
        defaults.set(false, forKey: Keys.enabled)
        stopActiveSyncActivity()
        scopedICloudFolder?.stopAccessingSecurityScopedResource()
        scopedICloudFolder = nil
        defaults.removeObject(forKey: Keys.bookmark)
        stopLocalSecurityScope()
    }

    /// Edits happen in the main window. Pull before the user starts, so they
    /// edit the latest data and conflicts stay rare.
    package func mainInterfaceDidShow(wasVisible: Bool) {
        guard !wasVisible else { return }
        requestSync()
    }

    package func requestSync(after delay: TimeInterval = 0) {
        guard isEnabled else { return }
        if isSyncing { rerunRequested = true; return }
        scheduled?.cancel()
        scheduled = Task { [weak self] in
            if delay > 0 {
                do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            }
            await self?.syncNow()
        }
    }

    package func syncNow() async {
        guard isEnabled else { return }
        guard !isSyncing else { rerunRequested = true; return }
        isSyncing = true
        defer { isSyncing = false }
        repeat {
            rerunRequested = false
            await runPass()
        } while rerunRequested && isEnabled
    }

    package func authorizeAccess() async {
        if providerKind == .localFolder {
            _ = await chooseLocalFolder(initialDirectory: localFolderBase)
            return
        }
        guard isEnabled else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = CloudSyncLocation.root(in: home)
        panel.message = L10n.tr("Allow access to iCloud Drive, or its \(channel.cloudDirectoryName) folder. Sync always uses \(channel.cloudDisplayPath).")
        panel.prompt = L10n.tr("Allow Access")
        guard await panel.begin() == .OK, let url = panel.url else { return }
        guard CloudSyncLocation.isAuthorizationLocation(url, root: CloudSyncLocation.root(in: home), channel: channel) else {
            issue = .make(CloudSyncError.message(L10n.tr("Authorize iCloud Drive or its \(channel.cloudDirectoryName) folder. Other folders cannot be used.")), stage: .connection, providerKind: .iCloud)
            return
        }
        do {
            let bookmark = try url.bookmarkData(options: .withSecurityScope)
            scopedICloudFolder?.stopAccessingSecurityScopedResource()
            scopedICloudFolder = url.startAccessingSecurityScopedResource() ? url : nil
            defaults.set(bookmark, forKey: Keys.bookmark)
            needsSetup = true
            requestSync()
        } catch { issue = .make(error, stage: .connection, providerKind: .iCloud) }
    }

    package func openICloudSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preferences.AppleIDPrefPane?iCloud"), NSWorkspace.shared.open(url) { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
    }

    // MARK: - Conflicts

    package func comment(for conflict: SyncConflict) -> Comment? {
        documents.appState.comments.first { $0.id == conflict.commentID }
    }

    package func keepCurrent(_ conflict: SyncConflict) {
        conflicts.removeAll { $0.id == conflict.id }
        persist()
    }

    /// Switches the field to the version that was not kept, as a new edit that
    /// then syncs to every Mac.
    package func useAlternative(_ conflict: SyncConflict) async {
        do {
            _ = try await documents.commitSyncedState { state in
                var state = state
                if let index = state.comments.firstIndex(where: { $0.id == conflict.commentID }) {
                    conflict.applyAlternative(to: &state.comments[index])
                }
                return state
            }
            keepCurrent(conflict)
            requestSync()
        } catch { issue = .make(error, stage: .applying, providerKind: providerKind) }
    }

    /// Restores the document saved before the most recent merge changed it.
    /// The restored values then sync out as this Mac's edits.
    @discardableResult
    package func undoLastSync() async -> Bool {
        guard !isSyncing else { return false }
        let root = self.root
        do {
            let point = try await Task.detached(priority: .utility) { try SyncLocalStore.latestRestorePoint(in: root) }.value
            guard let point else { return false }
            _ = try await documents.commitSyncedState { current in
                var restored = point.state
                restored.activeSessionID = current.activeSessionID
                return restored
            }
            try? FileManager.default.removeItem(at: point.url)
            canUndoLastSync = SyncLocalStore.hasRestorePoint(in: root)
            requestSync()
            return true
        } catch {
            issue = .make(error, stage: .applying, providerKind: providerKind)
            return false
        }
    }

    // MARK: - Pass

    private func activeProvider() -> any StorageProvider {
        if let providerOverride {
            return providerOverride(providerKind, localFolderBase)
        }
        switch providerKind {
        case .iCloud:
            if let iCloudConnectOverride {
                return ICloudStorageProvider(connect: iCloudConnectOverride)
            }
            return ICloudStorageProvider(root: CloudSyncLocation.root(in: home), channel: channel)
        case .localFolder:
            return LocalFolderStorageProvider(base: localFolderBase, channel: channel, home: home, appSupportRoot: root)
        }
    }

    private func runPass() async {
        let generation = self.generation
        let provider = activeProvider()
        let kind = provider.kind
        lastAttemptAt = Date()
        restorePointSaved = false
        var stage = CloudSyncIssue.Stage.connection
        do {
            let setup = needsSetup
            let folder = try await Task.detached(priority: .utility) {
                let folder = try provider.connect(createIfMissing: setup, verifyWriteAccess: setup)
                try SyncLayout(folder: folder).prepare()
                return folder
            }.value
            try checkActive(generation)
            needsSetup = false
            self.folder = folder
            let layout = SyncLayout(folder: folder)
            watch(layout.devices)

            stage = .preparing
            try await localizeLegacyImages(generation: generation)

            stage = .applying
            let pulled = try await pullDevices(layout, provider: provider, generation: generation)
            try checkActive(generation)
            let waiting = pulled.waiting
            devices = pulled.summaries

            stage = .publishing
            let publishedDigests = try await publish(layout, provider: provider, generation: generation)
            try checkActive(generation)

            await cleanupUnreferencedBlobsIfNeeded(
                layout: layout,
                provider: provider,
                referencedDigests: pulled.referencedDigests.union(publishedDigests),
                allDevicesReadable: pulled.allDevicesReadable,
                generation: generation
            )
            try checkActive(generation)

            let live = Set(documents.appState.comments.filter { !$0.isDeleted }.map(\.id))
            conflicts.removeAll { !live.contains($0.commentID) }
            record.lastSuccessAt = Date()
            lastSuccessAt = record.lastSuccessAt
            issue = nil
            waitingCount = waiting
            waitingSince = waiting > 0 ? (waitingSince ?? Date()) : nil
            persist()
            scheduleFollowUp(needed: waiting > 0 || unsyncedSince != nil)
        } catch is CancellationError {
            // Turning sync off or switching providers also invalidates a pass suspended in file IO.
        } catch {
            guard isEnabled, generation == self.generation else { return }
            issue = .make(error, stage: stage, providerKind: kind)
            persist()
            scheduleFollowUp(needed: true)
        }
    }

    private func checkActive(_ generation: Int) throws {
        try Task.checkCancellation()
        guard isEnabled, generation == self.generation else { throw CancellationError() }
    }

    /// Cloud providers deliver downloads and confirm uploads on their own schedule.
    /// Look again soon, backing off, instead of waiting for the window to reopen.
    private func scheduleFollowUp(needed: Bool) {
        followUp?.cancel()
        guard needed, isEnabled else { followUpDelay = 5; return }
        let delay = followUpDelay
        followUpDelay = min(followUpDelay * 2, 120)
        followUp = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            self?.requestSync()
        }
    }

    private func localizeLegacyImages(generation: Int) async throws {
        let state = documents.appState
        let hasLegacy = state.comments.contains { comment in
            (comment.attachments + [comment.type.imagePath].compactMap { $0 }).contains { $0.hasPrefix("/") }
        }
        guard hasLegacy else { return }
        let root = self.root
        let mapping = try await Task.detached(priority: .utility) { try SyncAssets.localizeLegacyPaths(in: state, root: root) }.value
        guard !mapping.isEmpty else { return }
        try checkActive(generation)
        _ = try await documents.commitSyncedState {
            guard self.isEnabled, generation == self.generation else { return $0 }
            return SyncAssets.applying(mapping, to: $0)
        }
    }

    private struct PullResult {
        var waiting = 0
        var summaries: [SyncDeviceSummary] = []
        var allDevicesReadable = true
        var referencedDigests = Set<String>()
    }

    private func pullDevices(_ layout: SyncLayout, provider: any StorageProvider, generation: Int) async throws -> PullResult {
        let id = deviceID
        let ids = try await Task.detached(priority: .utility) {
            try SyncCloud.listDevices(layout, provider: provider)
        }.value.filter { $0 != id }
        // Request every download first, then give the cloud provider a short grace period.
        // A file still remote after that is merged on a later pass.
        var results: [UUID: SyncCloud.LoadResult] = [:]
        var pending = ids
        let clock = ContinuousClock()
        let deadline = clock.now + Self.downloadGrace
        while !pending.isEmpty {
            try checkActive(generation)
            let batch = pending
            let loaded = await Task.detached(priority: .utility) {
                batch.map { ($0, SyncCloud.load($0, layout: layout, provider: provider)) }
            }.value
            for (key, value) in loaded { results[key] = value }
            pending = loaded.filter { $0.1 == .waiting }.map { $0.0 }
            if pending.isEmpty || clock.now >= deadline { break }
            try await Task.sleep(for: .seconds(1))
        }

        var result = PullResult()
        for remoteID in ids.sorted(by: { $0.uuidString < $1.uuidString }) {
            try checkActive(generation)
            let known = devices.first { $0.id == remoteID }
            switch results[remoteID] ?? .waiting {
            case .waiting:
                result.waiting += 1
                result.allDevicesReadable = false
                result.summaries.append(SyncDeviceSummary(id: remoteID, name: known?.name ?? L10n.tr("Another Mac"),
                                                          updatedAt: known?.updatedAt, isWaiting: true, needsNewerApp: false))
            case .newerFormat(let name):
                result.allDevicesReadable = false
                result.summaries.append(SyncDeviceSummary(id: remoteID, name: name, updatedAt: nil,
                                                          isWaiting: false, needsNewerApp: true))
            case .invalid:
                result.allDevicesReadable = false
                continue
            case .file(let remote):
                result.referencedDigests.formUnion(remote.assets.values)
                let waitingImages = try await merge(remote, layout: layout, provider: provider, generation: generation)
                result.waiting += waitingImages
                result.summaries.append(SyncDeviceSummary(id: remoteID, name: remote.deviceName, updatedAt: remote.writtenAt,
                                                          isWaiting: waitingImages > 0, needsNewerApp: false))
            }
        }
        return result
    }

    /// Merges one device's file and installs the image files it brought.
    /// Returns how many image files are still downloading.
    private func merge(_ remote: SyncDeviceFile, layout: SyncLayout, provider: any StorageProvider, generation: Int) async throws -> Int {
        let root = self.root
        let remoteID = remote.deviceID
        let base = await Task.detached(priority: .utility) { SyncLocalStore.loadBase(remoteID, in: root) }.value
        try checkActive(generation)
        guard base != remote else { return 0 }
        let localWinsTie = deviceID.uuidString > remote.deviceID.uuidString
        let merged = try await commitMerge(base: base?.state, remote: remote.state, localWinsTie: localWinsTie,
                                           remoteName: remote.deviceName, generation: generation)
        try checkActive(generation)

        let startingCache = digestCache
        let outcome = try await Task.detached(priority: .utility) { () -> (Set<String>, [String: SyncAssets.CachedDigest], Set<String>) in
            var cache = startingCache
            let local = SyncAssets.manifest(for: merged, root: root, cache: &cache)
            let plan = SyncAssets.plan(local: local, remote: remote.assets, base: base?.assets,
                                       referenced: SyncAssets.files(referencedBy: merged), localWinsTie: localWinsTie)
            let waiting = try SyncAssets.install(plan, root: root, layout: layout, provider: provider)
            return (waiting, cache, Set(plan.keys).subtracting(waiting))
        }.value
        try checkActive(generation)
        digestCache = outcome.1
        imagesDidChange(outcome.2)

        // Remember files still downloading as unchanged, so the next pass plans them again.
        var saved = remote
        for path in outcome.0 { saved.assets[path] = base?.assets[path] }
        let finished = saved
        try await Task.detached(priority: .utility) { try SyncLocalStore.saveBase(finished, in: root) }.value
        return outcome.0.count
    }

    /// Commits a merge only when it changes something, after saving one restore
    /// point per pass. Returns the resulting document.
    @discardableResult
    private func commitMerge(base: AppState?, remote: AppState, localWinsTie: Bool, remoteName: String, generation: Int) async throws -> AppState {
        let current = documents.appState
        let preview = SyncMerge.merge(base: base, local: current, remote: remote, localWinsTie: localWinsTie, remoteName: remoteName)
        guard preview.state != current || !preview.conflicts.isEmpty else { return current }
        if preview.state != current, !restorePointSaved {
            let root = self.root
            try await Task.detached(priority: .utility) { try SyncLocalStore.saveRestorePoint(current, in: root) }.value
            restorePointSaved = true
            canUndoLastSync = true
        }
        var found: [SyncConflict] = []
        try checkActive(generation)
        let merged = try await documents.commitSyncedState { state in
            guard self.isEnabled, generation == self.generation else { return state }
            let result = SyncMerge.merge(base: base, local: state, remote: remote, localWinsTie: localWinsTie, remoteName: remoteName)
            found = result.conflicts
            return result.state
        }
        try checkActive(generation)
        if !found.isEmpty {
            let ids = Set(found.map(\.id))
            conflicts = Array((conflicts.filter { !ids.contains($0.id) } + found).suffix(50))
        }
        return merged
    }

    private func publish(_ layout: SyncLayout, provider: any StorageProvider, generation: Int) async throws -> Set<String> {
        let state = try await documents.stateForSync()
        try checkActive(generation)
        let projection = SyncProjection.make(state)
        let root = self.root
        let id = deviceID
        let trimmed = deviceName.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = trimmed.isEmpty ? (Host.current().localizedName ?? "Mac") : trimmed
        let startingCache = digestCache
        let published = record.publishedDigest
        let outcome = try await Task.detached(priority: .utility) { () -> (written: String?, uploaded: Bool?, cache: [String: SyncAssets.CachedDigest], digests: Set<String>) in
            var cache = startingCache
            let manifest = SyncAssets.manifest(for: projection, root: root, cache: &cache)
            // Blobs first: another Mac never sees a reference before its bytes.
            try SyncAssets.upload(manifest, root: root, layout: layout, provider: provider)
            let file = SyncDeviceFile(deviceID: id, deviceName: name, writtenAt: Date(), state: projection, assets: manifest)
            let digest = file.contentDigest
            var written: String?
            if digest != published || !SyncCloud.exists(layout.deviceFile(id), provider: provider) {
                try SyncCloud.write(file, layout: layout, provider: provider)
                written = digest
            }
            let uploaded = try SyncCloud.uploadState(layout.deviceFile(id), provider: provider)
            return (written, uploaded, cache, Set(manifest.values))
        }.value
        try checkActive(generation)
        digestCache = outcome.cache
        if let written = outcome.written {
            record.publishedDigest = written
            record.publishedAt = Date()
        }
        if outcome.uploaded == false { unsyncedSince = unsyncedSince ?? Date() } else { unsyncedSince = nil }
        return outcome.digests
    }

    private func cleanupUnreferencedBlobsIfNeeded(
        layout: SyncLayout,
        provider: any StorageProvider,
        referencedDigests: Set<String>,
        allDevicesReadable: Bool,
        generation: Int
    ) async {
        guard allDevicesReadable else { return }
        let now = nowProvider()
        if let lastCleanup = record.lastBlobCleanupAt,
           now.timeIntervalSince(lastCleanup) < blobCleanupInterval {
            return
        }
        let gracePeriod = blobGracePeriod
        do {
            let deleted = try await Task.detached(priority: .utility) {
                try SyncAssets.cleanupBlobs(
                    referencedDigests: referencedDigests,
                    allDevicesReadable: allDevicesReadable,
                    layout: layout,
                    provider: provider,
                    now: now,
                    gracePeriod: gracePeriod
                )
            }.value
            guard isEnabled, generation == self.generation else { return }
            record.lastBlobCleanupAt = now
            if deleted > 0 {
                debugLog("CloudSync: Cleaned up \(deleted) unreferenced blob(s)")
            }
        } catch {
            debugLog("CloudSync: Blob cleanup skipped due to error: \(error)")
        }
    }

    // MARK: - Plumbing

    private func stopActiveSyncActivity() {
        generation += 1
        scheduled?.cancel()
        followUp?.cancel()
        watcher?.cancel()
        watcher = nil
        watchedDirectory = nil
        folder = nil
        issue = nil
        devices = []
        waitingCount = 0
        waitingSince = nil
        unsyncedSince = nil
    }

    private func resetSyncStateForProviderSwitch() {
        record.publishedDigest = nil
        record.publishedAt = nil
        record.lastBlobCleanupAt = nil
        conflicts = []
        SyncLocalStore.clearBases(in: root)
        persist()
    }

    private func stopLocalSecurityScope() {
        scopedLocalFolder?.stopAccessingSecurityScopedResource()
        scopedLocalFolder = nil
    }

    private func activateCurrentSecurityScope() {
        guard providerKind == .localFolder else { return }
        guard scopedLocalFolder == nil else { return }
        localFolderBase = Self.restoreLocalFolder(from: defaults, startAccess: true, scopedFolder: &scopedLocalFolder) ?? localFolderBase
    }

    private static func restoreLocalFolder(from defaults: UserDefaults, startAccess: Bool, scopedFolder: inout URL?) -> URL? {
        if let bookmark = defaults.data(forKey: Keys.localFolderBookmark) {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI], bookmarkDataIsStale: &stale) {
                if startAccess, url.startAccessingSecurityScopedResource() { scopedFolder = url }
                if stale, let fresh = try? url.bookmarkData(options: .withSecurityScope) {
                    defaults.set(fresh, forKey: Keys.localFolderBookmark)
                }
                return url.standardizedFileURL
            }
        }
        if let path = defaults.string(forKey: Keys.localFolderPath), !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        }
        return nil
    }

    /// Directory events cover new, replaced and hydrated device files across
    /// iCloud Drive, Google Drive (FileProvider), and Syncthing.
    private func watch(_ directory: URL) {
        var st = stat()
        let identity: WatchedDirectory? = lstat(directory.path, &st) == 0
            ? WatchedDirectory(path: directory.path, dev: st.st_dev, ino: st.st_ino)
            : nil
        if let identity, watchedDirectory == identity { return }
        watcher?.cancel()
        watcher = nil
        watchedDirectory = nil
        let descriptor = open(directory.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor,
                                                               eventMask: [.write, .rename, .delete, .extend, .attrib], queue: .main)
        source.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in self?.requestSync(after: 2) }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        watcher = source
        watchedDirectory = identity
    }

    private func persist() {
        record.conflicts = conflicts
        do {
            try SyncLocalStore.saveRecord(record, in: root)
            try SyncLocalStore.saveDigests(digestCache, in: root)
        } catch { issue = .make(error, stage: .localRecord, providerKind: providerKind) }
    }
}
