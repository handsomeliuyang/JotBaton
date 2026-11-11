import Foundation
import Testing
@testable import RemarcFeature

private typealias LayoutComment = RemarcFeature.Comment

@Suite("Clipboard composition")
@MainActor
struct ClipboardLayoutTests {
    private func render(
        _ comments: [LayoutComment],
        layout: ClipboardLayout = ClipboardLayout(),
        referenceStyle: SettingsManager.ReferenceStyle = .plain,
        numbering: SettingsManager.NumberingStyle = .none,
        includeSource: Bool = false
    ) -> String {
        ExportManager.shared.markdownForComments(
            comments, referenceStyle: referenceStyle, numberingStyle: numbering,
            dividerStyle: .horizontalRule, dateFormat: .iso,
            includeRemarkID: false, includeSource: includeSource, includeDate: false,
            includeStatus: false, includeType: false, layout: layout
        )
    }

    private func comment(
        type: CommentType = .comment(text: "Selected text"),
        text: String = "My comment",
        attachments: [String] = []
    ) -> LayoutComment {
        LayoutComment(type: type, commentText: text, source: "Xcode", appBundleID: nil,
                      sessionID: UUID(), attachments: attachments)
    }

    @Test("Default labels distinguish references, screenshots, attachments and comments")
    func defaultLabelsAndImages() throws {
        #expect(render([comment()]) == "Reference: Selected text\nComment: My comment")
        #expect(render([comment(type: .quickNote)]) == "Comment: My comment")
        let screenshotPath = "/tmp/Clipboard [review] (截图) #%.png"
        let attachmentPath = "/tmp/Attachment (final) #%.png"
        let item = comment(type: .screenshot(imagePath: screenshotPath), attachments: [attachmentPath])
        let result = render([item])
        #expect(result.hasPrefix("Screenshot: ![screenshot](<"))
        #expect(result.contains("\nAttachment: ![attachment](<"))
        #expect(!result.components(separatedBy: "\n").contains { $0.hasPrefix("!") })
        let parsed = try AttributedString(markdown: result)
        #expect(parsed.runs.compactMap(\.imageURL).map { $0.path(percentEncoded: false) }
                == [screenshotPath, attachmentPath])
    }

    @Test("Custom and empty labels preserve multiline references and literal comment content")
    func customLabels() {
        var layout = ClipboardLayout()
        layout.referencePrefix = "引用："
        layout.commentPrefix = ""
        let item = comment(type: .comment(text: "Line one\nLine two"), text: "/plan\n!literal command")
        #expect(render([item], layout: layout) == "引用： Line one\nLine two\n/plan\n!literal command")
        #expect(render([item], layout: layout, referenceStyle: .blockquote)
                == "> 引用： Line one\n> Line two\n/plan\n!literal command")

        layout.referencePrefix = ""
        layout.screenshotPrefix = "图片："
        layout.attachmentPrefix = "附件："
        #expect(render([comment()], layout: layout) == "Selected text\nMy comment")
        let images = render([comment(type: .screenshot(imagePath: "/tmp/image.png"),
                                     attachments: ["/tmp/attachment.png"])], layout: layout)
        #expect(images.hasPrefix("图片： ![screenshot]"))
        #expect(images.contains("\n附件： ![attachment]"))

        layout.screenshotPrefix = ""
        layout.attachmentPrefix = ""
        let unlabeled = render([comment(type: .screenshot(imagePath: "/tmp/image.png"),
                                        attachments: ["/tmp/attachment.png"])], layout: layout)
        #expect(unlabeled.hasPrefix("![screenshot]"))
        #expect(unlabeled.contains("\n![attachment]"))
    }

    @Test("Reordering and blank field spacing keep every field and number the first visible line")
    func fieldOrderAndSpacing() throws {
        var layout = ClipboardLayout()
        layout.fieldOrder = [.metadata, .comment, .attachments, .reference]
        layout.fieldSpacing = .blankLine
        let item = comment(attachments: ["/tmp/attachment.png"])
        let result = render([item, item], layout: layout, numbering: .numbered, includeSource: true)
        let records = result.components(separatedBy: "\n---\n")
        #expect(records.count == 2)
        for (index, record) in records.enumerated() {
            #expect(record.hasPrefix("\(index + 1). Xcode\n\nComment: My comment\n\nAttachment: "))
            #expect(record.hasSuffix("\n\nReference: Selected text"))
            let parsed = try AttributedString(markdown: record)
            #expect(parsed.runs.compactMap(\.imageURL).count == 1)
        }
        let note = render([comment(type: .quickNote)], layout: layout, numbering: .numbered)
        #expect(note == "1. Comment: My comment")
        #expect(render([], layout: layout).isEmpty)
        #expect(render([comment(text: " \n")], layout: layout) == "Reference: Selected text")
    }

    @Test("Preview uses the exact same multiline Markdown as exporting with the selected composition")
    func previewMatchesCopyFormat() {
        for spacing in ClipboardLayout.FieldSpacing.allCases {
            var layout = ClipboardLayout()
            layout.referencePrefix = "引用："
            layout.fieldOrder = [.comment, .metadata, .attachments, .reference]
            layout.fieldSpacing = spacing
            let preview = ExportManager.shared.previewLines(
                referenceStyle: .plain, numberingStyle: .numbered,
                dividerStyle: .horizontalRule, dateFormat: .iso,
                includeRemarkID: true, includeSource: true, includeDate: true,
                includeStatus: true, includeType: true, layout: layout
            )
            let markdown = ExportManager.shared.markdownForComments(
                ExportManager.shared.sampleComments,
                referenceStyle: .plain, numberingStyle: .numbered,
                dividerStyle: .horizontalRule, dateFormat: .iso,
                includeRemarkID: true, includeSource: true, includeDate: true,
                includeStatus: true, includeType: true, layout: layout
            )
            #expect(preview.map { $0.segments.map(\.text).joined() }.joined(separator: "\n") == markdown)
            #expect(preview.allSatisfy { $0.segments.allSatisfy { !$0.text.contains("\n") } })
            #expect(markdown.contains("Screenshot: ![screenshot]"))
            #expect(markdown.contains("Attachment: ![attachment]"))
        }
    }

    @Test("Moving metadata retains captured web context and region details")
    func webContextSurvivesReordering() {
        var item = comment(type: .webElement(componentName: "Card", filePath: "Card.swift"),
                           attachments: ["/tmp/attachment.png"])
        item.webContext = WebContext(
            elementName: "button", elementPath: "body > button", selectedText: "Submit",
            selector: "button.primary", computedStyles: "color: red", pageUrl: "https://example.com"
        )
        item.regionElements = [WebContext(elementName: "Save"), WebContext(elementName: "Cancel")]
        var layout = ClipboardLayout()
        layout.fieldOrder = [.metadata, .attachments, .comment, .reference]
        let result = render([item], layout: layout)
        for text in ["URL: https://example.com", "Element: button @ body > button", "Selected text: Submit",
                     "button.primary", "Styles: color: red", "Region elements (2):", "Save", "Cancel",
                     "Attachment: ![attachment]", "Comment: My comment", "Reference: Card · Card.swift"] {
            #expect(result.contains(text))
        }
    }

    @Test("Saved composition survives reload, including empty labels, without crossing defaults domains")
    func persistenceAndMigration() throws {
        let suite = "remarc.clipboard-tests.\(UUID().uuidString)"
        let otherSuite = suite + ".other"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let other = try #require(UserDefaults(suiteName: otherSuite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            other.removePersistentDomain(forName: otherSuite)
        }
        #expect(ClipboardLayout.load(from: defaults) == ClipboardLayout())
        for (legacy, label) in [("note", "Note:"), ("dash", "—"), ("arrow", "→"), ("none", "")] {
            defaults.set(legacy, forKey: "commentPrefixStyle")
            #expect(ClipboardLayout.load(from: defaults).commentPrefix == label)
        }
        var layout = ClipboardLayout()
        layout.referencePrefix = ""
        layout.screenshotPrefix = "截图："
        layout.attachmentPrefix = "附件："
        layout.commentPrefix = "想法："
        layout.fieldOrder = [.metadata, .attachments, .comment, .reference]
        layout.fieldSpacing = .blankLine
        layout.save(to: defaults)
        #expect(ClipboardLayout.load(from: defaults) == layout)
        #expect(ClipboardLayout.load(from: other) == ClipboardLayout())
        defaults.set(Data("invalid".utf8), forKey: ClipboardLayout.defaultsKey)
        #expect(ClipboardLayout.load(from: defaults).commentPrefix.isEmpty)
    }

    @Test("Partial orders cannot omit content, and moves stop at either boundary")
    func repairOrderAndMove() {
        var layout = ClipboardLayout()
        layout.fieldOrder = [.comment, .comment]
        #expect(layout.orderedFields == [.comment, .reference, .attachments, .metadata])
        layout.move(.comment, by: -1)
        #expect(layout.orderedFields.first == .comment)
        layout.move(.reference, by: -1)
        #expect(layout.orderedFields == [.reference, .comment, .attachments, .metadata])
        layout.move(.metadata, by: 1)
        #expect(layout.orderedFields.last == .metadata)
        #expect(render([comment()], layout: layout) == "Reference: Selected text\nComment: My comment")
        #expect(ClipboardLayout.prefixText(" \n").isEmpty)
        #expect(ClipboardLayout.prefixText("截图：\n") == "截图： ")
    }
}
