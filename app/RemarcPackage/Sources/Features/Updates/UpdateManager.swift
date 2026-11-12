import CoreLocalization
import CorePlatform
import AppKit
import Combine
import Foundation

/// Production releases are built on GitHub; installation is a user action in the browser.
@MainActor
public final class UpdateManager: NSObject, ObservableObject {
    public static let shared = UpdateManager()
    @Published public private(set) var canCheckForUpdates = false
    @Published public private(set) var status = ""
    @Published public private(set) var availableVersion: String?
    @Published public private(set) var isChecking = false
    private var candidate: GitHubRelease.Candidate?
    private var lastCheck = Date.distantPast
    private var promptedVersion: String?
    private var timer: Timer?
    private let defaults = UserDefaults.standard
    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 45
        return URLSession(configuration: configuration)
    }()

    private override init() {
        super.init()
        guard !AppIdentity.current.isDevelopment,
              Bundle.main.object(forInfoDictionaryKey: "RemarcGitHubUpdates") as? Bool == true else { return }
        canCheckForUpdates = true
        status = L10n.tr("Updates are checked on GitHub Releases.")
        // Retire only the old application-update authorization, never snapshot settings/data.
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

    @objc private func becameActive() {
        if let candidate, !isChecking { offer(candidate, manual: false) }
        check(manual: false)
    }
    public func checkForUpdates() { check(manual: true) }

    public func openDownload() {
        guard let candidate else { return }
        if !NSWorkspace.shared.open(candidate.downloadURL) {
            showMessage(L10n.tr("Could not open the GitHub download link."))
        }
    }

    private func check(manual: Bool) {
        guard canCheckForUpdates, !isChecking else { return }
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
                request.setValue("Remarc", forHTTPHeaderField: "User-Agent")
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
                    status = L10n.tr("Remarc is up to date.")
                    if manual { showMessage(status) }
                    return
                }
                status = L10n.tr("Update \(result.version) is available.")
                offer(result, manual: manual)
            } catch {
                // Never leave an old download button looking like a successful fresh check.
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
        alert.informativeText = L10n.tr("Download the installer from GitHub, quit Remarc, then replace the app in Applications. Your existing data is kept.")
        alert.addButton(withTitle: L10n.tr("Download from GitHub"))
        alert.addButton(withTitle: L10n.tr("Later"))
        alert.addButton(withTitle: L10n.tr("Skip This Version"))
        switch alert.runModal() {
        case .alertFirstButtonReturn: openDownload()
        case .alertThirdButtonReturn: defaults.set(candidate.version, forKey: "githubUpdateSkippedVersion")
        default:
            defaults.set(Date().addingTimeInterval(4 * 3600), forKey: "githubUpdateDeferredUntil")
            promptedVersion = nil
        }
    }

    private func showMessage(_ message: String) {
        let alert = NSAlert()
        alert.messageText = L10n.tr("Remarc Update")
        alert.informativeText = message
        alert.runModal()
    }
}
