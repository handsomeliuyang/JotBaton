@testable import FeatureComments
@testable import FeatureCloudSync
import Foundation
import Testing

/// Two Macs merge each other's files independently. Every scenario checks both
/// directions: sync is only correct if both Macs end up with the same document.
@Suite("Per-comment sync merge")
struct SyncMergeTests {
    private let macA = UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!
    private let macB = UUID(uuidString: "00000000-0000-0000-0000-00000000000B")!
    private let session = Session(name: "Project")
    private let t0 = Date(timeIntervalSince1970: 1_000)

    private func comment(_ text: String, id: UUID = UUID(), at time: Date? = nil) -> Comment {
        Comment(id: id, type: .quickNote, commentText: text, source: "test", appBundleID: nil,
                createdAt: t0, updatedAt: time ?? t0, sessionID: session.id)
    }

    private func state(_ comments: [Comment], sessions: [Session]? = nil) -> AppState {
        AppState(sessions: sessions ?? [session], comments: comments, totalCommentsCreated: comments.count)
    }

    /// Merges in both directions and requires the same result on both Macs.
    private func converge(base: AppState?, a: AppState, b: AppState)
        -> (state: AppState, onA: [SyncConflict], onB: [SyncConflict]) {
        let onA = SyncMerge.merge(base: base.map(SyncProjection.make), local: a, remote: SyncProjection.make(b),
                                  localWinsTie: macA.uuidString > macB.uuidString, remoteName: "B", now: t0)
        let onB = SyncMerge.merge(base: base.map(SyncProjection.make), local: b, remote: SyncProjection.make(a),
                                  localWinsTie: macB.uuidString > macA.uuidString, remoteName: "A", now: t0)
        #expect(Set(onA.state.comments.map(\.id)) == Set(onB.state.comments.map(\.id)))
        for merged in onA.state.comments {
            #expect(onB.state.comments.first { $0.id == merged.id } == merged)
        }
        return (onA.state, onA.conflicts, onB.conflicts)
    }

    @Test func tasksAddedOnTwoMacsAreBothKeptWithoutConflict() {
        let base = state([])
        let result = converge(base: base, a: state([comment("From A")]), b: state([comment("From B")]))
        #expect(Set(result.state.comments.map(\.commentText)) == ["From A", "From B"])
        #expect(result.onA.isEmpty && result.onB.isEmpty)
    }

    @Test func editsToDifferentFieldsOfOneTaskBothSurvive() {
        let original = comment("Draft")
        var onA = original
        onA.commentText = "Edited on A"
        onA.updatedAt = t0.addingTimeInterval(10)
        var onB = original
        onB.status = .resolved
        onB.resolvedAt = t0.addingTimeInterval(20)
        onB.updatedAt = t0.addingTimeInterval(20)
        let result = converge(base: state([original]), a: state([onA]), b: state([onB]))
        #expect(result.state.comments[0].commentText == "Edited on A")
        #expect(result.state.comments[0].status == .resolved)
        #expect(result.onA.isEmpty && result.onB.isEmpty)
    }

    @Test func sameFieldOnTwoMacsKeepsTheNewerEditAndReportsTheOther() {
        let original = comment("Draft")
        var onA = original
        onA.commentText = "Older A"
        onA.updatedAt = t0.addingTimeInterval(10)
        var onB = original
        onB.commentText = "Newer B"
        onB.updatedAt = t0.addingTimeInterval(20)
        let result = converge(base: state([original]), a: state([onA]), b: state([onB]))
        #expect(result.state.comments[0].commentText == "Newer B")
        #expect(result.onA.count == 1 && result.onB.count == 1)
        #expect(result.onA[0].field == .text && !result.onA[0].localWon)
        #expect(result.onA[0].alternative.commentText == "Older A")
        #expect(result.onB[0].localWon)
    }

    @Test func simultaneousEditsBreakTiesTheSameWayOnBothMacs() {
        let original = comment("Draft")
        var onA = original
        onA.commentText = "A"
        onA.updatedAt = t0.addingTimeInterval(5)
        var onB = original
        onB.commentText = "B"
        onB.updatedAt = t0.addingTimeInterval(5)
        let result = converge(base: state([original]), a: state([onA]), b: state([onB]))
        #expect(["A", "B"].contains(result.state.comments[0].commentText))
    }

    @Test func deletionWinsOverAnEditOnTheOtherMacAndKeepsTheEdit() {
        let original = comment("Draft")
        var onA = original
        onA.isDeleted = true
        onA.deletedAt = t0.addingTimeInterval(10)
        var onB = original
        onB.commentText = "Edited"
        onB.updatedAt = t0.addingTimeInterval(20)
        let result = converge(base: state([original]), a: state([onA]), b: state([onB]))
        #expect(result.state.comments[0].isDeleted)
        #expect(result.state.comments[0].commentText == "Edited")
    }

