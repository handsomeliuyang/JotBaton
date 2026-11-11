import AppKit
import Combine

@MainActor
final class SnapshotSyncManager: ObservableObject {
    static let shared = SnapshotSyncManager()
    @Published private(set) var isEnabled: Bool
    @Published private(set) var folder: URL?
    @Published var deviceName: String {
        didSet { UserDefaults.standard.set(deviceName, forKey: "snapshotDeviceName") }
    }
    @Published private(set) var cloudData: SnapshotVersion?
    @Published private(set) var rollback: SnapshotVersion?
    @Published private(set) var receipt: SnapshotReceipt?
    @Published private(set) var hasLocalChanges = true
    @Published private(set) var localUpdatedAt: Date?
    @Published private(set) var lastCheckedAt: Date?
    @Published private(set) var cloudTransfer = SnapshotCloudTransfer.unknown
    @Published private(set) var isBusy = false
    @Published private var progressKey: L10n.Key?
    @Published private var noticeKey: L10n.Key?
    @Published private(set) var record: SnapshotSyncRecord
    @Published private(set) var localContentHash: String?
    var progress: String? { progressKey.map { L10n.tr($0) } }
    var notice: String? { noticeKey.map { L10n.tr($0) } }
    var publication: SnapshotPublication? { record.publication }
    var issue: SnapshotSyncIssue? { record.issue }
    private let deviceID: UUID
    private var subscription: AnyCancellable?
    private var fingerprintGeneration = 0
    private var pollingTask: Task<Void, Never>?
    private var scopedFolder: URL?
    private var reviewHolders = Set<UUID>()
    private var lastCheckAttemptAt: Date?

    var comparison: SnapshotComparison {
        SnapshotComparison.compare(localHash: localContentHash, localTime: localUpdatedAt, cloud: cloudData,
            baselineID: receipt?.version.formatVersion == 2 ? receipt?.version.id : nil,
            localEdits: hasLocalChanges, multipleCloudHeads: false, baselineHash: receipt?.contentHash)
    }
    var canPublish: Bool { isEnabled && !isBusy && folder != nil }
    var canApply: Bool { canPublish && cloudData != nil && !cloudTransfer.isActive && publication?.isPending != true }
    var summary: String {
        if let progress { return progress }
        if !isEnabled { return L10n.tr("iCloud data is off") }
        if let issue { return L10n.lookup(issue.message) }
        if publication?.isPending == true { return L10n.tr("Waiting for iCloud upload confirmation") }
        if cloudData == nil { return L10n.tr("Publish this Mac to create the current cloud copy") }
        return comparison == .same ? L10n.tr("This Mac matches the current cloud data") : L10n.tr("This Mac and iCloud have different data")
    }
    var shortStatus: String {
        if !isEnabled { return L10n.tr("Off") }
        if isBusy || publication?.isPending == true { return L10n.tr("Syncing") }
        if issue != nil { return L10n.tr("Error") }
        return comparison == .same ? L10n.tr("Synced") : L10n.tr("Check")
    }

