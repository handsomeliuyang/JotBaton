import CorePlatform
import FeatureComments
import FeatureSettings
import Foundation
import Combine
import AppKit

@MainActor
public final class CommentStore: ObservableObject {
    let onCommentChange: (CommentChange, Comment) -> Void
    let onExternalChanges: ([Comment], [Comment], [Session], [Session]) -> Void

    @Published public internal(set) var appState: AppState

    let fileURL: URL
    /// The document as we last read or wrote it. Baseline for the three-way
    /// merge that keeps other processes' commits from being overwritten.
    var lastPersisted: AppState
    /// Serializes background writes off the main actor (see DocumentWriter).
    let documentWriter = DocumentWriter()
    let sessionTaskWriter = SessionTaskWriter()
    @Published public internal(set) var taskCompletionInFlight = false
    var backgroundSaveInFlight = false
    /// A mutation arrived while a save was in flight; that save's snapshot is
    /// stale, so another must follow it.
    var backgroundSaveRequested = false
    var snapshotGeneration = 0
    var saveCancellable: AnyCancellable?
    let saveSubject = PassthroughSubject<Void, Never>()
    var resolvedDeletionTimer: Timer?
    var resolvedDeletionCancellable: AnyCancellable?
    var inactiveSessionTimer: Timer?
    var inactiveSessionCancellable: AnyCancellable?
    var completionUndoDeadlines: [UUID: Date] = [:]

    // MARK: - Document write serialization
    //
    // `saveToDisk` is synchronous and runs entirely on the main actor, so no two
    // ordinary saves can interleave. A durable write cannot be synchronous - it
    // waits on a cross-process lock that polls with `Thread.sleep` - so it awaits
    // an off-main helper, and that await yields the main actor. Without a gate, a
    // debounced save or a reload adoption could land inside that window and
    // publish state computed from a snapshot older than the durable write's, both
    // clobbering the newer value and regressing `lastPersisted`.
    //
    // The gate is deliberately one flag plus deferrals rather than a general
    // operation queue. Routing the existing synchronous entry points through a
    // queue would make them async, which in turn would force `saveImmediately()`
    // to defer termination via `applicationShouldTerminate` - machinery Remarc
    // does not have today. Leaving them synchronous keeps quit exactly as durable
    // as it already is.

    /// True while a durable write owns the document. Ordinary saves and reloads
    /// arriving in this window record themselves and run once it clears.
    var documentWriteInFlight = false
    var deferredSaveRequested = false
    var deferredReloadRequested = false
    var documentSlotWaiters: [CheckedContinuation<Void, Never>] = []

    /// Sessions a durable write is currently staging a comment into. Deleting one
    /// mid-transaction would re-apply after validation had already passed,
    /// reproducing the invisible-comment state validation exists to prevent.
    var pinnedSessionIDs: Set<UUID> = []
    var deferredSessionDeletions: [UUID] = []

    init(onCommentChange: @escaping (CommentChange, Comment) -> Void,
         onExternalChanges: @escaping ([Comment], [Comment], [Session], [Session]) -> Void) {
        self.onCommentChange = onCommentChange
        self.onExternalChanges = onExternalChanges
        let remarcDir = remarcAppSupportURL

        if !FileManager.default.fileExists(atPath: remarcDir.path) {
            try? FileManager.default.createDirectory(at: remarcDir, withIntermediateDirectories: true)
        }

        // Create images subdirectory for future screenshot support
        let imagesDir = remarcDir.appendingPathComponent("images", isDirectory: true)
        if !FileManager.default.fileExists(atPath: imagesDir.path) {
            try? FileManager.default.createDirectory(at: imagesDir, withIntermediateDirectories: true)
        }

        // Migrate data.json → comments.json if needed
        let oldFileURL = remarcDir.appendingPathComponent("data.json")
        let newFileURL = remarcDir.appendingPathComponent("comments.json")
        if FileManager.default.fileExists(atPath: oldFileURL.path)
            && !FileManager.default.fileExists(atPath: newFileURL.path) {
            try? FileManager.default.moveItem(at: oldFileURL, to: newFileURL)
            debugLog("CommentStore: Migrated data.json → comments.json")
        }

        self.fileURL = newFileURL

        // Load or create default state
        if let data = try? Data(contentsOf: fileURL),
           let state = try? JSONDecoder().decode(AppState.self, from: data) {
            self.appState = state
            self.lastPersisted = state
            debugLog("CommentStore: Loaded \(state.comments.count) comments, \(state.sessions.count) sessions")
        } else {
            self.appState = AppState.defaultState()
            self.lastPersisted = AppState.defaultState()
            debugLog("CommentStore: Created default state")
        }

        // Migrate first session to Inbox if needed
        if let firstIndex = appState.sessions.firstIndex(where: { !$0.isDeleted }) {
            if appState.sessions[firstIndex].name != CommentConstants.inboxSessionName {
                appState.sessions[firstIndex].name = CommentConstants.inboxSessionName
            }
        }

        // Ensure Inbox session always exists (fresh install or all sessions deleted)
        if !appState.sessions.contains(where: { !$0.isDeleted && $0.isInbox }) {
            let inbox = Session(name: CommentConstants.inboxSessionName)
            appState.sessions.append(inbox)
            if appState.activeSessionID == nil {
                appState.activeSessionID = inbox.id
            }
            debugLog("CommentStore: Created Inbox session")
        }

        // Debounced auto-save (250ms)
        saveCancellable = saveSubject
            .debounce(for: .milliseconds(250), scheduler: DispatchQueue.main)
            .sink { [weak self] in
                self?.saveToDisk()
            }

        let loaded = appState
        if EmptySessionCleanupPolicy.reconcile(&appState, previous: loaded, now: Date()) {
            scheduleSave()
        }

        // Prune expired history on launch
        pruneExpiredHistory()

        // Listen for external reload requests (from MCP server)
        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name(AppIdentity.current.reloadNotification),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.reloadFromDisk()
        }

        // Auto-delete resolved comments on launch (catches expired while app was closed)
        autoDeleteResolvedComments()

        // Observe setting changes to start/stop the resolved deletion timer
        resolvedDeletionCancellable = SettingsManager.shared.$resolvedCommentDeletion
            .sink { [weak self] setting in
                self?.updateResolvedDeletionTimer(for: setting)
            }

        inactiveSessionCancellable = Publishers.CombineLatest(
            SettingsManager.shared.$inactiveSessionCleanupEnabled,
            SettingsManager.shared.$inactiveSessionCleanupInterval
        )
        .receive(on: RunLoop.main)
        .sink { [weak self] _, _ in self?.updateInactiveSessionTimer() }

        cleanupStaleClaudeCodeMarkers()

        reconcilePreparedCaptureLeases()

        // Ensure the data file exists on disk (bootstraps comments.json on fresh installs
        // so the CLI/hooks can read it immediately)
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            saveToDisk()
        }
    }

}