    @Test func restoringOnOneMacIsKeptWhenTheOtherDidNotTouchIt() {
        var original = comment("Draft")
        original.isDeleted = true
        original.deletedAt = t0
        var onA = original
        onA.isDeleted = false
        onA.deletedAt = nil
        let result = converge(base: state([original]), a: state([onA]), b: state([original]))
        #expect(!result.state.comments[0].isDeleted)
    }

    @Test func prunedHistoryIsNotResurrectedButARestoreIs() {
        var expired = comment("Old")
        expired.isDeleted = true
        expired.deletedAt = t0
        let base = state([expired])
        // A pruned it; B still has it deleted.
        #expect(converge(base: base, a: state([]), b: state([expired])).state.comments.isEmpty)
        // B restored it meanwhile: the restore must win over A's prune.
        var restored = expired
        restored.isDeleted = false
        restored.deletedAt = nil
        #expect(converge(base: base, a: state([]), b: state([restored])).state.comments.map(\.id) == [expired.id])
    }

    @Test func firstContactResolvesDifferencesByTimeWithoutReportingConflicts() {
        let id = UUID()
        let result = converge(base: nil, a: state([comment("A", id: id, at: t0.addingTimeInterval(1))]),
                              b: state([comment("B", id: id, at: t0.addingTimeInterval(2))]))
        #expect(result.state.comments[0].commentText == "B")
        #expect(result.onA.isEmpty && result.onB.isEmpty)
    }

    @Test func deviceLocalStateNeverTravelsOrCountsAsAnEdit() {
        var original = comment("Draft")
        var local = state([original])
        local.activeSessionID = session.id
        local.unknownFields["_newerBuildKey"] = .string("kept")
        local.sessions[0].emptySince = t0
        local.sessions[0].unknownFields["claudeCodeSessionId"] = .string("legacy")
        original.commentText = "Remote edit"
        original.updatedAt = t0.addingTimeInterval(5)
        let merged = SyncMerge.merge(base: SyncProjection.make(state([comment("Draft", id: original.id)])), local: local,
                                     remote: SyncProjection.make(state([original])), localWinsTie: true, remoteName: "B").state
        #expect(merged.comments[0].commentText == "Remote edit")
        #expect(merged.sessions[0].emptySince == t0)
        #expect(merged.activeSessionID == session.id)
        #expect(merged.unknownFields["_newerBuildKey"] == .string("kept"))
        let projection = SyncProjection.make(local)
        #expect(projection.activeSessionID == nil && projection.unknownFields.isEmpty)
        #expect(projection.sessions[0].emptySince == nil)
        #expect(projection.sessions[0].unknownFields["claudeCodeSessionId"] == nil)
    }

    @Test func inboxesCreatedOnTwoMacsFoldIntoOne() {
        let inboxA = Session(name: CommentConstants.inboxSessionName)
        let inboxB = Session(name: CommentConstants.inboxSessionName)
        var fromA = comment("A")
        fromA.sessionID = inboxA.id
        var fromB = comment("B")
        fromB.sessionID = inboxB.id
        let result = converge(base: state([], sessions: []), a: state([fromA], sessions: [inboxA]),
                              b: state([fromB], sessions: [inboxB]))
        let keeper = [inboxA, inboxB].min { $0.id.uuidString < $1.id.uuidString }!
        #expect(result.state.sessions.filter { $0.isInbox && !$0.isDeleted }.map(\.id) == [keeper.id])
        #expect(result.state.comments.allSatisfy { $0.sessionID == keeper.id })
    }

    @Test func choosingTheOtherVersionIsANewerEdit() {
        let original = comment("Draft")
        var kept = original
        kept.commentText = "Kept"
        kept.updatedAt = t0.addingTimeInterval(20)
        var other = original
        other.commentText = "Other"
        let conflict = SyncConflict(commentID: original.id, field: .text, deviceName: "B", localWon: true,
                                    alternative: other, date: t0)
        conflict.applyAlternative(to: &kept, now: t0)
        #expect(kept.commentText == "Other")
        #expect(kept.updatedAt > t0.addingTimeInterval(20))
    }
}

