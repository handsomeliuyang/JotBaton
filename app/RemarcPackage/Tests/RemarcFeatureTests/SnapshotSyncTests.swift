import Foundation
import AppKit
import Testing
@testable import RemarcFeature

@Suite(.serialized)
final class SnapshotSyncTests {
    private let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("RemarcSnapshotTests-\(UUID())")
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("images"), withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    private func state() -> AppState {
        let session = Session(name: "Office work")
        let comment = Comment(type: .quickNote, commentText: "From office", source: "test", appBundleID: nil, sessionID: session.id)
        return AppState(sessions: [session], comments: [comment], activeSessionID: session.id, totalCommentsCreated: 1)
    }

    private func makeVersion(_ prepared: SnapshotArchive.Prepared) throws -> SnapshotVersion {
        try SnapshotArchive.create(prepared, in: directory, deviceID: UUID(), deviceName: "Office Mac")
    }

    private func publishForTest(_ version: SnapshotVersion, from archive: URL, to cloud: URL) throws {
        let previous = try SnapshotDisk.current(in: cloud)
        try SnapshotDisk.stageArchive(version, from: archive, to: cloud)
        try SnapshotDisk.commitCurrent(version, replacing: previous?.id, in: cloud)
    }

    /// Build a current-format wire fixture without the receiving OS re-encoding it.
    private func wireVersion(stateData: Data, contentHash: String? = nil) throws -> SnapshotVersion {
        let stage = directory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: stage) }
        let inventoryData = Data("{}".utf8)
        try stateData.write(to: stage.appendingPathComponent("state.json"))
        try inventoryData.write(to: stage.appendingPathComponent("inventory.json"))
        let id = UUID()
        let archiveName = SnapshotArchive.filename(date: Date(), deviceName: "Ventura", id: id)
        let archive = directory.appendingPathComponent(archiveName)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--norsrc", stage.path, archive.path]
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        var identity = stateData
        identity.append(inventoryData)
        return SnapshotVersion(formatVersion: 2, id: id, deviceID: UUID(),
            deviceName: "Ventura Mac", createdAt: Date(), commentCount: 1, imageCount: 0,
            contentHash: contentHash ?? SnapshotArchive.digest(identity), archiveHash: try SnapshotArchive.fileDigest(archive),
            archiveName: archiveName)
    }

    @Test func testVenturaNumberSpellingVerifiesOriginalBytesAndTracksLocalFingerprint() throws {
        var original = state()
        original.comments[0].updatedAt = Date(timeIntervalSinceReferenceDate: 815627460.203401)
        let prepared = try SnapshotArchive.prepare(original, root: directory)
        let localJSON = String(decoding: try SnapshotArchive.encode(prepared.state), as: UTF8.self)
        // Both spellings denote the same IEEE-754 value. Ventura emitted the
        // longer spelling in the real office snapshot that failed to apply.
        let localNumber = String(decoding: try SnapshotArchive.encode(original.comments[0].updatedAt), as: UTF8.self)
        for spelling in ["815627460.20340097", "815627460.203401"] {
            let sourceData = Data(localJSON.replacingOccurrences(of: localNumber, with: spelling).utf8)
            let version = try wireVersion(stateData: sourceData)
            let restored = try SnapshotArchive.read(version, archive: directory.appendingPathComponent(version.archiveName))
            #expect(restored.state == prepared.state)
            #expect(restored.hash == prepared.hash)
            let installed = try SnapshotArchive.installFiles(restored, root: directory)
            #expect(try SnapshotArchive.prepare(installed.state, root: directory).hash == restored.hash)
            #expect(SnapshotComparison.compare(localTime: version.createdAt, cloud: version,
                baselineID: version.id, baselineLocalTime: version.createdAt,
                baselineCloudTime: version.createdAt) == .same)
        }
    }

    @Test func testContentHashMismatchIsRejectedEvenWithMatchingArchiveHash() throws {
        let prepared = try SnapshotArchive.prepare(state(), root: directory)
        var changed = prepared.state
        changed.comments[0].commentText = "changed after the content hash was recorded"
        let version = try wireVersion(stateData: SnapshotArchive.encode(changed), contentHash: prepared.hash)
        #expect(throws: (any Error).self) {
            try SnapshotArchive.read(version, archive: directory.appendingPathComponent(version.archiveName))
        }
    }

    @Test func testPinnedProjectSurvivesSnapshotAndChangesItsContentHash() throws {
        let original = state()
        let before = try SnapshotArchive.prepare(original, root: directory)
        var pinned = original
        pinned.sessions[0].isPinned = true
        pinned.sessions[0].emptySince = Date(timeIntervalSinceReferenceDate: 1)
        let prepared = try SnapshotArchive.prepare(pinned, root: directory)
        #expect(prepared.hash != before.hash)
        let version = try makeVersion(prepared)
        let restored = try SnapshotArchive.read(version, archive: directory.appendingPathComponent(version.archiveName))
        #expect(restored.state.sessions[0].isPinned)
        #expect(restored.state.sessions[0].emptySince == nil)
        let installed = try SnapshotArchive.installFiles(restored, root: directory)
        #expect(installed.state.sessions[0].isPinned)
        #expect(try SnapshotArchive.prepare(installed.state, root: directory).hash == prepared.hash)
    }

    @Test func testTimestampBaselineSurvivesChecksAndDetectsBothDirections() throws {
        var cloud = try makeVersion(SnapshotArchive.prepare(state(), root: directory))
        let baseline = Date(timeIntervalSince1970: 100)
        cloud.contentModifiedAt = baseline
        func compare(_ local: Date?, id: UUID? = nil, saved: Date? = nil) -> SnapshotComparison {
            SnapshotComparison.compare(localTime: local, cloud: cloud, baselineID: id,
                baselineLocalTime: saved, baselineCloudTime: baseline)
        }
        #expect(compare(baseline, id: cloud.id, saved: baseline) == .same)
        #expect(compare(baseline.addingTimeInterval(1), id: cloud.id, saved: baseline) == .publish)
        #expect(compare(baseline, id: UUID(), saved: baseline) == .same)
        #expect(compare(baseline.addingTimeInterval(-1), id: UUID(), saved: baseline) == .choose)
        #expect(compare(baseline) == .same)
        #expect(compare(baseline.addingTimeInterval(1)) == .choose)
        #expect(compare(nil, id: cloud.id, saved: baseline) == .choose)
        cloud.contentModifiedAt = baseline.addingTimeInterval(1)
        #expect(compare(baseline, id: UUID(), saved: baseline) == .receive)
    }

    @Test func testMatchingContentClocksDisableActionsDespiteAnOlderReceipt() throws {
        var cloud = try makeVersion(SnapshotArchive.prepare(state(), root: directory))
        let previous = Date(timeIntervalSince1970: 100)
        let current = previous.addingTimeInterval(10)
        cloud.contentModifiedAt = current
        let comparison = SnapshotComparison.compare(localTime: current, cloud: cloud,
            baselineID: UUID(), baselineLocalTime: previous, baselineCloudTime: previous)
        #expect(comparison == .same)
        let actions = SnapshotActionAvailability(enabled: true, busy: false, connected: true,
            checked: true, localReady: true, hasIssue: false, pending: false,
            transfer: .ready, comparison: comparison, hasCloud: true)
        #expect(!actions.canPublish)
        #expect(!actions.canApply)
    }

    @Test func testCompleteSnapshotRoundTripIncludesDeletionAndEditableImages() throws {
        let image = directory.appendingPathComponent("external.png")
        try Data("rendered png".utf8).write(to: image)
        try Data("redacted base".utf8).write(to: directory.appendingPathComponent("external.base.png"))
        try Data("vector marks".utf8).write(to: directory.appendingPathComponent("external.marks.json"))
        var original = state()
        original.comments[0].type = .screenshot(imagePath: image.path)
        original.comments[0].attachments = [image.path]
        original.comments[0].isDeleted = true
        original.comments[0].customTitle = "Office review"
        original.comments[0].deletedAt = Date()
        let prepared = try SnapshotArchive.prepare(original, root: directory)
        let version = try makeVersion(prepared)
        let restored = try SnapshotArchive.read(version, archive: directory.appendingPathComponent(version.archiveName))
        #expect(restored.state.comments[0].isDeleted)
        #expect(restored.state.comments[0].customTitle == "Office review")
        #expect(restored.state.comments[0].deletedAt == original.comments[0].deletedAt)
        #expect(restored.files.count == 3)
        #expect(restored.state.comments[0].type.imagePath == restored.state.comments[0].attachments.first)
        #expect(try #require(restored.state.comments[0].type.imagePath).hasPrefix("images/"))
        #expect(restored.hash == prepared.hash)
        let installed = try SnapshotArchive.installFiles(restored, root: directory)
        #expect(try SnapshotArchive.prepare(installed.state, root: directory).hash == prepared.hash, "Applying on another Mac must not immediately mark the content dirty")
    }

    @Test func testLocalSelectionAndAgentBindingDoNotChangeFingerprint() throws {
        var original = state()
        let first = try SnapshotArchive.prepare(original, root: directory)
        original.activeSessionID = nil
        original.sessions[0].claudeCodeSessionId = "process-on-another-mac"
        original.comments[0].wakeRequestedAt = Date()
        original.unknownFields["_snapshotReceipt"] = .string("local bookkeeping")
        original.unknownFields["_snapshotContentStamp"] = .string("local clock")
        original.unknownFields[SnapshotRollbackStore.key] = .string("local undo")
        #expect(try first.hash == SnapshotArchive.prepare(original, root: directory).hash)
        original.comments[0].commentText = "edited"
        #expect(try first.hash != SnapshotArchive.prepare(original, root: directory).hash)
    }

    @Test func testContentTimeSurvivesArchiveAndMetadata() throws {
        let prepared = try SnapshotArchive.prepare(state(), root: directory)
        let time = Date(timeIntervalSince1970: 123456)
        let version = try SnapshotArchive.create(prepared, in: directory, deviceID: UUID(), deviceName: "Office", contentModifiedAt: time)
        let decoded = try JSONDecoder().decode(SnapshotVersion.self, from: SnapshotArchive.encode(version))
        #expect(decoded.contentModifiedAt == time)
        #expect(try SnapshotArchive.read(decoded, archive: directory.appendingPathComponent(version.archiveName)).hash == prepared.hash)
        var json = try #require(JSONSerialization.jsonObject(with: SnapshotArchive.encode(version)) as? [String: Any])
        json.removeValue(forKey: "contentModifiedAt")
        #expect(try JSONDecoder().decode(SnapshotVersion.self, from: JSONSerialization.data(withJSONObject: json)).contentModifiedAt == nil)
    }

    @Test func testContentClockPersistsAndIgnoresSelectionAndSyncBookkeeping() throws {
        var original = state()
        let time = Date(timeIntervalSince1970: 100)
        original.markSnapshotDataChanged(at: time)
        let restored = try JSONDecoder().decode(AppState.self, from: JSONEncoder().encode(original))
        #expect(restored.snapshotDataUpdatedAt == time)
        var selected = restored
        selected.activeSessionID = nil
        selected.unknownFields["_snapshotReceipt"] = .string("bookkeeping")
        let merged = AppStateMerge.merge(base: restored, ours: restored, theirs: selected)
        #expect(merged.snapshotDataUpdatedAt == time)
        var edited = restored
        edited.markSnapshotDataChanged(at: time.addingTimeInterval(-20))
        #expect(try #require(edited.snapshotDataUpdatedAt) > time)
    }

    @Test func testLegacyExternalEditsAndConcurrentClocksAreRecorded() throws {
        var original = state()
        let time = Date(timeIntervalSince1970: 100)
        original.snapshotDataUpdatedAt = time
        var external = original
        external.sessions[0].isPinned = true
        let changed = AppStateMerge.merge(base: original, ours: original, theirs: external)
        #expect(try #require(changed.snapshotDataUpdatedAt) > time)
        var own = original
        own.snapshotDataUpdatedAt = time.addingTimeInterval(10)
        external.snapshotDataUpdatedAt = time.addingTimeInterval(20)
        #expect(AppStateMerge.merge(base: original, ours: own, theirs: external).snapshotDataUpdatedAt == external.snapshotDataUpdatedAt)
    }

    @Test func testReceiptKeepsTheCapturedClockWhileLaterEditsRemainPending() throws {
        let time = Date(timeIntervalSince1970: 100)
        let version = try SnapshotArchive.create(SnapshotArchive.prepare(state(), root: directory),
            in: directory, deviceID: UUID(), deviceName: "Mac", contentModifiedAt: time)
        let receipt = SnapshotReceipt(version: version, contentHash: "integrity only", localUpdatedAt: time)
        let reloaded = try JSONDecoder().decode(SnapshotReceipt.self, from: JSONEncoder().encode(receipt))
        #expect(SnapshotComparison.compare(localTime: time, cloud: version, baselineID: reloaded.version.id,
            baselineLocalTime: reloaded.localUpdatedAt, baselineCloudTime: version.contentModifiedAt) == .same)
        #expect(SnapshotComparison.compare(localTime: time.addingTimeInterval(1), cloud: version, baselineID: reloaded.version.id,
            baselineLocalTime: reloaded.localUpdatedAt, baselineCloudTime: version.contentModifiedAt) == .publish)
    }

    @Test func testTimestampComparisonDoesNotTreatLaterClocksAsSafeOverrides() throws {
        var cloud = try makeVersion(SnapshotArchive.prepare(state(), root: directory))
        let synced = Date(timeIntervalSince1970: 10)
        cloud.contentModifiedAt = Date(timeIntervalSince1970: 20)
        #expect(SnapshotComparison.compare(localTime: Date(timeIntervalSince1970: 30), cloud: cloud,
            baselineID: UUID(), baselineLocalTime: synced, baselineCloudTime: synced) == .choose)
        #expect(SnapshotComparison.compare(localTime: synced, cloud: cloud,
            baselineID: UUID(), baselineLocalTime: synced, baselineCloudTime: synced) == .receive)
        #expect(SnapshotComparison.compare(localTime: synced, cloud: nil,
            baselineID: nil, baselineLocalTime: nil, baselineCloudTime: nil) == .publish)
        cloud.contentModifiedAt = nil
        #expect(SnapshotComparison.compare(localTime: cloud.createdAt, cloud: cloud,
            baselineID: cloud.id, baselineLocalTime: cloud.createdAt,
            baselineCloudTime: cloud.createdAt) == .same)
    }

    @Test func testAbsoluteAndRelativeImageLocationsProduceTheSameContentIdentity() throws {
        var original = state()
        let name = "\(UUID()).png"
        let url = directory.appendingPathComponent("images/\(name)")
        try Data("png".utf8).write(to: url)
        original.comments[0].type = .screenshot(imagePath: url.path)
        let absolute = try SnapshotArchive.prepare(original, root: directory)
        original.comments[0].type = .screenshot(imagePath: "images/\(name)")
        #expect(try absolute.hash == SnapshotArchive.prepare(original, root: directory).hash)
    }

    @Test func testUnavailableLiveAttachmentPreventsPublishing() {
        var original = state()
        original.comments[0].attachments = ["images/\(UUID()).png"]
        #expect(throws: (any Error).self) { try SnapshotArchive.prepare(original, root: directory) }
    }

    @Test func testMissingDeletedImageHasAStablePortablePath() throws {
        var original = state()
        original.comments[0].isDeleted = true
        original.comments[0].type = .screenshot(imagePath: "/no-longer-present/image.png")
        let prepared = try SnapshotArchive.prepare(original, root: directory)
        #expect(try prepared.hash == SnapshotArchive.prepare(prepared.state, root: directory).hash)
        let version = try makeVersion(prepared)
        #expect(throws: Never.self) { try SnapshotArchive.read(version, archive: directory.appendingPathComponent(version.archiveName)) }
    }

    @Test func testCorruptArchiveIsRefusedBeforeLocalDataChanges() throws {
        let prepared = try SnapshotArchive.prepare(state(), root: directory)
        let version = try makeVersion(prepared)
        let archive = directory.appendingPathComponent(version.archiveName)
        try Data("truncated".utf8).write(to: archive)
        #expect(throws: (any Error).self) { try SnapshotArchive.read(version, archive: archive) }
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("images").path))
    }

    @Test func testPublishedArchiveCanBeDiscoveredAndAppliedFromAnotherDirectory() throws {
        let prepared = try SnapshotArchive.prepare(state(), root: directory)
        let version = try makeVersion(prepared)
        let cloud = directory.appendingPathComponent("cloud")
        try FileManager.default.createDirectory(at: cloud, withIntermediateDirectories: true)
        try publishForTest(version, from: directory.appendingPathComponent(version.archiveName), to: cloud)
        #expect(try SnapshotDisk.current(in: cloud)?.id == version.id)
        let downloaded = directory.appendingPathComponent("downloaded.zip")
        try SnapshotDisk.download(version, from: cloud, to: downloaded)
        #expect(try SnapshotArchive.read(version, archive: downloaded).hash == prepared.hash)
    }

    @Test func testWholeReplacementRemovesLocalOnlyTasksAndDoesNotMergeThemBack() throws {
        let local = state()
        var remote = state()
        remote.comments[0].isDeleted = true
        let file = directory.appendingPathComponent("comments.json")
        try SnapshotArchive.encode(local).write(to: file)
        try SnapshotReplacement.commit(remote, expected: local, fileURL: file)
        let stored = try JSONDecoder().decode(AppState.self, from: Data(contentsOf: file))
        #expect(stored == remote)
        #expect(!(stored.comments.contains { $0.id == local.comments[0].id }))
        var edited = stored
        edited.comments[0].commentText = "next edit"
        let saved = AppStateMerge.merge(base: stored, ours: edited, theirs: stored)
        #expect(saved.comments.count == 1)
        #expect(saved.comments[0].isDeleted)
    }

    @Test func testIntegrationWriteDuringPreparationPreventsReplacement() throws {
        let baseline = state()
        var newer = baseline
        newer.comments[0].commentText = "integration edit"
        let file = directory.appendingPathComponent("comments.json")
        try SnapshotArchive.encode(newer).write(to: file)
        #expect(throws: (any Error).self) { try SnapshotReplacement.commit(state(), expected: baseline, fileURL: file) }
        #expect(try JSONDecoder().decode(AppState.self, from: Data(contentsOf: file)) == newer)
    }

    @Test func testInstallingAnOlderImageNeverOverwritesTheCurrentlyEditedFile() throws {
        var original = state()
        let path = "images/\(UUID()).png"
        let source = directory.appendingPathComponent(path)
        try Data("old image".utf8).write(to: source)
        original.comments[0].type = .screenshot(imagePath: path)
        let prepared = try SnapshotArchive.prepare(original, root: directory)
        try Data("edited image".utf8).write(to: source)
        let installed = try SnapshotArchive.installFiles(prepared, root: directory)
        #expect(try Data(contentsOf: source) == Data("edited image".utf8))
        #expect(installed.state.comments[0].type.imagePath != path)
        #expect(try SnapshotArchive.prepare(installed.state, root: directory).hash == prepared.hash)
    }

    private func cloudFacts(root: URL) -> (URL) throws -> SnapshotCloudLocation.Facts {
        { url in
            let actual = try SnapshotCloudLocation.inspect(url)
            return SnapshotCloudLocation.Facts(isDirectory: actual.isDirectory,
                isCloudItem: url == root, isSymbolicLink: actual.isSymbolicLink)
        }
    }

    @Test func testFixedLocationUsesEachUsersHomeAndTheSameRelativeFolder() {
        let first = SnapshotCloudLocation.root(in: URL(fileURLWithPath: "/Users/office"))
        let second = SnapshotCloudLocation.root(in: URL(fileURLWithPath: "/Users/home"))
        #expect(first.path == "/Users/office/Library/Mobile Documents/com~apple~CloudDocs")
        #expect(second.path == "/Users/home/Library/Mobile Documents/com~apple~CloudDocs")
    }

    @Test func testMissingCloudRootIsNeverCreatedEvenAfterEnable() {
        let absent = directory.appendingPathComponent("missing/CloudDocs")
        #expect(throws: (any Error).self) {
            try SnapshotCloudLocation.connect(root: absent, createIfMissing: true)
        }
        #expect(!FileManager.default.fileExists(atPath: absent.deletingLastPathComponent().path))
    }

    @Test func testOrdinaryLocalDirectoryCannotPretendToBeICloud() {
        #expect(throws: (any Error).self) {
            try SnapshotCloudLocation.connect(root: directory, createIfMissing: true)
        }
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("Remarc").path))
    }

    @Test func testCheckingDoesNotCreateTheSnapshotFolderWithoutConsent() {
        #expect(throws: (any Error).self) {
            try SnapshotCloudLocation.connect(root: directory, inspect: cloudFacts(root: directory))
        }
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("Remarc").path))
    }

    @Test func testEnablingCreatesOnlyTheFixedChildAndCleansUpTheProbe() throws {
        let folder = try SnapshotCloudLocation.connect(root: directory, createIfMissing: true,
                                                       inspect: cloudFacts(root: directory))
        #expect(folder.path == directory.appendingPathComponent("Remarc").path)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
    }

    @Test func testExistingCloudSnapshotsAreReusedWithoutOverwriting() throws {
        let folder = directory.appendingPathComponent("Remarc")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let existing = folder.appendingPathComponent("existing-snapshot.zip")
        try Data("existing cloud data".utf8).write(to: existing)
        let result = try SnapshotCloudLocation.connect(root: directory, createIfMissing: true,
                                                       inspect: cloudFacts(root: directory))
        #expect(result.path == folder.path)
        #expect(try Data(contentsOf: existing) == Data("existing cloud data".utf8))
    }

    @Test func testFixedChildCannotRedirectToAnotherDirectoryThroughASymlink() throws {
        let outside = directory.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("Remarc"), withDestinationURL: outside)
        #expect(throws: (any Error).self) {
            try SnapshotCloudLocation.connect(root: directory, createIfMissing: true,
                                               inspect: cloudFacts(root: directory))
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
    }

    @Test func testAuthorizationCannotSelectADifferentSyncLocation() {
        #expect(SnapshotCloudLocation.isAuthorizationLocation(directory, root: directory))
        #expect(SnapshotCloudLocation.isAuthorizationLocation(directory.appendingPathComponent("Remarc"), root: directory))
        #expect(!SnapshotCloudLocation.isAuthorizationLocation(directory.appendingPathComponent("Other"), root: directory))
    }
    @Test func testStagingTheSamePayloadDoesNotDuplicateFiles() throws {
        let prepared = try SnapshotArchive.prepare(state(), root: directory)
        let version = try makeVersion(prepared)
        let cloud = directory.appendingPathComponent("retry-cloud")
        try FileManager.default.createDirectory(at: cloud, withIntermediateDirectories: true)
        let archive = directory.appendingPathComponent(version.archiveName)
        try publishForTest(version, from: archive, to: cloud)
        try publishForTest(version, from: archive, to: cloud)
        #expect(try SnapshotDisk.current(in: cloud)?.id == version.id)
        #expect(try FileManager.default.contentsOfDirectory(atPath: cloud.path).count == 2)
    }

    @Test func testRetryDoesNotOverwriteADifferentCloudArchive() throws {
        let prepared = try SnapshotArchive.prepare(state(), root: directory)
        let version = try makeVersion(prepared)
        let cloud = directory.appendingPathComponent("different-cloud")
        try FileManager.default.createDirectory(at: cloud, withIntermediateDirectories: true)
        let target = cloud.appendingPathComponent(version.archiveName)
        try Data("different content".utf8).write(to: target)
        #expect(throws: (any Error).self) {
            try publishForTest(version, from: directory.appendingPathComponent(version.archiveName), to: cloud)
        }
        #expect(try Data(contentsOf: target) == Data("different content".utf8))
    }

    @Test func testStagedPayloadIsNotCurrentUntilCommitted() throws {
        let prepared = try SnapshotArchive.prepare(state(), root: directory)
        let version = try makeVersion(prepared)
        let cloud = directory.appendingPathComponent("partial-cloud")
        try FileManager.default.createDirectory(at: cloud, withIntermediateDirectories: true)
        let archive = directory.appendingPathComponent(version.archiveName)
        try SnapshotDisk.stageArchive(version, from: archive, to: cloud)
        #expect(try SnapshotDisk.current(in: cloud) == nil)
        try SnapshotDisk.commitCurrent(version, replacing: nil, in: cloud)
        #expect(try SnapshotDisk.current(in: cloud)?.id == version.id)
    }

    @Test func testBothCloudFilesMustConfirmUpload() throws {
        let complete = SnapshotDisk.UploadEvidence(isCloudItem: true, isUploaded: true, error: nil)
        let pending = SnapshotDisk.UploadEvidence(isCloudItem: true, isUploaded: false, error: nil)
        #expect(try SnapshotDisk.uploadState(from: [complete, pending]) == .uploading)
        #expect(try SnapshotDisk.uploadState(from: [complete, complete]) == .uploaded)
        #expect(try SnapshotDisk.uploadState(from: [complete]) == .unknown)
    }

    @Test func testMissingMetadataIsUnconfirmedRatherThanSuccess() throws {
        let unknown = SnapshotDisk.UploadEvidence(isCloudItem: true, isUploaded: nil, error: nil)
        let local = SnapshotDisk.UploadEvidence(isCloudItem: false, isUploaded: false, error: nil)
        #expect(try SnapshotDisk.uploadState(from: [unknown, unknown]) == .unknown)
        #expect(try SnapshotDisk.uploadState(from: [local, local]) == .unknown)
    }

    @Test func testConfirmedUploadsIgnoreAStaleProviderError() throws {
        let stale = NSError(domain: NSCocoaErrorDomain, code: NSUbiquitousFileUbiquityServerNotAvailable)
        let complete = SnapshotDisk.UploadEvidence(isCloudItem: true, isUploaded: true, error: stale)
        #expect(try SnapshotDisk.uploadState(from: [complete, complete]) == .uploaded)
    }

    @Test func testServerFailureIsNotMisclassifiedAsFilePermission() {
        let error = NSError(domain: NSCocoaErrorDomain, code: NSUbiquitousFileUbiquityServerNotAvailable)
        let issue = SnapshotSyncIssue.make(error, stage: .uploadConfirmation)
        #expect(issue.kind == .cloudUnavailable)
        #expect(!issue.needsAuthorization)
        #expect(issue.needsICloudSettings)
        #expect(issue.isWarning)
    }

    @Test func testUnderlyingPermissionErrorOffersAuthorization() {
        let error = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError,
            userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))])
        let wrapped = SnapshotError.underlying("Folder write failed", error)
        let issue = SnapshotSyncIssue.make(wrapped, stage: .publishing)
        #expect(issue.kind == .permission)
        #expect(issue.needsAuthorization)
        #expect(issue.codes.count == 2)
    }

    @Test func testQuotaFailureOffersStorageManagementRatherThanAuthorization() {
        let issue = SnapshotSyncIssue.make(NSError(domain: NSCocoaErrorDomain,
            code: NSUbiquitousFileNotUploadedDueToQuotaError), stage: .uploadConfirmation)
        #expect(issue.kind == .quota)
        #expect(issue.needsICloudSettings)
        #expect(!issue.needsAuthorization)
    }

    @Test func testDiagnosticsDoNotCopyErrorUserInfoOrAccountData() {
        let error = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError,
            userInfo: ["account": "private@example.com", "task": "PRIVATE_TASK_BODY", NSFilePathErrorKey: "/private/user/path"])
        let issue = SnapshotSyncIssue.make(error, stage: .publishing)
        #expect(!issue.diagnostic.contains("private@example.com"))
        #expect(!issue.diagnostic.contains("PRIVATE_TASK_BODY"))
        #expect(!issue.diagnostic.contains("/private/user/path"))
        #expect(issue.diagnostic.contains("NSCocoaErrorDomain (513)"))
    }

    @Test func testCloudUploadMarkerAndFailureSurviveRestartWithoutAnOutbox() throws {
        let version = try makeVersion(SnapshotArchive.prepare(state(), root: directory))
        let issue = SnapshotSyncIssue.make(NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError),
            stage: .publishing, versionID: version.id)
        let record = SnapshotSyncRecord(publication: SnapshotPublication(version: version, phase: .awaitingUpload), issue: issue)
        try SnapshotSyncStore.save(record, to: directory)
        let restored = try SnapshotSyncStore.load(from: directory)
        #expect(restored.publication?.version.id == version.id)
        #expect(restored.publication?.phase == .awaitingUpload)
        #expect(restored.issue == issue)
    }

    @Test func testReportedUploadErrorIsPropagatedUntilBothFilesAreConfirmed() {
        let error = NSError(domain: NSCocoaErrorDomain, code: NSUbiquitousFileUbiquityServerNotAvailable)
        let pending = SnapshotDisk.UploadEvidence(isCloudItem: true, isUploaded: false, error: error)
        let complete = SnapshotDisk.UploadEvidence(isCloudItem: true, isUploaded: true, error: nil)
        #expect(throws: (any Error).self) { try SnapshotDisk.uploadState(from: [pending, complete]) }
    }

    @Test func testDefinitiveQuotaAndPermissionProblemsRemainErrors() {
        let quota = SnapshotSyncIssue.make(NSError(domain: NSCocoaErrorDomain,
            code: NSUbiquitousFileNotUploadedDueToQuotaError), stage: .uploadConfirmation)
        let denied = SnapshotSyncIssue.make(NSError(domain: NSCocoaErrorDomain,
            code: NSFileReadNoPermissionError), stage: .uploadConfirmation)
        #expect(!quota.isWarning)
        #expect(!denied.isWarning)
    }

    @Test func testCloudTransferRequiresBothFilesAndCurrentDownloadEvidence() {
        let ready = SnapshotDisk.TransferEvidence(isCloudItem: true, isUploaded: true, isCurrent: true)
        #expect(SnapshotDisk.transferState(from: [ready, ready]) == .ready)
        #expect(SnapshotDisk.transferState(from: [ready]) == .unknown)
        #expect(SnapshotDisk.transferState(from: [ready, .init(isMissing: true)]) == .waiting)
        #expect(SnapshotDisk.transferState(from: [ready, .init(isCloudItem: true, isUploaded: true, isCurrent: false)]) == .waiting)
        #expect(SnapshotDisk.transferState(from: [ready, .init(isCloudItem: true, isUploaded: true)]) == .unknown)
    }

    @Test func testCloudTransferDistinguishesUploadDownloadAndSimultaneousActivity() {
        let upload = SnapshotDisk.TransferEvidence(isCloudItem: true, isUploading: true)
        let download = SnapshotDisk.TransferEvidence(isCloudItem: true, isDownloading: true)
        let ready = SnapshotDisk.TransferEvidence(isCloudItem: true, isUploaded: true, isCurrent: true)
        #expect(SnapshotDisk.transferState(from: [upload, ready]) == .uploading)
        #expect(SnapshotDisk.transferState(from: [download, ready]) == .downloading)
        #expect(SnapshotDisk.transferState(from: [upload, download]) == .transferring)
        #expect(SnapshotDisk.transferState(from: [ready, .init(isCloudItem: true, isUploaded: false, isCurrent: true)]) == .waiting)
    }

    @Test func testCloudTransferRetainsFailuresUntilBothDirectionsAreConfirmed() {
        let stale = SnapshotDisk.TransferEvidence(isCloudItem: true, isUploaded: true, isCurrent: true, hasError: true)
        let failed = SnapshotDisk.TransferEvidence(isCloudItem: true, isUploaded: true, isCurrent: false, hasError: true)
        #expect(SnapshotDisk.transferState(from: [stale, stale]) == .ready)
        #expect(SnapshotDisk.transferState(from: [stale, failed]) == .failed)
    }

    @Test func testIncompleteCloudTransferPreventsReplacingEitherCopy() {
        for status: SnapshotCloudTransfer in [.uploading, .downloading, .transferring, .waiting, .failed] {
            #expect(status.blocksReplacement)
        }
        // Some providers omit attributes; a manual, verified operation may
        // still proceed when status is unknown, or when no cloud data exists.
        #expect(!SnapshotCloudTransfer.unknown.blocksReplacement)
        #expect(!SnapshotCloudTransfer.empty.blocksReplacement)
        #expect(!SnapshotCloudTransfer.ready.blocksReplacement)
    }

    @Test func testReadableFilenameIncludesSecondsZoneDeviceAndIdentity() {
        let id = UUID(uuidString: "12345678-1234-1234-1234-123456789ABC")!
        let name = SnapshotArchive.filename(date: Date(timeIntervalSince1970: 0), deviceName: "Office / Mac",
                                            id: id, timeZone: TimeZone(secondsFromGMT: 28800)!)
        #expect(name == "1970-01-01_08-00-00+0800_Office---Mac_12345678.zip")
        #expect(SnapshotArchive.validArchiveName(name))
        #expect(!SnapshotArchive.validArchiveName("../" + name))
        #expect(!SnapshotArchive.validArchiveName("current.json"))
    }

    @Test func testPublishSwitchKeepsOldCopyUntilCommitAndCleanupLeavesOnlyCurrentPair() throws {
        let cloud = directory.appendingPathComponent("current-cloud")
        try FileManager.default.createDirectory(at: cloud, withIntermediateDirectories: false)
        let first = try makeVersion(SnapshotArchive.prepare(state(), root: directory))
        try publishForTest(first, from: directory.appendingPathComponent(first.archiveName), to: cloud)
        let legacy = UUID().uuidString
        for ext in ["zip", "json"] { try Data("obsolete".utf8).write(to: cloud.appendingPathComponent("\(legacy).\(ext)")) }
        try Data("user file".utf8).write(to: cloud.appendingPathComponent("notes.txt"))
        let names = try SnapshotDisk.cleanupCandidates(in: cloud, current: first, abandoned: nil)
        let next = try makeVersion(SnapshotArchive.prepare(state(), root: directory))
        try SnapshotDisk.stageArchive(next, from: directory.appendingPathComponent(next.archiveName), to: cloud)
        #expect(try SnapshotDisk.current(in: cloud)?.id == first.id)
        #expect(FileManager.default.fileExists(atPath: cloud.appendingPathComponent(first.archiveName).path))
        try SnapshotDisk.commitCurrent(next, replacing: first.id, in: cloud)
        #expect(try SnapshotDisk.current(in: cloud)?.id == next.id)
        // Another Mac started uploading after our deletion list was captured.
        let concurrent = try makeVersion(SnapshotArchive.prepare(state(), root: directory))
        try SnapshotDisk.stageArchive(concurrent, from: directory.appendingPathComponent(concurrent.archiveName), to: cloud)
        try SnapshotDisk.cleanup(names, keeping: next, in: cloud)
        #expect(!FileManager.default.fileExists(atPath: cloud.appendingPathComponent(first.archiveName).path))
        #expect(!FileManager.default.fileExists(atPath: cloud.appendingPathComponent("\(legacy).zip").path))
        #expect(FileManager.default.fileExists(atPath: cloud.appendingPathComponent(next.archiveName).path))
        #expect(FileManager.default.fileExists(atPath: cloud.appendingPathComponent(concurrent.archiveName).path))
        #expect(try Data(contentsOf: cloud.appendingPathComponent("notes.txt")) == Data("user file".utf8))
        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: cloud.path))
                == Set(["current.json", next.archiveName, concurrent.archiveName, "notes.txt"]))
    }

    @Test func testConcurrentPublishDoesNotOverwriteAnotherMacOrDeleteItsPayload() throws {
        let cloud = directory.appendingPathComponent("concurrent-cloud")
        try FileManager.default.createDirectory(at: cloud, withIntermediateDirectories: false)
        let first = try makeVersion(SnapshotArchive.prepare(state(), root: directory))
        let second = try makeVersion(SnapshotArchive.prepare(state(), root: directory))
        try publishForTest(first, from: directory.appendingPathComponent(first.archiveName), to: cloud)
        try SnapshotDisk.stageArchive(second, from: directory.appendingPathComponent(second.archiveName), to: cloud)
        #expect(throws: (any Error).self) { try SnapshotDisk.commitCurrent(second, replacing: nil, in: cloud) }
        #expect(try SnapshotDisk.current(in: cloud)?.id == first.id)
        try SnapshotDisk.cleanup([first.archiveName], keeping: second, in: cloud)
        #expect(FileManager.default.fileExists(atPath: cloud.appendingPathComponent(first.archiveName).path))
    }

    @Test func testCurrentManifestRejectsOldProtocolAndUnsafePayloadPaths() throws {
        let cloud = directory.appendingPathComponent("invalid-current")
        try FileManager.default.createDirectory(at: cloud, withIntermediateDirectories: false)
        var version = try makeVersion(SnapshotArchive.prepare(state(), root: directory))
        version.archiveName = "../outside.zip"
        try SnapshotArchive.encode(version).write(to: cloud.appendingPathComponent("current.json"))
        #expect(throws: (any Error).self) { try SnapshotDisk.current(in: cloud) }
        version.archiveName = SnapshotArchive.filename(date: version.createdAt, deviceName: version.deviceName, id: version.id)
        var raw = try #require(JSONSerialization.jsonObject(with: SnapshotArchive.encode(version)) as? [String: Any])
        raw["formatVersion"] = 1
        try JSONSerialization.data(withJSONObject: raw).write(to: cloud.appendingPathComponent("current.json"))
        #expect(throws: (any Error).self) { try SnapshotDisk.current(in: cloud) }
    }

    @Test func testUndoPointerSurvivesRestartAndFailedApplicationPreservesPreviousUndo() throws {
        let rollbackRoot = SnapshotRollbackStore.directory(in: directory)
        let original = state()
        let previousUndo = try SnapshotArchive.create(SnapshotArchive.prepare(original, root: directory), in: rollbackRoot,
                                                     deviceID: UUID(), deviceName: "Office")
        var before = original
        try SnapshotRollbackStore.set(previousUndo, in: &before)
        let file = directory.appendingPathComponent("comments.json")
        try SnapshotArchive.encode(before).write(to: file)
        let stagedUndo = try SnapshotArchive.create(SnapshotArchive.prepare(before, root: directory), in: rollbackRoot,
                                                   deviceID: UUID(), deviceName: "Office")
        var replacement = state()
        try SnapshotRollbackStore.set(stagedUndo, in: &replacement)
        var later = before
        later.comments[0].commentText = "Integration edited while applying"
        try SnapshotArchive.encode(later).write(to: file)
        #expect(throws: (any Error).self) { try SnapshotReplacement.commit(replacement, expected: before, fileURL: file) }
        let restored = try JSONDecoder().decode(AppState.self, from: Data(contentsOf: file))
        #expect(SnapshotRollbackStore.version(in: restored)?.id == previousUndo.id)
        try SnapshotRollbackStore.cleanup(in: directory, keeping: SnapshotRollbackStore.version(in: restored))
        #expect(try FileManager.default.contentsOfDirectory(atPath: rollbackRoot.path) == [previousUndo.archiveName])
        let recovered = try SnapshotArchive.read(previousUndo, archive: rollbackRoot.appendingPathComponent(previousUndo.archiveName)).state
        #expect(recovered.comments == original.comments && recovered.sessions == original.sessions)
    }

    @Test func testSuccessfulApplicationReplacesSingleUndoAndRollbackConsumesIt() throws {
        let rollbackRoot = SnapshotRollbackStore.directory(in: directory)
        let first = try SnapshotArchive.create(SnapshotArchive.prepare(state(), root: directory), in: rollbackRoot,
                                               deviceID: UUID(), deviceName: "Office")
        let file = directory.appendingPathComponent("comments.json")
        var before = state()
        try SnapshotRollbackStore.set(first, in: &before)
        try SnapshotArchive.encode(before).write(to: file)
        let undo = try SnapshotArchive.create(SnapshotArchive.prepare(before, root: directory), in: rollbackRoot,
                                              deviceID: UUID(), deviceName: "Office")
        var applied = state()
        try SnapshotRollbackStore.set(undo, in: &applied)
        try SnapshotReplacement.commit(applied, expected: before, fileURL: file)
        let restarted = try JSONDecoder().decode(AppState.self, from: Data(contentsOf: file))
        #expect(SnapshotRollbackStore.version(in: restarted)?.id == undo.id)
        try SnapshotRollbackStore.cleanup(in: directory, keeping: undo)
        #expect(try FileManager.default.contentsOfDirectory(atPath: rollbackRoot.path) == [undo.archiveName])
        var restored = try SnapshotArchive.read(undo, archive: rollbackRoot.appendingPathComponent(undo.archiveName)).state
        try SnapshotRollbackStore.set(nil, in: &restored)
        try SnapshotReplacement.commit(restored, expected: restarted, fileURL: file)
        #expect(restored.comments == before.comments && restored.sessions == before.sessions)
        #expect(SnapshotRollbackStore.version(in: restored) == nil)
        try SnapshotRollbackStore.cleanup(in: directory, keeping: nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: rollbackRoot.path).isEmpty)
    }

}


