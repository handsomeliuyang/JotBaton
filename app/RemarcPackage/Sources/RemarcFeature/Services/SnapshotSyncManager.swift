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
    @Published private(set) var versions: [SnapshotVersion] = []
    @Published private(set) var backups: [SnapshotVersion] = []
    @Published private(set) var receipt: SnapshotReceipt?
    @Published private(set) var hasLocalChanges = true
    @Published private(set) var localUpdatedAt: Date?
    @Published private(set) var lastCheckedAt: Date?
    @Published private(set) var cloudTransfer = SnapshotCloudTransfer.unknown
    @Published private(set) var isBusy = false
    @Published private var progressKey: L10n.Key?
    var progress: String? { progressKey.map { L10n.tr($0) } }
    @Published private var noticeKey: L10n.Key?
    var notice: String? { noticeKey.map { L10n.tr($0) } }
    @Published private(set) var record: SnapshotSyncRecord
    @Published private(set) var localContentHash: String?
    private let deviceID: UUID
    private var subscription: AnyCancellable?
    private var fingerprintGeneration = 0
    private var pollingTask: Task<Void, Never>?
    private var scopedFolder: URL?
    private var reviewHolders = Set<UUID>()
    private var transferReadInFlight = false
    private var lastCheckAttemptAt: Date?

    func holdAutomaticChecks(_ active: Bool, token: UUID) {
        if active { reviewHolders.insert(token) } else { reviewHolders.remove(token) }
    }

    var currentVersion: SnapshotVersion? { receipt?.version }
    var publication: SnapshotPublication? { record.publication }
    var issue: SnapshotSyncIssue? { record.issue }
    var heads: [SnapshotVersion] { SnapshotDisk.heads(versions) }
    var remoteHeads: [SnapshotVersion] {
        heads.filter { $0.id != currentVersion?.id && !($0.id == publication?.version.id && publication?.isPending == true) }
    }
    var hasRemoteUpdate: Bool { !remoteHeads.isEmpty }
    var hasSavedCurrentSnapshot: Bool { publication?.isPending == true && publication?.version.contentHash == localContentHash }
    var cloudHeads: [SnapshotVersion] {
        SnapshotDisk.heads(versions.filter { !($0.id == publication?.version.id && publication?.isPending == true) })
    }
    var cloudData: SnapshotVersion? { cloudHeads.count == 1 ? cloudHeads.first : nil }
    var cloudSource: String {
        if cloudHeads.count > 1 { return L10n.tr("Needs review") }
        guard let cloudData else { return L10n.tr("Not published yet") }
        return cloudData.deviceID == deviceID ? L10n.tr("This Mac · \(cloudData.deviceName)") : L10n.tr("Other Mac · \(cloudData.deviceName)")
    }
    var comparison: SnapshotComparison {
        let state = PersistenceManager.shared.appState
        let meaningful = !state.comments.isEmpty || !state.transcriptions.isEmpty || state.totalCommentsCreated > 0
            || state.sessions.contains { !$0.isInbox }
        return SnapshotComparison.compare(localHash: localContentHash, localTime: localUpdatedAt, cloud: cloudData,
            baselineID: currentVersion?.id, localEdits: hasLocalChanges && (receipt != nil || meaningful),
            multipleCloudHeads: cloudHeads.count > 1, baselineHash: receipt?.contentHash)
    }
    var shortStatus: String {
        if !isEnabled { return L10n.tr("Off") }
        if isBusy { return L10n.tr("Check") }
        if let issue { return issue.kind == .review ? L10n.tr("Review") : issue.isWarning ? L10n.tr("Pending") : L10n.tr("Error") }
        if folder == nil { return L10n.tr("Check") }
        if cloudTransfer == .failed { return L10n.tr("Error") }
        if cloudTransfer.isActive { return L10n.tr("Syncing") }
        if publication?.isPending == true || cloudTransfer == .waiting { return L10n.tr("Pending") }
        switch comparison {
        case .same: return L10n.tr("Synced")
        case .publish: return L10n.tr("Publish")
        case .receive: return L10n.tr("Update")
        case .choose: return L10n.tr("Review")
        }
    }
    var presentation: SnapshotSyncPresentation {
        if isEnabled, folder != nil, issue == nil, progress == nil, publication?.isPending != true, cloudTransfer.blocksReplacement {
            return SnapshotSyncPresentation(title: cloudTransfer.title, action: .check,
                tone: cloudTransfer == .failed ? .error : .warning)
        }
        return SnapshotSyncPresentation.make(enabled: isEnabled, directoryReady: folder != nil, progress: progress,
            issue: issue, publication: publication, hasLocalChanges: hasLocalChanges,
            remoteCount: cloudHeads.count > 1 ? cloudHeads.count : remoteHeads.count, comparison: comparison)
    }
    var summary: String {
        if issue == nil, progress == nil, cloudTransfer.blocksReplacement { return cloudTransfer.title }
        return presentation.title
    }
    var cloudTransferTitle: String {
        if !isEnabled { return L10n.tr("Not enabled") }
        if folder == nil { return issue == nil ? L10n.tr("Not checked") : L10n.tr("Unavailable") }
        return cloudTransfer.title
    }
    var canPublish: Bool {
        isEnabled && !isBusy && folder != nil && publication?.isPending != true && !cloudTransfer.blocksReplacement && comparison == .publish
    }
    var uploadMessage: String? {
        guard let publication else { return nil }
        switch publication.phase {
        case .savedLocally: return L10n.tr("The data is saved on this Mac. Retry to send this same copy to iCloud.")
        case .awaitingUpload: return L10n.tr("The data is saved in iCloud Drive. Waiting for upload confirmation.")
        case .unconfirmed: return L10n.tr("The data is saved. Cloud upload has not been confirmed yet.")
        case .confirmed:
            let date = publication.confirmedAt?.formatted(date: .abbreviated, time: .standard) ?? L10n.tr("previously")
            return L10n.tr("Upload confirmed \(date). Your other Mac must check and apply the version manually.")
        }
    }
    private var backupDirectory: URL { remarcAppSupportURL.appendingPathComponent("snapshot-backups", isDirectory: true) }
    private var outboxDirectory: URL { SnapshotSyncStore.outbox(in: remarcAppSupportURL) }

    private init() {
        let defaults = UserDefaults.standard
        isEnabled = defaults.bool(forKey: "snapshotICloudEnabled")
        deviceName = defaults.string(forKey: "snapshotDeviceName") ?? Host.current().localizedName ?? "This Mac"
        if let raw = defaults.string(forKey: "snapshotDeviceID"), let id = UUID(uuidString: raw) { deviceID = id }
        else {
            deviceID = UUID()
            defaults.set(deviceID.uuidString, forKey: "snapshotDeviceID")
        }
        receipt = PersistenceManager.shared.snapshotReceipt
        do { record = try SnapshotSyncStore.load(from: remarcAppSupportURL) }
        catch { record = SnapshotSyncRecord(issue: .make(error, stage: .localRecord)) }
        // Older previews recorded a receipt as soon as the directory write
        // succeeded. Require fresh upload confirmation for those versions.
        if record.publication == nil, let receipt, receipt.version.deviceID == deviceID {
            record.publication = SnapshotPublication(version: receipt.version, phase: .unconfirmed)
        }
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
        localUpdatedAt = record.contentStamp?.modifiedAt
        subscription = PersistenceManager.shared.$appState
            .debounce(for: .milliseconds(500), scheduler: DispatchQueue.main)
            .sink { [weak self] state in
                Task { @MainActor [weak self] in await self?.refreshLocalStatus(state) }
            }
        Task { await loadBackups() }
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
        versions = []
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

    /// Observe only while a sync surface is open. Receiving task data remains
    /// manual; these reads never apply a snapshot or change content timestamps.
    func observeCloud() async {
        while !Task.isCancelled {
            await checkIfNeeded()
            if !isBusy, reviewHolders.isEmpty, let folder { await updateCloudTransfer(in: folder) }
            do { try await Task.sleep(for: .seconds(3)) } catch { return }
        }
    }

    private func updateCloudTransfer(in directory: URL) async {
        guard isEnabled, !transferReadInFlight else { return }
        transferReadInFlight = true
        defer { transferReadInFlight = false }
        let known = versions
        let pending = publication?.isPending == true ? publication?.version : nil
        let observed: SnapshotCloudTransfer
        do {
            observed = try await Task.detached(priority: .utility) {
                try SnapshotDisk.transferState(in: directory, versions: known, pending: pending)
            }.value
        } catch { observed = .failed }
        // A disabled connection, newly discovered snapshot, or finished publish
        // invalidates any metadata read that was already in flight.
        guard isEnabled, folder == directory, Set(versions.map(\.id)) == Set(known.map(\.id)),
              (publication?.isPending == true ? publication?.version.id : nil) == pending?.id else { return }
        cloudTransfer = observed
    }

    func check(createIfMissing: Bool = false) async {
        guard isEnabled, !isBusy else { return }
        lastCheckAttemptAt = Date()
        isBusy = true
        progressKey = "Checking iCloud…"
        noticeKey = nil
        defer { isBusy = false; progressKey = nil }
        var stage = SnapshotSyncIssue.Stage.connection
        do {
            let directory = try await Task.detached(priority: .utility) {
                try SnapshotCloudLocation.connect(createIfMissing: createIfMissing)
            }.value
            folder = directory
            stage = .checking
            versions = try await Task.detached(priority: .utility) { try SnapshotDisk.versions(in: directory) }.value
            let state = try await PersistenceManager.shared.stateForSnapshot()
            await refreshLocalStatus(state)
            lastCheckedAt = Date()
            if issue?.stage == .connection || issue?.stage == .checking || issue?.stage == .uploadConfirmation {
                record.issue = nil
            }
            try await confirmUpload(in: directory)
            if issue?.stage == .localRecord {
                try SnapshotSyncStore.save(record, to: remarcAppSupportURL)
                record.issue = nil
            }
            persist()
            startUploadPolling()
        } catch SnapshotError.waitingForDownload {
            lastCheckedAt = Date()
            if issue?.stage == .checking { record.issue = nil; persist() }
        } catch {
            if stage == .connection { folder = nil }
            fail(error, stage: stage)
        }
        if let folder { await updateCloudTransfer(in: folder) }
    }

    func publish(allowReplacingRemote: Bool = false) async {
        guard isEnabled, !isBusy else { return }
        if publication?.isPending == true {
            await retryPublication()
            return
        }
        let knownIDs = Set(versions.map(\.id))
        isBusy = true
        progressKey = "Checking access before publishing…"
        noticeKey = nil
        defer { isBusy = false; progressKey = nil }
        var stage = SnapshotSyncIssue.Stage.connection
        do {
            let directory = try await Task.detached(priority: .utility) {
                try SnapshotCloudLocation.connect(verifyWriteAccess: true)
            }.value
            folder = directory
            stage = .checking
            let fresh = try await Task.detached(priority: .utility) { try SnapshotDisk.versions(in: directory) }.value
            versions = fresh
            guard Set(fresh.map(\.id)) == knownIDs else {
                record.issue = .review("The cloud version list changed. Review the versions before publishing.")
                persist(); return
            }
            guard allowReplacingRemote || (!hasRemoteUpdate && heads.count < 2) else {
                record.issue = .review("There are other cloud versions. Choose which complete state to keep.")
                persist(); return
            }
            stage = .preparing
            progressKey = "Saving a complete snapshot on this Mac…"
            let state = try await PersistenceManager.shared.stateForSnapshot()
            await refreshLocalStatus(state)
            let contentTime = localUpdatedAt
            let root = remarcAppSupportURL
            let outbox = outboxDirectory
            let id = deviceID
            let name = deviceName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { throw SnapshotError.message(L10n.tr("Enter a name for this Mac before publishing.")) }
            let parents = heads.map(\.id)
            let parent = heads.count == 1 ? heads.first?.id : currentVersion?.id
            let version = try await Task.detached(priority: .utility) {
                let prepared = try SnapshotArchive.prepare(state, root: root)
                return try SnapshotArchive.create(prepared, in: outbox, deviceID: id, deviceName: name,
                    parentID: parent, supersededIDs: parents, contentModifiedAt: contentTime)
            }.value
            record.publication = SnapshotPublication(version: version, phase: .savedLocally)
            record.issue = nil
            // This record and the outbox archive must survive a crash BEFORE
            // anything is sent to iCloud. Do not advance the app receipt yet.
            stage = .localRecord
            try SnapshotSyncStore.save(record, to: root)
            stage = .publishing
            try await sendSavedPublication(to: directory)
            await refreshLocalStatus(PersistenceManager.shared.appState)
            startUploadPolling()
        } catch SnapshotError.waitingForDownload {
            noticeKey = "Waiting for the cloud data to download. Check again before publishing."
        } catch {
            if stage == .connection { folder = nil }
            fail(error, stage: stage, versionID: publication?.version.id)
        }
        if let folder { await updateCloudTransfer(in: folder) }
    }

    func retry() async {
        guard !isBusy else { return }
        if publication?.phase == .savedLocally { await retryPublication() }
        else if issue?.stage == .preparing || (issue?.stage == .publishing && publication?.isPending != true) {
            await publish()
        } else { await check() }
    }

    private func retryPublication() async {
        guard isEnabled, !isBusy, let saved = publication else { return }
        isBusy = true
        progressKey = "Retrying saved data…"
        noticeKey = nil
        defer { isBusy = false; progressKey = nil }
        var stage = SnapshotSyncIssue.Stage.connection
        do {
            let directory = try await Task.detached(priority: .utility) {
                try SnapshotCloudLocation.connect(verifyWriteAccess: true)
            }.value
            folder = directory
            stage = .publishing
            try await sendSavedPublication(to: directory)
            startUploadPolling()
        } catch SnapshotError.waitingForDownload {
            noticeKey = "Waiting for the saved cloud data to download. Retry shortly."
        } catch {
            if stage == .connection { folder = nil }
            fail(error, stage: stage, versionID: saved.version.id)
        }
        if let folder { await updateCloudTransfer(in: folder) }
    }

    private func sendSavedPublication(to directory: URL) async throws {
        guard let saved = publication else { return }
        progressKey = "Sending saved data to iCloud…"
        let outbox = outboxDirectory
        try await Task.detached(priority: .utility) {
            let archive = outbox.appendingPathComponent("\(saved.version.id).zip")
            if !FileManager.default.fileExists(atPath: archive.path) {
                // Migration of an older preview: recover its existing archive,
                // never generate a new version just to retry the status check.
                try FileManager.default.createDirectory(at: outbox, withIntermediateDirectories: true)
                try SnapshotDisk.download(saved.version, from: directory, to: archive)
            }
            try SnapshotDisk.publish(saved.version, from: archive, to: directory)
        }.value
        record.publication?.phase = .awaitingUpload
        record.issue = nil
        try SnapshotSyncStore.save(record, to: remarcAppSupportURL)
        if !versions.contains(where: { $0.id == saved.version.id }) { versions.insert(saved.version, at: 0) }
        try await confirmUpload(in: directory)
    }

    private func confirmUpload(in directory: URL) async throws {
        guard let saved = publication else { return }
        guard versions.contains(where: { $0.id == saved.version.id }) else {
            record.publication?.phase = .savedLocally
            return
        }
        let state: SnapshotDisk.UploadState
        do {
            state = try await Task.detached(priority: .utility) { try SnapshotDisk.uploadState(saved.version, in: directory) }.value
        } catch {
            guard publication?.version.id == saved.version.id else { return }
            if saved.isPending { record.publication?.phase = .unconfirmed }
            fail(error, stage: .uploadConfirmation, versionID: saved.version.id)
            return
        }
        guard publication?.version.id == saved.version.id else { return }
        switch state {
        case .uploaded:
            record.publication?.phase = .confirmed
            if record.publication?.confirmedAt == nil { record.publication?.confirmedAt = Date() }
            if issue?.stage == .uploadConfirmation || issue?.stage == .publishing { record.issue = nil }
            // A published baseline is recorded only after both cloud files are
            // confirmed. New edits made meanwhile remain dirty against it.
            if receipt?.version.id != saved.version.id {
                do {
                    try await PersistenceManager.shared.recordSnapshotReceipt(SnapshotReceipt(version: saved.version, contentHash: saved.version.contentHash))
                    receipt = PersistenceManager.shared.snapshotReceipt
                    await refreshLocalStatus(PersistenceManager.shared.appState)
                } catch { fail(error, stage: .receipt, versionID: saved.version.id); return }
            }
            if issue?.stage == .receipt { record.issue = nil }
        case .uploading:
            record.publication?.phase = .awaitingUpload
        case .unknown:
            record.publication?.phase = .unconfirmed
        }
        persist()
    }

    func apply(_ version: SnapshotVersion, isBackup: Bool = false) async {
        guard !isBusy, let source = isBackup ? backupDirectory : folder else { return }
        isBusy = true
        progressKey = "Downloading and verifying snapshot…"
        noticeKey = nil
        defer { isBusy = false; progressKey = nil }
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("remarc-apply-\(UUID()).zip")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let root = remarcAppSupportURL
        let backupsURL = backupDirectory
        let id = deviceID
        let name = deviceName
        let parent = currentVersion?.id
        do {
            let incoming = try await Task.detached(priority: .utility) {
                if !isBackup { _ = try SnapshotCloudLocation.connect() }
                try SnapshotDisk.download(version, from: source, to: temporary)
                return try SnapshotArchive.read(version, archive: temporary)
            }.value
            let before = try await PersistenceManager.shared.stateForSnapshot()
            await refreshLocalStatus(before)
            let previousContentTime = localUpdatedAt
            progressKey = "Backing up local data…"
            let installed = try await Task.detached(priority: .utility) {
                let local = try SnapshotArchive.prepare(before, root: root)
                _ = try SnapshotArchive.create(local, in: backupsURL, deviceID: id, deviceName: name + " (local backup)",
                    parentID: parent, contentModifiedAt: previousContentTime)
                return try SnapshotArchive.installFiles(incoming, root: root)
            }.value
            progressKey = "Applying snapshot…"
            try await PersistenceManager.shared.applySnapshot(installed, version: version, expected: before)
            receipt = PersistenceManager.shared.snapshotReceipt
            pollingTask?.cancel()
            record.publication = nil
            record.issue = nil
            record.contentStamp = SnapshotContentStamp(contentHash: incoming.hash, modifiedAt: version.contentModifiedAt)
            record.lastAppliedAt = receipt?.appliedAt
            localContentHash = incoming.hash
            localUpdatedAt = version.contentModifiedAt
            persist()
            await refreshLocalStatus(PersistenceManager.shared.appState)
            noticeKey = isBackup ? "Local backup restored." : "Applied data from \(version.deviceName)."
            await loadBackups()
        } catch SnapshotError.waitingForDownload {
            noticeKey = "Downloading cloud data. Apply again when it is ready; your local tasks are kept."
        } catch {
            fail(error, stage: .applying, versionID: version.id)
            await loadBackups()
        }
        if let folder { await updateCloudTransfer(in: folder) }
    }

    private func refreshLocalStatus(_ state: AppState) async {
        fingerprintGeneration += 1
        let generation = fingerprintGeneration
        let root = remarcAppSupportURL
        receipt = PersistenceManager.shared.snapshotReceipt
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

    private func loadBackups() async {
        let url = backupDirectory
        backups = (try? await Task.detached(priority: .utility) { try SnapshotDisk.versions(in: url) }.value) ?? []
    }

    private func fail(_ error: Error, stage: SnapshotSyncIssue.Stage, versionID: UUID? = nil) {
        record.issue = .make(error, stage: stage, versionID: versionID)
        debugLog("SnapshotSync: \(stage.rawValue); \(record.issue?.codes.joined(separator: ", ") ?? "unknown")")
        persist()
    }

    private func persist() {
        do { try SnapshotSyncStore.save(record, to: remarcAppSupportURL) }
        catch { record.issue = .make(error, stage: .localRecord, versionID: publication?.version.id) }
    }

    private func startUploadPolling() {
        pollingTask?.cancel()
        guard publication?.isPending == true, publication?.phase != .savedLocally else { return }
        pollingTask = Task { [weak self] in
            for _ in 0..<60 {
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
                guard let self, self.isEnabled, let folder = self.folder, self.publication?.isPending == true else { return }
                if self.isBusy || !self.reviewHolders.isEmpty { continue }
                if self.issue?.needsAuthorization == true || self.issue?.kind == .quota { return }
                self.isBusy = true
                do {
                    try await self.confirmUpload(in: folder)
                } catch { self.fail(error, stage: .uploadConfirmation, versionID: self.publication?.version.id) }
                await self.updateCloudTransfer(in: folder)
                self.isBusy = false
            }
        }
    }

    func openICloudSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preferences.AppleIDPrefPane?iCloud"), NSWorkspace.shared.open(url) { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
    }
}
