@testable import FeatureComments
@testable import FeatureSettings
@testable import RemarcFeature
import Foundation
import Testing

@Suite("History defaults and restoration")
struct HistoryBehaviorTests {
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    @Test("An upgrade applies the new defaults once, then preserves manual choices and other settings")
    @MainActor
    func defaultsMigration() throws {
        let domain = "remarc.history-tests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set(false, forKey: "deleteResolvedComments")
        defaults.set("never", forKey: "resolvedCommentDeletion")
        defaults.set(false, forKey: "inactiveSessionCleanupEnabled")
        defaults.set("after4Hours", forKey: "inactiveSessionCleanupInterval")
        defaults.set(7, forKey: "historyRetentionDays")
        defaults.set(30, forKey: "imageRetentionDays")
        SettingsManager.applyHistoryDefaults(to: defaults)
        #expect(defaults.string(forKey: "resolvedCommentDeletion") == "immediately")
        #expect(defaults.bool(forKey: "inactiveSessionCleanupEnabled"))
        #expect(defaults.string(forKey: "inactiveSessionCleanupInterval") == "after30Minutes")
        #expect(defaults.integer(forKey: "historyRetentionDays") == 7)
        #expect(defaults.object(forKey: "imageRetentionDays") == nil)

        defaults.set("never", forKey: "resolvedCommentDeletion")
        defaults.set(false, forKey: "inactiveSessionCleanupEnabled")
        defaults.set("after1Hour", forKey: "inactiveSessionCleanupInterval")
        defaults.set(14, forKey: "imageRetentionDays")
        let relaunched = try #require(UserDefaults(suiteName: domain))
        SettingsManager.applyHistoryDefaults(to: relaunched)
        #expect(relaunched.string(forKey: "resolvedCommentDeletion") == "never")
        #expect(!relaunched.bool(forKey: "inactiveSessionCleanupEnabled"))
        #expect(relaunched.string(forKey: "inactiveSessionCleanupInterval") == "after1Hour")
        #expect(relaunched.integer(forKey: "historyRetentionDays") == 7)
        #expect(relaunched.object(forKey: "imageRetentionDays") == nil)
    }

    @Test("Fresh defaults are applied independently to each channel")
    @MainActor
    func independentDefaults() throws {
        let first = "remarc.history-tests.\(UUID())"
        let second = "remarc.history-tests.\(UUID())"
        let production = try #require(UserDefaults(suiteName: first))
        let development = try #require(UserDefaults(suiteName: second))
        defer {
            production.removePersistentDomain(forName: first)
            development.removePersistentDomain(forName: second)
        }
        SettingsManager.applyHistoryDefaults(to: production)
        #expect(development.object(forKey: "historyDefaultsVersion") == nil)
        SettingsManager.applyHistoryDefaults(to: development)
        development.set(false, forKey: "inactiveSessionCleanupEnabled")
        #expect(production.bool(forKey: "inactiveSessionCleanupEnabled"))
        #expect(!development.bool(forKey: "inactiveSessionCleanupEnabled"))
        #expect(InactiveSessionCleanupInterval.after30Minutes.interval == 1800)
    }

    private func archivedComment(_ sessionID: UUID, at time: Date) -> FeatureComments.Comment {
        FeatureComments.Comment(type: .screenshot(imagePath: "images/reference.png"), commentText: "Keep this context",
            source: "Test source", appBundleID: nil, sessionID: sessionID, isDeleted: true, deletedAt: time,
            status: .resolved, resolutionSummary: "Completed", resolvedBy: "Test agent", resolvedAt: time,
            attachments: ["images/attachment.png"])
    }