@Suite("Sync image files")
struct SyncAssetTests {
    @Test func onlyImageFilesInsideTheImagesFolderAreAccepted() {
        let id = UUID().uuidString
        #expect(SyncAssets.isValidPath("images/\(id).png"))
        #expect(SyncAssets.isValidPath("images/\(id).base.png"))
        #expect(SyncAssets.isValidPath("images/\(id).marks.json"))
        #expect(!SyncAssets.isValidPath("images/../\(id).png"))
        #expect(!SyncAssets.isValidPath("/Users/me/\(id).png"))
        #expect(!SyncAssets.isValidPath("images/\(id).txt"))
    }

    @Test func fileContentsFollowTheSameThreeWayRuleAsFields() {
        let path = "images/\(UUID().uuidString).png"
        let all: Set<String> = [path]
        #expect(SyncAssets.plan(local: [:], remote: [path: "new"], base: nil, referenced: all, localWinsTie: true) == [path: "new"])
        #expect(SyncAssets.plan(local: [path: "old"], remote: [path: "new"], base: [path: "old"], referenced: all, localWinsTie: true) == [path: "new"])
        #expect(SyncAssets.plan(local: [path: "mine"], remote: [path: "old"], base: [path: "old"], referenced: all, localWinsTie: false).isEmpty)
        #expect(SyncAssets.plan(local: [path: "mine"], remote: [path: "theirs"], base: [path: "old"], referenced: all, localWinsTie: true).isEmpty)
        #expect(SyncAssets.plan(local: [path: "mine"], remote: [path: "theirs"], base: [path: "old"], referenced: all, localWinsTie: false) == [path: "theirs"])
        #expect(SyncAssets.plan(local: [:], remote: [path: "new"], base: nil, referenced: [], localWinsTie: true).isEmpty)
    }

    @Test func annotatedScreenshotsBringTheirEditingFiles() {
        let stem = "images/\(UUID().uuidString)"
        let session = Session(name: "S")
        let comment = Comment(type: .screenshot(imagePath: "\(stem).png"), commentText: "", source: "test",
                              appBundleID: nil, sessionID: session.id)
        #expect(SyncAssets.files(referencedBy: AppState(sessions: [session], comments: [comment]))
                == ["\(stem).png", "\(stem).base.png", "\(stem).marks.json"])
    }
}

@Suite("Sync health")
struct SyncHealthTests {
    private let now = Date(timeIntervalSince1970: 10_000)

    private func health(issue: CloudSyncIssue? = nil, newer: String? = nil, waiting: Int = 0, waitingFor: TimeInterval = 0,
                        unsyncedFor: TimeInterval? = nil, conflicts: Int = 0, syncing: Bool = false) -> SyncHealth {
        SyncHealth.evaluate(enabled: true, syncing: syncing, issue: issue, newerFormatDevice: newer, waitingCount: waiting,
                            waitingSince: now.addingTimeInterval(-waitingFor),
                            unsyncedSince: unsyncedFor.map { now.addingTimeInterval(-$0) },
                            conflictCount: conflicts, now: now)
    }

    @Test func shortWaitsStayQuiet() {
        #expect(health(waiting: 2, waitingFor: 60) == .waiting(count: 2))
        #expect(health(unsyncedFor: 60) == .ok)
        #expect(health(syncing: true) == .syncing)
    }

    @Test func longWaitsProblemsAndConflictsNeedAttention() {
        #expect(health(waiting: 1, waitingFor: SyncHealth.stuckDownloadDelay) == .attention(.stuckDownload(count: 1)))
        #expect(health(unsyncedFor: SyncHealth.unsyncedDelay).needsAttention)
        #expect(health(newer: "Office") == .attention(.newerFormat(deviceName: "Office")))
        #expect(health(conflicts: 2) == .attention(.conflicts(count: 2)))
        let issue = CloudSyncIssue.make(NSError(domain: NSCocoaErrorDomain, code: NSUbiquitousFileUbiquityServerNotAvailable), stage: .connection)
        #expect(health(issue: issue, conflicts: 2) == .attention(.issue(issue)))
    }

    @Test func disabledSyncIsNeverAProblem() {
        #expect(SyncHealth.evaluate(enabled: false, syncing: false, issue: nil, newerFormatDevice: "x", waitingCount: 3,
                                    waitingSince: .distantPast, unsyncedSince: .distantPast, conflictCount: 1, now: now) == .off)
    }
}

@Suite("Sync files", .serialized)
final class SyncFileTests {
    private let directory: URL
    private let layout: SyncLayout

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("RemarcSyncTests-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        layout = SyncLayout(folder: directory)
        try layout.prepare()
    }

    deinit { try? FileManager.default.removeItem(at: directory) }

