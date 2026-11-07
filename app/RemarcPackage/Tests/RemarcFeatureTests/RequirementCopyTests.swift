import Foundation
import Testing
@testable import RemarcFeature

@Suite("Requirement clipboard and development handoff")
@MainActor
struct RequirementCopyTests {
    @Test("Only the fixed requirement line is added; image syntax, special prefixes and ordering remain exact")
    func prefixOnly() {
        for original in ["![screenshot](</a%20b/image.png>)\nComment: text", "/plan\n!literal command", "1. first\n---\n2. second"] {
            #expect(ExportManager.clipboardMarkdown(original) == "需求\n" + original)
        }
        #expect(ExportManager.clipboardMarkdown("").isEmpty)
    }

    @Test("Development status changes only after a successful copy, with the intended status in the snapshot")
    func copyThenStart() {
        let item = RemarcFeature.Comment(
            type: .quickNote, commentText: "需求正文", source: "test", appBundleID: nil,
            sessionID: UUID(), status: .resolved, resolutionSummary: "完成说明", resolvedBy: "agent",
            resolvedAt: Date(), customTitle: "任务名称"
        )
        var events: [String] = []
        let success = ExportManager.shared.copyCommentAndStartDevelopment(item, copy: { snapshot in
            #expect(snapshot.status == .inProgress)
            #expect(snapshot.customTitle == item.customTitle)
            #expect(snapshot.resolutionSummary == nil && snapshot.resolvedAt == nil && snapshot.resolvedBy == nil)
            events.append("copied")
            return true
        }, startDevelopment: { id in
            #expect(id == item.id)
            events.append("started")
        })
        #expect(success)
        #expect(events == ["copied", "started"])
        #expect(item.status == .resolved)
    }

    @Test("A clipboard failure leaves the task status untouched")
    func failedCopyDoesNotStart() {
        let item = RemarcFeature.Comment(type: .quickNote, commentText: "正文", source: "test", appBundleID: nil, sessionID: UUID())
        var started = false
        let success = ExportManager.shared.copyCommentAndStartDevelopment(item, copy: { _ in false }, startDevelopment: { _ in started = true })
        #expect(!success)
        #expect(!started)
        #expect(item.status == .open)
    }

    @Test("The task title adds no new fields to the existing Markdown export")
    func titleDoesNotChangeExport() {
        var item = RemarcFeature.Comment(type: .quickNote, commentText: "保持原有正文", source: "test", appBundleID: nil, sessionID: UUID())
        let before = ExportManager.shared.markdownForComment(item)
        item.customTitle = "只在界面显示的任务名"
        #expect(ExportManager.shared.markdownForComment(item) == before)
    }
}