@Suite("iCloud action availability")
struct SnapshotActionAvailabilityTests {
    private func actions(comparison: SnapshotComparison = .publish, hasCloud: Bool = true,
                         enabled: Bool = true, busy: Bool = false, connected: Bool = true,
                         checked: Bool = true, localReady: Bool = true,
                         hasIssue: Bool = false, pending: Bool = false,
                         transfer: SnapshotCloudTransfer = .ready) -> SnapshotActionAvailability {
        SnapshotActionAvailability(enabled: enabled, busy: busy, connected: connected, checked: checked,
            localReady: localReady, hasIssue: hasIssue, pending: pending,
            transfer: transfer, comparison: comparison, hasCloud: hasCloud)
    }

    @Test func matchingCopiesDisableBothDirections() {
        let result = actions(comparison: .same)
        #expect(!result.canPublish)
        #expect(!result.canApply)
    }

    @Test func localChangesOnlyEnablePublishing() {
        let result = actions(comparison: .publish)
        #expect(result.canPublish)
        #expect(!result.canApply)
    }

    @Test func cloudChangesOnlyEnableApplying() {
        let result = actions(comparison: .receive)
        #expect(!result.canPublish)
        #expect(result.canApply)
    }

    @Test func conflictingOrUnrelatedCopiesAllowBothChoices() {
        let result = actions(comparison: .choose)
        #expect(result.canPublish)
        #expect(result.canApply)
    }

