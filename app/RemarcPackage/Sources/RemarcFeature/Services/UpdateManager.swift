import AppKit
import Combine
import Foundation

/// Personal production updates are distributed through this account's ordinary
/// iCloud Drive folder. Data snapshot synchronization need not be enabled.
@MainActor
public final class UpdateManager: NSObject, ObservableObject {
    public static let shared = UpdateManager()
    @Published public private(set) var canCheckForUpdates = false
    @Published public private(set) var status = ""
    @Published public private(set) var availableVersion: String?
    @Published public private(set) var isInstalling = false
    @Published public private(set) var waitingForDownload = false
    private var scopedFolder: URL?
    private var timer: Timer?
    private var candidate: Candidate?
    private var checking = false
    private var lastCheck = Date.distantPast
    private var promptedBuild: Int?
    private var downloadGeneration = 0
    private let defaults = UserDefaults.standard

    private struct Candidate: Sendable {
        let manifest: CloudUpdateManifest
        let package: CloudUpdateManifest.Package
        let envelope: Data
        let directory: URL
    }

    private override init() {
        super.init()
        guard !AppIdentity.current.isDevelopment,
              Bundle.main.object(forInfoDictionaryKey: "RemarcCloudUpdates") as? Bool == true else { return }
        if let bookmark = defaults.data(forKey: "cloudUpdateICloudAccessBookmark") {
            do {
                var stale = false
                let url = try URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI], bookmarkDataIsStale: &stale)
                if SnapshotCloudLocation.isAuthorizationLocation(url, channel: .production) {
                    if url.startAccessingSecurityScopedResource() { scopedFolder = url }
                    if stale { defaults.set(try url.bookmarkData(options: .withSecurityScope), forKey: "cloudUpdateICloudAccessBookmark") }
                }
            } catch { /* A manual authorization action remains available in About. */ }
        }
        canCheckForUpdates = true
        status = L10n.tr("Updates are checked in iCloud Drive/Remarc/Updates.")
        NotificationCenter.default.addObserver(self, selector: #selector(becameActive), name: NSApplication.didBecomeActiveNotification, object: nil)
        timer = Timer.scheduledTimer(timeInterval: 60, target: self, selector: #selector(tick), userInfo: nil, repeats: true)
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            self?.check(manual: false)
        }
    }

    @objc private func becameActive() {
        check(manual: false)
        if let candidate { offer(candidate, manual: false) }
    }
    @objc private func tick() {
        if waitingForDownload { check(manual: false) }
        else if Date().timeIntervalSince(lastCheck) >= 600 { check(manual: false) }
    }
    public func checkForUpdates() { check(manual: true) }
    public func authorizeICloudAccess() async {
        guard canCheckForUpdates, !isInstalling else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = SnapshotCloudLocation.driveRoot
        panel.message = L10n.tr("Allow access to iCloud Drive or its Remarc folder to check for application updates.")
        panel.prompt = L10n.tr("Allow Access")
        guard await panel.begin() == .OK, let url = panel.url else { return }
        guard SnapshotCloudLocation.isAuthorizationLocation(url, channel: .production) else {
            showError(L10n.tr("Choose iCloud Drive or its Remarc folder.")); return
        }
        do {
            let bookmark = try url.bookmarkData(options: .withSecurityScope)
            if let scopedFolder { scopedFolder.stopAccessingSecurityScopedResource() }
            scopedFolder = url.startAccessingSecurityScopedResource() ? url : nil
            defaults.set(bookmark, forKey: "cloudUpdateICloudAccessBookmark")
            check(manual: true)
        } catch { showError(error.localizedDescription) }
    }

    public func cancelDownload() {
        downloadGeneration += 1
        waitingForDownload = false
        status = L10n.tr("Update download cancelled.")
    }

    private func check(manual: Bool) {
        guard canCheckForUpdates, !checking, !isInstalling else { return }
        guard manual || Date().timeIntervalSince(lastCheck) >= 60 else { return }
        checking = true
        lastCheck = Date()
        status = L10n.tr("Checking iCloud for updates…")
        Task {
            defer { checking = false }
            do {
                let result = try await Task.detached(priority: .utility) {
                    let root = try SnapshotCloudLocation.connect(channel: .production)
                    let directory = root.appendingPathComponent("Updates", isDirectory: true)
                    guard directory.resolvingSymlinksInPath() == directory.standardizedFileURL else { throw CloudUpdateError.invalidManifest }
                    let file = directory.appendingPathComponent("latest.json")
                    try CloudUpdateTrust.ensureDownloaded(file)
                    let bytes = try SnapshotDisk.coordinate(file, writing: false) { url -> Data in
                        let handle = try FileHandle(forReadingFrom: url)
                        defer { try? handle.close() }
                        let data = try handle.read(upToCount: 256_001) ?? Data()
                        guard data.count <= 256_000 else { throw CloudUpdateError.invalidManifest }
                        return data
                    }
                    let envelope = try JSONDecoder().decode(CloudUpdateEnvelope.self, from: bytes)
                    let manifest = try envelope.verified(fingerprint: CloudUpdateTrust.productionFingerprint)
                    let package = try manifest.package(for: CloudUpdateTrust.architecture(), os: ProcessInfo.processInfo.operatingSystemVersion)
                    return Candidate(manifest: manifest, package: package, envelope: bytes, directory: directory)
                }.value
                let installed = Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "") ?? 0
                guard result.manifest.build > installed else {
                    candidate = nil
                    availableVersion = nil
                    waitingForDownload = false
                    status = L10n.tr("Remarc is up to date.")
                    return
                }
                if waitingForDownload, candidate?.manifest.build != result.manifest.build {
                    cancelDownload() // A different release needs a new installation confirmation.
                }
                candidate = result
                availableVersion = result.manifest.version
                status = L10n.tr("Update \(result.manifest.version) is available.")
                if waitingForDownload { installUpdate() }
                else { offer(result, manual: manual) }
            } catch CloudUpdateError.waitingForDownload {
                status = L10n.tr("Waiting for iCloud to download the update…")
                lastCheck = .distantPast
            } catch {
                status = L10n.tr("Could not check for updates: \(L10n.lookup(error.localizedDescription))")
                if manual { showError(status) }
            }
        }
    }

    private func offer(_ candidate: Candidate, manual: Bool) {
        guard !isInstalling, !waitingForDownload else { return }
        if !manual {
            guard NSApp.isActive, promptedBuild != candidate.manifest.build,
                  defaults.integer(forKey: "cloudUpdateSkippedBuild") != candidate.manifest.build,
                  (defaults.object(forKey: "cloudUpdateDeferredUntil") as? Date ?? .distantPast) < Date() else { return }
        }
        promptedBuild = candidate.manifest.build
        let alert = NSAlert()
        alert.messageText = L10n.tr("Update \(candidate.manifest.version) is available.")
        alert.informativeText = L10n.tr("Install the verified update from iCloud? Remarc will restart. Your data is kept and the previous app is backed up.")
        alert.addButton(withTitle: L10n.tr("Install Update"))
        alert.addButton(withTitle: L10n.tr("Later"))
        alert.addButton(withTitle: L10n.tr("Skip This Version"))
        switch alert.runModal() {
        case .alertFirstButtonReturn: installUpdate()
        case .alertThirdButtonReturn: defaults.set(candidate.manifest.build, forKey: "cloudUpdateSkippedBuild")
        default:
            defaults.set(Date().addingTimeInterval(4 * 3600), forKey: "cloudUpdateDeferredUntil")
            promptedBuild = nil
        }
    }

    public func installUpdate() {
        guard let candidate, !isInstalling else { return }
        guard Bundle.main.bundleURL.standardizedFileURL.path == "/Applications/Remarc.app" else {
            showError(L10n.tr("Install Remarc in /Applications before updating.")); return
        }
        isInstalling = true
        waitingForDownload = false
        let generation = downloadGeneration
        status = L10n.tr("Preparing verified update…")
        Task {
            defer { isInstalling = false }
            var stage: URL?
            do {
                let prepared = try await Task.detached(priority: .utility) {
                    let fm = FileManager.default
                    let directory = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/com.metepolat.Remarc/Updates", isDirectory: true)
                        .appendingPathComponent(UUID().uuidString, isDirectory: true)
                    try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                    do {
                        let source = candidate.directory.appendingPathComponent(candidate.package.filename)
                        try CloudUpdateTrust.ensureDownloaded(source)
                        let archive = directory.appendingPathComponent(candidate.package.filename)
                        try SnapshotDisk.coordinate(source, writing: false) { try fm.copyItem(at: $0, to: archive) }
                        try CloudUpdateTrust.verifyArchive(archive, package: candidate.package)
                        try candidate.envelope.write(to: directory.appendingPathComponent("latest.json"), options: .atomic)
                        let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/RemarcUpdateInstaller")
                        try CloudUpdateTrust.verifyCode(bundled, identifier: "RemarcUpdateInstaller")
                        let helper = directory.appendingPathComponent("RemarcUpdateInstaller")
                        try fm.copyItem(at: bundled, to: helper)
                        try CloudUpdateTrust.verifyCode(helper, identifier: "RemarcUpdateInstaller")
                        return directory
                    } catch { try? fm.removeItem(at: directory); throw error }
                }.value
                stage = prepared
                guard generation == downloadGeneration else { try? FileManager.default.removeItem(at: prepared); return }
                let process = Process()
                process.executableURL = prepared.appendingPathComponent("RemarcUpdateInstaller")
                process.arguments = [prepared.path, String(ProcessInfo.processInfo.processIdentifier)]
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                let previousError = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Remarc Updates/error.txt")
                try? FileManager.default.removeItem(at: previousError)
                try process.run()
                // The helper owns the staged files after launch, even if preparation takes a while.
                stage = nil
                let deadline = Date().addingTimeInterval(180)
                while process.isRunning && Date() < deadline {
                    if FileManager.default.fileExists(atPath: prepared.appendingPathComponent("ready").path) {
                        guard !SnapshotSyncManager.shared.isBusy, PersistenceManager.shared.prepareForUpdate() else {
                            process.terminate()
                            throw CloudUpdateError.operation(L10n.tr("Finish the current data operation and save your changes before updating. The update was cancelled."))
                        }
                        NSApp.terminate(nil)
                        return
                    }
                    try await Task.sleep(for: .milliseconds(250))
                }
                if process.isRunning { process.terminate() }
                let report = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Remarc Updates/error.txt")
                let detail = (try? String(contentsOf: report, encoding: .utf8)) ?? L10n.tr("The update installer could not prepare the installation.")
                throw CloudUpdateError.operation(detail)
            } catch CloudUpdateError.waitingForDownload {
                if generation == downloadGeneration { waitingForDownload = true }
                status = L10n.tr("Waiting for iCloud to download the update…")
            } catch {
                status = L10n.tr("Update was not installed: \(L10n.lookup(error.localizedDescription))")
                showError(status)
            }
            if let stage { try? FileManager.default.removeItem(at: stage) }
        }
    }
    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = L10n.tr("Remarc Update")
        alert.informativeText = L10n.lookup(message)
        alert.runModal()
    }
}
