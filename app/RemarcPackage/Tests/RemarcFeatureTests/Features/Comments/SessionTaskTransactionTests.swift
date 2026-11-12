@testable import CorePlatform
@testable import FeatureComments
@testable import FeatureSnapshotSync
@testable import RemarcFeature
import Foundation
import Testing

@Suite("Fresh document session and completion transactions")
struct SessionTaskTransactionTests {
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func fixture() -> AppState {
        let inbox = Session(name: "Inbox", createdAt: now.addingTimeInterval(-7200))
        let work = Session(name: "Work", createdAt: inbox.createdAt, emptySince: inbox.createdAt)
        return AppState(sessions: [inbox, work], activeSessionID: work.id)
    }
    private func task(_ sessionID: UUID, status: CommentStatus = .inProgress) -> FeatureComments.Comment {
        FeatureComments.Comment(type: .quickNote, commentText: "Task", source: "Tests", appBundleID: nil,
                             createdAt: now, updatedAt: now, sessionID: sessionID, status: status)
    }
    private func tempDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("remarc-session-tasks-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    private func write(_ state: AppState, to url: URL) throws {
        try JSONEncoder().encode(state).write(to: url, options: .atomic)
    }
    private func read(_ url: URL) throws -> AppState {
        try JSONDecoder().decode(AppState.self, from: Data(contentsOf: url))
    }

    @Test("A task written on disk before the reload reaches the UI always prevents cleanup")
    func freshTaskProtectsSession() throws {
        let dir = try tempDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("comments.json")
        let baseline = fixture()
        for status in CommentStatus.allCases {
            var disk = baseline
            disk.comments = [task(baseline.sessions[1].id, status: status)]
            try write(disk, to: file)
            let commit = try SessionTaskTransactions.cleanupEmpty(fileURL: file, candidate: baseline, baseline: baseline,
                interval: 1800, excluding: [], now: now)
            #expect(commit.value.isEmpty)
            #expect(!commit.state.sessions[1].isDeleted)
            #expect(commit.state.sessions[1].emptySince == nil)
            #expect(try read(file).comments == disk.comments)
        }
    }

    @Test("An external last-task deletion resets a stale empty timestamp instead of immediately deleting the session")
    func externalEmptyTransition() throws {
        let dir = try tempDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("comments.json")
        var baseline = fixture()
        baseline.comments = [task(baseline.sessions[1].id)]
        var disk = baseline
        disk.comments[0].isDeleted = true
        disk.comments[0].deletedAt = now
        disk.comments[0].updatedAt = now
        try write(disk, to: file)
        let commit = try SessionTaskTransactions.cleanupEmpty(fileURL: file, candidate: baseline, baseline: baseline,
            interval: 1800, excluding: [], now: now)
        #expect(commit.value.isEmpty)
        #expect(commit.state.sessions[1].emptySince == now)
        #expect(!commit.state.sessions[1].isDeleted)
    }

    @Test("Only expired empty sessions are removed, and the active selection returns to Inbox")
    func emptyDeletion() throws {
        let dir = try tempDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("comments.json")
        let baseline = fixture()
        try write(baseline, to: file)
        let commit = try SessionTaskTransactions.cleanupEmpty(fileURL: file, candidate: baseline, baseline: baseline,
            interval: 1800, excluding: [], now: now)
        #expect(commit.value == [baseline.sessions[1].id])
        #expect(commit.state.activeSessionID == baseline.sessions[0].id)
        #expect(!commit.state.sessions[0].isDeleted && commit.state.sessions[1].isDeleted)
        #expect(try read(file) == commit.state)
    }

    @Test("A pin just written by another process protects a session before the UI reloads")
    func freshPinProtectsSession() throws {
        let dir = try tempDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("comments.json")
        let baseline = fixture()
        var pinned = baseline
        pinned.sessions[1].isPinned = true
        for (disk, candidate) in [(pinned, baseline), (baseline, pinned)] {
            try write(disk, to: file)
            let commit = try SessionTaskTransactions.cleanupEmpty(fileURL: file, candidate: candidate, baseline: baseline,
                interval: 1800, excluding: [], now: now)
            #expect(commit.value.isEmpty && commit.state.sessions[1].isPinned)
            #expect(!commit.state.sessions[1].isDeleted && commit.state.sessions[1].emptySince == nil)
            #expect(commit.state.activeSessionID == baseline.activeSessionID)
            #expect(try read(file) == commit.state)
        }
    }