    @Test func firstPublicationCannotApplyAnAbsentCopy() {
        let result = actions(hasCloud: false, transfer: .empty)
        #expect(result.canPublish)
        #expect(!result.canApply)
    }

    @Test(arguments: [SnapshotComparison.same, .publish, .receive, .choose])
    func unverifiedOrUnavailableStateBlocksBothDirections(_ comparison: SnapshotComparison) {
        let blocked = [actions(comparison: comparison, enabled: false), actions(comparison: comparison, busy: true),
            actions(comparison: comparison, connected: false), actions(comparison: comparison, checked: false),
            actions(comparison: comparison, localReady: false), actions(comparison: comparison, hasIssue: true),
            actions(comparison: comparison, pending: true)]
        for result in blocked {
            #expect(!result.canPublish)
            #expect(!result.canApply)
        }
    }

    @Test(arguments: [SnapshotCloudTransfer.unknown, .uploading, .downloading, .transferring, .waiting, .failed])
    func incompleteTransfersBlockBothDirections(_ transfer: SnapshotCloudTransfer) {
        let result = actions(transfer: transfer)
        #expect(!result.canPublish)
        #expect(!result.canApply)
    }
}

@Suite("Snapshot guidance")
struct SnapshotGuidanceTests {
    @Test func missingHistoryIsNotReportedAsAConflict() {
        #expect(SnapshotGuidance(comparison: .choose, hasBaseline: false) == .setup)
        #expect(SnapshotGuidance(comparison: .choose, hasBaseline: true) == .conflict)
    }

