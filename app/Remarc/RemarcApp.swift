import SwiftUI
import AppKit
import RemarcFeature
import AppMover
import ApplicationServices

@main
struct RemarcApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") {
                    Task { @MainActor in
                        PreferencesWindowController.shared.show()
                    }
                }
                .keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    private var shouldSkipSetup = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        #if !DEBUG
        // AppMover copies the quarantined download into Applications, then
        // schedules this process to exit and relaunch from the stable path.
        // Do not let the transient Downloads/App Translocation process begin
        // onboarding or register itself with TCC in the meantime.
        let moveStarted = AppMover.moveIfNecessary()
        let installedCopyIsAlreadyRunning = installedRemarcCopyIsAlreadyRunning
        shouldSkipSetup = moveStarted || installedCopyIsAlreadyRunning

        // AppMover activates an existing Applications copy and returns false.
        // Terminate this downloaded copy so it cannot register a second TCC
        // identity while the installed app is already serving the user.
        if !moveStarted && installedCopyIsAlreadyRunning {
            DispatchQueue.main.async {
                NSApp.terminate(nil)
            }
        }
        #endif

        RemarcURLHandler.shared.register()
        if shouldSkipSetup {
            // Cheap insurance, not active discarding: handleGetURLEvent hops to
            // the main actor via Task { @MainActor }, which cannot run before
            // this method returns, so the queue is always empty here in
            // practice. Kept in case that dispatch ever changes.
            RemarcURLHandler.shared.discardQueued()
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !shouldSkipSetup else { return }

        // Opt-in, read-only installation diagnostics for both signed channels.
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "--diagnostics-output"), index + 1 < arguments.count {
            let identity = AppIdentity.current
            let home = FileManager.default.homeDirectoryForCurrentUser
            let drive = home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs")
            let report: [String: Any] = [
                "channel": identity.rawValue, "bundleID": Bundle.main.bundleIdentifier ?? "",
                "bundlePath": Bundle.main.bundlePath, "name": identity.displayName,
                "dataDirectory": identity.appSupportURL(in: home).path,
                "cloudDirectory": identity.cloudURL(in: drive).path,
                "urlScheme": identity.urlScheme, "webSocketPort": identity.webSocketPort,
                "accessibilityGranted": AXIsProcessTrusted(),
                "screenCaptureGranted": CGPreflightScreenCaptureAccess(),
                "appIcon": Bundle.main.object(forInfoDictionaryKey: "CFBundleIconName") as? String ?? "",
                "menuBarIcon": identity.menuBarIconName,
            ]
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: URL(fileURLWithPath: arguments[index + 1]), options: .atomic)
            }
        }

        AppController.shared.setup()
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--show-sync") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                PreferencesWindowController.shared.show(tab: "iCloud Sync")
            }
        }
        #endif
    }

    private var installedRemarcCopyIsAlreadyRunning: Bool {
        guard !Self.isInApplicationsDirectory(Bundle.main.bundleURL) else { return false }
        guard let bundleIdentifier = Bundle.main.bundleIdentifier else { return false }
        let currentProcessIdentifier = ProcessInfo.processInfo.processIdentifier

        return NSWorkspace.shared.runningApplications.contains { application in
            guard application.bundleIdentifier == bundleIdentifier,
                  application.processIdentifier != currentProcessIdentifier,
                  let bundleURL = application.bundleURL
            else { return false }

            return Self.isInApplicationsDirectory(bundleURL)
        }
    }

    private static func isInApplicationsDirectory(_ bundleURL: URL) -> Bool {
        let standardizedBundleURL = bundleURL.resolvingSymlinksInPath().standardizedFileURL

        return FileManager.default.urls(for: .applicationDirectory, in: .allDomainsMask).contains { directory in
            let standardizedDirectory = directory.resolvingSymlinksInPath().standardizedFileURL
            return standardizedBundleURL.path == standardizedDirectory.path
                || standardizedBundleURL.path.hasPrefix(standardizedDirectory.path + "/")
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        Task { @MainActor in
            AppController.shared.handleDockIconClick()
        }
        return false
    }
}
