@testable import FeatureComments
@testable import RemarcFeature
import Foundation
import Testing

@Suite("Comment list filtering and search")
struct CommentListQueryTests {
    private func comment(
        _ text: String = "正文",
        title: String? = nil,
        quote: String? = nil,
        status: CommentStatus = .open,
        session: UUID = UUID(),
        createdAt: Date = Date()
    ) -> FeatureComments.Comment {
        FeatureComments.Comment(
            type: quote.map { .comment(text: $0) } ?? .quickNote,
            commentText: text, source: "Safari", appBundleID: nil,
            createdAt: createdAt, sessionID: session, status: status, customTitle: title
        )
    }

    @Test("The four unfinished status buckets are separate; completed work has no chip")
    func statusBuckets() {
        #expect(CommentStatusFilter.allCases.map(\.rawValue) == ["open", "handedOff", "inProgress", "deferred"])
        #expect(!CommentStatusFilter.inProgress.includes(.handedOff))
        #expect(CommentStatusFilter.handedOff.includes(.handedOff))
        #expect(CommentStatusFilter.inProgress.includes(.inProgress))
        #expect(!CommentStatusFilter.open.includes(.handedOff))
        for status in CommentStatus.allCases {
            #expect(CommentStatusFilter.allCases.filter { $0.includes(status) }.count == (status == .resolved ? 0 : 1))
        }
        let counts = CommentListQuery.counts(of: [
            comment(status: .open), comment(status: .handedOff),
            comment(status: .inProgress), comment(status: .deferred), comment(status: .resolved),
        ])
        #expect(counts[.open] == 1)
        #expect(counts[.handedOff] == 1)
        #expect(counts[.inProgress] == 1)
        #expect(counts[.deferred] == 1)
        #expect(counts.values.reduce(0, +) == 4)
    }

    @Test("Chips combine; selecting none shows every status")
    func multiSelectFilter() {
        let items = [comment("o", status: .open), comment("h", status: .handedOff),
                     comment("p", status: .inProgress), comment("r", status: .resolved)]
        #expect(CommentListQuery.filtered(items, statuses: []).count == 4)
        #expect(CommentListQuery.filtered(items, statuses: [.open]).map(\.commentText) == ["o"])
        #expect(CommentListQuery.filtered(items, statuses: [.handedOff]).map(\.commentText) == ["h"])
        #expect(CommentListQuery.filtered(items, statuses: [.open, .inProgress]).map(\.commentText) == ["o", "p"])
    }

    @Test("Each session count follows the selected chips and excludes deleted comments")
    func sidebarStatusCounts() {
        let a = UUID(), b = UUID(), empty = UUID()
        var deleted = comment(status: .open, session: a)
        deleted.isDeleted = true
        let items = [comment(status: .open, session: a), comment(status: .handedOff, session: a),
                     comment(status: .inProgress, session: a), comment(status: .resolved, session: a),
                     comment(status: .resolved, session: b), deleted]
        let all = CommentListQuery.countsBySession(of: items, statuses: [])
        #expect(all[a] == 4)
        #expect(all[b] == 1)
        #expect(all[empty, default: 0] == 0)
        let progress = CommentListQuery.countsBySession(of: items, statuses: [.inProgress])
        #expect(progress[a] == 1)
        #expect(progress[b, default: 0] == 0)
        #expect(CommentListQuery.countsBySession(of: items, statuses: [.open, .inProgress])[a] == 2)
        let handedOff = CommentListQuery.countsBySession(of: items, statuses: [.handedOff])
        #expect(handedOff[a] == 1)
        #expect(handedOff[b, default: 0] == 0)
    }

    @Test("Status edits and session moves update counts using the same rule as the header")
    func sidebarCountsAfterEdits() {
        let a = UUID(), b = UUID()
        var items = [comment(status: .open, session: a), comment(status: .inProgress, session: a)]
        items[0].status = .inProgress
        #expect(CommentListQuery.countsBySession(of: items, statuses: [.open])[a, default: 0] == 0)
        #expect(CommentListQuery.countsBySession(of: items, statuses: [.inProgress])[a] == 2)
        items[1].status = .resolved
        items[1].sessionID = b
        for session in [a, b] {
            let scoped = items.filter { $0.sessionID == session }
            let header = CommentListQuery.counts(of: scoped)
            for filter in CommentStatusFilter.allCases {
                let sidebar = CommentListQuery.countsBySession(of: items, statuses: [filter])
                #expect(sidebar[session, default: 0] == header[filter, default: 0])
            }
        }
    }

