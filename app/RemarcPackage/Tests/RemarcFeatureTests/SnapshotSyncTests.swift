import Foundation
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

    private func makeVersion(_ prepared: SnapshotArchive.Prepared, parent: UUID? = nil) throws -> SnapshotVersion {
        try SnapshotArchive.create(prepared, in: directory, deviceID: UUID(), deviceName: "Office Mac", parentID: parent)
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
        original.comments[0].deletedAt = Date()
        let prepared = try SnapshotArchive.prepare(original, root: directory)
        let version = try makeVersion(prepared)
        let restored = try SnapshotArchive.read(version, archive: directory.appendingPathComponent("\(version.id).zip"))
        #expect(restored.state.comments[0].isDeleted)
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
        #expect(try first.hash == SnapshotArchive.prepare(original, root: directory).hash)
        original.comments[0].commentText = "edited"
        #expect(try first.hash != SnapshotArchive.prepare(original, root: directory).hash)
    }

    @Test func testContentTimeSurvivesArchiveAndLegacyMetadata() throws {
        let prepared = try SnapshotArchive.prepare(state(), root: directory)
        let time = Date(timeIntervalSince1970: 123456)
        let version = try SnapshotArchive.create(prepared, in: directory, deviceID: UUID(), deviceName: "Office", parentID: nil, contentModifiedAt: time)
        let decoded = try JSONDecoder().decode(SnapshotVersion.self, from: SnapshotArchive.encode(version))
        #expect(decoded.contentModifiedAt == time)
        #expect(try SnapshotArchive.read(decoded, archive: directory.appendingPathComponent("\(version.id).zip")).hash == prepared.hash)
        var json = try #require(JSONSerialization.jsonObject(with: SnapshotArchive.encode(version)) as? [String: Any])
        json.removeValue(forKey: "contentModifiedAt")
        #expect(try JSONDecoder().decode(SnapshotVersion.self, from: JSONSerialization.data(withJSONObject: json)).contentModifiedAt == nil)
    }

    @Test func testContentClockCheckRestartAndApplyAreNotEdits() {
        let old = Date(timeIntervalSince1970: 10)
        let now = Date(timeIntervalSince1970: 20)
        let saved = SnapshotContentStamp(contentHash: "a", modifiedAt: old)
        #expect(SnapshotContentStamp.tracking(hash: "a", saved: saved, adopted: nil, observedLive: true, now: now) == saved)
        #expect(SnapshotContentStamp.tracking(hash: "a", saved: saved, adopted: nil, observedLive: false, now: now) == saved)
        let incoming = SnapshotContentStamp(contentHash: "b", modifiedAt: old)
        #expect(SnapshotContentStamp.tracking(hash: "b", saved: saved, adopted: incoming, observedLive: false, now: now) == incoming)
        #expect(SnapshotContentStamp.tracking(hash: "b", saved: saved, adopted: nil, observedLive: true, now: now).modifiedAt == now)
        #expect(SnapshotContentStamp.tracking(hash: "b", saved: saved, adopted: nil, observedLive: false, now: now).modifiedAt == nil)
        #expect(SnapshotContentStamp.tracking(hash: "b", saved: nil, adopted: nil, observedLive: false, now: now).modifiedAt == nil)
    }

    @Test func testContentComparisonKeepsWholeDataChoicesSafe() throws {
        var cloud = try makeVersion(SnapshotArchive.prepare(state(), root: directory))
        cloud.contentModifiedAt = Date(timeIntervalSince1970: 10)
        func compare(_ hash: String?, _ time: Date?, baseline: UUID?, edits: Bool, multiple: Bool = false) -> SnapshotComparison {
            SnapshotComparison.compare(localHash: hash, localTime: time, cloud: cloud, baselineID: baseline, localEdits: edits, multipleCloudHeads: multiple)
        }
        #expect(compare(cloud.contentHash, nil, baseline: nil, edits: true) == .same)
        #expect(compare("changed", nil, baseline: cloud.id, edits: true) == .publish)
        #expect(compare("changed", nil, baseline: nil, edits: false) == .receive)
        #expect(compare("changed", Date(timeIntervalSince1970: 30), baseline: nil, edits: true) == .choose)
        #expect(compare("changed", nil, baseline: cloud.id, edits: false) == .choose)
        #expect(compare("changed", cloud.contentModifiedAt, baseline: cloud.id, edits: false) == .choose)
        #expect(compare("changed", Date(timeIntervalSince1970: 30), baseline: cloud.id, edits: false) == .publish)
        #expect(compare("changed", Date(timeIntervalSince1970: 5), baseline: cloud.id, edits: false) == .receive)
        #expect(compare(cloud.contentHash, nil, baseline: cloud.id, edits: false, multiple: true) == .choose)
    }

    @Test func testSharedPresentationUsesContentComparison() {
        let comparisons: [(SnapshotComparison, SnapshotSyncPresentation.Action)] = [(.same, .publish), (.publish, .publish), (.receive, .apply), (.choose, .choose)]
        for (comparison, action) in comparisons {
            let result = SnapshotSyncPresentation.make(enabled: true, directoryReady: true, progress: nil, issue: nil, publication: nil, hasLocalChanges: true, remoteCount: 1, comparison: comparison)
            #expect(result.action == action)
        }
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
        #expect(throws: Never.self) { try SnapshotArchive.read(version, archive: directory.appendingPathComponent("\(version.id).zip")) }
    }

    @Test func testCorruptArchiveIsRefusedBeforeLocalDataChanges() throws {
        let prepared = try SnapshotArchive.prepare(state(), root: directory)
        let version = try makeVersion(prepared)
        let archive = directory.appendingPathComponent("\(version.id).zip")
        try Data("truncated".utf8).write(to: archive)
        #expect(throws: (any Error).self) { try SnapshotArchive.read(version, archive: archive) }
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("images").path))
    }

    @Test func testVersionAncestryWinsOverClockDifferencesAndForksRemainVisible() throws {
        let prepared = try SnapshotArchive.prepare(state(), root: directory)
        let first = try makeVersion(prepared)
        let next = try makeVersion(prepared, parent: first.id)
        let fork = try makeVersion(prepared, parent: first.id)
        #expect(SnapshotDisk.heads([first, next]).map(\.id) == [next.id])
        #expect(Set(SnapshotDisk.heads([first, next, fork]).map(\.id)) == Set([next.id, fork.id]))
    }

    @Test func testPublishedArchiveCanBeDiscoveredAndAppliedFromAnotherDirectory() throws {
        let prepared = try SnapshotArchive.prepare(state(), root: directory)
        let version = try makeVersion(prepared)
        let cloud = directory.appendingPathComponent("cloud")
        try FileManager.default.createDirectory(at: cloud, withIntermediateDirectories: true)
        try SnapshotDisk.publish(version, from: directory.appendingPathComponent("\(version.id).zip"), to: cloud)
        #expect(try SnapshotDisk.versions(in: cloud).map(\.id) == [version.id])
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

    @Test func testExplicitLocalOverrideClosesAllPreviouslyDiscoveredVersions() throws {
        let prepared = try SnapshotArchive.prepare(state(), root: directory)
        let first = try makeVersion(prepared)
        let second = try makeVersion(prepared)
        let override = try SnapshotArchive.create(prepared, in: directory, deviceID: UUID(),
            deviceName: "Home Mac", parentID: first.id, supersededIDs: [first.id, second.id])
        #expect(SnapshotDisk.heads([first, second, override]).map(\.id) == [override.id])
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
    @Test func testRetryUsesTheSameArchiveAndVersionWithoutDuplicatingCloudFiles() throws {
        let prepared = try SnapshotArchive.prepare(state(), root: directory)
        let version = try makeVersion(prepared)
        let cloud = directory.appendingPathComponent("retry-cloud")
        try FileManager.default.createDirectory(at: cloud, withIntermediateDirectories: true)
        let archive = directory.appendingPathComponent("\(version.id).zip")
        try SnapshotDisk.publish(version, from: archive, to: cloud)
        try SnapshotDisk.publish(version, from: archive, to: cloud)
        #expect(try SnapshotDisk.versions(in: cloud).map(\.id) == [version.id])
        #expect(try FileManager.default.contentsOfDirectory(atPath: cloud.path).count == 2)
    }

    @Test func testRetryDoesNotOverwriteADifferentCloudArchive() throws {
        let prepared = try SnapshotArchive.prepare(state(), root: directory)
        let version = try makeVersion(prepared)
        let cloud = directory.appendingPathComponent("different-cloud")
        try FileManager.default.createDirectory(at: cloud, withIntermediateDirectories: true)
        let target = cloud.appendingPathComponent("\(version.id).zip")
        try Data("different content".utf8).write(to: target)
        #expect(throws: (any Error).self) {
            try SnapshotDisk.publish(version, from: directory.appendingPathComponent("\(version.id).zip"), to: cloud)
        }
        #expect(try Data(contentsOf: target) == Data("different content".utf8))
    }

    @Test func testPartialPublicationCanRetryItsMissingManifest() throws {
        let prepared = try SnapshotArchive.prepare(state(), root: directory)
        let version = try makeVersion(prepared)
        let cloud = directory.appendingPathComponent("partial-cloud")
        try FileManager.default.createDirectory(at: cloud, withIntermediateDirectories: true)
        let archive = directory.appendingPathComponent("\(version.id).zip")
        try FileManager.default.copyItem(at: archive, to: cloud.appendingPathComponent("\(version.id).zip"))
        try SnapshotDisk.publish(version, from: archive, to: cloud)
        #expect(try SnapshotDisk.versions(in: cloud).map(\.id) == [version.id])
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

    @Test func testPendingSnapshotAndFailureSurviveRestart() throws {
        let version = try makeVersion(SnapshotArchive.prepare(state(), root: directory))
        let issue = SnapshotSyncIssue.make(NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError),
            stage: .publishing, versionID: version.id)
        let record = SnapshotSyncRecord(publication: SnapshotPublication(version: version, phase: .savedLocally), issue: issue)
        try SnapshotSyncStore.save(record, to: directory)
        let restored = try SnapshotSyncStore.load(from: directory)
        #expect(restored.publication?.version.id == version.id)
        #expect(restored.publication?.phase == .savedLocally)
        #expect(restored.issue == issue)
    }

    @Test func testUploadFailureOverridesOtherwiseHealthyStatusOnBothSurfaces() throws {
        let version = try makeVersion(SnapshotArchive.prepare(state(), root: directory))
        let issue = SnapshotSyncIssue.make(NSError(domain: NSCocoaErrorDomain,
            code: NSUbiquitousFileUbiquityServerNotAvailable), stage: .uploadConfirmation)
        let view = SnapshotSyncPresentation.make(enabled: true, directoryReady: true, progress: nil,
            issue: issue, publication: SnapshotPublication(version: version, phase: .unconfirmed),
            hasLocalChanges: false, remoteCount: 0)
        #expect(view.tone == .warning)
        #expect(view.action == .retry)
        #expect(view.title != "Uploaded to iCloud")
    }

    @Test func testDirectoryAccessAloneNeverClaimsUploadSuccess() {
        let view = SnapshotSyncPresentation.make(enabled: true, directoryReady: true, progress: nil,
            issue: nil, publication: nil, hasLocalChanges: false, remoteCount: 0)
        #expect(view.title != "Uploaded to iCloud")
        #expect(view.tone != .success)
    }

    @Test func testWaitingSnapshotOffersCheckWithoutCreatingAnotherVersion() throws {
        let version = try makeVersion(SnapshotArchive.prepare(state(), root: directory))
        let view = SnapshotSyncPresentation.make(enabled: true, directoryReady: true, progress: nil,
            issue: nil, publication: SnapshotPublication(version: version, phase: .awaitingUpload),
            hasLocalChanges: true, remoteCount: 0)
        #expect(view.action == .check)
        #expect(view.tone == .warning)
    }

    @Test func testSuccessfulRecheckClearsOldFailurePresentation() throws {
        let version = try makeVersion(SnapshotArchive.prepare(state(), root: directory))
        let view = SnapshotSyncPresentation.make(enabled: true, directoryReady: true, progress: nil,
            issue: nil, publication: SnapshotPublication(version: version, phase: .confirmed, confirmedAt: Date()),
            hasLocalChanges: false, remoteCount: 0)
        #expect(view.title == "Uploaded to iCloud")
        #expect(view.tone == .success)
    }

    @Test func testRemoteUpdateAndDivergenceOfferDirectApplyOrChoice() {
        let remote = SnapshotSyncPresentation.make(enabled: true, directoryReady: true, progress: nil,
            issue: nil, publication: nil, hasLocalChanges: false, remoteCount: 1)
        let conflict = SnapshotSyncPresentation.make(enabled: true, directoryReady: true, progress: nil,
            issue: nil, publication: nil, hasLocalChanges: true, remoteCount: 1)
        #expect(remote.action == .apply)
        #expect(conflict.action == .choose)
    }

    @Test func testCloudWriteFailureKeepsTheLocalArchiveForTheSameVersionRetry() throws {
        let outbox = SnapshotSyncStore.outbox(in: directory)
        let prepared = try SnapshotArchive.prepare(state(), root: directory)
        let version = try SnapshotArchive.create(prepared, in: outbox, deviceID: UUID(), deviceName: "Office", parentID: nil)
        let archive = outbox.appendingPathComponent("\(version.id).zip")
        let blocked = directory.appendingPathComponent("blocked-cloud")
        try Data("not a folder".utf8).write(to: blocked)
        #expect(throws: (any Error).self) { try SnapshotDisk.publish(version, from: archive, to: blocked) }
        #expect(try SnapshotArchive.fileDigest(archive) == version.archiveHash)
        try FileManager.default.removeItem(at: blocked)
        try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: false)
        try SnapshotDisk.publish(version, from: archive, to: blocked)
        #expect(try SnapshotDisk.versions(in: blocked).map(\.id) == [version.id])
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

    @Test func testDirectoryTransferIgnoresHistoryButIncludesIncomingAndPendingPairs() throws {
        let prepared = try SnapshotArchive.prepare(state(), root: directory)
        let old = try makeVersion(prepared)
        let current = try makeVersion(prepared, parent: old.id)
        let pending = try makeVersion(prepared, parent: current.id)
        let incomingID = UUID()
        let names = ["\(old.id).zip", "\(old.id).json", "\(current.id).zip", "\(current.id).json", ".\(incomingID).json.icloud", "notes.txt"]
        let files = SnapshotDisk.transferFileNames(versions: [old, current], pending: pending, discoveredNames: names)
        #expect(files == Set([current.id, pending.id, incomingID].flatMap { ["\($0).json", "\($0).zip"] }))
        #expect(!files.contains("\(old.id).zip"))
    }

    @Test func testArchiveArrivingBeforeManifestStillWaitsForCompleteData() {
        let id = UUID()
        let files = SnapshotDisk.transferFileNames(versions: [], pending: nil, discoveredNames: ["\(id).zip"])
        #expect(files == Set(["\(id).json", "\(id).zip"]))
    }

    @Test func testCloudMetadataReadDoesNotMistakeAnOrdinaryFolderForReadyData() throws {
        #expect(try SnapshotDisk.transferState(in: directory, versions: [], pending: nil) == .empty)
        let version = try makeVersion(SnapshotArchive.prepare(state(), root: directory))
        #expect(try SnapshotDisk.transferState(in: directory, versions: [version], pending: nil) == .unknown)
        try FileManager.default.removeItem(at: directory.appendingPathComponent("\(version.id).zip"))
        #expect(try SnapshotDisk.transferState(in: directory, versions: [version], pending: nil) == .waiting)
    }

    @Test func testCloudPlaceholderReadReportsWaitingWithoutReadingTaskData() throws {
        let id = UUID()
        let placeholder = directory.appendingPathComponent(".\(id).json.icloud")
        let bytes = Data("placeholder is not a snapshot".utf8)
        try bytes.write(to: placeholder)
        #expect(try SnapshotDisk.transferState(in: directory, versions: [], pending: nil) == .waiting)
        #expect(try Data(contentsOf: placeholder) == bytes)
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

}