    @Test("Restored comments become pending, retain their content, and do not immediately return to History")
    func restoredCommentStaysActive() {
        let target = UUID()
        var comment = archivedComment(UUID(), at: now.addingTimeInterval(-100))
        let before = comment
        HistoryRestorationPolicy.reopen(&comment, to: target, now: now)
        #expect(!comment.isDeleted && comment.deletedAt == nil)
        #expect(comment.status == .open && comment.resolvedAt == nil && comment.resolvedBy == nil)
        #expect(comment.resolutionSummary == nil)
        #expect(comment.sessionID == target && comment.updatedAt == now)
        #expect(comment.type == before.type && comment.commentText == before.commentText)
        #expect(comment.attachments == before.attachments && comment.source == before.source)
        #expect(ResolvedCommentDeletionPolicy.expiredIDs(in: [comment], interval: 0, now: now.addingTimeInterval(1)).isEmpty)
    }

    @Test("Restoring an empty session restarts 30 minutes without resurrecting earlier archived comments")
    func restoredEmptySession() {
        let inbox = Session(name: "Inbox")
        let session = Session(name: "Finished work", isDeleted: true, deletedAt: now.addingTimeInterval(-100))
        let earlier = archivedComment(session.id, at: now.addingTimeInterval(-2000))
        var state = AppState(sessions: [inbox, session], comments: [earlier], activeSessionID: inbox.id)
        #expect(HistoryRestorationPolicy.restoreSession(session.id, in: &state, maxActiveSessions: 8, now: now))
        #expect(state.activeSessionID == session.id)
        #expect(state.comments == [earlier])
        #expect(!state.sessions[1].isDeleted && state.sessions[1].emptySince == now)
        #expect(EmptySessionCleanupPolicy.expiredIDs(in: state, interval: 1800, now: now.addingTimeInterval(1799)).isEmpty)
        #expect(EmptySessionCleanupPolicy.expiredIDs(in: state, interval: 1800, now: now.addingTimeInterval(1800)) == [session.id])
    }

    @Test("Restoring a deleted session only reopens comments that were deleted with it")
    func restoreSessionWithComments() {
        let session = Session(name: "Work", isDeleted: true, deletedAt: now.addingTimeInterval(-100))
        let together = archivedComment(session.id, at: session.deletedAt!)
        let earlier = archivedComment(session.id, at: now.addingTimeInterval(-200))
        var state = AppState(sessions: [session], comments: [together, earlier])
        #expect(HistoryRestorationPolicy.restoreSession(session.id, in: &state, maxActiveSessions: 8, now: now))
        #expect(!state.comments[0].isDeleted && state.comments[0].status == .open)
        #expect(state.comments[1] == earlier)
        #expect(state.sessions[0].emptySince == nil)
        #expect(EmptySessionCleanupPolicy.expiredIDs(in: state, interval: 1800, now: now.addingTimeInterval(1800)).isEmpty)
        let restored = state
        #expect(!HistoryRestorationPolicy.restoreSession(session.id, in: &state, maxActiveSessions: 8, now: now))
        #expect(state == restored)
    }

    @Test("Restoration checks fresh capacity and preserves comments written by another process")
    func freshSessionRestoration() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("remarc-history-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("comments.json")
        let archived = Session(name: "Old", isDeleted: true, deletedAt: now.addingTimeInterval(-100))
        let baseline = AppState(sessions: [archived])
        let external = Session(name: "New work")
        var disk = baseline
        disk.sessions.append(external)
        disk.comments = [FeatureComments.Comment(type: .quickNote, commentText: "External edit", source: "Tests",
            appBundleID: nil, sessionID: external.id)]
        try JSONEncoder().encode(disk).write(to: file)
        let blocked = try SessionTaskTransactions.restoreHistorySession(fileURL: file, candidate: baseline,
            baseline: baseline, sessionID: archived.id, maxActiveSessions: 1, now: now)
        #expect(!blocked.value && blocked.state.sessions[0].isDeleted)
        #expect(blocked.state.comments == disk.comments)
        let restored = try SessionTaskTransactions.restoreHistorySession(fileURL: file, candidate: baseline,
            baseline: baseline, sessionID: archived.id, maxActiveSessions: 8, now: now)
        #expect(restored.value && !restored.state.sessions[0].isDeleted)
        #expect(restored.state.comments == disk.comments)
        #expect(try JSONDecoder().decode(AppState.self, from: Data(contentsOf: file)) == restored.state)
    }
}