    private func file(_ id: UUID) -> SyncDeviceFile {
        let session = Session(name: "S")
        let comment = Comment(type: .quickNote, commentText: "Hi", source: "test", appBundleID: nil, sessionID: session.id)
        return SyncDeviceFile(deviceID: id, deviceName: "Office", writtenAt: Date(timeIntervalSince1970: 5),
                              state: AppState(sessions: [session], comments: [comment]), assets: [:])
    }

    @Test func deviceFilesRoundTripAndEvictedOnesAreListed() throws {
        let id = UUID()
        let written = file(id)
        try SyncCloud.write(written, layout: layout)
        let evicted = UUID()
        try Data().write(to: layout.devices.appendingPathComponent(".\(evicted.uuidString).json.icloud"))
        #expect(Set(try SyncCloud.listDevices(layout)) == [id, evicted])
        #expect(SyncCloud.load(id, layout: layout) == .file(written))
    }

    @Test func aFileClaimingAnotherDeviceOrANewerFormatIsNotMerged() throws {
        let id = UUID()
        try SyncCloud.write(file(id), layout: layout)
        try FileManager.default.moveItem(at: layout.deviceFile(id), to: layout.deviceFile(UUID(uuidString: "00000000-0000-0000-0000-000000000001")!))
        #expect(SyncCloud.load(UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, layout: layout) == .invalid)

        let newer = UUID()
        var future = file(newer)
        future.formatVersion = SyncDeviceFile.currentFormat + 1
        try SyncCloud.write(future, layout: layout)
        #expect(SyncCloud.load(newer, layout: layout) == .newerFormat(deviceName: "Office"))
    }

    @Test func contentDigestIgnoresWriteTimeButNotContent() {
        let original = file(UUID())
        var rewritten = original
        rewritten.writtenAt = .distantFuture
        #expect(rewritten.contentDigest == original.contentDigest)
        var edited = original
        edited.state.comments[0].commentText = "Edited"
        #expect(edited.contentDigest != original.contentDigest)
    }

    @Test func onlyRetiredSnapshotFilesAreRemovedFromICloud() throws {
        let fm = FileManager.default
        let legacy = ["current.json", "2026-01-02_03-04-05+0800_Office_ABCDEF12.zip", "\(UUID().uuidString).zip",
                      ".2026-01-02_03-04-05+0800_Home_12345678.zip.icloud"]
        for name in legacy + ["notes.txt"] { try Data("x".utf8).write(to: directory.appendingPathComponent(name)) }
        try SyncCloud.write(file(UUID()), layout: layout)
        try SyncCloud.removeLegacySnapshots(in: directory)
        let remaining = Set(try fm.contentsOfDirectory(atPath: directory.path))
        #expect(remaining == ["notes.txt", "sync-v3"])
        #expect(try fm.contentsOfDirectory(atPath: layout.devices.path).count == 1)
    }

    @Test func retiredSnapshotBookkeepingIsDroppedFromTheDocument() throws {
        let json = """
        {"sessions": [], "comments": [], "totalCommentsCreated": 0,
         "_snapshotReceipt": {"x": 1}, "_snapshotContentStamp": "s", "_snapshotUndo": "u",
         "_snapshotDataUpdatedAt": 5, "transcriptions": [{"id": "x"}], "futureKey": true}
        """
        let state = try JSONDecoder().decode(AppState.self, from: Data(json.utf8))
        #expect(Set(state.unknownFields.keys) == ["transcriptions", "futureKey"])
        let saved = try JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as? [String: Any]
        #expect(saved?["_snapshotReceipt"] == nil && saved?["transcriptions"] != nil)
    }

    @Test func leftoverLocalSnapshotFilesAreRemoved() throws {
        let root = directory.appendingPathComponent("support")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("snapshot-rollback"), withIntermediateDirectories: true)
        try Data().write(to: root.appendingPathComponent("snapshot-sync-v2.json"))
        try Data().write(to: root.appendingPathComponent("comments.json"))
        SyncLocalStore.removeLegacySnapshotFiles(in: root)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["comments.json"])
    }

    @Test func recordToleratesMissingFieldsAndRestorePointsAreBounded() throws {
        let record = try JSONDecoder().decode(SyncRecord.self, from: Data("{}".utf8))
        #expect(record.conflicts.isEmpty && record.publishedDigest == nil)
        for index in 0..<(SyncLocalStore.restorePointLimit + 3) {
            try SyncLocalStore.saveRestorePoint(AppState(totalCommentsCreated: index),
                                                at: Date(timeIntervalSince1970: Double(index)), in: directory)
        }
        let latest = try #require(try SyncLocalStore.latestRestorePoint(in: directory))
        #expect(latest.state.totalCommentsCreated == SyncLocalStore.restorePointLimit + 2)
        let kept = try FileManager.default.contentsOfDirectory(
            at: SyncLocalStore.directory(in: directory).appendingPathComponent("restore-points"), includingPropertiesForKeys: nil)
        #expect(kept.count == SyncLocalStore.restorePointLimit)
    }
}

