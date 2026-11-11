import AppKit
import Foundation
import Darwin

// This helper is copied outside the app before launch; it never replaces a
// running bundle and does not require Python, a shell script or administrator UI.
let fm = FileManager.default
let home = fm.homeDirectoryForCurrentUser
let installed = URL(fileURLWithPath: "/Applications/Remarc.app", isDirectory: true)
let cache = home.appendingPathComponent("Library/Caches/com.metepolat.Remarc/Updates", isDirectory: true)
let state = home.appendingPathComponent("Library/Application Support/Remarc Updates", isDirectory: true)
var stage: URL?
var replacement: URL?
var originalBuild: String?
var parentExited = false
NSApplication.shared.setActivationPolicy(.accessory)

func pause(_ seconds: TimeInterval) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }

func launchInstalled() throws {
    _ = try CloudUpdateTrust.run("/usr/bin/open", ["-n", installed.path])
    let deadline = Date().addingTimeInterval(30)
    while Date() < deadline {
        if let app = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == "com.metepolat.Remarc" && $0.bundleURL?.standardizedFileURL == installed
        }) {
            pause(3)
            if !app.isTerminated { return }
        }
        pause(0.25)
    }
    throw CloudUpdateError.operation("The updated app could not be started. Recovery will use the previous app backup.")
}

do {
    guard CommandLine.arguments.count == 3, let pid = Int32(CommandLine.arguments[2]), pid > 1 else {
        throw CloudUpdateError.operation("Invalid installer request.")
    }
    let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true).standardizedFileURL
    guard directory.deletingLastPathComponent() == cache.standardizedFileURL,
          directory.resolvingSymlinksInPath() == directory,
          UUID(uuidString: directory.lastPathComponent) != nil else { throw CloudUpdateError.invalidPackage }
    stage = directory
    defer { try? fm.removeItem(at: directory) }
    let envelope = try JSONDecoder().decode(CloudUpdateEnvelope.self, from: Data(contentsOf: directory.appendingPathComponent("latest.json")))
    let manifest = try envelope.verified(fingerprint: CloudUpdateTrust.productionFingerprint)
    let package = try manifest.package(for: CloudUpdateTrust.architecture(), os: ProcessInfo.processInfo.operatingSystemVersion)
    let archive = directory.appendingPathComponent(package.filename)
    try CloudUpdateTrust.verifyArchive(archive, package: package)
    try CloudUpdateTrust.verifyCode(installed)
    let oldInfo = try CloudUpdateTrust.info(installed)
    originalBuild = oldInfo["CFBundleVersion"] as? String
    guard let oldBuild = Int(oldInfo["CFBundleVersion"] as? String ?? ""), oldBuild < manifest.build,
          let parent = NSRunningApplication(processIdentifier: pid),
          parent.bundleIdentifier == "com.metepolat.Remarc", parent.bundleURL?.standardizedFileURL == installed else {
        throw CloudUpdateError.wrongApplication
    }
    let entries = try CloudUpdateTrust.run("/usr/bin/zipinfo", ["-1", archive.path]).split(separator: "\n")
    guard CloudUpdateTrust.validArchiveEntries(entries.map(String.init)) else { throw CloudUpdateError.invalidPackage }
    let unpacked = directory.appendingPathComponent("unpacked", isDirectory: true)
    try fm.createDirectory(at: unpacked, withIntermediateDirectories: false)
    _ = try CloudUpdateTrust.run("/usr/bin/ditto", ["-x", "-k", archive.path, unpacked.path])
    let candidate = unpacked.appendingPathComponent("Remarc.app", isDirectory: true)
    try CloudUpdateTrust.verifyApplication(candidate, manifest: manifest, package: package)
    let staged = URL(fileURLWithPath: "/Applications/.remarc-update-\(UUID().uuidString).app", isDirectory: true)
    replacement = staged
    _ = try CloudUpdateTrust.run("/usr/bin/ditto", [candidate.path, staged.path])
    try CloudUpdateTrust.verifyApplication(staged, manifest: manifest, package: package)
    // All package and destination checks finish before the running app quits.
    try Data("ready".utf8).write(to: directory.appendingPathComponent("ready"), options: .atomic)
    let deadline = Date().addingTimeInterval(120)
    while !parent.isTerminated && Date() < deadline { pause(0.2) }
    guard parent.isTerminated else { throw CloudUpdateError.operation("The app did not quit. The update was cancelled.") }
    parentExited = true
    try CloudUpdateTrust.verifyCode(installed)
    guard (try CloudUpdateTrust.info(installed))["CFBundleVersion"] as? String == String(oldBuild) else {
        throw CloudUpdateError.wrongApplication
    }
    let backups = home.appendingPathComponent("Library/Application Support/Remarc Update Backups", isDirectory: true)
    let data = home.appendingPathComponent("Library/Application Support/Remarc", isDirectory: true)
    try CloudUpdateReplacement.install(staged: staged, installed: installed, data: data, backups: backups,
        validateBackup: { try CloudUpdateTrust.verifyCode($0) }, launch: { try launchInstalled() }, stop: {
            let running = NSWorkspace.shared.runningApplications.filter { $0.bundleURL?.standardizedFileURL == installed }
            for app in running { app.terminate() }
            let deadline = Date().addingTimeInterval(10)
            while running.contains(where: { !$0.isTerminated }) && Date() < deadline { pause(0.2) }
            guard running.allSatisfy({ $0.isTerminated }) else {
                throw CloudUpdateError.operation("The updated app could not quit. The previous version remains in Remarc Update Backups/Previous.")
            }
        })
    try? fm.removeItem(at: state.appendingPathComponent("error.txt"))
} catch {
    if let replacement { try? fm.removeItem(at: replacement) }
    try? fm.createDirectory(at: state, withIntermediateDirectories: true)
    try? Data(error.localizedDescription.utf8).write(to: state.appendingPathComponent("error.txt"), options: .atomic)
    if parentExited, let originalBuild,
       (try? CloudUpdateTrust.info(installed))?["CFBundleVersion"] as? String == originalBuild { try? launchInstalled() }
    if parentExited {
        let alert = NSAlert()
        alert.messageText = "Remarc update was not installed"
        alert.informativeText = error.localizedDescription
        alert.runModal()
    }
    if let stage { try? fm.removeItem(at: stage) }
    exit(1)
}
