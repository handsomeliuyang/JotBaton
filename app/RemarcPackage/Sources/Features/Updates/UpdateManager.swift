import CoreLocalization
import CorePlatform
import AppKit
import Combine
import Foundation
import Sparkle

/// GitHub owns release discovery; Sparkle owns verified download, replacement and relaunch.
@MainActor
public final class UpdateManager: NSObject, ObservableObject {
    public static let shared = UpdateManager()
    @Published public private(set) var canCheckForUpdates = false
    @Published public private(set) var status = ""
    @Published public private(set) var availableVersion: String?
    @Published public private(set) var isChecking = false
    @Published public private(set) var isUpdating = false
    @Published public private(set) var progress: Double?
    @Published public private(set) var canCancelUpdate = false
    @Published public private(set) var canResumeUpdate = false
    public private(set) var requiresSafeTermination = false

    private var candidate: GitHubRelease.Candidate?
    private var installingCandidate: GitHubRelease.Candidate?
    private var lastCheck = Date.distantPast
    private var promptedVersion: String?
    private var timer: Timer?
    private var updater: SPUUpdater?
    private var cancelAction: (() -> Void)?
    private var readyReply: ((SPUUserUpdateChoice) -> Void)?
    private var retryTermination: (() -> Void)?
    private var preparationTask: Task<Void, Never>?
    private var installationID = UUID()
    private var installationPrepared = false
    private var expectedLength: UInt64 = 0
    private var receivedLength: UInt64 = 0
    private var prepareForRestart: (() -> String?)?
    private var makeBackup: @Sendable () async throws -> Void = {
        _ = try await Task.detached(priority: .userInitiated) {
            try UpdateBackup.create(app: Bundle.main.bundleURL,
                                    home: FileManager.default.homeDirectoryForCurrentUser,
                                    identity: AppIdentity.current)
        }.value
    }
    private var testingMessage: ((String) -> Void)?
    private let defaults = UserDefaults.standard
    private lazy var progressWindow = UpdateProgressWindow(manager: self)
    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 45
        return URLSession(configuration: configuration)
    }()

    private override init() {
        super.init()
        guard !AppIdentity.current.isDevelopment,
              Bundle.main.bundleIdentifier == AppIdentity.production.bundleIdentifier,
              Bundle.main.object(forInfoDictionaryKey: "RemarcGitHubUpdates") as? Bool == true else { return }
        canCheckForUpdates = true
        status = L10n.tr("Updates are checked on GitHub Releases.")
        for key in ["cloudUpdateICloudAccessBookmark", "cloudUpdateSkippedBuild", "cloudUpdateDeferredUntil"] {
            defaults.removeObject(forKey: key)
        }
        NotificationCenter.default.addObserver(self, selector: #selector(becameActive), name: NSApplication.didBecomeActiveNotification, object: nil)
        timer = Timer.scheduledTimer(timeInterval: 3600, target: self, selector: #selector(becameActive), userInfo: nil, repeats: true)
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            self?.check(manual: false)
        }
    }

    /// Exercise the installation handshake without a live updater, app, network or user data.
    package init(testing candidate: GitHubRelease.Candidate, prepareForRestart: @escaping () -> String?,
                 makeBackup: @escaping @Sendable () async throws -> Void, reportMessage: @escaping (String) -> Void) {
        self.candidate = candidate
        self.installingCandidate = candidate
        self.prepareForRestart = prepareForRestart
        self.makeBackup = makeBackup
        self.testingMessage = reportMessage
        super.init()
        isUpdating = true
    }

    /// The application supplies its editor/recording/save gates without reversing feature dependencies.
    public func configure(prepareForRestart: @escaping () -> String?) {
        self.prepareForRestart = prepareForRestart
    }

    @objc private func becameActive() {
        guard !isUpdating else { return }
        if let candidate, !isChecking { offer(candidate, manual: false) }
        check(manual: false)
    }

    public func checkForUpdates() {
        if isUpdating { presentProgress(); return }
        check(manual: true)
    }

    public func installUpdate() {
        guard canCheckForUpdates, !isChecking, !isUpdating, let candidate else { return }
        guard let prepareForRestart else { return }
        if let reason = prepareForRestart() { showMessage(reason); return }
        installingCandidate = candidate
        isUpdating = true
        setProgress(L10n.tr("Preparing update…"))
        presentProgress()
        do {
            if updater == nil {
                let instance = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: self, delegate: self)
                try instance.start()
                updater = instance
            }
            updater?.checkForUpdates()
        } catch {
            failUpdate(error.localizedDescription)
        }
    }

    public func cancelUpdate() {
        guard canCancelUpdate else { return }
        let cancel = cancelAction
        let reply = readyReply
        cancelAction = nil
        readyReply = nil
        preparationTask?.cancel()
        preparationTask = nil
        // Skip at the ready stage cancels installation, including installation on quit.
        if let reply { reply(.skip) } else { cancel?() }
        finishSession()
        status = L10n.tr("Update canceled. Your current version is unchanged.")
    }

    public func resumeUpdate() {
        guard canResumeUpdate else { return }
        if let retryTermination {
            guard validateTermination() else { return }
            canResumeUpdate = false
            setProgress(L10n.tr("Installing update and restarting…"))
            retryTermination()
        } else if readyReply != nil {
            prepareInstallation()
        }
    }

    /// Also checked at the actual quit event: editing may have resumed during a download or backup.
    public func validateTermination() -> Bool {
        guard requiresSafeTermination else { return true }
        if let reason = prepareForRestart?() {
            canResumeUpdate = true
            setProgress(reason)
            presentProgress()
            return false
        }
        guard installationPrepared else {
            canResumeUpdate = preparationTask == nil && readyReply != nil
            setProgress(L10n.tr("The update is preparing. Wait for completion or cancel the update before quitting."))
            presentProgress()
            return false
        }
        return prepareForRestart != nil
    }

    private func check(manual: Bool) {
        guard canCheckForUpdates, !isChecking, !isUpdating else { return }
        guard manual || Date().timeIntervalSince(lastCheck) >= 6 * 3600 else { return }
        isChecking = true
        lastCheck = Date()
        status = L10n.tr("Checking GitHub for updates…")
        Task {
            defer { isChecking = false }
            do {
                var request = URLRequest(url: GitHubRelease.latestURL)
                request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
                request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
                request.setValue("JotBaton", forHTTPHeaderField: "User-Agent")
                let (data, response) = try await session.data(for: request)
                let release = try GitHubRelease.decode(data, response: response)
                #if arch(arm64)
                let architecture = "arm64"
                #else
                let architecture = "x86_64"
                #endif
                let result = try release.update(
                    installedVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
                    architecture: architecture,
                    os: ProcessInfo.processInfo.operatingSystemVersion
                )
                candidate = result
                availableVersion = result?.version
                guard let result else {
                    status = L10n.tr("JotBaton is up to date.")
                    if manual { showMessage(status) }
                    return
                }
                status = L10n.tr("Update \(result.version) is available.")
                // End the check before the modal offer can start an installation.
                isChecking = false
                offer(result, manual: manual)
            } catch {
                candidate = nil
                availableVersion = nil
                status = L10n.tr("Could not check for updates: \(L10n.lookup(error.localizedDescription))")
                if manual { showMessage(status) }
            }
        }
    }

    private func offer(_ candidate: GitHubRelease.Candidate, manual: Bool) {
        if !manual {
            guard NSApp.isActive, promptedVersion != candidate.version,
                  defaults.string(forKey: "githubUpdateSkippedVersion") != candidate.version,
                  (defaults.object(forKey: "githubUpdateDeferredUntil") as? Date ?? .distantPast) < Date() else { return }
        }
        promptedVersion = candidate.version
        let alert = NSAlert()
        alert.messageText = L10n.tr("Update \(candidate.version) is available.")
        alert.informativeText = L10n.tr("Download and verify the update, then automatically restart JotBaton. Your comments and settings are kept.")
        if !candidate.releaseNotes.isEmpty {
            let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 380, height: 160))
            scroll.hasVerticalScroller = true
            let text = NSTextView(frame: scroll.bounds)
            text.isEditable = false
            text.font = .systemFont(ofSize: 12)
            text.string = candidate.releaseNotes
            text.autoresizingMask = [.width]
            scroll.documentView = text
            alert.accessoryView = scroll
        }
        alert.addButton(withTitle: L10n.tr("Upgrade and Restart"))
        alert.addButton(withTitle: L10n.tr("Later"))
        alert.addButton(withTitle: L10n.tr("Skip This Version"))
        switch alert.runModal() {
        case .alertFirstButtonReturn: installUpdate()
        case .alertThirdButtonReturn: defaults.set(candidate.version, forKey: "githubUpdateSkippedVersion")
        default:
            defaults.set(Date().addingTimeInterval(4 * 3600), forKey: "githubUpdateDeferredUntil")
            promptedVersion = nil
        }
    }

    private func prepareInstallation() {
        guard preparationTask == nil, readyReply != nil, let prepareForRestart else { return }
        if let reason = prepareForRestart() {
            canResumeUpdate = true
            setProgress(reason)
            return
        }
        canResumeUpdate = false
        setProgress(L10n.tr("Backing up the current app and data…"))
        let id = installationID
        preparationTask = Task {
            do {
                try await makeBackup()
                try Task.checkCancellation()
                guard installationID == id else { return }
                preparationTask = nil
                guard readyReply != nil else { return }
                if let reason = prepareForRestart() {
                    canResumeUpdate = true
                    setProgress(reason)
                    return
                }
                let reply = readyReply
                readyReply = nil
                cancelAction = nil
                canCancelUpdate = false
                installationPrepared = true
                requiresSafeTermination = true
                setProgress(L10n.tr("Installing update and restarting…"))
                reply?(.install)
            } catch is CancellationError {
                // Cancel already replied to Sparkle; the completed backup can remain for recovery.
            } catch {
                guard !Task.isCancelled, installationID == id else { return }
                preparationTask = nil
                let reply = readyReply
                readyReply = nil
                reply?(.skip)
                failUpdate(L10n.tr("Could not back up the current app and data. The update was canceled.") + "\n" + error.localizedDescription)
            }
        }
    }

    private func setProgress(_ message: String, fraction: Double? = nil) {
        status = message
        progress = fraction
    }

    private func finishSession() {
        installationID = UUID()
        preparationTask?.cancel()
        preparationTask = nil
        isUpdating = false
        canCancelUpdate = false
        canResumeUpdate = false
        progress = nil
        cancelAction = nil
        readyReply = nil
        retryTermination = nil
        installingCandidate = nil
        requiresSafeTermination = false
        installationPrepared = false
        if testingMessage == nil { progressWindow.close() }
    }

    private func failUpdate(_ message: String) {
        finishSession()
        status = L10n.tr("Could not install the update: \(L10n.lookup(message))")
        showMessage(status)
    }

    private func showMessage(_ message: String) {
        if let testingMessage { testingMessage(message); return }
        let alert = NSAlert()
        alert.messageText = L10n.tr("JotBaton Update")
        alert.informativeText = message
        alert.runModal()
    }

    private func presentProgress() {
        if testingMessage == nil { progressWindow.present() }
    }
}

