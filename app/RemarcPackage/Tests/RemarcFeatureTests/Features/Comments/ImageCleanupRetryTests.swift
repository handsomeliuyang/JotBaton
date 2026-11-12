@testable import FeatureCapture
@testable import FeatureComments
@testable import RemarcFeature
import Foundation
import XCTest

@MainActor
final class ImageCleanupRetryTests: XCTestCase {
    private var storage = TemporaryStorageRoot()

    override func setUp() async throws {
        storage = TemporaryStorageRoot()
        try storage.install()
    }

    override func tearDown() async throws {
        storage.remove()
    }

    func testAbandonedLeaseSurvivesUnavailableFolderAndReclaimsAfterReturn() throws {
        let directory = try configureCustomDirectory()
        let path = try writeNewScreenshotData(Data("capture".utf8))
        try recordAbandonedLease(path)
        let offline = storage.url.appendingPathComponent("offline")
        try FileManager.default.moveItem(at: directory, to: offline)

        let unavailable = PreparedCaptureLeaseRegistry.reconcile { _ in false }
        XCTAssertEqual(unavailable.keptFailed, [path])
        XCTAssertTrue(unavailable.deleted.isEmpty)
        XCTAssertEqual(PreparedCaptureLeaseRegistry.currentLeases().map(\.path), [path])
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))

        try FileManager.default.moveItem(at: offline, to: directory)
        let reconnected = PreparedCaptureLeaseRegistry.reconcile { _ in false }
        XCTAssertEqual(reconnected.deleted, [path])
        XCTAssertTrue(PreparedCaptureLeaseRegistry.currentLeases().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }

    func testPartialFamilyDeletionPreservesLeaseUntilSidecarsCanBeRemoved() throws {
        let path = try writeNewScreenshotData(Data("capture".utf8))
        let outside = storage.url.appendingPathComponent("unrelated.png")
        try Data("unrelated".utf8).write(to: outside)
        let sidecar = resolveImagePath(AnnotationMarkStore.basePath(for: path))
        try FileManager.default.createSymbolicLink(at: sidecar, withDestinationURL: outside)
        try recordAbandonedLease(path)

        let partial = PreparedCaptureLeaseRegistry.reconcile { _ in false }
        XCTAssertEqual(partial.keptFailed, [path])
        XCTAssertTrue(partial.deleted.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: resolveImagePath(path).path))
        XCTAssertEqual(try Data(contentsOf: outside), Data("unrelated".utf8))
        XCTAssertEqual(PreparedCaptureLeaseRegistry.currentLeases().map(\.path), [path])

        // Removing the invalid link allows cleanup to finish even though its
        // primary PNG was already removed by the first attempt.
        try FileManager.default.removeItem(at: sidecar)
        let retried = PreparedCaptureLeaseRegistry.reconcile { _ in false }
        XCTAssertEqual(retried.deleted, [path])
        XCTAssertTrue(PreparedCaptureLeaseRegistry.currentLeases().isEmpty)
        XCTAssertEqual(try Data(contentsOf: outside), Data("unrelated".utf8))
    }

    func testRetentionKeepsUnavailableExpiredFilesAndUnexpiredFiles() throws {
        let available = try writeNewScreenshotData(Data("expired".utf8))
        let recent = try writeNewScreenshotData(Data("recent".utf8))
        let directory = try configureCustomDirectory()
        let unavailable = try writeNewScreenshotData(Data("offline".utf8))
        let offline = storage.url.appendingPathComponent("offline")
        try FileManager.default.moveItem(at: directory, to: offline)
        let cutoff = Date()
        var orphans = [
            OrphanedImage(path: available, deletedAt: .distantPast),
            OrphanedImage(path: unavailable, deletedAt: .distantPast),
            OrphanedImage(path: recent, deletedAt: .distantFuture),
        ]

        CommentStore.pruneExpiredImages(&orphans, before: cutoff)
        XCTAssertEqual(orphans.map(\.path), [unavailable, recent])
        XCTAssertFalse(FileManager.default.fileExists(atPath: resolveImagePath(available).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: resolveImagePath(recent).path))

        try FileManager.default.moveItem(at: offline, to: directory)
        CommentStore.pruneExpiredImages(&orphans, before: cutoff)
        XCTAssertEqual(orphans.map(\.path), [recent])
        XCTAssertFalse(FileManager.default.fileExists(atPath: unavailable))
        XCTAssertTrue(FileManager.default.fileExists(atPath: resolveImagePath(recent).path))
    }

    func testPermanentDeletionQueuesOneImmediateRetryAndPreservesItsIdentity() throws {
        let directory = try configureCustomDirectory()
        let path = try writeNewScreenshotData(Data("capture".utf8))
        let offline = storage.url.appendingPathComponent("offline")
        try FileManager.default.moveItem(at: directory, to: offline)
        let original = OrphanedImage(path: path, deletedAt: Date())
        var orphans = [original]

        CommentStore.deleteImageOrRetainForRetry(path, orphanedImages: &orphans)
        CommentStore.deleteImageOrRetainForRetry(path, orphanedImages: &orphans)
        XCTAssertEqual(orphans.count, 1)
        XCTAssertEqual(orphans.first?.id, original.id)
        XCTAssertEqual(orphans.first?.deletedAt, Date.distantPast)

        try FileManager.default.moveItem(at: offline, to: directory)
        let retentionCutoff = Date().addingTimeInterval(-365 * 24 * 60 * 60)
        CommentStore.pruneExpiredImages(&orphans, before: retentionCutoff)
        XCTAssertTrue(orphans.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }

    func testAnAlreadyMissingFileInAnAvailableFolderCompletesCleanup() throws {
        let path = "images/\(UUID().uuidString).png"
        try recordAbandonedLease(path)

        let result = PreparedCaptureLeaseRegistry.reconcile { _ in false }
        XCTAssertEqual(result.deleted, [path])
        XCTAssertTrue(result.keptFailed.isEmpty)
        XCTAssertTrue(PreparedCaptureLeaseRegistry.currentLeases().isEmpty)
    }

    func testHistoryExpiryRemovesCommentsSessionsAndWholeImageFamiliesTogether() throws {
        let cutoff = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let screenshot = try writeNewScreenshotData(Data("screenshot".utf8))
        let attachment = try writeNewScreenshotData(Data("attachment".utf8))
        let base = resolveImagePath(AnnotationMarkStore.basePath(for: screenshot))
        let marks = resolveImagePath(AnnotationMarkStore.marksPath(for: screenshot))
        try Data("base".utf8).write(to: base)
        try Data("marks".utf8).write(to: marks)
        let session = Session(name: "Expired", isDeleted: true, deletedAt: cutoff)
        let comment = FeatureComments.Comment(type: .screenshot(imagePath: screenshot), commentText: "Expired",
            source: "Tests", appBundleID: nil, sessionID: session.id, isDeleted: true,
            deletedAt: cutoff, attachments: [attachment])
        var state = AppState(sessions: [session], comments: [comment])

        CommentStore.pruneExpiredHistory(&state, before: cutoff)

        XCTAssertTrue(state.sessions.isEmpty)
        XCTAssertTrue(state.comments.isEmpty)
        XCTAssertTrue(state.orphanedImages.isEmpty)
        for url in [resolveImagePath(screenshot), resolveImagePath(attachment), base, marks] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        }
    }

    func testHistoryRetentionPreservesActiveAndUnexpiredCommentsAndImages() throws {
        let cutoff = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let activeImage = try writeNewScreenshotData(Data("active".utf8))
        let historyImage = try writeNewScreenshotData(Data("history".utf8))
        let active = FeatureComments.Comment(type: .screenshot(imagePath: activeImage), commentText: "Active",
            source: "Tests", appBundleID: nil, createdAt: .distantPast, sessionID: UUID())
        let recent = FeatureComments.Comment(type: .quickNote, commentText: "History",
            source: "Tests", appBundleID: nil, sessionID: UUID(), isDeleted: true,
            deletedAt: cutoff.addingTimeInterval(1), attachments: [historyImage])
        var state = AppState(comments: [active, recent])
        let before = state

        CommentStore.pruneExpiredHistory(&state, before: cutoff)

        XCTAssertEqual(state, before)
        XCTAssertTrue(FileManager.default.fileExists(atPath: resolveImagePath(activeImage).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: resolveImagePath(historyImage).path))
    }

    func testSharedImagesSurviveUntilTheLastHistoryReferenceExpires() throws {
        let cutoff = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let path = try writeNewScreenshotData(Data("shared".utf8))
        let expired = FeatureComments.Comment(type: .screenshot(imagePath: path), commentText: "Expired",
            source: "Tests", appBundleID: nil, sessionID: UUID(), isDeleted: true, deletedAt: cutoff)
        var active = FeatureComments.Comment(type: .quickNote, commentText: "Active",
            source: "Tests", appBundleID: nil, sessionID: UUID(), attachments: [resolveImagePath(path).path])
        let recent = FeatureComments.Comment(type: .quickNote, commentText: "History",
            source: "Tests", appBundleID: nil, sessionID: UUID(), isDeleted: true,
            deletedAt: cutoff.addingTimeInterval(2), attachments: [path])
        var state = AppState(comments: [expired, active, recent])

        CommentStore.pruneExpiredHistory(&state, before: cutoff)
        XCTAssertEqual(state.comments, [active, recent])
        XCTAssertEqual(state.orphanedImages.map(\.path), [path])
        XCTAssertTrue(FileManager.default.fileExists(atPath: resolveImagePath(path).path))

        active.isDeleted = true
        active.deletedAt = cutoff.addingTimeInterval(1)
        state.comments[0] = active
        CommentStore.pruneExpiredHistory(&state, before: cutoff.addingTimeInterval(1))
        XCTAssertEqual(state.comments, [recent])
        XCTAssertTrue(FileManager.default.fileExists(atPath: resolveImagePath(path).path))

        CommentStore.pruneExpiredHistory(&state, before: cutoff.addingTimeInterval(2))
        XCTAssertTrue(state.comments.isEmpty)
        XCTAssertTrue(state.orphanedImages.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: resolveImagePath(path).path))
    }

    func testHistoryExpiryQueuesUnavailableImagesAndRetriesLegacyOrphans() throws {
        let cutoff = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let legacyPath = try writeNewScreenshotData(Data("legacy".utf8))
        let directory = try configureCustomDirectory()
        let path = try writeNewScreenshotData(Data("offline".utf8))
        let offline = storage.url.appendingPathComponent("offline")
        try FileManager.default.moveItem(at: directory, to: offline)
        let comment = FeatureComments.Comment(type: .screenshot(imagePath: path), commentText: "Expired",
            source: "Tests", appBundleID: nil, sessionID: UUID(), isDeleted: true, deletedAt: cutoff)
        var state = AppState(comments: [comment], orphanedImages: [OrphanedImage(path: legacyPath, deletedAt: cutoff)])

        CommentStore.pruneExpiredHistory(&state, before: cutoff)
        XCTAssertTrue(state.comments.isEmpty)
        XCTAssertEqual(state.orphanedImages.map(\.path), [path])
        XCTAssertFalse(FileManager.default.fileExists(atPath: resolveImagePath(legacyPath).path))
        let retry = state.orphanedImages[0]
        CommentStore.pruneExpiredHistory(&state, before: cutoff)
        XCTAssertEqual(state.orphanedImages, [retry])

        try FileManager.default.moveItem(at: offline, to: directory)
        CommentStore.pruneExpiredHistory(&state, before: cutoff)
        XCTAssertTrue(state.orphanedImages.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: resolveImagePath(path).path))
    }

    private func configureCustomDirectory() throws -> URL {
        let directory = storage.url.appendingPathComponent("custom", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try ScreenshotStorage.configure(directory: directory, defaults: remarcScreenshotDefaults)
        return directory
    }

    private func recordAbandonedLease(_ path: String) throws {
        let lease = PreparedCaptureLease(path: path, pid: 99_999,
                                         bootTime: -1, startTime: -1, at: 0)
        try JSONEncoder().encode([lease]).write(to: PreparedCaptureLeaseRegistry.registryURL, options: .atomic)
    }
}