@Suite("iCloud folder", .serialized)
final class CloudSyncLocationTests {
    private let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("RemarcCloudLocation-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: directory) }

    private func cloudFacts(root: URL) -> (URL) throws -> CloudSyncLocation.Facts {
        { url in
            let actual = try CloudSyncLocation.inspect(url)
            return CloudSyncLocation.Facts(isDirectory: actual.isDirectory,
                isCloudItem: url == root, isSymbolicLink: actual.isSymbolicLink)
        }
    }

    @Test func eachUserGetsTheSameRelativeFolder() {
        #expect(CloudSyncLocation.root(in: URL(fileURLWithPath: "/Users/office")).path
                == "/Users/office/Library/Mobile Documents/com~apple~CloudDocs")
    }

    @Test func aMissingOrOrdinaryRootIsNeverTreatedAsICloud() {
        let absent = directory.appendingPathComponent("missing/CloudDocs")
        #expect(throws: (any Error).self) { try CloudSyncLocation.connect(root: absent, createIfMissing: true) }
        #expect(!FileManager.default.fileExists(atPath: absent.deletingLastPathComponent().path))
        #expect(throws: (any Error).self) { try CloudSyncLocation.connect(root: directory, createIfMissing: true) }
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("Remarc").path))
    }

    @Test func theFolderIsCreatedOnlyWithConsentAndTheProbeIsCleanedUp() throws {
        #expect(throws: (any Error).self) { try CloudSyncLocation.connect(root: directory, inspect: cloudFacts(root: directory)) }
        let folder = try CloudSyncLocation.connect(root: directory, createIfMissing: true, inspect: cloudFacts(root: directory))
        #expect(folder.path == directory.appendingPathComponent("Remarc").path)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
    }

    @Test func theFolderCannotRedirectThroughASymlink() throws {
        let outside = directory.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("Remarc"), withDestinationURL: outside)
        #expect(throws: (any Error).self) {
            try CloudSyncLocation.connect(root: directory, createIfMissing: true, inspect: cloudFacts(root: directory))
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
    }

    @Test func authorizationCannotSelectAnotherLocation() {
        #expect(CloudSyncLocation.isAuthorizationLocation(directory, root: directory))
        #expect(CloudSyncLocation.isAuthorizationLocation(directory.appendingPathComponent("Remarc"), root: directory))
        #expect(!CloudSyncLocation.isAuthorizationLocation(directory.appendingPathComponent("Other"), root: directory))
    }
}

@Suite("iCloud sync problems")
struct CloudSyncIssueTests {
    @Test func serverFailureIsNotMisclassifiedAsPermission() {
        let issue = CloudSyncIssue.make(NSError(domain: NSCocoaErrorDomain, code: NSUbiquitousFileUbiquityServerNotAvailable), stage: .publishing)
        #expect(issue.kind == .cloudUnavailable && issue.needsICloudSettings && !issue.needsAuthorization)
    }

    @Test func underlyingPermissionErrorOffersAuthorization() {
        let error = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError,
            userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))])
        let issue = CloudSyncIssue.make(CloudSyncError.underlying("Folder write failed", error), stage: .publishing)
        #expect(issue.kind == .permission && issue.needsAuthorization)
        #expect(issue.codes.count == 2)
    }

    @Test func quotaOffersStorageManagementRatherThanAuthorization() {
        let issue = CloudSyncIssue.make(NSError(domain: NSCocoaErrorDomain, code: NSUbiquitousFileNotUploadedDueToQuotaError), stage: .publishing)
        #expect(issue.kind == .quota && issue.needsICloudSettings && !issue.needsAuthorization)
    }

    @Test func diagnosticsDoNotCopyUserInfoOrAccountData() {
        let error = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError,
            userInfo: ["account": "private@example.com", "task": "PRIVATE_TASK_BODY", NSFilePathErrorKey: "/private/user/path"])
        let diagnostic = CloudSyncIssue.make(error, stage: .publishing).diagnostic
        #expect(!diagnostic.contains("private@example.com") && !diagnostic.contains("PRIVATE_TASK_BODY"))
        #expect(!diagnostic.contains("/private/user/path"))
        #expect(diagnostic.contains("NSCocoaErrorDomain (513)"))
    }
}
