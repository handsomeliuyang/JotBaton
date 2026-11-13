@testable import FeatureComments
@testable import RemarcFeature
import Foundation
import Testing

@Suite("Pinned project sessions")
struct SessionPinningTests {
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func project(pinned: Bool = false) -> Session {
        Session(name: "Project", createdAt: now.addingTimeInterval(-7200),
                emptySince: now.addingTimeInterval(-7200), isPinned: pinned)
    }

    @Test("Legacy sessions default to unpinned; pinned state round-trips without shadow unknown fields")
    func codingCompatibility() throws {
        let item = project()
        let legacy = try JSONEncoder().encode(item)
        let legacyJSON = try #require(JSONSerialization.jsonObject(with: legacy) as? [String: Any])
        #expect(legacyJSON["isPinned"] == nil)
        #expect(try JSONDecoder().decode(Session.self, from: legacy).isPinned == false)

        var raw = legacyJSON
        raw["isPinned"] = true
        raw["futureProjectField"] = "preserved"
        var pinned = try JSONDecoder().decode(Session.self, from: JSONSerialization.data(withJSONObject: raw))
        #expect(pinned.isPinned)
        #expect(pinned.unknownFields["isPinned"] == nil)
        let roundTrip = try JSONDecoder().decode(Session.self, from: JSONEncoder().encode(pinned))
        #expect(roundTrip == pinned)
        pinned.isPinned = false
        let unpinnedData = try JSONEncoder().encode(pinned)
        let unpinned = try #require(JSONSerialization.jsonObject(with: unpinnedData) as? [String: Any])
        #expect(unpinned["isPinned"] == nil)
        #expect(unpinned["futureProjectField"] as? String == "preserved")
    }

