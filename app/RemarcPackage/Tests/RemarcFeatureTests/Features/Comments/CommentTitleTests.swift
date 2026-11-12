@testable import FeatureComments
@testable import RemarcFeature
import Foundation
import Testing

private typealias TaskComment = FeatureComments.Comment

@Suite("Legacy title storage compatibility")
struct CommentTitleTests {
    @Test("Historical titles survive body edits and a JSON round trip")
    func customTitleRoundTrip() throws {
        var item = TaskComment(
            type: .comment(text: "引用"), commentText: "正文", source: "test", appBundleID: nil,
            sessionID: UUID(), customTitle: "  自定义\n任务名  "
        )
        item.commentText = "改过的正文"
        let decoded = try JSONDecoder().decode(TaskComment.self, from: JSONEncoder().encode(item))
        #expect(decoded.customTitle == "自定义 任务名")
        #expect(decoded.commentText == "改过的正文")
    }

    @Test("Comments without a legacy title remain readable and do not acquire one")
    func legacyJSON() throws {
        let item = TaskComment(
            type: .quickNote, commentText: "任务正文", source: "test", appBundleID: nil,
            sessionID: UUID(), customTitle: "移除这个字段"
        )
        var raw = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(item)) as? [String: Any])
        raw.removeValue(forKey: "customTitle")
        let decoded = try JSONDecoder().decode(TaskComment.self, from: JSONSerialization.data(withJSONObject: raw))
        #expect(decoded.customTitle == nil)
        #expect(decoded.commentText == "任务正文")
        let encoded = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(decoded)) as? [String: Any])
        #expect(encoded["customTitle"] == nil)
    }
}
