@testable import FeatureComments
@testable import FeatureSettings
@testable import RemarcFeature
import Foundation
import AppKit
import Testing

@Suite("Requirement clipboard and development handoff")
@MainActor
struct RequirementCopyTests {
    @Test("Single and session clipboard copies write the configured Markdown without a fixed requirement header")
    func configuredCopy() {
        let session = Session(name: "Copy")
        let item = FeatureComments.Comment(
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
        let item = FeatureComments.Comment(
            type: .quickNote, commentText: "需求正文", source: "test", appBundleID: nil,
            sessionID: UUID(), status: .open, resolutionSummary: "完成说明", resolvedBy: "agent",
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
        #expect(item.status == .open)
    }

    @Test("A clipboard failure leaves the task status untouched")
    func failedCopyDoesNotStart() {
        let item = FeatureComments.Comment(type: .quickNote, commentText: "正文", source: "test", appBundleID: nil, sessionID: UUID())
        var started = false
        let success = ExportManager.shared.copyCommentAndStartDevelopment(item, copy: { _ in false }, startDevelopment: { _ in started = true })
        #expect(!success)
        #expect(!started)
        #expect(item.status == .open)
    }

    @Test("The task title adds no new fields to the existing Markdown export")
    func titleDoesNotChangeExport() {
        var item = FeatureComments.Comment(type: .quickNote, commentText: "保持原有正文", source: "test", appBundleID: nil, sessionID: UUID())
        let before = ExportManager.shared.markdownForComment(item)
        item.customTitle = "只在界面显示的任务名"
        #expect(ExportManager.shared.markdownForComment(item) == before)
    }

    @Test("Bulk handoff includes reusable context in order, and starts only pending comments")
    func sessionCopyThenStart() throws {
        let session = Session(name: "Current")
        func item(_ status: CommentStatus, sessionID: UUID? = nil, deleted: Bool = false) -> FeatureComments.Comment {
            FeatureComments.Comment(
                type: .quickNote, commentText: status.rawValue, source: "test", appBundleID: nil,
                sessionID: sessionID ?? session.id, isDeleted: deleted, status: status,
                resolutionSummary: status == .resolved ? "完成说明" : nil,
                resolvedBy: status == .resolved ? "agent" : nil,
                resolvedAt: status == .resolved ? Date() : nil
            )
        }
        let open = item(.open), reusable = item(.reusable), inProgress = item(.inProgress)
        let resolved = item(.resolved), other = item(.open, sessionID: UUID()), deleted = item(.open, deleted: true)
        let deferred = item(.deferred)
        let comments = [open, other, deferred, reusable, deleted, inProgress, resolved]
        var events: [String] = []
        let receipt = ExportManager.shared.copySessionAndStartDevelopment(session, comments: comments, copy: { snapshot in
            #expect(snapshot.map(\.id) == [open.id, reusable.id, inProgress.id])
            #expect(snapshot.map(\.status) == [.inProgress, .reusable, .inProgress])
            #expect(snapshot[1] == reusable && snapshot[2] == inProgress)
            #expect(snapshot.allSatisfy { !$0.isDeleted })
            events.append("copied")
            return ExportReceipt(sessionID: session.id, comments: snapshot)
        }, startDevelopment: { ids in
            #expect(ids == [open.id])
            events.append("started")
        })
        let copied = try #require(receipt)
        #expect(copied.count == 3)
        #expect(events == ["copied", "started"])
        #expect(open.status == .open && resolved.status == .resolved && deferred.status == .deferred)
    }

    @Test("Skipped statuses never overwrite the clipboard or start; ordinary copying and reopening still work",
          arguments: [CommentStatus.deferred, .resolved])
    func skippedCopyAndRecovery(status: CommentStatus) throws {
        #expect(!status.canStartDevelopment)
        let session = Session(name: "Skipped work")
        var item = FeatureComments.Comment(type: .quickNote, commentText: "暂缓的需求", source: "test", appBundleID: nil,
                                          sessionID: session.id, status: status)
        let clipboard = TestTextClipboard()
        #expect(ExportManager.shared.copySessionToClipboard(session, comments: [item], format: .markdown, to: clipboard)?.count == 1)
        #expect(clipboard.content?.contains(item.commentText) == true)
        #expect(ExportManager.shared.copyCommentToClipboard(item, to: clipboard)?.count == 1)

        let single = ExportManager.shared.copyCommentAndStartDevelopment(item, copy: { _ in
            Issue.record("A skipped comment must not overwrite the clipboard")
            return true
        }, startDevelopment: { _ in Issue.record("A skipped comment must not start") })
        #expect(!single)
        let bulk = ExportManager.shared.copySessionAndStartDevelopment(session, comments: [item], copy: { _ in
            Issue.record("A session with no eligible comments must not overwrite the clipboard")
            return nil
        }, startDevelopment: { _ in Issue.record("Skipped comments must not start") })
        #expect(bulk == nil)

        item.status = .open
        var startedIDs: [UUID] = []
        let resumed = ExportManager.shared.copySessionAndStartDevelopment(session, comments: [item], copy: { snapshot in
            #expect(snapshot.map(\.status) == [.inProgress])
            return ExportReceipt(sessionID: session.id, comments: snapshot)
        }, startDevelopment: { startedIDs = $0 })
        #expect(try #require(resumed).count == 1)
        #expect(startedIDs == [item.id])
    }

    @Test("Reusable prompts can start repeatedly on their own without status changes or export cleanup")
    func reusablePromptSurvivesRepeatedUse() throws {
        let session = Session(name: "Release")
        let item = FeatureComments.Comment(type: .quickNote, commentText: "发布前检查清单", source: "test", appBundleID: nil,
                                          sessionID: session.id, status: .reusable)
        #expect(item.status.canStartDevelopment)
        #expect(try JSONDecoder().decode(CommentStatus.self, from: Data(#""handedOff""#.utf8)) == .reusable)
        #expect(String(data: try JSONEncoder().encode(item.status), encoding: .utf8) == #""handedOff""#)
        for _ in 0..<3 {
            let success = ExportManager.shared.copyCommentAndStartDevelopment(item, copy: { snapshot in
                #expect(snapshot == item)
                return true
            }, startDevelopment: { _ in Issue.record("Reusable context must not change status or timestamps") })
            #expect(success)
            let receipt = try #require(ExportManager.shared.copySessionAndStartDevelopment(session, comments: [item], copy: { snapshot in
                #expect(snapshot == [item])
                return ExportReceipt(sessionID: session.id, comments: snapshot)
            }, startDevelopment: { _ in Issue.record("Reusable-only sessions must not change status") }))
            #expect(receipt.count == 1)
            #expect(receipt.clearableCommentIDs(in: [item]).isEmpty)
        }
        #expect(!ExportManager.shared.copyCommentAndStartDevelopment(item, copy: { _ in false },
            startDevelopment: { _ in Issue.record("A failed reusable copy must not change status") }))
    }

    @Test("Status filters limit both clipboard actions without changing their status rules")
    func filteredClipboardScope() throws {
        let session = Session(name: "Filtered")
        let comments = CommentStatus.allCases.enumerated().map { index, status in
            FeatureComments.Comment(type: .quickNote, commentText: "scope-marker-\(status.rawValue)", source: "test",
                appBundleID: nil, createdAt: Date(timeIntervalSince1970: Double(index)), sessionID: session.id, status: status)
        }
        let selections: [Set<CommentStatusFilter>] = [[.open, .inProgress], [.reusable], [.deferred], []]
        for selection in selections {
            let visible = CommentListQuery.visibleComments(in: comments, statuses: selection,
                terms: [], sessionName: session.name, newestFirst: true)
            let clipboard = TestTextClipboard()
            let copied = try #require(ExportManager.shared.copySessionToClipboard(
                session, comments: visible, format: .markdown, to: clipboard))
            #expect(Set(copied.commentIDs) == Set(visible.map(\.id)))
            for comment in comments {
                #expect(clipboard.content?.contains(comment.commentText) == visible.contains { $0.id == comment.id })
            }

            var startedIDs: [UUID] = []
            let eligible = visible.filter { $0.status.canStartDevelopment }
            let receipt = ExportManager.shared.copySessionAndStartDevelopment(session, comments: visible, copy: { snapshot in
                #expect(snapshot.map(\.id) == eligible.map(\.id))
                for (original, exported) in zip(eligible, snapshot) {
                    #expect(exported.status == (original.status == .open ? .inProgress : original.status))
                }
                return ExportReceipt(sessionID: session.id, comments: snapshot)
            }, startDevelopment: { startedIDs = $0 })
            #expect((receipt?.count ?? 0) == eligible.count)
            #expect(startedIDs == visible.filter { $0.status == .open }.map(\.id))
        }
    }

    @Test("Bulk copy failure and an empty session never start development")
    func sessionCopyFailure() {
        let session = Session(name: "Current")
        let item = FeatureComments.Comment(type: .quickNote, commentText: "正文", source: "test", appBundleID: nil, sessionID: session.id)
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

    @Test("Starting ongoing work copies it without modifying its status or timestamps")
    func inProgressCopy() {
        #expect(CommentStatus.inProgress.canStartDevelopment)
        #expect(CommentStatus.open.canStartDevelopment)
        let session = Session(name: "Ongoing")
        let item = FeatureComments.Comment(type: .quickNote, commentText: "进行中", source: "test", appBundleID: nil,
                                          sessionID: session.id, status: .inProgress)
        let success = ExportManager.shared.copyCommentAndStartDevelopment(item, copy: { snapshot in
            #expect(snapshot == item)
            return true
        }, startDevelopment: { _ in Issue.record("Ongoing work must remain unchanged") })
        #expect(success)
        let receipt = ExportManager.shared.copySessionAndStartDevelopment(session, comments: [item], copy: { snapshot in
            #expect(snapshot == [item])
            return ExportReceipt(sessionID: session.id, comments: snapshot)
        }, startDevelopment: { _ in Issue.record("Ongoing work must remain unchanged") })
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
