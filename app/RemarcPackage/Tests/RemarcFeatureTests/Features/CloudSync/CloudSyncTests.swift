@testable import CorePlatform
@testable import FeatureComments
@testable import FeatureCloudSync
import Foundation
import Combine
import Testing

private typealias Comment = FeatureComments.Comment

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

    @Test func anOfflineMacCanKeepCapturingIntoAnAlreadyFoldedInbox() {
        let keeper = Session(id: macA, name: CommentConstants.inboxSessionName)
        let obsolete = Session(id: macB, name: CommentConstants.inboxSessionName)
        let remoteBase = state([], sessions: [obsolete])
        let first = SyncMerge.merge(base: nil, local: state([], sessions: [keeper]), remote: remoteBase,
                                    localWinsTie: true, remoteName: "B", now: t0).state
        var capturedOffline = comment("Captured while offline")
        capturedOffline.sessionID = obsolete.id
        let remote = state([capturedOffline], sessions: [obsolete])
        let merged = SyncMerge.merge(base: remoteBase, local: first, remote: remote,
                                     localWinsTie: true, remoteName: "B", now: t0.addingTimeInterval(10)).state
        #expect(merged.comments.first?.sessionID == keeper.id)
        #expect(merged.sessions.first { $0.id == obsolete.id }?.deletedAt == t0)
        let repeated = SyncMerge.merge(base: remote, local: merged, remote: remote,
                                       localWinsTie: true, remoteName: "B", now: t0.addingTimeInterval(20)).state
        #expect(repeated == merged)
    }

    @Test func prunedRemoteCommentsQueueUnreferencedLocalImagesWithoutAffectingSharedOnes() {
        let expiredImage = "images/\(UUID().uuidString).png"
        let alreadyQueued = "images/\(UUID().uuidString).png"
        let sharedImage = "images/\(UUID().uuidString).png"
        let expired = Comment(type: .screenshot(imagePath: expiredImage), commentText: "Old", source: "test",
                              appBundleID: nil, createdAt: t0, updatedAt: t0, sessionID: session.id,
                              isDeleted: true, deletedAt: t0, attachments: [sharedImage, alreadyQueued])
        let active = Comment(type: .screenshot(imagePath: sharedImage), commentText: "Keep", source: "test",
                             appBundleID: nil, createdAt: t0, updatedAt: t0, sessionID: session.id)
        let base = state([expired, active])
        var local = base
        local.orphanedImages = [OrphanedImage(path: alreadyQueued, deletedAt: t0)]
        let remote = state([active])

        let merged = SyncMerge.merge(base: SyncProjection.make(base), local: local,
                                     remote: SyncProjection.make(remote), localWinsTie: false,
                                     remoteName: "A", now: t0.addingTimeInterval(100)).state

        #expect(merged.comments.map(\.id) == [active.id])
        #expect(Set(merged.orphanedImages.map(\.path)) == [expiredImage, alreadyQueued])
        #expect(merged.orphanedImages.count == 2)
        #expect(merged.orphanedImages.first { $0.path == expiredImage }?.deletedAt == t0)
    }

    @Test func restoredCommentsDoNotQueueLocalImagesAsOrphans() {
        let image = "images/\(UUID().uuidString).png"
        let deleted = Comment(type: .screenshot(imagePath: image), commentText: "Old", source: "test",
                              appBundleID: nil, createdAt: t0, updatedAt: t0, sessionID: session.id,
                              isDeleted: true, deletedAt: t0)
        var restored = deleted
        restored.isDeleted = false
        restored.deletedAt = nil

        let merged = SyncMerge.merge(base: SyncProjection.make(state([deleted])), local: state([restored]),
                                     remote: SyncProjection.make(state([])), localWinsTie: false,
                                     remoteName: "A", now: t0.addingTimeInterval(100)).state

        #expect(merged.comments.map(\.id) == [deleted.id])
        #expect(merged.orphanedImages.isEmpty)
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

    @Test func unreferencedBlobSelectionRequiresReadableDevicesNoReferenceAndGracePeriod() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let grace = SyncAssets.blobGracePeriod
        let oldUnused = SyncIO.digest(Data("old-unused".utf8))
        let exactBoundary = SyncIO.digest(Data("exact-boundary".utf8))
        let freshUnused = SyncIO.digest(Data("fresh-unused".utf8))
        let oldReferenced = SyncIO.digest(Data("old-referenced".utf8))
        let missingDate = SyncIO.digest(Data("missing-date".utf8))
        let entries = [
            SyncBlobEntry(digest: oldUnused, createdAt: now.addingTimeInterval(-grace - 1)),
            SyncBlobEntry(digest: exactBoundary, createdAt: now.addingTimeInterval(-grace)),
            SyncBlobEntry(digest: freshUnused, createdAt: now.addingTimeInterval(-grace + 1)),
            SyncBlobEntry(digest: oldReferenced, createdAt: now.addingTimeInterval(-grace * 3)),
            SyncBlobEntry(digest: missingDate, createdAt: nil),
            SyncBlobEntry(digest: "not-a-valid-sha256", createdAt: .distantPast),
        ]

        #expect(SyncAssets.unreferencedBlobs(existing: entries, referencedDigests: [oldReferenced],
                                             allDevicesReadable: false, now: now).isEmpty)
        #expect(SyncAssets.unreferencedBlobs(existing: entries, referencedDigests: [oldReferenced],
                                             allDevicesReadable: true, now: now)
                == [oldUnused, exactBoundary].sorted())
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

    @Test func syncSubdirectoriesCannotRedirectToAnotherChannel() throws {
        let fm = FileManager.default
        let outside = directory.appendingPathComponent("outside")
        try fm.createDirectory(at: outside, withIntermediateDirectories: false)
        for target in [layout.devices, layout.blobs, layout.root] {
            try fm.removeItem(at: target)
            try fm.createSymbolicLink(at: target, withDestinationURL: outside)
            #expect(throws: (any Error).self) { try layout.prepare() }
            #expect(try fm.contentsOfDirectory(atPath: outside.path).isEmpty)
            try fm.removeItem(at: target)
            try layout.prepare()
        }
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

    @Test func recordToleratesMissingFieldsAndRestorePointsAreBounded() throws {
        var record = try JSONDecoder().decode(SyncRecord.self, from: Data("{}".utf8))
        #expect(record.conflicts.isEmpty && record.publishedDigest == nil && record.lastBlobCleanupAt == nil)
        let cleanupDate = Date(timeIntervalSince1970: 123_456)
        record.lastBlobCleanupAt = cleanupDate
        try SyncLocalStore.saveRecord(record, in: directory)
        #expect(try SyncLocalStore.loadRecord(in: directory).lastBlobCleanupAt == cleanupDate)
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

    @Test func storageProvidersListAndDeleteBlobsSafely() throws {
        let regularDigest = SyncIO.digest(Data("regular-blob".utf8))
        let evictedDigest = SyncIO.digest(Data("evicted-blob".utf8))
        let regularURL = layout.blob(regularDigest)
        let evictedPlaceholder = CloudFileStatus.iCloudPlaceholder(for: layout.blob(evictedDigest))
        try Data("regular-blob".utf8).write(to: regularURL)
        try Data("placeholder".utf8).write(to: evictedPlaceholder)
        try Data("finder".utf8).write(to: layout.blobs.appendingPathComponent(".DS_Store"))
        try Data("tmp".utf8).write(to: layout.blobs.appendingPathComponent(".syncthing.\(regularDigest).blob.tmp"))
        try Data("conflict".utf8).write(to: layout.blobs.appendingPathComponent("\(regularDigest).sync-conflict-20261125.blob"))

        let dir = directory
        let iCloud = ICloudStorageProvider(connect: { _ in dir })
        let local = LocalFolderStorageProvider(base: dir)

        #expect(Set(try iCloud.listBlobs(layout).map(\.digest)) == [regularDigest, evictedDigest])
        #expect(try local.listBlobs(layout).map(\.digest) == [regularDigest])

        // Deleting an evicted placeholder removes it; deleting an already-missing file succeeds.
        try iCloud.deleteItem(at: layout.blob(evictedDigest))
        #expect(!FileManager.default.fileExists(atPath: evictedPlaceholder.path))
        try iCloud.deleteItem(at: layout.blob(evictedDigest))

        try local.deleteItem(at: regularURL)
        #expect(!FileManager.default.fileExists(atPath: regularURL.path))
        try local.deleteItem(at: regularURL)
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
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("JotBaton").path))
    }

    @Test func theFolderIsCreatedOnlyWithConsentAndTheProbeIsCleanedUp() throws {
        #expect(throws: (any Error).self) { try CloudSyncLocation.connect(root: directory, inspect: cloudFacts(root: directory)) }
        let folder = try CloudSyncLocation.connect(root: directory, createIfMissing: true, inspect: cloudFacts(root: directory))
        #expect(folder.path == directory.appendingPathComponent("JotBaton").path)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
    }

    @Test func theFolderCannotRedirectThroughASymlink() throws {
        let outside = directory.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("JotBaton"), withDestinationURL: outside)
        #expect(throws: (any Error).self) {
            try CloudSyncLocation.connect(root: directory, createIfMissing: true, inspect: cloudFacts(root: directory))
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
    }

    @Test func authorizationRejectsSymlinkAliases() throws {
        let alias = directory.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: directory)
        #expect(!CloudSyncLocation.isAuthorizationLocation(alias, root: directory))
    }

    @Test func authorizationCannotSelectAnotherLocation() {
        #expect(CloudSyncLocation.isAuthorizationLocation(directory, root: directory))
        #expect(CloudSyncLocation.isAuthorizationLocation(directory.appendingPathComponent("JotBaton"), root: directory))
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

@Suite("Automatic sync coordinator", .serialized)
@MainActor
struct CloudSyncManagerTests {
    private final class Documents: CloudSyncDocumentStore {
        @Published var appState: AppState
        var beforeRead: (() -> Void)?
        var beforeCommit: (() -> Void)?
        var publishUnchangedOnRead = false
        var readCount = 0
        var statePublisher: AnyPublisher<AppState, Never> { $appState.eraseToAnyPublisher() }
        init(_ state: AppState) { appState = state }
        func stateForSync() async throws -> AppState {
            readCount += 1
            if publishUnchangedOnRead { reconcileWithoutChanges(&appState) }
            beforeRead?()
            return appState
        }
        private func reconcileWithoutChanges(_ state: inout AppState) {}
        func commitSyncedState(_ transform: (AppState) -> AppState) async throws -> AppState {
            beforeCommit?()
            appState = transform(appState)
            return appState
        }
    }

    private func withManager(_ body: (CloudSyncManager, Documents, URL, SyncLayout) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SyncCoordinator-\(UUID())")
        let cloud = root.appendingPathComponent("cloud")
        try FileManager.default.createDirectory(at: cloud, withIntermediateDirectories: true)
        let domain = "SyncCoordinatorTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: domain))
        let session = Session(name: "Project")
        let comment = Comment(type: .quickNote, commentText: "Original", source: "test", appBundleID: nil,
                              createdAt: Date(timeIntervalSince1970: 100), updatedAt: Date(timeIntervalSince1970: 100),
                              sessionID: session.id)
        let documents = Documents(AppState(sessions: [session], comments: [comment]))
        let manager = CloudSyncManager(documents: documents, root: root, defaults: defaults, connect: { _ in cloud })
        defer {
            manager.disable()
            defaults.removePersistentDomain(forName: domain)
            try? FileManager.default.removeItem(at: root)
        }
        let layout = SyncLayout(folder: cloud)
        try layout.prepare()
        try await body(manager, documents, root, layout)
    }

    @Test func unchangedPublicationsDuringSyncDoNotScheduleAnotherPass() async throws {
        try await withManager { manager, documents, _, _ in
            // Reproduce a save passing @Published state through a no-op inout helper.
            documents.publishUnchangedOnRead = true
            manager.enable()
            await manager.syncNow()
            // Allow the initial cloud-file directory event to settle as well.
            try await Task.sleep(for: .milliseconds(2300))
            let completed = documents.readCount
            try await Task.sleep(for: .milliseconds(3400))
            #expect(manager.lastSuccessAt != nil && manager.issue == nil)
            #expect(documents.readCount == completed)
        }
    }

    @Test func localOnlyChangesStayQuietAndRealEditsStillSync() async throws {
        try await withManager { manager, documents, _, layout in
            manager.enable()
            await manager.syncNow()
            try await Task.sleep(for: .milliseconds(2300))
            let completed = documents.readCount
            documents.appState.activeSessionID = UUID()
            documents.appState.sessions[0].emptySince = Date()
            documents.appState.unknownFields["localOnly"] = .string("ignored")
            try await Task.sleep(for: .milliseconds(3400))
            #expect(documents.readCount == completed)

            documents.appState.comments[0].commentText = "A real edit"
            documents.appState.comments[0].updatedAt = Date()
            let edited = documents.appState
            // Repeated no-op publications must not postpone a real edit's debounce.
            for _ in 0..<4 {
                try await Task.sleep(for: .milliseconds(800))
                documents.appState = edited
            }
            try await Task.sleep(for: .milliseconds(200))
            let data = try Data(contentsOf: layout.deviceFile(manager.deviceID))
            let published = try JSONDecoder().decode(SyncDeviceFile.self, from: data)
            #expect(published.state.comments[0].commentText == "A real edit")
            #expect(documents.readCount > completed)
        }
    }

    @Test func anExplicitRequestSyncsNewImageBytesAtAnUnchangedPath() async throws {
        try await withManager { manager, documents, root, layout in
            let path = "images/\(UUID()).png"
            try FileManager.default.createDirectory(at: root.appendingPathComponent("images"), withIntermediateDirectories: true)
            let image = root.appendingPathComponent(path)
            try Data("original image".utf8).write(to: image)
            documents.appState.comments[0].type = .screenshot(imagePath: path)
            manager.enable()
            await manager.syncNow()
            try await Task.sleep(for: .milliseconds(2300))
            let unchanged = documents.appState
            let replacement = Data("annotated replacement image".utf8)
            try replacement.write(to: image, options: .atomic)
            // The annotation workflow requests sync explicitly: no document edit.
            let previousSuccess = manager.lastSuccessAt
            manager.requestSync()
            for _ in 0..<50 {
                if manager.lastSuccessAt != previousSuccess { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            #expect(manager.lastSuccessAt != previousSuccess)
            let data = try Data(contentsOf: layout.deviceFile(manager.deviceID))
            let published = try JSONDecoder().decode(SyncDeviceFile.self, from: data)
            let digest = SyncIO.digest(replacement)
            #expect(documents.appState == unchanged)
            #expect(published.assets[path] == digest)
            #expect(try Data(contentsOf: layout.blob(digest)) == replacement)
        }
    }

    @Test func aLocallyWinningConflictStillRetainsTheOtherVersion() async throws {
        try await withManager { manager, documents, root, layout in
            let remoteID = UUID()
            let original = SyncDeviceFile(deviceID: remoteID, deviceName: "Other Mac", writtenAt: Date(),
                                          state: documents.appState, assets: [:])
            try SyncLocalStore.saveBase(original, in: root)
            var remote = original
            remote.state.comments[0].commentText = "Remote alternative"
            remote.state.comments[0].updatedAt = Date(timeIntervalSince1970: 110)
            try SyncCloud.write(remote, layout: layout)
            documents.appState.comments[0].commentText = "Local winner"
            documents.appState.comments[0].updatedAt = Date(timeIntervalSince1970: 120)
            manager.enable()
            await manager.syncNow()
            #expect(documents.appState.comments[0].commentText == "Local winner")
            #expect(manager.conflicts.count == 1)
            #expect(manager.conflicts.first?.alternative.commentText == "Remote alternative")
            #expect(manager.health.needsAttention)
            #expect(try SyncLocalStore.loadRecord(in: root).conflicts.count == 1)
        }
    }

    @Test func disablingWhileReadingTheDocumentPreventsPublishing() async throws {
        try await withManager { manager, documents, _, layout in
            documents.beforeRead = { manager.disable() }
            manager.enable()
            await manager.syncNow()
            #expect(!SyncCloud.exists(layout.deviceFile(manager.deviceID)))
            #expect(manager.folder == nil && manager.issue == nil)
            #expect(manager.health == .off)
        }
    }

    @Test func disablingBeforeTheDocumentTransactionPreventsApplyingRemoteEdits() async throws {
        try await withManager { manager, documents, _, layout in
            var remote = SyncDeviceFile(deviceID: UUID(), deviceName: "Other Mac", writtenAt: Date(),
                                        state: documents.appState, assets: [:])
            remote.state.comments[0].commentText = "Remote edit"
            remote.state.comments[0].updatedAt = Date(timeIntervalSince1970: 120)
            try SyncCloud.write(remote, layout: layout)
            documents.beforeCommit = { manager.disable() }
            manager.enable()
            await manager.syncNow()
            #expect(documents.appState.comments[0].commentText == "Original")
            #expect(!SyncCloud.exists(layout.deviceFile(manager.deviceID)))
            #expect(manager.folder == nil && manager.issue == nil)
        }
    }

    @Test func startupAndSuccessfulSyncPreserveLegacyRecoveryFiles() async throws {
        try await withManager { manager, _, root, layout in
            let local = root.appendingPathComponent("snapshot-backups")
            try FileManager.default.createDirectory(at: local, withIntermediateDirectories: false)
            let backup = local.appendingPathComponent("recover.zip")
            let archive = layout.root.deletingLastPathComponent().appendingPathComponent("current.json")
            let bytes = Data("historical recovery data".utf8)
            try bytes.write(to: backup)
            try bytes.write(to: archive)
            manager.enable()
            await manager.syncNow()
            #expect(manager.lastSuccessAt != nil)
            #expect(try Data(contentsOf: backup) == bytes)
            #expect(try Data(contentsOf: archive) == bytes)
        }
    }

    @Test func anEnabledInstallationSetsUpTheNewCloudFolderOnStartup() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SyncStartup-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let domain = "SyncStartupTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defaults.set(true, forKey: "snapshotICloudEnabled")
        let cloud = root.appendingPathComponent("JotBaton")
        let documents = Documents(AppState())
        let manager = CloudSyncManager(documents: documents, root: root, defaults: defaults, connect: { setup in
            if setup { try FileManager.default.createDirectory(at: cloud, withIntermediateDirectories: false) }
            guard FileManager.default.fileExists(atPath: cloud.path) else {
                throw CloudSyncError.message("The new cloud folder has not been set up.")
            }
            return cloud
        })
        defer {
            manager.disable()
            defaults.removePersistentDomain(forName: domain)
            try? FileManager.default.removeItem(at: root)
        }
        await manager.syncNow()
        #expect(manager.lastSuccessAt != nil)
        #expect(manager.issue == nil)
        #expect(SyncCloud.exists(SyncLayout(folder: cloud).deviceFile(manager.deviceID)))
    }

    @Test func downloadedImagesNotifyTheApplication() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SyncImageNotification-\(UUID())")
        let cloud = root.appendingPathComponent("cloud")
        try FileManager.default.createDirectory(at: cloud, withIntermediateDirectories: true)
        let domain = "SyncImageNotification.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: domain))
        let session = Session(name: "Project")
        let path = "images/\(UUID()).png"
        let comment = Comment(type: .screenshot(imagePath: path), commentText: "Image", source: "test",
                              appBundleID: nil, sessionID: session.id)
        let documents = Documents(AppState(sessions: [session], comments: [comment]))
        var notified = Set<String>()
        let manager = CloudSyncManager(documents: documents, root: root, defaults: defaults,
                                       connect: { _ in cloud }, imagesDidChange: { notified.formUnion($0) })
        defer {
            manager.disable()
            defaults.removePersistentDomain(forName: domain)
            try? FileManager.default.removeItem(at: root)
        }
        let layout = SyncLayout(folder: cloud)
        try layout.prepare()
        let bytes = Data("downloaded image bytes".utf8)
        let digest = SyncIO.digest(bytes)
        try bytes.write(to: layout.blob(digest))
        try SyncCloud.write(SyncDeviceFile(deviceID: UUID(), deviceName: "Other Mac", writtenAt: Date(),
                                          state: documents.appState, assets: [path: digest]), layout: layout)
        manager.enable()
        await manager.syncNow()
        #expect(try Data(contentsOf: root.appendingPathComponent(path)) == bytes)
        #expect(notified == [path])
    }

    @Test func localFolderProviderSyncsBetweenTwoMacsAndIgnoresSyncthingArtifacts() async throws {
        let rootA = FileManager.default.temporaryDirectory.appendingPathComponent("LocalSyncA-\(UUID())")
        let rootB = FileManager.default.temporaryDirectory.appendingPathComponent("LocalSyncB-\(UUID())")
        let sharedBase = FileManager.default.temporaryDirectory.appendingPathComponent("SharedSyncthing-\(UUID())")
        try FileManager.default.createDirectory(at: rootA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: rootB, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sharedBase, withIntermediateDirectories: true)
        let domainA = "LocalSyncA.\(UUID())"
        let domainB = "LocalSyncB.\(UUID())"
        let defaultsA = try #require(UserDefaults(suiteName: domainA))
        let defaultsB = try #require(UserDefaults(suiteName: domainB))
        defer {
            defaultsA.removePersistentDomain(forName: domainA)
            defaultsB.removePersistentDomain(forName: domainB)
            try? FileManager.default.removeItem(at: rootA)
            try? FileManager.default.removeItem(at: rootB)
            try? FileManager.default.removeItem(at: sharedBase)
        }

        let session = Session(name: "Project")
        let imagePath = "images/\(UUID()).png"
        try FileManager.default.createDirectory(at: rootA.appendingPathComponent("images"), withIntermediateDirectories: true)
        let imageBytes = Data("syncthing-shared-image".utf8)
        try imageBytes.write(to: rootA.appendingPathComponent(imagePath))
        let commentA = Comment(type: .screenshot(imagePath: imagePath), commentText: "From Mac A", source: "test",
                               appBundleID: nil, sessionID: session.id)
        let docsA = Documents(AppState(sessions: [session], comments: [commentA]))
        let docsB = Documents(AppState(sessions: [session], comments: []))

        let managerA = CloudSyncManager(documents: docsA, root: rootA, defaults: defaultsA, channel: .production)
        let managerB = CloudSyncManager(documents: docsB, root: rootB, defaults: defaultsB, channel: .production)
        defer {
            managerA.disable()
            managerB.disable()
        }

        try managerA.setLocalFolder(sharedBase, storeBookmark: false)
        managerA.enable()
        await managerA.syncNow()

        let expectedChannelFolder = sharedBase.appendingPathComponent("JotBaton", isDirectory: true)
        let layout = SyncLayout(folder: expectedChannelFolder)
        #expect(managerA.folder?.standardizedFileURL.path == expectedChannelFolder.standardizedFileURL.path)

        // Drop Syncthing temporary and conflict artifacts next to device files.
        try Data("temp".utf8).write(to: layout.devices.appendingPathComponent(".syncthing.\(UUID()).json.tmp"))
        try Data("conflict".utf8).write(to: layout.devices.appendingPathComponent("\(UUID()).sync-conflict-20261125-120000.json"))
        try Data("finder".utf8).write(to: layout.devices.appendingPathComponent(".DS_Store"))

        try managerB.setLocalFolder(sharedBase, storeBookmark: false)
        managerB.enable()
        await managerB.syncNow()

        #expect(docsB.appState.comments.map(\.commentText) == ["From Mac A"])
        #expect(try Data(contentsOf: rootB.appendingPathComponent(imagePath)) == imageBytes)
        #expect(managerB.issue == nil && managerB.unsyncedSince == nil)
    }

    @Test func switchingProvidersResetsPublishedDigestAndPreservesOldFolder() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ProviderSwitch-\(UUID())")
        let iCloudDir = root.appendingPathComponent("iCloudFolder")
        let localDir = FileManager.default.temporaryDirectory.appendingPathComponent("GoogleDriveBase-\(UUID())")
        try FileManager.default.createDirectory(at: iCloudDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: localDir, withIntermediateDirectories: true)
        let domain = "ProviderSwitch.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer {
            defaults.removePersistentDomain(forName: domain)
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: localDir)
        }

        let session = Session(name: "Project")
        let comment = Comment(type: .quickNote, commentText: "Migrate me", source: "test", appBundleID: nil, sessionID: session.id)
        let docs = Documents(AppState(sessions: [session], comments: [comment]))
        let manager = CloudSyncManager(documents: docs, root: root, defaults: defaults, channel: .production,
                                       connect: { _ in iCloudDir })
        defer { manager.disable() }

        manager.enable()
        await manager.syncNow()
        let iCloudDeviceFile = SyncLayout(folder: iCloudDir).deviceFile(manager.deviceID)
        #expect(FileManager.default.fileExists(atPath: iCloudDeviceFile.path))

        // Switch to local folder without changing the local document.
        try manager.setLocalFolder(localDir, storeBookmark: false)
        await manager.syncNow()

        let localDeviceFile = SyncLayout(folder: localDir.appendingPathComponent("JotBaton")).deviceFile(manager.deviceID)
        #expect(FileManager.default.fileExists(atPath: localDeviceFile.path))
        // Old iCloud file is preserved untouched.
        #expect(FileManager.default.fileExists(atPath: iCloudDeviceFile.path))

        // Disabling keeps the chosen local folder for quick re-enabling.
        manager.disable()
        #expect(manager.providerKind == .localFolder)
        #expect(manager.localFolderBase?.standardizedFileURL.path == localDir.standardizedFileURL.path)
    }

    @Test func fileProviderUploadAndDatalessStatesTrackGoogleDriveSyncStatus() async throws {
        final class StubFileProvider: StorageProvider, @unchecked Sendable {
            let kind: StorageProviderKind = .localFolder
            let supportsSystemCloudSettings = false
            let folder: URL
            var remoteAvailability: SyncFileAvailability = .downloading
            var uploaded: Bool? = false

            init(folder: URL) { self.folder = folder }
            func connect(createIfMissing: Bool, verifyWriteAccess: Bool) throws -> URL { folder }
            func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }
            func availability(_ url: URL) -> SyncFileAvailability { remoteAvailability }
            func listDevices(_ layout: SyncLayout) throws -> [UUID] {
                try LocalFolderStorageProvider(base: folder).listDevices(layout)
            }
            func listBlobs(_ layout: SyncLayout) throws -> [SyncBlobEntry] {
                try LocalFolderStorageProvider(base: folder).listBlobs(layout)
            }
            func readData(at url: URL) throws -> Data { try Data(contentsOf: url) }
            func writeData(_ data: Data, to url: URL, onlyIfMissing: Bool) throws {
                if onlyIfMissing, FileManager.default.fileExists(atPath: url.path) { return }
                try data.write(to: url, options: .atomic)
            }
            func deleteItem(at url: URL) throws {
                try LocalFolderStorageProvider(base: folder).deleteItem(at: url)
            }
            func uploadState(_ url: URL) throws -> Bool? { uploaded }
        }

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("GDriveStub-\(UUID())")
        let driveFolder = FileManager.default.temporaryDirectory.appendingPathComponent("GDriveStubFolder-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: driveFolder, withIntermediateDirectories: true)
        let domain = "GDriveStub.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer {
            defaults.removePersistentDomain(forName: domain)
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: driveFolder)
        }

        let stub = StubFileProvider(folder: driveFolder)
        let layout = SyncLayout(folder: driveFolder)
        try layout.prepare()
        let session = Session(name: "Project")
        let remoteComment = Comment(type: .quickNote, commentText: "From Drive", source: "test", appBundleID: nil, sessionID: session.id)
        let remoteID = UUID()
        try SyncCloud.write(SyncDeviceFile(deviceID: remoteID, deviceName: "Office", writtenAt: Date(),
                                           state: AppState(sessions: [session], comments: [remoteComment]), assets: [:]),
                            layout: layout, provider: stub)

        let docs = Documents(AppState(sessions: [session], comments: []))
        let manager = CloudSyncManager(documents: docs, root: root, defaults: defaults,
                                       providerFactory: { _, _ in stub })
        defer { manager.disable() }
        try manager.setLocalFolder(driveFolder, storeBookmark: false)
        manager.enable()

        // Pass 1: remote device file is hydrated and merged; local publish is still uploading to Google Drive.
        stub.remoteAvailability = .ready
        stub.uploaded = false
        await manager.syncNow()
        #expect(docs.appState.comments.map(\.commentText) == ["From Drive"])
        #expect(manager.unsyncedSince != nil)
        #expect(manager.issue == nil)

        // Pass 2: Google Drive FileProvider confirms upload completed.
        stub.uploaded = true
        await manager.syncNow()
        #expect(manager.unsyncedSince == nil)
        #expect(manager.health == .ok)
    }

    @Test func blobCleanupRunsAfterPublishRespectsThrottleAndSkipsWhenAnyDeviceIsUnreadable() async throws {
        final class ClockBox: @unchecked Sendable {
            var now: Date
            init(_ now: Date) { self.now = now }
        }
        func writeBlob(_ bytes: Data, to layout: SyncLayout, dated date: Date) throws -> String {
            let digest = SyncIO.digest(bytes)
            let url = layout.blob(digest)
            try bytes.write(to: url)
            try FileManager.default.setAttributes([.creationDate: date, .modificationDate: date], ofItemAtPath: url.path)
            return digest
        }

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BlobCleanup-\(UUID())")
        let cloud = root.appendingPathComponent("cloud")
        try FileManager.default.createDirectory(at: cloud, withIntermediateDirectories: true)
        let domain = "BlobCleanup.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer {
            defaults.removePersistentDomain(forName: domain)
            try? FileManager.default.removeItem(at: root)
        }

        let t0 = Date()
        let fiveDaysAgo = t0.addingTimeInterval(-5 * 24 * 60 * 60)
        let oneDayAgo = t0.addingTimeInterval(-24 * 60 * 60)
        let clock = ClockBox(t0)

        let session = Session(name: "Project")
        let localImagePath = "images/\(UUID().uuidString).png"
        try FileManager.default.createDirectory(at: root.appendingPathComponent("images"), withIntermediateDirectories: true)
        let localImageBytes = Data("local-referenced-image".utf8)
        try localImageBytes.write(to: root.appendingPathComponent(localImagePath))
        let localComment = Comment(type: .screenshot(imagePath: localImagePath), commentText: "Local", source: "test",
                                   appBundleID: nil, sessionID: session.id)
        let docs = Documents(AppState(sessions: [session], comments: [localComment]))
        let manager = CloudSyncManager(documents: docs, root: root, defaults: defaults,
                                       connect: { _ in cloud }, now: { clock.now })
        defer { manager.disable() }

        let layout = SyncLayout(folder: cloud)
        try layout.prepare()

        let oldUnusedDigest = try writeBlob(Data("old-unused".utf8), to: layout, dated: fiveDaysAgo)
        let freshUnusedDigest = try writeBlob(Data("fresh-unused".utf8), to: layout, dated: oneDayAgo)
        let localImageDigest = try writeBlob(localImageBytes, to: layout, dated: fiveDaysAgo)
        let remoteImagePath = "images/\(UUID().uuidString).png"
        let remoteImageBytes = Data("remote-referenced-image".utf8)
        let remoteImageDigest = try writeBlob(remoteImageBytes, to: layout, dated: fiveDaysAgo)

        let remoteComment = Comment(type: .screenshot(imagePath: remoteImagePath), commentText: "Remote", source: "test",
                                    appBundleID: nil, sessionID: session.id)
        let readableRemote = SyncDeviceFile(deviceID: UUID(), deviceName: "Office", writtenAt: t0,
                                            state: AppState(sessions: [session], comments: [remoteComment]),
                                            assets: [remoteImagePath: remoteImageDigest])
        try SyncCloud.write(readableRemote, layout: layout)

        // With a newer-format or corrupt device file present, cleanup must skip completely.
        let newerID = UUID()
        var newer = readableRemote
        newer.deviceID = newerID
        newer.formatVersion = SyncDeviceFile.currentFormat + 1
        try SyncCloud.write(newer, layout: layout)

        manager.enable()
        await manager.syncNow()
        #expect(FileManager.default.fileExists(atPath: layout.blob(oldUnusedDigest).path))
        #expect(try SyncLocalStore.loadRecord(in: root).lastBlobCleanupAt == nil)

        // Corrupt device file also blocks cleanup.
        try Data("corrupt json".utf8).write(to: layout.deviceFile(newerID))
        await manager.syncNow()
        #expect(FileManager.default.fileExists(atPath: layout.blob(oldUnusedDigest).path))
        #expect(try SyncLocalStore.loadRecord(in: root).lastBlobCleanupAt == nil)

        // Removing the unreadable device lets the first full pass clean old unreferenced blobs only.
        try FileManager.default.removeItem(at: layout.deviceFile(newerID))
        await manager.syncNow()
        #expect(!FileManager.default.fileExists(atPath: layout.blob(oldUnusedDigest).path))
        #expect(FileManager.default.fileExists(atPath: layout.blob(freshUnusedDigest).path))
        #expect(FileManager.default.fileExists(atPath: layout.blob(localImageDigest).path))
        #expect(FileManager.default.fileExists(atPath: layout.blob(remoteImageDigest).path))
        #expect(try SyncLocalStore.loadRecord(in: root).lastBlobCleanupAt == t0)

        // Within 24 hours, cleanup is throttled.
        clock.now = t0.addingTimeInterval(12 * 60 * 60)
        let secondOldDigest = try writeBlob(Data("second-old-unused".utf8), to: layout, dated: fiveDaysAgo)
        await manager.syncNow()
        #expect(FileManager.default.fileExists(atPath: layout.blob(secondOldDigest).path))
        #expect(try SyncLocalStore.loadRecord(in: root).lastBlobCleanupAt == t0)

        // After 24 hours, cleanup runs again and deletes the new expired orphan.
        let nextRun = t0.addingTimeInterval(25 * 60 * 60)
        clock.now = nextRun
        await manager.syncNow()
        #expect(!FileManager.default.fileExists(atPath: layout.blob(secondOldDigest).path))
        #expect(try SyncLocalStore.loadRecord(in: root).lastBlobCleanupAt == nextRun)
    }
}