    @Test func clearDirectionsAndMatchingCopiesDoNotAskTheUserToChoose() {
        for hasBaseline in [false, true] {
            #expect(SnapshotGuidance(comparison: .same, hasBaseline: hasBaseline) == .current)
            #expect(SnapshotGuidance(comparison: .publish, hasBaseline: hasBaseline) == .backup)
            #expect(SnapshotGuidance(comparison: .receive, hasBaseline: hasBaseline) == .restore)
        }
    }
}

@Suite("On-demand iCloud refresh")
struct SnapshotRefreshPolicyTests {
    @Test func eachReopeningChecksWithoutATimeThrottle() {
        for _ in 0..<3 {
            #expect(SnapshotRefreshPolicy.shouldCheckOnShow(wasVisible: false, enabled: true, busy: false, reviewing: false))
        }
    }
    @Test func anAlreadyVisibleInterfaceDoesNotRefresh() {
        #expect(!SnapshotRefreshPolicy.shouldCheckOnShow(wasVisible: true, enabled: true, busy: false, reviewing: false))
    }
    @Test func disabledBusyOrReviewingDoesNotStartAnotherCheck() {
        #expect(!SnapshotRefreshPolicy.shouldCheckOnShow(wasVisible: false, enabled: false, busy: false, reviewing: false))
        #expect(!SnapshotRefreshPolicy.shouldCheckOnShow(wasVisible: false, enabled: true, busy: true, reviewing: false))
        #expect(!SnapshotRefreshPolicy.shouldCheckOnShow(wasVisible: false, enabled: true, busy: false, reviewing: true))
    }
}