    @Test("An empty pinned project survives cleanup even with an expired legacy timestamp")
    func pinnedEmptySessionSurvives() {
        let item = project(pinned: true)
        var state = AppState(sessions: [item], activeSessionID: item.id)
        #expect(EmptySessionCleanupPolicy.expiredIDs(in: state, interval: 1800, now: now).isEmpty)
        let before = state
        #expect(EmptySessionCleanupPolicy.reconcile(&state, previous: before, now: now))
        #expect(state.sessions[0].emptySince == nil)
        #expect(EmptySessionCleanupPolicy.removeExpired(from: &state, interval: 1800,
                                                      now: now.addingTimeInterval(86400)).isEmpty)
        #expect(state.activeSessionID == item.id)
        #expect(!state.sessions[0].isDeleted)
    }

    @Test("Unpinning an empty project starts a fresh interval; repeated clicks do not extend it")
    func unpinRestartsClock() {
        let item = project(pinned: true)
        var state = AppState(sessions: [item], activeSessionID: item.id)
        let pinned = state
        #expect(SessionPinningPolicy.setPinned(false, for: item.id, in: &state, now: now))
        EmptySessionCleanupPolicy.reconcile(&state, previous: pinned, now: now)
        #expect(state.sessions[0].emptySince == now)
        #expect(!SessionPinningPolicy.setPinned(false, for: item.id, in: &state, now: now.addingTimeInterval(600)))
        #expect(state.sessions[0].emptySince == now)
        #expect(EmptySessionCleanupPolicy.expiredIDs(in: state, interval: 1800,
                                                   now: now.addingTimeInterval(1799)).isEmpty)
        #expect(EmptySessionCleanupPolicy.expiredIDs(in: state, interval: 1800,
                                                   now: now.addingTimeInterval(1800)) == [item.id])
        #expect(SessionPinningPolicy.setPinned(true, for: item.id, in: &state, now: now.addingTimeInterval(1800)))
        #expect(state.sessions[0].emptySince == nil)
    }

    @Test("Pinning changes no comments or selection; occupied projects start their clock only after their last comment leaves")
    func commentsStayIndependent() {
        let item = project()
        let task = FeatureComments.Comment(type: .quickNote, commentText: "Task", source: "Tests", appBundleID: nil,
                                         sessionID: item.id, status: .resolved)
        var state = AppState(sessions: [item], comments: [task], activeSessionID: item.id)
        #expect(SessionPinningPolicy.setPinned(true, for: item.id, in: &state, now: now))
        #expect(state.comments == [task] && state.activeSessionID == item.id)
        #expect(SessionPinningPolicy.setPinned(false, for: item.id, in: &state, now: now))
        #expect(state.sessions[0].emptySince == nil)
        let occupied = state
        state.comments[0].isDeleted = true
        state.comments[0].deletedAt = now.addingTimeInterval(600)
        EmptySessionCleanupPolicy.reconcile(&state, previous: occupied, now: now.addingTimeInterval(600))
        #expect(state.sessions[0].emptySince == now.addingTimeInterval(600))
        #expect(SessionPinningPolicy.setPinned(true, for: item.id, in: &state, now: now.addingTimeInterval(700)))
        #expect(state.comments[0].isDeleted && state.comments[0].status == .resolved)
        #expect(state.sessions[0].emptySince == nil)
    }

    @Test("Inbox and removed sessions cannot be pinned; automatic dismissal is repaired while explicit deletion remains")
    func visibilityAndDeletion() {
        let inbox = Session(name: "Inbox")
        var dismissed = project(pinned: true)
        dismissed.isAutoDismissed = true
        dismissed.autoDismissedAt = now
        var deleted = project(pinned: true)
        deleted.isDeleted = true
        deleted.deletedAt = now
        var state = AppState(sessions: [inbox, dismissed, deleted])
        #expect(!SessionPinningPolicy.setPinned(true, for: inbox.id, in: &state, now: now))
        #expect(!SessionPinningPolicy.setPinned(false, for: deleted.id, in: &state, now: now))
        let before = state
        EmptySessionCleanupPolicy.reconcile(&state, previous: before, now: now)
        #expect(!state.sessions[1].isAutoDismissed && state.sessions[1].autoDismissedAt == nil)
        #expect(state.sessions[2].isDeleted && state.sessions[2].deletedAt == now)
        #expect(SessionPinningPolicy.activeSessions(in: state.sessions).map(\.id) == [inbox.id, dismissed.id])
    }

    @Test("Navigation keeps Inbox first and stable order within pinned and ordinary groups")
    func stableOrdering() {
        let first = project(), pin1 = project(pinned: true), inbox = Session(name: "Inbox")
        let second = project(), pin2 = project(pinned: true)
        var deleted = project(pinned: true); deleted.isDeleted = true
        var dismissed = project(); dismissed.isAutoDismissed = true
        var state = AppState(sessions: [first, pin1, inbox, second, pin2, deleted, dismissed])
        #expect(SessionPinningPolicy.activeSessions(in: state.sessions).map(\.id)
                == [inbox.id, pin1.id, pin2.id, first.id, second.id])
        #expect(SessionPinningPolicy.setPinned(false, for: pin1.id, in: &state, now: now))
        #expect(SessionPinningPolicy.activeSessions(in: state.sessions).map(\.id)
                == [inbox.id, pin2.id, first.id, pin1.id, second.id])
        #expect(state.sessions.map(\.id) == [first.id, pin1.id, inbox.id, second.id, pin2.id, deleted.id, dismissed.id])
    }

    @Test("Restoring a manually deleted pinned session retains the pin and never starts an empty clock")
    func restorePinnedSession() {
        var item = project(pinned: true)
        item.isDeleted = true
        item.deletedAt = now.addingTimeInterval(-60)
        var state = AppState(sessions: [Session(name: "Inbox"), item])
        #expect(HistoryRestorationPolicy.restoreSession(item.id, in: &state, now: now))
        #expect(state.sessions[1].isPinned && !state.sessions[1].isDeleted)
        #expect(state.sessions[1].emptySince == nil && state.activeSessionID == item.id)
    }

    @Test("Pin state merges independently of concurrent renames, and explicit session deletion still wins")
    func concurrentChanges() {
        let base = AppState(sessions: [project()])
        var ours = base, theirs = base
        ours.sessions[0].name = "Renamed project"
        theirs.sessions[0].isPinned = true
        let merged = AppStateMerge.merge(base: base, ours: ours, theirs: theirs)
        #expect(merged.sessions[0].name == ours.sessions[0].name && merged.sessions[0].isPinned)
        #expect(AppStateMerge.merge(base: base, ours: theirs, theirs: ours).sessions[0] == merged.sessions[0])

        var unpin = merged, rename = merged
        unpin.sessions[0].isPinned = false
        rename.sessions[0].name = "Another name"
        let unpinned = AppStateMerge.merge(base: merged, ours: unpin, theirs: rename)
        #expect(!unpinned.sessions[0].isPinned && unpinned.sessions[0].name == rename.sessions[0].name)

        theirs = base
        theirs.sessions[0].isDeleted = true
        theirs.sessions[0].deletedAt = now
        ours.sessions[0].isPinned = true
        var removed = AppStateMerge.merge(base: base, ours: ours, theirs: theirs)
        let previous = removed
        EmptySessionCleanupPolicy.reconcile(&removed, previous: previous, now: now)
        #expect(removed.sessions[0].isDeleted)
        #expect(SessionPinningPolicy.activeSessions(in: removed.sessions).isEmpty)
    }
}