    private init() {
        let defaults = UserDefaults.standard
        isEnabled = defaults.bool(forKey: "snapshotICloudEnabled")
        deviceName = defaults.string(forKey: "snapshotDeviceName") ?? Host.current().localizedName ?? "This Mac"
        if let raw = defaults.string(forKey: "snapshotDeviceID"), let id = UUID(uuidString: raw) { deviceID = id }
        else { deviceID = UUID(); defaults.set(deviceID.uuidString, forKey: "snapshotDeviceID") }
        receipt = PersistenceManager.shared.snapshotReceipt
        rollback = PersistenceManager.shared.snapshotUndo
        do { record = try SnapshotSyncStore.load(from: remarcAppSupportURL) }
        catch { record = SnapshotSyncRecord(issue: .make(error, stage: .localRecord)) }
        localUpdatedAt = record.contentStamp?.modifiedAt
        if let bookmark = defaults.data(forKey: "snapshotICloudAccessBookmark") {
            do {
                var stale = false
                let url = try URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI], bookmarkDataIsStale: &stale)
                if SnapshotCloudLocation.isAuthorizationLocation(url) {
                    if url.startAccessingSecurityScopedResource() { scopedFolder = url }
                    if stale { defaults.set(try url.bookmarkData(options: .withSecurityScope), forKey: "snapshotICloudAccessBookmark") }
                }
            } catch { record.issue = .make(error, stage: .connection) }
        }
        subscription = PersistenceManager.shared.$appState
            .debounce(for: .milliseconds(500), scheduler: DispatchQueue.main)
            .sink { [weak self] state in Task { @MainActor [weak self] in await self?.refreshLocalStatus(state) } }
    }

    func holdAutomaticChecks(_ active: Bool, token: UUID) {
        if active { reviewHolders.insert(token) } else { reviewHolders.remove(token) }
    }

    func enable() async {
        guard !isBusy else { return }
        isEnabled = true
        UserDefaults.standard.set(true, forKey: "snapshotICloudEnabled")
        await check(createIfMissing: true)
    }

    func authorizeAccess() async {
        guard isEnabled, !isBusy else { return }
        let reviewToken = UUID()
        reviewHolders.insert(reviewToken)
        defer { reviewHolders.remove(reviewToken) }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = SnapshotCloudLocation.driveRoot
        panel.message = L10n.tr("Allow access to iCloud Drive, or its \(AppIdentity.current.directoryName) folder. Snapshots always use \(AppIdentity.current.cloudDisplayPath). Your saved snapshot will be kept for retry.")
        panel.prompt = L10n.tr("Allow Access")
        let response = await panel.begin()
        guard response == .OK, let url = panel.url else { return }
        guard SnapshotCloudLocation.isAuthorizationLocation(url) else {
            fail(SnapshotError.message(L10n.tr("Authorize iCloud Drive or its \(AppIdentity.current.directoryName) folder. Other folders cannot be used.")), stage: .connection)
            return
        }
        do {
            let bookmark = try url.bookmarkData(options: .withSecurityScope)
            if let scopedFolder { scopedFolder.stopAccessingSecurityScopedResource() }
            scopedFolder = url.startAccessingSecurityScopedResource() ? url : nil
            UserDefaults.standard.set(bookmark, forKey: "snapshotICloudAccessBookmark")
            await check(createIfMissing: true)
        } catch { fail(error, stage: .connection) }
    }

    func disconnect() {
        guard !isBusy else { return }
        pollingTask?.cancel()
        isEnabled = false
        UserDefaults.standard.set(false, forKey: "snapshotICloudEnabled")
        if let scopedFolder { scopedFolder.stopAccessingSecurityScopedResource() }
        scopedFolder = nil
        folder = nil
        cloudTransfer = .unknown
        cloudData = nil
        lastCheckedAt = nil
        lastCheckAttemptAt = nil
        noticeKey = nil
        UserDefaults.standard.removeObject(forKey: "snapshotICloudAccessBookmark")
        // Keep the durable pending snapshot and diagnostic for the next enable.
    }

    func checkIfNeeded() async {
        guard isEnabled, !isBusy, reviewHolders.isEmpty,
              lastCheckAttemptAt.map({ Date().timeIntervalSince($0) > 15 }) ?? true else { return }
        await check()
    }

    func observeCloud() async {
        while !Task.isCancelled {
            await checkIfNeeded()
            do { try await Task.sleep(for: .seconds(3)) } catch { return }
        }
    }

    func check(createIfMissing: Bool = false) async {
        guard isEnabled, !isBusy else { return }
        lastCheckAttemptAt = Date()
        isBusy = true
        progressKey = "Checking iCloud…"
        noticeKey = nil
        defer { isBusy = false; progressKey = nil }
        do {
            let directory = try await Task.detached(priority: .utility) {
                try SnapshotCloudLocation.connect(createIfMissing: createIfMissing)
            }.value
            folder = directory
            cloudData = try await Task.detached(priority: .utility) { try SnapshotDisk.current(in: directory) }.value
            await refreshLocalStatus(try await PersistenceManager.shared.stateForSnapshot())
            record.issue = nil
            try await advancePublication(in: directory)
            await updateCloudTransfer(in: directory)
            lastCheckedAt = Date()
            persist()
            startUploadPolling()
            let root = remarcAppSupportURL
            let undo = PersistenceManager.shared.snapshotUndo
            try await Task.detached(priority: .utility) { try SnapshotRollbackStore.cleanup(in: root, keeping: undo) }.value
        } catch SnapshotError.waitingForDownload {
            noticeKey = "Waiting for iCloud to download the current data. Your local tasks are kept."
        } catch { fail(error, stage: folder == nil ? .connection : .checking) }
    }

    /// Each click prepares the current live document. There is no local outbox.
    func publish() async {
        guard isEnabled, !isBusy else { return }
        let expected = cloudData?.id
        let abandoned = publication?.isPending == true ? publication?.version : nil
        pollingTask?.cancel()
        isBusy = true
        progressKey = "Preparing current data…"
        noticeKey = nil
        defer { isBusy = false; progressKey = nil }
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("remarc-publish-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        do {
            let directory = try await Task.detached(priority: .utility) {
                try SnapshotCloudLocation.connect(verifyWriteAccess: true)
            }.value
            folder = directory
            let fresh = try await Task.detached(priority: .utility) { try SnapshotDisk.current(in: directory) }.value
            cloudData = fresh
            guard fresh?.id == expected else {
                throw SnapshotError.message(L10n.tr("Cloud data changed while publishing. Check again before replacing it."))
            }
            let state = try await PersistenceManager.shared.stateForSnapshot()
            await refreshLocalStatus(state)
            let root = remarcAppSupportURL
            let prepared = try await Task.detached(priority: .utility) { try SnapshotArchive.prepare(state, root: root) }.value
            if let fresh, prepared.hash == fresh.contentHash || (receipt?.version.id == fresh.id && prepared.hash == receipt?.contentHash) {
                noticeKey = "The current cloud copy already matches this Mac."
                return
            }
            let name = deviceName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { throw SnapshotError.message(L10n.tr("Enter a name for this Mac before publishing.")) }
            let id = deviceID
            let time = localUpdatedAt
            let result = try await Task.detached(priority: .utility) {
                let cleanup = try SnapshotDisk.cleanupCandidates(in: directory, current: fresh, abandoned: abandoned)
                let version = try SnapshotArchive.create(prepared, in: temporary, deviceID: id, deviceName: name, contentModifiedAt: time)
                try SnapshotDisk.stageArchive(version, from: temporary.appendingPathComponent(version.archiveName), to: directory)
                return (version, cleanup)
            }.value
            record.publication = SnapshotPublication(version: result.0, phase: .awaitingUpload,
                previousID: fresh?.id, cleanupNames: result.1)
            record.issue = nil
            try SnapshotSyncStore.save(record, to: root)
            try await advancePublication(in: directory)
            await updateCloudTransfer(in: directory)
            persist()
            startUploadPolling()
        } catch SnapshotError.waitingForDownload {
            noticeKey = "Waiting for iCloud to download the current data. Your local tasks are kept."
        } catch { fail(error, stage: .publishing, versionID: publication?.version.id) }
    }

    func retry() async { await publish() }

    private func advancePublication(in directory: URL) async throws {
        guard var saved = publication else { return }
        let version = saved.version
        let current = try await Task.detached(priority: .utility) { try SnapshotDisk.current(in: directory) }.value
        if current?.id == saved.version.id { saved.currentCommitted = true }
        if saved.currentCommitted && current?.id != saved.version.id {
            record.publication = nil
            cloudData = current
            noticeKey = "Cloud data changed on another Mac. Check before publishing again."
            return
        }
        if !saved.currentCommitted {
            let upload = try await Task.detached(priority: .utility) { try SnapshotDisk.archiveUploadState(version, in: directory) }.value
            guard upload == .uploaded else {
                record.publication?.phase = upload == .uploading ? .awaitingUpload : .unconfirmed
                return
            }
            let previous = saved.previousID
            try await Task.detached(priority: .utility) { try SnapshotDisk.commitCurrent(version, replacing: previous, in: directory) }.value
            saved.currentCommitted = true
            record.publication = saved
            try SnapshotSyncStore.save(record, to: remarcAppSupportURL)
        }
        let upload = try await Task.detached(priority: .utility) { try SnapshotDisk.uploadState(version, in: directory) }.value
        guard upload == .uploaded else {
            record.publication?.phase = upload == .uploading ? .awaitingUpload : .unconfirmed
            return
        }
        let currentID = try await Task.detached(priority: .utility) { try SnapshotDisk.current(in: directory)?.id }.value
        guard currentID == version.id else { return }
        record.publication?.phase = .confirmed
        record.publication?.currentCommitted = true
        if record.publication?.confirmedAt == nil { record.publication?.confirmedAt = Date() }
        if receipt?.version.id != version.id {
            try await PersistenceManager.shared.recordSnapshotReceipt(SnapshotReceipt(version: version, contentHash: version.contentHash))
            await refreshLocalStatus(PersistenceManager.shared.appState)
        }
        let cleanup = saved.cleanupNames
        let root = remarcAppSupportURL
        try await Task.detached(priority: .utility) {
            try SnapshotDisk.cleanup(cleanup, keeping: version, in: directory)
            try SnapshotRollbackStore.removeLegacyCaches(in: root)
        }.value
        record.issue = nil
        cloudData = version
        persist()
    }

    func apply(_ version: SnapshotVersion) async {
        guard !isBusy, let source = folder else { return }
        isBusy = true
        progressKey = "Downloading and verifying current data…"
        noticeKey = nil
        defer { isBusy = false; progressKey = nil }
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("remarc-apply-\(UUID()).zip")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let root = remarcAppSupportURL
        do {
            let incoming = try await Task.detached(priority: .utility) {
                _ = try SnapshotCloudLocation.connect()
                guard try SnapshotDisk.current(in: source)?.id == version.id else {
                    throw SnapshotError.message(L10n.tr("Cloud data changed. Check again before applying it."))
                }
                try SnapshotDisk.download(version, from: source, to: temporary)
                return try SnapshotArchive.read(version, archive: temporary)
            }.value
            let before = try await PersistenceManager.shared.stateForSnapshot()
            let local = try await Task.detached(priority: .utility) { try SnapshotArchive.prepare(before, root: root) }.value
            guard local.hash != incoming.hash else { noticeKey = "The current cloud copy already matches this Mac."; return }
            progressKey = "Saving one undo copy…"
            let id = deviceID
            let name = deviceName
            let time = localUpdatedAt
            let undo = try await Task.detached(priority: .utility) {
                try SnapshotArchive.create(local, in: SnapshotRollbackStore.prepareDirectory(in: root), deviceID: id,
                                           deviceName: name, contentModifiedAt: time)
            }.value
            do {
                let installed = try await Task.detached(priority: .utility) { try SnapshotArchive.installFiles(incoming, root: root) }.value
                try await PersistenceManager.shared.applySnapshot(installed, version: version, expected: before, undo: undo)
            } catch {
                // The document still points to the previous undo copy on failure.
                let committed = PersistenceManager.shared.snapshotUndo
                try? await Task.detached(priority: .utility) { try SnapshotRollbackStore.cleanup(in: root, keeping: committed) }.value
                throw error
            }
            record.publication = nil
            record.issue = nil
            record.contentStamp = SnapshotContentStamp(contentHash: incoming.hash, modifiedAt: version.contentModifiedAt)
            record.lastAppliedAt = PersistenceManager.shared.snapshotReceipt?.appliedAt
            await refreshLocalStatus(PersistenceManager.shared.appState)
            persist()
            noticeKey = "Cloud data applied. You can undo this application once."
            try await Task.detached(priority: .utility) { try SnapshotRollbackStore.cleanup(in: root, keeping: undo) }.value
        } catch SnapshotError.waitingForDownload {
            noticeKey = "Waiting for iCloud to download the current data. Your local tasks are kept."
        } catch { fail(error, stage: .applying, versionID: version.id) }
    }

    func undoLastApply() async {
        guard !isBusy, let version = PersistenceManager.shared.snapshotUndo else { return }
        isBusy = true
        progressKey = "Restoring data from before the last application…"
        noticeKey = nil
        defer { isBusy = false; progressKey = nil }
        let root = remarcAppSupportURL
        do {
            let incoming = try await Task.detached(priority: .utility) {
                try SnapshotArchive.read(version, archive: SnapshotRollbackStore.prepareDirectory(in: root).appendingPathComponent(version.archiveName))
            }.value
            let before = try await PersistenceManager.shared.stateForSnapshot()
            let installed = try await Task.detached(priority: .utility) { try SnapshotArchive.installFiles(incoming, root: root) }.value
            try await PersistenceManager.shared.applySnapshot(installed, version: version, expected: before, undoing: true)
            record.issue = nil
            record.contentStamp = SnapshotContentStamp(contentHash: incoming.hash, modifiedAt: Date())
            record.lastAppliedAt = nil
            await refreshLocalStatus(PersistenceManager.shared.appState)
            persist()
            noticeKey = "Last application undone on this Mac."
            try await Task.detached(priority: .utility) { try SnapshotRollbackStore.cleanup(in: root, keeping: nil) }.value
        } catch { fail(error, stage: .applying, versionID: version.id) }
    }

    private func updateCloudTransfer(in directory: URL) async {
        let version = publication?.isPending == true && publication?.currentCommitted == true ? publication?.version : cloudData
        do {
            cloudTransfer = try await Task.detached(priority: .utility) { try SnapshotDisk.transferState(in: directory, version: version) }.value
        } catch { cloudTransfer = .failed }
    }

    private func refreshLocalStatus(_ state: AppState) async {
        fingerprintGeneration += 1
        let generation = fingerprintGeneration
        let root = remarcAppSupportURL
        receipt = PersistenceManager.shared.snapshotReceipt
        rollback = PersistenceManager.shared.snapshotUndo
        do {
            let hash = try await Task.detached(priority: .utility) { try SnapshotArchive.prepare(state, root: root).hash }.value
            guard generation == fingerprintGeneration else { return }
            let newApplication = receipt?.appliedAt != nil && receipt?.appliedAt != record.lastAppliedAt
            let adopted = newApplication || record.contentStamp == nil ? PersistenceManager.shared.snapshotContentStamp : nil
            let stamp = SnapshotContentStamp.tracking(hash: hash, saved: record.contentStamp, adopted: adopted,
                observedLive: localContentHash != nil && !newApplication, now: Date())
            let stampChanged = stamp != record.contentStamp
            record.contentStamp = stamp
            if newApplication { record.lastAppliedAt = receipt?.appliedAt }
            localUpdatedAt = stamp.modifiedAt
            localContentHash = hash
            hasLocalChanges = hash != receipt?.contentHash
            if stampChanged { persist() }
        } catch {
            guard generation == fingerprintGeneration else { return }
            localContentHash = nil
            hasLocalChanges = true
        }
    }

    private func fail(_ error: Error, stage: SnapshotSyncIssue.Stage, versionID: UUID? = nil) {
        record.issue = .make(error, stage: stage, versionID: versionID)
        persist()
    }

    private func persist() {
        do { try SnapshotSyncStore.save(record, to: remarcAppSupportURL) }
        catch { record.issue = .make(error, stage: .localRecord, versionID: publication?.version.id) }
    }

    private func startUploadPolling() {
        pollingTask?.cancel()
        guard publication?.isPending == true else { return }
        pollingTask = Task { [weak self] in
            for _ in 0..<60 {
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
                guard let self, self.isEnabled, let folder = self.folder, self.publication?.isPending == true else { return }
                if self.isBusy || !self.reviewHolders.isEmpty { continue }
                self.isBusy = true
                do { try await self.advancePublication(in: folder) }
                catch { self.fail(error, stage: .uploadConfirmation, versionID: self.publication?.version.id) }
                await self.updateCloudTransfer(in: folder)
                self.persist()
                self.isBusy = false
            }
        }
    }

    func openICloudSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preferences.AppleIDPrefPane?iCloud"), NSWorkspace.shared.open(url) { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
    }
}
