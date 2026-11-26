@testable import FeatureComments
import Foundation
import Testing

@Suite("Card media policy")
struct CardMediaPolicyTests {
    private let sessionID = UUID()

    private func makeComment(type: CommentType, attachments: [String] = []) -> Comment {
        Comment(
            type: type,
            commentText: "Note",
            source: "Test",
            appBundleID: nil,
            sessionID: sessionID,
            attachments: attachments
        )
    }

    @Test("screenshot only uses screenshot path with zero extra images")
    func screenshotOnly() {
        let comment = makeComment(type: .screenshot("shot.png"))
        let media = CardMediaPolicy.leadImage(for: comment)
        #expect(media == CardMediaPolicy.LeadMedia(imagePath: "shot.png", extraImageCount: 0))
    }

    @Test("attachments only uses first attachment and counts remaining attachments")
    func attachmentsOnly() {
        let single = makeComment(type: .quickNote, attachments: ["a.png"])
        #expect(CardMediaPolicy.leadImage(for: single) == .init(imagePath: "a.png", extraImageCount: 0))

        let multiple = makeComment(type: .comment("quoted"), attachments: ["a.png", "b.png", "c.png"])
        #expect(CardMediaPolicy.leadImage(for: multiple) == .init(imagePath: "a.png", extraImageCount: 2))
    }

    @Test("screenshot with attachments leads with screenshot and counts all attachments as extra")
    func screenshotAndAttachments() {
        let comment = makeComment(type: .screenshot("shot.png"), attachments: ["a.png", "b.png"])
        let media = CardMediaPolicy.leadImage(for: comment)
        #expect(media == CardMediaPolicy.LeadMedia(imagePath: "shot.png", extraImageCount: 2))
    }

    @Test("comments without screenshot or attachments return nil")
    func noImages() {
        #expect(CardMediaPolicy.leadImage(for: makeComment(type: .quickNote)) == nil)
        #expect(CardMediaPolicy.leadImage(for: makeComment(type: .comment("quoted"))) == nil)
        #expect(CardMediaPolicy.leadImage(for: makeComment(type: .webElement(name: "Button", path: "App > Button"))) == nil)
    }
}