@Suite("Google Drive and local folder storage", .serialized)
final class LocalFolderStorageTests {
    private let tempRoot: URL
    private let fakeHome: URL
    private let fakeAppSupport: URL

    init() throws {
        tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent("RemarcLocalFolder-\(UUID())")
        fakeHome = tempRoot.appendingPathComponent("home", isDirectory: true)
        fakeAppSupport = AppIdentity.production.appSupportURL(in: fakeHome)
        try FileManager.default.createDirectory(at: fakeHome, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: fakeAppSupport, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: tempRoot) }

    @Test func channelSubfolderIsCreatedAndReusedWithoutDoubleNesting() throws {
        let base = tempRoot.appendingPathComponent("Syncthing", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: false)

        let prodFolder = try LocalFolderLocation.connect(base: base, createIfMissing: true, verifyWriteAccess: true,
                                                         channel: .production, home: fakeHome, appSupportRoot: fakeAppSupport)
        #expect(prodFolder.standardizedFileURL.path == base.appendingPathComponent("JotBaton").standardizedFileURL.path)

        // Selecting the JotBaton folder directly does not nest JotBaton/JotBaton.
        let direct = try LocalFolderLocation.resolveSyncFolder(base: prodFolder, channel: .production,
                                                               home: fakeHome, appSupportRoot: fakeAppSupport)
        #expect(direct.standardizedFileURL.path == prodFolder.standardizedFileURL.path)

        // Development gets its own sibling JotBaton Dev folder in the same base.
        let devFolder = try LocalFolderLocation.connect(base: base, createIfMissing: true, verifyWriteAccess: true,
                                                        channel: .development, home: fakeHome, appSupportRoot: fakeAppSupport)
        #expect(devFolder.standardizedFileURL.path == base.appendingPathComponent("JotBaton Dev").standardizedFileURL.path)
    }

