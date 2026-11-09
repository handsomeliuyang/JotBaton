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

    @Test("Status buckets: in progress covers handed off, outstanding excludes resolved")
    func statusBuckets() {
        #expect(CommentStatusFilter.inProgress.includes(.handedOff))
        #expect(CommentStatusFilter.inProgress.includes(.inProgress))
        #expect(!CommentStatusFilter.open.includes(.handedOff))
        #expect(!CommentStatusFilter.outstanding.includes(.resolved))
        let counts = CommentListQuery.counts(of: [
            comment(status: .open), comment(status: .handedOff),
            comment(status: .inProgress), comment(status: .resolved),
        ])
        #expect(counts[.outstanding] == 3)
        #expect(counts[.open] == 1)
        #expect(counts[.inProgress] == 2)
        #expect(counts[.resolved] == 1)
    }

    @Test("Search matches the custom task title shown on the card")
    func titleIsSearchable() {
        let item = comment("无关正文", title: "PromptSite的web站点可以独立git仓库")
        #expect(CommentListQuery.matches(item, terms: ["独立git"], sessionName: nil))
        #expect(CommentListQuery.matches(item, terms: ["promptsite"], sessionName: nil))
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