    @Test("Selection round-trips through storage and ignores retired values")
    func selectionStorage() {
        let value = CommentStatusFilter.storageValue(of: [.handedOff, .open])
        #expect(value == "open,handedOff")
        #expect(CommentStatusFilter.selection(from: value) == [.open, .handedOff])
        #expect(CommentStatusFilter.selection(from: "resolved").isEmpty)
        #expect(CommentStatusFilter.selection(from: "resolved,open") == [.open])
        #expect(CommentStatusFilter.selection(from: "outstanding,inProgress") == [.inProgress])
        #expect(CommentStatusFilter.selection(from: "").isEmpty)
    }

    @Test("Resolved comments sink below outstanding ones, order kept within each")
    func unresolvedFirst() {
        let items = [comment("r1", status: .resolved), comment("o1"), comment("r2", status: .resolved),
                     comment("p1", status: .inProgress)]
        #expect(CommentListQuery.unresolvedFirst(items).map(\.commentText) == ["o1", "p1", "r1", "r2"])
    }

    @Test("On-hold work follows active work and precedes completed work in either time order; reopening restores its place")
    func deferredOrderingAndRecovery() {
        var items = [comment("d1", status: .deferred, createdAt: Date(timeIntervalSince1970: 1)),
                     comment("r1", status: .resolved, createdAt: Date(timeIntervalSince1970: 2)),
                     comment("o1", createdAt: Date(timeIntervalSince1970: 3)),
                     comment("d2", status: .deferred, createdAt: Date(timeIntervalSince1970: 4)),
                     comment("p1", status: .inProgress, createdAt: Date(timeIntervalSince1970: 5))]
        for newestFirst in [false, true] {
            let sorted = CommentListQuery.sorted(items, newestFirst: newestFirst)
            #expect(CommentListQuery.unresolvedFirst(sorted).map(\.commentText) ==
                    (newestFirst ? ["p1", "o1", "d2", "d1", "r1"] : ["o1", "p1", "d1", "d2", "r1"]))
        }
        #expect(CommentListQuery.filtered(items, statuses: [.open]).map(\.commentText) == ["o1"])
        #expect(CommentListQuery.filtered(items, statuses: [.deferred]).map(\.commentText) == ["d1", "d2"])
        #expect(CommentStatusFilter.selection(from: CommentStatusFilter.storageValue(of: [.deferred])) == [.deferred])
        #expect(CommentListQuery.countsBySession(of: items, statuses: [.deferred])[items[0].sessionID] == 1)
        items[0].status = .open
        #expect(CommentListQuery.unresolvedFirst(items).map(\.commentText) == ["d1", "o1", "p1", "d2", "r1"])
    }

    @Test("Retired titles do not produce invisible search matches")
    func retiredTitleIsNotSearchable() {
        let item = comment("无关正文", title: "PromptSite的web站点可以独立git仓库")
        #expect(!CommentListQuery.matches(item, terms: ["独立git"], sessionName: nil))
        #expect(!CommentListQuery.matches(item, terms: ["promptsite"], sessionName: nil))
    }

    @Test("Every term must match, across any field")
    func termsAreAnded() {
        let item = comment("agentmesh 新能力", quote: "POST /api/project-applications")
        let terms = CommentListQuery.searchTerms(from: "  AgentMesh   project-applications ")
        #expect(terms == ["AgentMesh", "project-applications"])
        #expect(CommentListQuery.matches(item, terms: terms, sessionName: nil))
        #expect(!CommentListQuery.matches(item, terms: ["agentmesh", "不存在"], sessionName: nil))
        #expect(CommentListQuery.matches(item, terms: ["agentmesh", "PromptSite"], sessionName: "PromptSite"))
        #expect(CommentListQuery.matches(item, terms: [item.shortID], sessionName: nil))
    }

    @Test("Highlight ranges find every case-insensitive occurrence")
    func highlightRanges() {
        let text = "Git 仓库和 git 分支"
        let ranges = CommentListQuery.matchRanges(of: ["git"], in: text)
        #expect(ranges.map { String(text[$0]) } == ["Git", "git"])
    }

    @Test("Groups follow session order and skip sessions without comments")
    func grouping() {
        let a = Session(name: "A"), b = Session(name: "B"), c = Session(name: "C")
        let items = [comment(session: c.id), comment(session: a.id), comment(session: c.id)]
        let groups = CommentListQuery.grouped(items, sessions: [a, b, c])
        #expect(groups.map(\.session.name) == ["A", "C"])
        #expect(groups.last?.comments.count == 2)
    }

    @Test("Sorting honours the newest-first toggle")
    func sorting() {
        let older = comment("old", createdAt: Date(timeIntervalSince1970: 1))
        let newer = comment("new", createdAt: Date(timeIntervalSince1970: 2))
        #expect(CommentListQuery.sorted([older, newer], newestFirst: true).map(\.commentText) == ["new", "old"])
        #expect(CommentListQuery.sorted([newer, older], newestFirst: false).map(\.commentText) == ["old", "new"])
    }
}
