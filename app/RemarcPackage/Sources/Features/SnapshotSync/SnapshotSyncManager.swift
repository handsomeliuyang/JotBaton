import CoreLocalization
import CorePlatform
import FeatureComments
import AppKit
import Combine

@MainActor
package final class SnapshotSyncManager: ObservableObject {
    private let documents: any SnapshotDocumentStore
    @Published package private(set) var isEnabled: Bool
    @Published package private(set) var folder: URL?
    @Published package var deviceName: String {
        didSet { UserDefaults.standard.set(deviceName, forKey: "snapshotDeviceName") }
    }
    @Published package private(set) var cloudData: SnapshotVersion?
    @Published package private(set) var rollback: SnapshotVersion?
    @Published package private(set) var receipt: SnapshotReceipt?
    @Published package private(set) var hasLocalChanges = true
    @Published package private(set) var localUpdatedAt: Date?
    @Published package private(set) var lastCheckedAt: Date?
    @Published package private(set) var cloudTransfer = SnapshotCloudTransfer.unknown
    @Published package private(set) var isBusy = false
    @Published package private(set) var isChecking = false
    @Published private var progressKey: L10n.Key?
    @Published private var noticeKey: L10n.Key?
    @Published package private(set) var record: SnapshotSyncRecord
    @Published package private(set) var localCommentCount: Int?
    @Published package private(set) var localImageCount: Int?
    @Published package private(set) var localStatusReady = false
    package var progress: String? { progressKey.map { L10n.tr($0) } }
    package var notice: String? { noticeKey.map { L10n.tr($0) } }
    package var publication: SnapshotPublication? { record.publication }
    package var issue: SnapshotSyncIssue? { record.issue }
    private let deviceID: UUID
    private var subscription: AnyCancellable?
    private var pollingTask: Task<Void, Never>?
    private var scopedFolder: URL?
    private var reviewHolders = Set<UUID>()

    package var comparison: SnapshotComparison {
        SnapshotComparison.compare(localTime: localUpdatedAt, cloud: cloudData,
            baselineID: receipt?.version.id,
            baselineLocalTime: receipt?.localUpdatedAt ?? receipt?.version.contentModifiedAt,
            baselineCloudTime: receipt.map { $0.version.contentModifiedAt ?? $0.version.createdAt })
    }

    private var actions: SnapshotActionAvailability {
        SnapshotActionAvailability(enabled: isEnabled, busy: isBusy, connected: folder != nil,
            checked: lastCheckedAt != nil, localReady: localStatusReady,
            hasIssue: issue != nil, pending: publication?.isPending == true,
            transfer: cloudTransfer, comparison: comparison, hasCloud: cloudData != nil)
    }
    package var canPublish: Bool { actions.canPublish }
    package var canApply: Bool { actions.canApply }
    package var summary: String {
        if let progress { return progress }
        if !isEnabled { return L10n.tr("iCloud data is off") }
        if let issue { return L10n.lookup(issue.message) }
        if publication?.isPending == true { return L10n.tr("Waiting for iCloud upload confirmation") }
        if cloudTransfer.blocksReplacement { return cloudTransfer.title }
        if lastCheckedAt == nil { return L10n.tr("Check iCloud before choosing an action.") }
        if cloudTransfer == .unknown { return L10n.tr("iCloud transfer status is unconfirmed. Check again.") }
        if !localStatusReady { return L10n.tr("Local data could not be verified. Check again.") }
        if cloudData == nil { return L10n.tr("No cloud copy yet. Publish this Mac’s data to create one.") }
        switch comparison {
        case .same: return L10n.tr("This Mac and iCloud match. No action needed.")
        case .publish: return L10n.tr("This Mac has unpublished changes.")
        case .receive: return L10n.tr("iCloud has changes not yet applied to this Mac.")
        case .choose: return L10n.tr("This Mac and iCloud have different content.")
        }
    }
    package var isStatusConfirmed: Bool {
        isEnabled && (!isBusy || isChecking) && issue == nil && lastCheckedAt != nil && localStatusReady
            && publication?.isPending != true && !cloudTransfer.blocksReplacement && cloudTransfer != .unknown
    }
    package var guidance: SnapshotGuidance {
        SnapshotGuidance(comparison: comparison,
            hasBaseline: receipt != nil && (receipt?.localUpdatedAt ?? receipt?.version.contentModifiedAt) != nil)
    }
    package var statusSymbol: String {
        if !isEnabled { return "icloud.slash" }
        if issue != nil || cloudTransfer == .failed { return "exclamationmark.icloud" }
        guard isStatusConfirmed else { return "icloud" }
        switch comparison {
        case .same: return "checkmark.icloud"
        case .publish: return "icloud.and.arrow.up"
        case .receive: return "icloud.and.arrow.down"
        case .choose: return "exclamationmark.icloud"
        }
    }
    package var shortStatus: String {
        if !isEnabled { return L10n.tr("Off") }
        guard isStatusConfirmed else { return summary }
        switch comparison {
        case .same: return L10n.tr("Up to date")
        case .publish: return L10n.tr("Backup needed")
        case .receive: return L10n.tr("Cloud update available")
        case .choose: return guidance.title
        }
    }

    package init(documents: any SnapshotDocumentStore) {
        self.documents = documents
        let defaults = UserDefaults.standard
        isEnabled = defaults.bool(forKey: "snapshotICloudEnabled")
        deviceName = defaults.string(forKey: "snapshotDeviceName") ?? Host.current().localizedName ?? "This Mac"
        if let raw = defaults.string(forKey: "snapshotDeviceID"), let id = UUID(uuidString: raw) { deviceID = id }
        else { deviceID = UUID(); defaults.set(deviceID.uuidString, forKey: "snapshotDeviceID") }
        receipt = documents.snapshotReceipt
        rollback = documents.snapshotUndo
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
        subscription = documents.statePublisher
            .debounce(for: .milliseconds(500), scheduler: DispatchQueue.main)
            .sink { [weak self] state in Task { @MainActor [weak self] in await self?.refreshLocalStatus(state) } }
    }

    package func holdAutomaticChecks(_ active: Bool, token: UUID) {
        if active { reviewHolders.insert(token) } else { reviewHolders.remove(token) }
    }

    package func enable() async {
        guard !isBusy else { return }
        isEnabled = true
        UserDefaults.standard.set(true, forKey: "snapshotICloudEnabled")
        await check(createIfMissing: true)
    }

    package func authorizeAccess() async {
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

    package func disconnect() {
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
        noticeKey = nil
        UserDefaults.standard.removeObject(forKey: "snapshotICloudAccessBookmark")
        // Keep the durable pending snapshot and diagnostic for the next enable.
    }

    /// Only a hidden-to-visible transition of the main interface automatically checks iCloud.
    package func mainInterfaceDidShow(wasVisible: Bool) async {
        guard SnapshotRefreshPolicy.shouldCheckOnShow(wasVisible: wasVisible, enabled: isEnabled,
            busy: isBusy, reviewing: !reviewHolders.isEmpty) else { return }
        await check()
    }

    package func check(createIfMissing: Bool = false) async {
        guard isEnabled, !isBusy else { return }
        isBusy = true
        isChecking = true
        progressKey = "Checking iCloud…"
        defer { isChecking = false; isBusy = false; progressKey = nil }
        do {
            let directory = try await Task.detached(priority: .utility) {
                try SnapshotCloudLocation.connect(createIfMissing: createIfMissing)
            }.value
            folder = directory
            cloudData = try await Task.detached(priority: .utility) { try SnapshotDisk.current(in: directory) }.value
            await refreshLocalStatus(try await documents.stateForSnapshot())
            record.issue = nil
            try await advancePublication(in: directory)
            await updateCloudTransfer(in: directory)
            lastCheckedAt = Date()
            persist()
            startUploadPolling()
            let root = remarcAppSupportURL
            let undo = documents.snapshotUndo
            try await Task.detached(priority: .utility) { try SnapshotRollbackStore.cleanup(in: root, keeping: undo) }.value
        } catch SnapshotError.waitingForDownload {
            cloudTransfer = .waiting
            noticeKey = "Waiting for iCloud to download the current data. Your local tasks are kept."
        } catch { fail(error, stage: folder == nil ? .connection : .checking) }
    }

    /// Each click prepares the current live document. There is no local outbox.
    package func publish() async {
        guard canPublish else { return }
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
            let state = try await documents.stateForSnapshot()
            await refreshLocalStatus(state)
            let capturedTime = localUpdatedAt
            let root = remarcAppSupportURL
            let prepared = try await Task.detached(priority: .utility) { try SnapshotArchive.prepare(state, root: root) }.value
            if fresh != nil, comparison != .publish && comparison != .choose {
                noticeKey = nil
                return
            }
            let name = deviceName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { throw SnapshotError.message(L10n.tr("Enter a name for this Mac before publishing.")) }
            let id = deviceID
            let time = capturedTime
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
            cloudTransfer = .waiting
            noticeKey = "Waiting for iCloud to download the current data. Your local tasks are kept."
        } catch { fail(error, stage: .publishing, versionID: publication?.version.id) }
    }

    package func retry() async { await publish() }

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
            try await documents.recordSnapshotReceipt(SnapshotReceipt(version: version, contentHash: version.contentHash, localUpdatedAt: version.contentModifiedAt ?? version.createdAt))
            await refreshLocalStatus(documents.appState)
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

    /// Returns true once the cloud data is installed and an undo copy exists.
    @discardableResult
    package func apply(_ version: SnapshotVersion) async -> Bool {
        guard canApply, cloudData?.id == version.id, let source = folder else { return false }
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
            let before = try await documents.stateForSnapshot()
            await refreshLocalStatus(before)
            let local = try await Task.detached(priority: .utility) { try SnapshotArchive.prepare(before, root: root) }.value
            guard comparison == .receive || comparison == .choose else { return false }
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
                try await documents.applySnapshot(installed, version: version, expected: before, undo: undo, undoing: false)
            } catch {
                // The document still points to the previous undo copy on failure.
                let committed = documents.snapshotUndo
                try? await Task.detached(priority: .utility) { try SnapshotRollbackStore.cleanup(in: root, keeping: committed) }.value
                throw error
            }
            record.publication = nil
            record.issue = nil
            record.contentStamp = SnapshotContentStamp(contentHash: incoming.hash, modifiedAt: version.contentModifiedAt)
            record.lastAppliedAt = documents.snapshotReceipt?.appliedAt
            await refreshLocalStatus(documents.appState)
            persist()
            noticeKey = "Cloud data applied. You can undo this application once."
            try await Task.detached(priority: .utility) { try SnapshotRollbackStore.cleanup(in: root, keeping: undo) }.value
            return true
        } catch SnapshotError.waitingForDownload {
            cloudTransfer = .waiting
            noticeKey = "Waiting for iCloud to download the current data. Your local tasks are kept."
        } catch { fail(error, stage: .applying, versionID: version.id) }
        return false
    }

    @discardableResult
    package func undoLastApply() async -> Bool {
        guard !isBusy, let version = documents.snapshotUndo else { return false }
        isBusy = true
        progressKey = "Restoring data from before the last application…"
        noticeKey = nil
        defer { isBusy = false; progressKey = nil }
        let root = remarcAppSupportURL
        do {
            let incoming = try await Task.detached(priority: .utility) {
                try SnapshotArchive.read(version, archive: SnapshotRollbackStore.prepareDirectory(in: root).appendingPathComponent(version.archiveName))
            }.value
            let before = try await documents.stateForSnapshot()
            let installed = try await Task.detached(priority: .utility) { try SnapshotArchive.installFiles(incoming, root: root) }.value
            try await documents.applySnapshot(installed, version: version, expected: before, undo: nil, undoing: true)
            record.issue = nil
            record.contentStamp = SnapshotContentStamp(contentHash: incoming.hash, modifiedAt: Date())
            record.lastAppliedAt = nil
            await refreshLocalStatus(documents.appState)
            persist()
            noticeKey = "Last application undone on this Mac."
            try await Task.detached(priority: .utility) { try SnapshotRollbackStore.cleanup(in: root, keeping: nil) }.value
            return true
        } catch { fail(error, stage: .applying, versionID: version.id) }
        return false
    }

    private func updateCloudTransfer(in directory: URL) async {
        let version = publication?.isPending == true && publication?.currentCommitted == true ? publication?.version : cloudData
        do {
            cloudTransfer = try await Task.detached(priority: .utility) { try SnapshotDisk.transferState(in: directory, version: version) }.value
        } catch { cloudTransfer = .failed }
    }

    private func refreshLocalStatus(_ state: AppState) async {
        receipt = documents.snapshotReceipt
        rollback = documents.snapshotUndo
        // Older documents carry a saved content time. Adopt it once; checking never dates data as new.
        let legacyTime = documents.snapshotContentStamp?.modifiedAt ?? record.contentStamp?.modifiedAt
        let entityTime = state.comments.map(\.updatedAt).max()
        localUpdatedAt = state.snapshotDataUpdatedAt
            ?? [legacyTime, entityTime, receipt?.localUpdatedAt, receipt?.version.contentModifiedAt].compactMap { $0 }.max()
            ?? state.sessions.map(\.createdAt).max() ?? .distantPast
        localCommentCount = state.comments.filter { !$0.isDeleted }.count
        var images = Set<String>()
        for comment in state.comments {
            if let path = comment.type.imagePath { images.insert(path) }
            images.formUnion(comment.attachments)
        }
        images.formUnion(state.orphanedImages.map(\.path))
        localImageCount = images.count
        localStatusReady = true
        hasLocalChanges = localUpdatedAt != (receipt?.localUpdatedAt ?? receipt?.version.contentModifiedAt)
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

    package func openICloudSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preferences.AppleIDPrefPane?iCloud"), NSWorkspace.shared.open(url) { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
    }
}
