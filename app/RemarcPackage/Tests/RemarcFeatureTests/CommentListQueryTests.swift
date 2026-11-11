import Foundation
import Testing
@testable import RemarcFeature

@Suite("Comment list filtering and search")
struct CommentListQueryTests {
    private func comment(
        _ text: String = "正文",
        title: String? = nil,
        quote: String? = nil,
        status: CommentStatus = .open,
        session: UUID = UUID(),
        createdAt: Date = Date()
    ) -> RemarcFeature.Comment {
        RemarcFeature.Comment(
            type: quote.map { .comment(text: $0) } ?? .quickNote,
            commentText: text, source: "Safari", appBundleID: nil,
            createdAt: createdAt, sessionID: session, status: status, customTitle: title
        )
    }

    @Test("Status buckets: in progress covers handed off; every status lands in exactly one bucket")
    func statusBuckets() {
        #expect(CommentStatusFilter.inProgress.includes(.handedOff))
        #expect(CommentStatusFilter.inProgress.includes(.inProgress))
        #expect(!CommentStatusFilter.open.includes(.handedOff))
        for status in CommentStatus.allCases {
            #expect(CommentStatusFilter.allCases.filter { $0.includes(status) }.count == 1)
        }
        let counts = CommentListQuery.counts(of: [
            comment(status: .open), comment(status: .handedOff),
            comment(status: .inProgress), comment(status: .resolved),
        ])
        #expect(counts[.open] == 1)
        #expect(counts[.inProgress] == 2)
        #expect(counts[.resolved] == 1)
    }

    @Test("Chips combine; selecting none shows every status")
    func multiSelectFilter() {
        let items = [comment("o", status: .open), comment("h", status: .handedOff),
                     comment("p", status: .inProgress), comment("r", status: .resolved)]
        #expect(CommentListQuery.filtered(items, statuses: []).count == 4)
        #expect(CommentListQuery.filtered(items, statuses: [.open]).map(\.commentText) == ["o"])
        #expect(CommentListQuery.filtered(items, statuses: [.open, .inProgress]).map(\.commentText) == ["o", "h", "p"])
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
        #expect(progress[a] == 2)
        #expect(progress[b, default: 0] == 0)
        #expect(CommentListQuery.countsBySession(of: items, statuses: [.open, .inProgress])[a] == 3)
        let resolved = CommentListQuery.countsBySession(of: items, statuses: [.resolved])
        #expect(resolved[a] == 1)
        #expect(resolved[b] == 1)
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
        let value = CommentStatusFilter.storageValue(of: [.resolved, .open])
        #expect(value == "open,resolved")
        #expect(CommentStatusFilter.selection(from: value) == [.open, .resolved])
        #expect(CommentStatusFilter.selection(from: "outstanding,inProgress") == [.inProgress])
        #expect(CommentStatusFilter.selection(from: "").isEmpty)
    }

    @Test("Resolved comments sink below outstanding ones, order kept within each")
    func unresolvedFirst() {
        let items = [comment("r1", status: .resolved), comment("o1"), comment("r2", status: .resolved),
                     comment("p1", status: .inProgress)]
        #expect(CommentListQuery.unresolvedFirst(items).map(\.commentText) == ["o1", "p1", "r1", "r2"])
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
