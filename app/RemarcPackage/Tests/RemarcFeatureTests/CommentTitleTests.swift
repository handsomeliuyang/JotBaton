import Foundation
import Testing
@testable import RemarcFeature

private typealias TaskComment = RemarcFeature.Comment

@Suite("Task titles")
struct CommentTitleTests {
    private func comment(type: CommentType = .quickNote, body: String = "任务正文", title: String? = nil) -> TaskComment {
        TaskComment(type: type, commentText: body, source: "Screenshot", appBundleID: nil,
                    sessionID: UUID(), customTitle: title)
    }

    @Test("Custom titles survive body edits and a JSON round trip; clearing restores the automatic title")
    func customTitleRoundTrip() throws {
        var item = comment(type: .comment(text: "引用标题"), title: "  自定义\n任务名  ")
        item.commentText = "改过的正文"
        let decoded = try JSONDecoder().decode(TaskComment.self, from: JSONEncoder().encode(item))
        #expect(decoded.taskTitle == "自定义 任务名")
        item.customTitle = " \n "
        #expect(item.taskTitle == "引用标题")
    }

    @Test("Old comments without a title field remain readable")
    func legacyJSON() throws {
        let item = comment(title: "移除这个字段")
        var raw = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(item)) as? [String: Any])
        raw.removeValue(forKey: "customTitle")
        let decoded = try JSONDecoder().decode(TaskComment.self, from: JSONSerialization.data(withJSONObject: raw))
        #expect(decoded.customTitle == nil)
        #expect(decoded.taskTitle == "任务正文")
    }

    @Test("Automatic names prefer reference text, then the first meaningful body line")
    func automaticPriority() {
        #expect(comment(type: .comment(text: "\n  \n引用标题\n其他引用"), body: "备注标题").taskTitle == "引用标题")
        #expect(comment(type: .screenshot(imagePath: "images/capture.png"), body: "\n  \n截图任务\n需求细节").taskTitle == "截图任务")
    }

    @Test("Readable filenames work, but generated screenshot identifiers and type labels are not titles")
    func filenameFallback() {
        #expect(comment(type: .screenshot(imagePath: "images/页面布局.png"), body: "").taskTitle == "页面布局")
        #expect(comment(type: .screenshot(imagePath: "images/\(UUID()).png"), body: "").taskTitle == "未命名任务")
        #expect(comment(type: .screenshot(imagePath: "Screenshot-2026-11-07.png"), body: "").taskTitle == "未命名任务")
        #expect(comment(body: " ").taskTitle == "未命名任务")
    }

    @Test("Automatic truncation counts user-visible characters and leaves the body intact")
    func unicodeTitle() {
        let body = String(repeating: "👨‍👩‍👧‍👦", count: 30)
        let item = comment(body: body)
        #expect(item.taskTitle.count == 24)
        #expect(item.commentText == body)
    }
}
