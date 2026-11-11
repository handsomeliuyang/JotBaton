import Foundation
import AppKit
import Testing
@testable import RemarcFeature

@Suite("Requirement clipboard and development handoff")
@MainActor
struct RequirementCopyTests {
    @Test("Single and session clipboard copies write the configured Markdown without a fixed requirement header")
    func configuredCopy() {
        let session = Session(name: "Copy")
        let item = RemarcFeature.Comment(
            type: .screenshot(imagePath: "images/screenshot.png"), commentText: "/plan\n!literal command",
            source: "test", appBundleID: nil, sessionID: session.id,
            attachments: ["images/attachment.png"]
        )
        let clipboard = TestTextClipboard()
        #expect(ExportManager.shared.copyCommentToClipboard(item, to: clipboard) != nil)
        #expect(clipboard.content == ExportManager.shared.markdownForComment(item))
        #expect(clipboard.content?.hasPrefix("需求\n") == false)
        #expect(clipboard.content?.contains("/plan\n!literal command") == true)

        #expect(ExportManager.shared.copySessionToClipboard(session, comments: [item], format: .markdown, to: clipboard) != nil)
        #expect(clipboard.content == ExportManager.shared.markdownForSession(session, comments: [item], includeMetadata: true))
        #expect(clipboard.content?.hasPrefix("需求\n") == false)

        #expect(ExportManager.shared.copySessionToClipboard(session, comments: [item], format: .json, to: clipboard) != nil)
        #expect(clipboard.content == ExportManager.shared.jsonForSession(session, comments: [item], includeMetadata: SettingsManager.shared.includeMetadataInExport))
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

    @Test("Bulk handoff copies the active session in order, starts only pending comments, and preserves completed work")
    func sessionCopyThenStart() throws {
        let session = Session(name: "Current")
        func item(_ status: CommentStatus, sessionID: UUID? = nil, deleted: Bool = false) -> RemarcFeature.Comment {
            RemarcFeature.Comment(
                type: .quickNote, commentText: status.rawValue, source: "test", appBundleID: nil,
                sessionID: sessionID ?? session.id, isDeleted: deleted, status: status,
                resolutionSummary: status == .resolved ? "完成说明" : nil,
                resolvedBy: status == .resolved ? "agent" : nil,
                resolvedAt: status == .resolved ? Date() : nil
            )
        }
        let open = item(.open), handedOff = item(.handedOff), inProgress = item(.inProgress)
        let resolved = item(.resolved), other = item(.open, sessionID: UUID()), deleted = item(.open, deleted: true)
        let comments = [open, other, handedOff, deleted, inProgress, resolved]
        var events: [String] = []
        let receipt = ExportManager.shared.copySessionAndStartDevelopment(session, comments: comments, copy: { snapshot in
            #expect(snapshot.map(\.id) == [open.id, handedOff.id, inProgress.id, resolved.id])
            #expect(snapshot.map(\.status) == [.inProgress, .inProgress, .inProgress, .resolved])
            #expect(snapshot[2] == inProgress)
            #expect(snapshot[3] == resolved)
            #expect(snapshot.allSatisfy { !$0.isDeleted })
            events.append("copied")
            return ExportReceipt(sessionID: session.id, comments: snapshot)
        }, startDevelopment: { ids in
            #expect(ids == [open.id, handedOff.id])
            events.append("started")
        })
        let copied = try #require(receipt)
        #expect(copied.count == 4)
        #expect(events == ["copied", "started"])
        #expect(open.status == .open && resolved.status == .resolved)
    }

    @Test("Bulk copy failure and an empty session never start development")
    func sessionCopyFailure() {
        let session = Session(name: "Current")
        let item = RemarcFeature.Comment(type: .quickNote, commentText: "正文", source: "test", appBundleID: nil, sessionID: session.id)
        var copied = false
        let failed = ExportManager.shared.copySessionAndStartDevelopment(session, comments: [item], copy: { _ in
            copied = true
            return nil
        }, startDevelopment: { _ in Issue.record("A failed copy must not change status") })
        #expect(copied && failed == nil)
        let empty = ExportManager.shared.copySessionAndStartDevelopment(session, comments: [], copy: { _ in
            Issue.record("An empty session must not overwrite the clipboard")
            return nil
        }, startDevelopment: { _ in Issue.record("An empty session must not change status") })
        #expect(empty == nil)
    }

    @Test("Copying an entirely completed session never reopens its comments")
    func completedSessionCopy() {
        let session = Session(name: "Done")
        let item = RemarcFeature.Comment(type: .quickNote, commentText: "已完成", source: "test", appBundleID: nil, sessionID: session.id, status: .resolved)
        let receipt = ExportManager.shared.copySessionAndStartDevelopment(session, comments: [item], copy: { snapshot in
            #expect(snapshot == [item])
            return ExportReceipt(sessionID: session.id, comments: snapshot)
        }, startDevelopment: { _ in Issue.record("Completed comments must stay completed") })
        #expect(receipt?.count == 1)
    }
}

@MainActor
private final class TestTextClipboard: TextClipboardDestination {
    var content: String?

    func clearContents() -> Int { content = nil; return 1 }
    func setString(_ string: String, forType: NSPasteboard.PasteboardType) -> Bool {
        content = string
        return true
    }
}