    @Test("An external unpin starts a full empty interval before cleanup, even with an old timestamp")
    func externalUnpin() throws {
        let dir = try tempDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("comments.json")
        var baseline = fixture()
        baseline.sessions[1].isPinned = true
        var disk = baseline
        disk.sessions[1].isPinned = false
        try write(disk, to: file)
        let commit = try SessionTaskTransactions.cleanupEmpty(fileURL: file, candidate: baseline, baseline: baseline,
            interval: 1800, excluding: [], now: now)
        #expect(commit.value.isEmpty && !commit.state.sessions[1].isDeleted)
        #expect(commit.state.sessions[1].emptySince == now)
        #expect(try read(file) == commit.state)
    }

    @Test("A busy document is skipped without queued deletion; a subsequent task remains protected")
    func busyDocument() throws {
        let dir = try tempDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("comments.json")
        let baseline = fixture()
        try write(baseline, to: file)
        try DocumentLock.withLock(file) {
            do {
                _ = try SessionTaskTransactions.cleanupEmpty(fileURL: file, candidate: baseline, baseline: baseline,
                    interval: 1800, excluding: [], now: now)
                Issue.record("Busy cleanup must defer to the next scan")
            } catch let error as PersistenceError {
                #expect(error == .lockTimeout)
            }
        }
        var disk = baseline; disk.comments = [task(baseline.sessions[1].id)]
        try write(disk, to: file)
        let next = try SessionTaskTransactions.cleanupEmpty(fileURL: file, candidate: baseline, baseline: baseline,
            interval: 1800, excluding: [], now: now.addingTimeInterval(60))
        #expect(next.value.isEmpty && next.state.comments == disk.comments)
    }

    @Test("Unreadable documents are never overwritten by cleanup or completion")
    func unreadableDocument() throws {
        let dir = try tempDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("comments.json")
        let baseline = fixture(), corrupt = Data("not-json".utf8)
        try corrupt.write(to: file)
        do {
            _ = try SessionTaskTransactions.cleanupEmpty(fileURL: file, candidate: baseline, baseline: baseline,
                interval: 1800, excluding: [], now: now)
            Issue.record("Corrupt documents must refuse cleanup")
        } catch let error as PersistenceError {
            if case .documentUnreadable = error {} else { Issue.record("Unexpected error: \(error)") }
        }
        do {
            _ = try SessionTaskTransactions.complete(fileURL: file, candidate: baseline, baseline: baseline,
                sessionID: baseline.sessions[1].id, scope: .inProgress, now: now)
            Issue.record("Corrupt documents must refuse completion")
        } catch let error as PersistenceError {
            if case .documentUnreadable = error {} else { Issue.record("Unexpected error: \(error)") }
        }
        #expect(try Data(contentsOf: file) == corrupt)
    }

    @Test("Completion rechecks current disk statuses and Undo preserves a later external edit")
    func freshCompletionAndUndo() throws {
        let dir = try tempDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("comments.json")
        var baseline = fixture()
        baseline.comments = [task(baseline.sessions[1].id, status: .open), task(baseline.sessions[1].id)]
        var disk = baseline
        disk.comments[0].status = .inProgress
        disk.comments[0].commentText = "Fresh text"
        disk.comments[0].updatedAt = now.addingTimeInterval(1)
        disk.comments[1].status = .resolved
        disk.comments[1].resolvedBy = "agent"
        disk.comments[1].updatedAt = now.addingTimeInterval(1)
        try write(disk, to: file)
        let commit = try SessionTaskTransactions.complete(fileURL: file, candidate: baseline, baseline: baseline,
            sessionID: baseline.sessions[1].id, scope: .inProgress, now: now.addingTimeInterval(2))
        #expect(commit.value.commentIDs == [disk.comments[0].id])
        #expect(commit.state.comments[0].commentText == "Fresh text")
        #expect(commit.state.comments[1] == disk.comments[1])
        var later = commit.state
        later.comments[0].commentText = "Newer external text"
        later.comments[0].updatedAt = now.addingTimeInterval(3)
        try write(later, to: file)
        let undo = try SessionTaskTransactions.undo(fileURL: file, candidate: commit.state, baseline: commit.state,
            receipt: commit.value, now: now.addingTimeInterval(4))
        #expect(undo.value.isEmpty)
        #expect(undo.state.comments[0] == later.comments[0])
        #expect(try read(file) == undo.state)
    }

