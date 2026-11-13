@testable import FeatureUpdates
import CorePlatform
import Foundation
import Sparkle
import Testing

@Suite("In-app update installation")
@MainActor
struct UpdateInstallationTests {
    private var candidate: GitHubRelease.Candidate {
        .init(version: "1.2.37", releaseURL: URL(string: "https://github.com/handsomeliuyang/Remarc/releases/tag/v1.2.37")!,
              downloadURL: URL(string: "https://github.com/handsomeliuyang/Remarc/releases/download/v1.2.37/Remarc-Apple-Silicon-arm64.dmg")!,
              releaseNotes: "Update notes")
    }

    @Test("One consent proceeds through backup to install without another prompt")
    func singleConsent() async {
        let manager = UpdateManager(testing: candidate, prepareForRestart: { nil }, makeBackup: {}, reportMessage: { _ in Issue.record("Unexpected error") })
        let choice = await withCheckedContinuation { continuation in
            manager.showReady(toInstallAndRelaunch: { continuation.resume(returning: $0) })
            #expect(!manager.validateTermination(), "Quitting during backup must not bypass preparation")
        }
        #expect(choice == .install)
        #expect(manager.requiresSafeTermination)
        #expect(!manager.canCancelUpdate)
    }

    @Test("Unsaved work pauses restart; one resume continues after it is saved")
    func unsavedWork() async {
        var blocker: String? = "Unsaved comment"
        let manager = UpdateManager(testing: candidate, prepareForRestart: { blocker }, makeBackup: {}, reportMessage: { _ in Issue.record("Unexpected error") })
        let choice = await withCheckedContinuation { continuation in
            manager.showReady(toInstallAndRelaunch: { continuation.resume(returning: $0) })
            #expect(manager.canResumeUpdate)
            #expect(manager.requiresSafeTermination)
            #expect(manager.status == blocker)
            blocker = nil
            manager.resumeUpdate()
        }
        #expect(choice == .install)
        blocker = "Recording started during backup"
        #expect(!manager.validateTermination())
        #expect(manager.canResumeUpdate)
        var retried = false
        manager.showInstallingUpdate(withApplicationTerminated: false, retryTerminatingApplication: { retried = true })
        #expect(manager.status == blocker)
        blocker = nil
        manager.resumeUpdate()
        #expect(retried)
    }

    @Test("A failed backup cancels installation rather than quitting the app")
    func backupFailure() async {
        struct DiskFull: Error {}
        var messages: [String] = []
        let manager = UpdateManager(testing: candidate, prepareForRestart: { nil }, makeBackup: { throw DiskFull() }, reportMessage: { messages.append($0) })
        let choice = await withCheckedContinuation { continuation in
            manager.showReady(toInstallAndRelaunch: { continuation.resume(returning: $0) })
        }
        #expect(choice == .skip)
        #expect(!manager.requiresSafeTermination)
        #expect(!manager.isUpdating)
        #expect(messages.count == 1)
    }

    @Test("Canceling a ready update also cancels installation on quit")
    func cancelReadyUpdate() {
        var replies: [SPUUserUpdateChoice] = []
        let manager = UpdateManager(testing: candidate, prepareForRestart: { "Recording" }, makeBackup: {}, reportMessage: { _ in })
        manager.showReady(toInstallAndRelaunch: { replies.append($0) })
        manager.cancelUpdate()
        manager.cancelUpdate()
        #expect(replies == [.skip])
        #expect(!manager.isUpdating)
        #expect(!manager.requiresSafeTermination)
    }

    @Test("Canceling a download invokes its cancellation exactly once")
    func cancelDownload() {
        var canceled = 0
        let manager = UpdateManager(testing: candidate, prepareForRestart: { nil }, makeBackup: {}, reportMessage: { _ in })
        manager.showDownloadInitiated(cancellation: { canceled += 1 })
        manager.showDownloadDidReceiveExpectedContentLength(100)
        manager.showDownloadDidReceiveData(ofLength: 40)
        #expect(manager.progress == 0.4)
        manager.cancelUpdate()
        manager.cancelUpdate()
        #expect(canceled == 1)
        #expect(!manager.isUpdating)
    }

    @Test("A draft opened during backup is checked again before installation")
    func editingDuringBackup() async {
        var checks = 0
        let manager = UpdateManager(testing: candidate, prepareForRestart: {
            checks += 1
            return checks == 1 ? nil : "New draft"
        }, makeBackup: {}, reportMessage: { _ in })
        var replies: [SPUUserUpdateChoice] = []
        manager.showReady(toInstallAndRelaunch: { replies.append($0) })
        // Yield to the main actor task which completes the backup and rechecks the editor gate.
        for _ in 0..<100 where !manager.canResumeUpdate { await Task.yield() }
        #expect(manager.canResumeUpdate)
        #expect(replies.isEmpty)
        manager.cancelUpdate()
        #expect(replies == [.skip])
    }
}

@Suite("Update recovery backups")
struct UpdateBackupTests {
    @Test("Backup preserves the app, comments and images, excludes live locks, and never reads Dev data")
    func isolatedBackup() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: home) }
        let app = home.appendingPathComponent("Applications/Remarc.app")
        try fm.createDirectory(at: app.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        let plist = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "com.metepolat.Remarc"], format: .xml, options: 0)
        try plist.write(to: app.appendingPathComponent("Contents/Info.plist"))
        let production = AppIdentity.production.appSupportURL(in: home)
        let dev = AppIdentity.development.appSupportURL(in: home)
        for folder in [production, dev] { try fm.createDirectory(at: folder, withIntermediateDirectories: true) }
        try Data("production comments".utf8).write(to: production.appendingPathComponent("comments.json"))
        try Data("dev comments".utf8).write(to: dev.appendingPathComponent("comments.json"))
        try Data([1, 2, 3]).write(to: production.appendingPathComponent("image.png"))
        let first = try UpdateBackup.create(app: app, home: home, identity: .production)
        #expect(try Data(contentsOf: first.appendingPathComponent("user-data/comments.json")) == Data("production comments".utf8))
        #expect(try Data(contentsOf: first.appendingPathComponent("user-data/image.png")) == Data([1, 2, 3]))
        #expect(!fm.fileExists(atPath: first.appendingPathComponent("user-data/comments.json.lock").path))
        #expect(try Data(contentsOf: dev.appendingPathComponent("comments.json")) == Data("dev comments".utf8))
        let second = try UpdateBackup.create(app: app, home: home, identity: .production)
        #expect(first != second)
        #expect(fm.fileExists(atPath: first.path))
        #expect(throws: UpdateBackup.Failure.self) { try UpdateBackup.create(app: app, home: home, identity: .development) }
    }
}