extension UpdateManager: SPUUpdaterDelegate {
    public func feedURLString(for updater: SPUUpdater) -> String? {
        // Old Sparkle installations may have persisted an upstream feed in defaults.
        // Always use this signed app's architecture-specific GitHub feed instead.
        Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String
    }

    public func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        guard isUpdating, installingCandidate != nil else {
            throw NSError(domain: "Remarc.Update", code: 2, userInfo: [NSLocalizedDescriptionKey: L10n.tr("Choose Upgrade and Restart to install an update.")])
        }
    }
    public func updater(_ updater: SPUUpdater, shouldProceedWithUpdate updateItem: SUAppcastItem, updateCheck: SPUUpdateCheck) throws {
        guard let expected = installingCandidate,
              updateItem.displayVersionString == expected.version,
              updateItem.fileURL == expected.downloadURL,
              !updateItem.isInformationOnlyUpdate else {
            throw NSError(domain: "Remarc.Update", code: 1, userInfo: [NSLocalizedDescriptionKey:
                L10n.tr("The release changed or has no matching signed update. Check for updates again.")])
        }
    }
}

extension UpdateManager: SPUUserDriver {
    public func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: false, sendSystemProfile: false))
    }

    public func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        cancelAction = cancellation
        canCancelUpdate = true
        setProgress(L10n.tr("Verifying update information…"))
    }

    public func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        guard isUpdating, let expected = installingCandidate,
              appcastItem.displayVersionString == expected.version,
              appcastItem.fileURL == expected.downloadURL,
              !appcastItem.isInformationOnlyUpdate else { reply(.dismiss); return }
        reply(.install) // The user already consented via Upgrade and Restart.
    }

    public func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}
    public func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {}

    public func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) {
        failUpdate(L10n.tr("The release changed or has no matching signed update. Check for updates again."))
        acknowledgement()
    }

    public func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
        failUpdate(error.localizedDescription)
        acknowledgement()
    }

    public func showDownloadInitiated(cancellation: @escaping () -> Void) {
        cancelAction = cancellation
        canCancelUpdate = true
        expectedLength = 0
        receivedLength = 0
        setProgress(L10n.tr("Downloading update…"))
    }

    public func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        expectedLength = expectedContentLength
    }

    public func showDownloadDidReceiveData(ofLength length: UInt64) {
        let sum = receivedLength.addingReportingOverflow(length)
        receivedLength = sum.overflow ? .max : sum.partialValue
        let fraction = expectedLength > 0 ? min(1, Double(receivedLength) / Double(expectedLength)) : nil
        setProgress(L10n.tr("Downloading update…"), fraction: fraction)
    }

    public func showDownloadDidStartExtractingUpdate() {
        cancelAction = nil
        canCancelUpdate = false
        setProgress(L10n.tr("Verifying and extracting update…"))
    }

    public func showExtractionReceivedProgress(_ progress: Double) {
        setProgress(L10n.tr("Verifying and extracting update…"), fraction: min(1, max(0, progress)))
    }

    public func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        requiresSafeTermination = true
        readyReply = reply
        canCancelUpdate = true
        prepareInstallation()
    }

    public func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) {
        retryTermination = applicationTerminated ? nil : retryTerminatingApplication
        if !canResumeUpdate { setProgress(L10n.tr("Installing update and restarting…")) }
    }

    public func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        finishSession()
        acknowledgement()
    }

    public func dismissUpdateInstallation() { finishSession() }
    public func showUpdateInFocus() { presentProgress() }
}
