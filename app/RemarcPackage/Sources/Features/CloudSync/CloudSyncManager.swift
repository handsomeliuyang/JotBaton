import CoreLocalization
import CorePlatform
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
/// A pass: connect, pull and merge each device file (requesting downloads for
/// evicted ones and moving on rather than waiting), install images, then publish
/// this Mac's merged document. Local data never depends on iCloud being ready.
@MainActor
package final class CloudSyncManager: ObservableObject {
    private enum Keys {
        // Shared with the manual snapshot flow, so Macs that opted in keep syncing.
        static let enabled = "snapshotICloudEnabled"
        static let deviceName = "snapshotDeviceName"
        static let deviceID = "snapshotDeviceID"
        static let bookmark = "snapshotICloudAccessBookmark"
    }

    private static let periodicInterval: TimeInterval = 180
    private static let downloadGrace: Duration = .seconds(10)

    private let documents: any CloudSyncDocumentStore
    private let root: URL
    private let defaults: UserDefaults
    private let connect: @Sendable (Bool) throws -> URL
    private let imagesDidChange: @MainActor (Set<String>) -> Void
    private var generation = 0
    package let deviceID: UUID
    @Published package private(set) var isEnabled: Bool
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
    private var scopedFolder: URL?
    private var watcher: DispatchSourceFileSystemObject?
    private var watchedPath: String?
    private var cancellables = Set<AnyCancellable>()

    package var health: SyncHealth {
        SyncHealth.evaluate(enabled: isEnabled, syncing: isSyncing, issue: issue,
                            newerFormatDevice: devices.first(where: { $0.needsNewerApp })?.name,
                            waitingCount: waitingCount, waitingSince: waitingSince, unsyncedSince: unsyncedSince,
                            conflictCount: conflicts.count, now: clock)
    }

    package init(documents: any CloudSyncDocumentStore, root: URL = remarcAppSupportURL,
                 defaults: UserDefaults = .standard,
                 connect: @escaping @Sendable (Bool) throws -> URL = {
                     try CloudSyncLocation.connect(createIfMissing: $0, verifyWriteAccess: $0)
                 },
                 imagesDidChange: @escaping @MainActor (Set<String>) -> Void = { _ in }) {
        self.documents = documents
        self.root = root
        self.defaults = defaults
        self.connect = connect
        self.imagesDidChange = imagesDidChange
        isEnabled = defaults.bool(forKey: Keys.enabled)
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
               CloudSyncLocation.isAuthorizationLocation(url) {
                if url.startAccessingSecurityScopedResource() { scopedFolder = url }
                if stale, let fresh = try? url.bookmarkData(options: .withSecurityScope) { defaults.set(fresh, forKey: Keys.bookmark) }
            }
        }

        documents.statePublisher
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

    // MARK: - Entry points

    package func enable() {
        isEnabled = true
        defaults.set(true, forKey: Keys.enabled)
        needsSetup = true
        requestSync()
    }

    package func disable() {
        isEnabled = false
        generation += 1
        defaults.set(false, forKey: Keys.enabled)
        scheduled?.cancel()
        followUp?.cancel()
        watcher?.cancel()
        watcher = nil
        watchedPath = nil
        scopedFolder?.stopAccessingSecurityScopedResource()
        scopedFolder = nil
        defaults.removeObject(forKey: Keys.bookmark)
        folder = nil
        issue = nil
        devices = []
        waitingCount = 0
        waitingSince = nil
        unsyncedSince = nil
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
        guard isEnabled else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = CloudSyncLocation.driveRoot
        panel.message = L10n.tr("Allow access to iCloud Drive, or its \(AppIdentity.current.cloudDirectoryName) folder. Sync always uses \(AppIdentity.current.cloudDisplayPath).")
        panel.prompt = L10n.tr("Allow Access")
        guard await panel.begin() == .OK, let url = panel.url else { return }
        guard CloudSyncLocation.isAuthorizationLocation(url) else {
            issue = .make(CloudSyncError.message(L10n.tr("Authorize iCloud Drive or its \(AppIdentity.current.cloudDirectoryName) folder. Other folders cannot be used.")), stage: .connection)
            return
        }
        do {
            let bookmark = try url.bookmarkData(options: .withSecurityScope)
            scopedFolder?.stopAccessingSecurityScopedResource()
            scopedFolder = url.startAccessingSecurityScopedResource() ? url : nil
            defaults.set(bookmark, forKey: Keys.bookmark)
            needsSetup = true
            requestSync()
        } catch { issue = .make(error, stage: .connection) }
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
        } catch { issue = .make(error, stage: .applying) }
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
            issue = .make(error, stage: .applying)
            return false
        }
    }

    // MARK: - Pass

    private func runPass() async {
        let generation = self.generation
        lastAttemptAt = Date()
        restorePointSaved = false
        var stage = CloudSyncIssue.Stage.connection
        do {
            let setup = needsSetup
            let connect = self.connect
            let folder = try await Task.detached(priority: .utility) {
                let folder = try connect(setup)
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
            let pulled = try await pullDevices(layout, generation: generation)
            try checkActive(generation)
            let waiting = pulled.waiting
            devices = pulled.summaries

            stage = .publishing
            try await publish(layout, generation: generation)
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
            // Turning sync off also invalidates a pass suspended in file IO.
        } catch {
            guard isEnabled, generation == self.generation else { return }
            issue = .make(error, stage: stage)
            persist()
            scheduleFollowUp(needed: true)
        }
    }

    private func checkActive(_ generation: Int) throws {
        try Task.checkCancellation()
        guard isEnabled, generation == self.generation else { throw CancellationError() }
    }

    /// iCloud delivers downloads and confirms uploads on its own schedule. Look
    /// again soon, backing off, instead of waiting for the window to reopen.
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
    }

    private func pullDevices(_ layout: SyncLayout, generation: Int) async throws -> PullResult {
        let id = deviceID
        let ids = try await Task.detached(priority: .utility) { try SyncCloud.listDevices(layout) }.value.filter { $0 != id }
        // Request every download first, then give iCloud a short grace period.
        // A file still remote after that is merged on a later pass.
        var results: [UUID: SyncCloud.LoadResult] = [:]
        var pending = ids
        let clock = ContinuousClock()
        let deadline = clock.now + Self.downloadGrace
        while !pending.isEmpty {
            try checkActive(generation)
            let batch = pending
            let loaded = await Task.detached(priority: .utility) { batch.map { ($0, SyncCloud.load($0, layout: layout)) } }.value
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
                result.summaries.append(SyncDeviceSummary(id: remoteID, name: known?.name ?? L10n.tr("Another Mac"),
                                                          updatedAt: known?.updatedAt, isWaiting: true, needsNewerApp: false))
            case .newerFormat(let name):
                result.summaries.append(SyncDeviceSummary(id: remoteID, name: name, updatedAt: nil,
                                                          isWaiting: false, needsNewerApp: true))
            case .invalid:
                continue
            case .file(let remote):
                let waitingImages = try await merge(remote, layout: layout, generation: generation)
                result.waiting += waitingImages
                result.summaries.append(SyncDeviceSummary(id: remoteID, name: remote.deviceName, updatedAt: remote.writtenAt,
                                                          isWaiting: waitingImages > 0, needsNewerApp: false))
            }
        }
        return result
    }

    /// Merges one device's file and installs the image files it brought.
    /// Returns how many image files are still downloading.
    private func merge(_ remote: SyncDeviceFile, layout: SyncLayout, generation: Int) async throws -> Int {
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
            let waiting = try SyncAssets.install(plan, root: root, layout: layout)
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

    private func publish(_ layout: SyncLayout, generation: Int) async throws {
        let state = try await documents.stateForSync()
        try checkActive(generation)
        let projection = SyncProjection.make(state)
        let root = self.root
        let id = deviceID
        let trimmed = deviceName.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = trimmed.isEmpty ? (Host.current().localizedName ?? "Mac") : trimmed
        let startingCache = digestCache
        let published = record.publishedDigest
        let outcome = try await Task.detached(priority: .utility) { () -> (written: String?, uploaded: Bool?, cache: [String: SyncAssets.CachedDigest]) in
            var cache = startingCache
            let manifest = SyncAssets.manifest(for: projection, root: root, cache: &cache)
            // Blobs first: another Mac never sees a reference before its bytes.
            try SyncAssets.upload(manifest, root: root, layout: layout)
            let file = SyncDeviceFile(deviceID: id, deviceName: name, writtenAt: Date(), state: projection, assets: manifest)
            let digest = file.contentDigest
            var written: String?
            if digest != published || !SyncCloud.exists(layout.deviceFile(id)) {
                try SyncCloud.write(file, layout: layout)
                written = digest
            }
            let uploaded = try SyncCloud.uploadState(layout.deviceFile(id))
            return (written, uploaded, cache)
        }.value
        try checkActive(generation)
        digestCache = outcome.cache
        if let written = outcome.written {
            record.publishedDigest = written
            record.publishedAt = Date()
        }
        if outcome.uploaded == false { unsyncedSince = unsyncedSince ?? Date() } else { unsyncedSince = nil }
    }

    // MARK: - Plumbing

    /// Directory events cover new and replaced device files; iCloud swaps a
    /// file in atomically when its download completes.
    private func watch(_ directory: URL) {
        guard watchedPath != directory.path else { return }
        watcher?.cancel()
        let descriptor = open(directory.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor,
                                                               eventMask: [.write, .rename, .delete], queue: .main)
        source.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in self?.requestSync(after: 2) }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        watcher = source
        watchedPath = directory.path
    }

    private func persist() {
        record.conflicts = conflicts
        do {
            try SyncLocalStore.saveRecord(record, in: root)
            try SyncLocalStore.saveDigests(digestCache, in: root)
        } catch { issue = .make(error, stage: .localRecord) }
    }
}