    @Test("A foreign session deletion cannot be undone by clicking a stale completion button")
    func deletedSession() throws {
        let dir = try tempDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("comments.json")
        var baseline = fixture(); baseline.comments = [task(baseline.sessions[1].id)]
        var disk = baseline; disk.sessions[1].isDeleted = true; disk.sessions[1].deletedAt = now
        try write(disk, to: file)
        do {
            _ = try SessionTaskTransactions.complete(fileURL: file, candidate: baseline, baseline: baseline,
                sessionID: baseline.sessions[1].id, scope: .inProgress, now: now)
            Issue.record("A removed session must stay removed")
        } catch let error as PersistenceError { #expect(error == .sessionUnavailable) }
        #expect(try read(file) == disk)
    }

    @Test("Empty-session clocks are local housekeeping and do not change cloud snapshot content")
    func snapshotClockIsolation() throws {
        let dir = try tempDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        var state = fixture()
        let original = try SnapshotArchive.prepare(state, root: dir)
        state.sessions[1].emptySince = now
        let changed = try SnapshotArchive.prepare(state, root: dir)
        #expect(original.hash == changed.hash)
        #expect(changed.state.sessions.allSatisfy { $0.emptySince == nil })
    }

    @Test("Immediate completion and archive are persisted together, with a receipt that can undo from History")
    func atomicArchiveAndUndo() throws {
        let dir = try tempDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("comments.json")
        var baseline = fixture()
        baseline.comments = [task(baseline.sessions[1].id)]
        try write(baseline, to: file)
        let commit = try SessionTaskTransactions.complete(
            fileURL: file, candidate: baseline, baseline: baseline, sessionID: baseline.sessions[1].id,
            scope: .inProgress, archiveImmediately: true, now: now)
        let saved = try read(file)
        #expect(saved == commit.state)
        #expect(saved.comments[0].isDeleted && saved.comments[0].status == .resolved)
        #expect(saved.comments[0].deletedAt == now)
        #expect(saved.sessions[1].emptySince == now, "archiving the last task starts the empty-session clock")
        let undo = try SessionTaskTransactions.undo(
            fileURL: file, candidate: saved, baseline: saved, receipt: commit.value, now: now.addingTimeInterval(1))
        #expect(undo.value == [baseline.comments[0].id])
        #expect(!undo.state.comments[0].isDeleted && undo.state.comments[0].status == .inProgress)
        #expect(undo.state.sessions[1].emptySince == nil)
        #expect(try read(file) == undo.state)
    }

    @Test("Waiting for the document lock leaves the main actor responsive")
    @MainActor
    func completionWriterDoesNotBlockMainActor() async throws {
        let dir = try tempDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("comments.json")
        var baseline = fixture()
        baseline.comments = [task(baseline.sessions[1].id)]
        try write(baseline, to: file)
        let lock = DocumentLock.lockURL(for: file)
        try FileManager.default.createDirectory(at: lock, withIntermediateDirectories: false)
        let writer = SessionTaskWriter()
        let candidate = baseline
        let started = Date()
        let pending = Task {
            try await writer.complete(fileURL: file, candidate: candidate, baseline: candidate,
                sessionID: candidate.sessions[1].id, scope: .inProgress,
                archiveImmediately: true, now: now)
        }
        // This resumes while the writer is still polling the held lock. Running
        // the transaction on MainActor would stall here for its 2-second timeout.
        try await Task.sleep(for: .milliseconds(80))
        #expect(Date().timeIntervalSince(started) < 1)
        try FileManager.default.removeItem(at: lock)
        let commit = try await pending.value
        #expect(commit.state.comments[0].isDeleted)
        #expect(try read(file) == commit.state)
    }

    @Test("Publishing completion retains UI text edits, new tasks and session switching during the background write")
    func completionPublicationRebase() throws {
        let dir = try tempDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("comments.json")
        var baseline = fixture()
        baseline.comments = [task(baseline.sessions[1].id)]
        try write(baseline, to: file)
        let commit = try SessionTaskTransactions.complete(
            fileURL: file, candidate: baseline, baseline: baseline, sessionID: baseline.sessions[1].id,
            scope: .inProgress, archiveImmediately: true, now: now)
        var local = baseline
        local.comments[0].commentText = "Edited while saving"
        let added = task(baseline.sessions[0].id, status: .open)
        local.comments.append(added)
        local.activeSessionID = baseline.sessions[0].id
        let published = AppStateMerge.merge(base: baseline, ours: local, theirs: commit.state)
        #expect(published.comments[0].commentText == "Edited while saving")
        #expect(published.comments[0].isDeleted && published.comments[0].status == .resolved)
        #expect(published.comments[1] == added)
        #expect(published.activeSessionID == local.activeSessionID)
    }
}