    @Test func rejectsCrossChannelFoldersSymlinksICloudAndAppSupport() throws {
        let base = tempRoot.appendingPathComponent("Shared", isDirectory: true)
        let prodDir = base.appendingPathComponent("JotBaton", isDirectory: true)
        let devDir = base.appendingPathComponent("JotBaton Dev", isDirectory: true)
        let iCloudDir = CloudSyncLocation.root(in: fakeHome)
        let symlinkDir = tempRoot.appendingPathComponent("Link", isDirectory: true)
        try FileManager.default.createDirectory(at: prodDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: devDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: iCloudDir, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: symlinkDir, withDestinationURL: base)

        // Cross-channel rejection
        #expect(throws: (any Error).self) {
            try LocalFolderLocation.resolveSyncFolder(base: devDir, channel: .production, home: fakeHome, appSupportRoot: fakeAppSupport)
        }
        #expect(throws: (any Error).self) {
            try LocalFolderLocation.resolveSyncFolder(base: prodDir, channel: .development, home: fakeHome, appSupportRoot: fakeAppSupport)
        }
        // Symlink rejection
        #expect(throws: (any Error).self) {
            try LocalFolderLocation.resolveSyncFolder(base: symlinkDir, channel: .production, home: fakeHome, appSupportRoot: fakeAppSupport)
        }
        // iCloud Drive root rejection
        #expect(throws: (any Error).self) {
            try LocalFolderLocation.resolveSyncFolder(base: iCloudDir, channel: .production, home: fakeHome, appSupportRoot: fakeAppSupport)
        }
        // App Support local data folder rejection
        #expect(throws: (any Error).self) {
            try LocalFolderLocation.resolveSyncFolder(base: fakeAppSupport, channel: .production, home: fakeHome, appSupportRoot: fakeAppSupport)
        }
    }

    @Test func detectsGoogleDriveUnderCloudStorage() throws {
        let gdriveRoot = fakeHome.appendingPathComponent("Library/CloudStorage/GoogleDrive-user@example.com", isDirectory: true)
        let myDrive = gdriveRoot.appendingPathComponent("My Drive", isDirectory: true)
        let nested = myDrive.appendingPathComponent("Sync/JotBaton", isDirectory: true)
        let syncthing = fakeHome.appendingPathComponent("Syncthing/JotBaton", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: syncthing, withIntermediateDirectories: true)

        #expect(LocalFolderLocation.isGoogleDriveFolder(nested, home: fakeHome))
        #expect(LocalFolderLocation.isCloudStorageFolder(nested, home: fakeHome))
        #expect(!LocalFolderLocation.isGoogleDriveFolder(syncthing, home: fakeHome))
        #expect(!LocalFolderLocation.isCloudStorageFolder(syncthing, home: fakeHome))

        let detected = LocalFolderLocation.detectedGoogleDriveFolders(home: fakeHome)
        #expect(detected.map { $0.standardizedFileURL.path } == [myDrive.standardizedFileURL.path])
    }

    @Test func cloudFileStatusHandlesGoogleDriveFileProviderAndSyncthingCorrectly() throws {
        var downloadsStarted = 0

        // Google Drive FileProvider dehydrated file (.notDownloaded) triggers download without blocking.
        let gdriveNotDownloaded = CloudItemState(exists: true, isUbiquitous: true, downloadingStatus: .notDownloaded)
        #expect(CloudFileStatus.availability(for: gdriveNotDownloaded) { downloadsStarted += 1 } == .downloading)
        #expect(downloadsStarted == 1)

        // APFS SF_DATALESS safety net catches dataless placeholders even if ubiquitous status is absent.
        let dataless = CloudItemState(exists: true, isUbiquitous: false, isDataless: true)
        #expect(CloudFileStatus.availability(for: dataless) { downloadsStarted += 1 } == .downloading)
        #expect(downloadsStarted == 2)

        // Downloaded stale copy stays readable while requesting an update.
        let staleLocal = CloudItemState(exists: true, isUbiquitous: true, downloadingStatus: .downloaded)
        #expect(CloudFileStatus.availability(for: staleLocal) { downloadsStarted += 1 } == .ready)
        #expect(downloadsStarted == 3)

        // Current Google Drive file needs no download trigger.
        let current = CloudItemState(exists: true, isUbiquitous: true, downloadingStatus: .current, isUploaded: true)
        #expect(CloudFileStatus.availability(for: current) { downloadsStarted += 1 } == .ready)
        #expect(downloadsStarted == 3)
        #expect(try CloudFileStatus.uploadState(for: current) == true)

        // Google Drive upload in progress reports false; quota error throws.
        #expect(try CloudFileStatus.uploadState(for: CloudItemState(exists: true, isUbiquitous: true, isUploaded: false)) == false)
        let quotaError = NSError(domain: "NSFileProviderErrorDomain", code: -1003)
        #expect(throws: (any Error).self) {
            _ = try CloudFileStatus.uploadState(for: CloudItemState(exists: true, isUbiquitous: true, isUploaded: false, uploadingError: quotaError))
        }

        // Syncthing / plain local folder is ready immediately and does not report cloud upload state.
        let syncthing = CloudItemState(exists: true, isUbiquitous: false, isDataless: false)
        #expect(CloudFileStatus.availability(for: syncthing) { downloadsStarted += 1 } == .ready)
        #expect(downloadsStarted == 3)
        #expect(try CloudFileStatus.uploadState(for: syncthing) == nil)
    }

    @Test func providerAwareIssuesAndHealthTitlesAvoidICloudCopyForGoogleDrive() {
        let quota = CloudSyncIssue.make(NSError(domain: "NSFileProviderErrorDomain", code: -1003),
                                        stage: .publishing, providerKind: .localFolder)
        #expect(quota.kind == .quota)
        #expect(!quota.message.contains("iCloud"))

        let perm = CloudSyncIssue.make(NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES)),
                                       stage: .connection, providerKind: .localFolder)
        #expect(perm.kind == .permission && !perm.message.contains("iCloud"))

        let waitingTitle = SyncHealth.waiting(count: 2).title(providerKind: .localFolder, providerName: "Google Drive")
        #expect(waitingTitle.contains("Google Drive") && !waitingTitle.contains("iCloud"))
        let unsyncedTitle = SyncHealth.attention(.unsynced(since: Date())).title(providerKind: .localFolder, providerName: "Google Drive")
        #expect(unsyncedTitle.contains("Google Drive") && !unsyncedTitle.contains("iCloud"))
    }
}
