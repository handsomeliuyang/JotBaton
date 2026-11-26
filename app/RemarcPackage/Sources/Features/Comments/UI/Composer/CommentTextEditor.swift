import SwiftUI
import AppKit

/// NSTextView wrapper that intercepts Enter (submit) vs Shift+Enter (newline)
/// and reports its ideal content height for dynamic sizing.
struct CommentTextEditor: NSViewRepresentable {
    @Binding var text: String
    var onSubmit: () -> Void
    var onCancel: () -> Void
    var onImagePaste: ((NSImage) -> Void)?
    var onContentHeightChange: ((CGFloat) -> Void)?
    var lineSpacing: CGFloat = 0
    var showsVerticalScroller: Bool = false

    func makeCoordinator() -> Coordinator {
        Coordinator(
            text: $text,
            onSubmit: onSubmit,
            onCancel: onCancel,
            onImagePaste: onImagePaste,
            onContentHeightChange: onContentHeightChange,
            lineSpacing: lineSpacing
        )
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = showsVerticalScroller
        scrollView.hasHorizontalScroller = false
        if showsVerticalScroller {
            scrollView.scrollerStyle = .overlay
            scrollView.autohidesScrollers = true
        }
        scrollView.borderType = .noBorder

        let textView = InterceptingTextView()
        textView.isRichText = false
        textView.allowsUndo = true
        let font = NSFont.systemFont(ofSize: 13)
        textView.font = font
        textView.textColor = NSColor.labelColor
        textView.backgroundColor = .clear
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainerInset = NSSize(width: 0, height: 4)
        textView.autoresizingMask = [.width]
        textView.delegate = context.coordinator
        textView.interceptDelegate = context.coordinator

        applyTextStyleIfNeeded(to: textView, font: font)

        if let textContainer = textView.textContainer {
            textContainer.widthTracksTextView = true
            textContainer.lineFragmentPadding = 0
        }

        scrollView.documentView = textView
        scrollView.drawsBackground = false

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        // NSViewRepresentable keeps the coordinator alive across SwiftUI updates.
        // Refresh every callback so keyboard submission and paste handling always
        // use the current draft rather than closures captured at creation time.
        context.coordinator.update(
            text: $text,
            onSubmit: onSubmit,
            onCancel: onCancel,
            onImagePaste: onImagePaste,
            onContentHeightChange: onContentHeightChange,
            lineSpacing: lineSpacing
        )

        guard let textView = scrollView.documentView as? InterceptingTextView else { return }
        if textView.string != text {
            textView.string = text
            applyTextStyleIfNeeded(to: textView, font: textView.font ?? NSFont.systemFont(ofSize: 13))
            textView.invalidateIntrinsicContentSize()
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        guard let textView = nsView.documentView as? InterceptingTextView else { return nil }
        let width = proposal.width ?? nsView.frame.width
        guard width > 0 else { return nil }
        let contentHeight = textView.textContentHeight(forWidth: width)
        // Respect the proposed height so the NSScrollView is sized correctly
        // and enables scrolling when content exceeds the frame max.
        if let maxHeight = proposal.height, maxHeight < contentHeight {
            return CGSize(width: width, height: maxHeight)
        }
        return CGSize(width: width, height: contentHeight)
    }

    private func applyTextStyleIfNeeded(to textView: NSTextView, font: NSFont) {
        guard lineSpacing > 0 else { return }
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = lineSpacing
        textView.defaultParagraphStyle = paragraphStyle
        textView.typingAttributes = [
            .font: font,
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraphStyle
        ]
        if let textStorage = textView.textStorage, textStorage.length > 0 {
            let fullRange = NSRange(location: 0, length: textStorage.length)
            textStorage.addAttribute(.paragraphStyle, value: paragraphStyle, range: fullRange)
        }
    }

    class Coordinator: NSObject, NSTextViewDelegate, InterceptingTextViewDelegate {
        var text: Binding<String>
        var onSubmit: () -> Void
        var onCancel: () -> Void
        var onImagePaste: ((NSImage) -> Void)?
        var onContentHeightChange: ((CGFloat) -> Void)?
        var lineSpacing: CGFloat

        init(
            text: Binding<String>,
            onSubmit: @escaping () -> Void,
            onCancel: @escaping () -> Void,
            onImagePaste: ((NSImage) -> Void)?,
            onContentHeightChange: ((CGFloat) -> Void)?,
            lineSpacing: CGFloat = 0
        ) {
            self.text = text
            self.onSubmit = onSubmit
            self.onCancel = onCancel
            self.onImagePaste = onImagePaste
            self.onContentHeightChange = onContentHeightChange
            self.lineSpacing = lineSpacing
        }

        func update(
            text: Binding<String>,
            onSubmit: @escaping () -> Void,
            onCancel: @escaping () -> Void,
            onImagePaste: ((NSImage) -> Void)?,
            onContentHeightChange: ((CGFloat) -> Void)?,
            lineSpacing: CGFloat = 0
        ) {
            self.text = text
            self.onSubmit = onSubmit
            self.onCancel = onCancel
            self.onImagePaste = onImagePaste
            self.onContentHeightChange = onContentHeightChange
            self.lineSpacing = lineSpacing
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? InterceptingTextView else { return }
            if lineSpacing > 0, textView.string.isEmpty {
                let paragraphStyle = NSMutableParagraphStyle()
                paragraphStyle.lineSpacing = lineSpacing
                textView.defaultParagraphStyle = paragraphStyle
                textView.typingAttributes = [
                    .font: textView.font ?? NSFont.systemFont(ofSize: 13),
                    .foregroundColor: NSColor.labelColor,
                    .paragraphStyle: paragraphStyle
                ]
            }
            text.wrappedValue = textView.string
            textView.invalidateIntrinsicContentSize()
            onContentHeightChange?(textView.textContentHeight)
        }

        func textView(_ textView: InterceptingTextView, shouldHandleKeyDown event: NSEvent) -> Bool {
            // Escape: cancel
            if event.keyCode == 53 {
                onCancel()
                return true
            }

            // Cmd+Enter: submit
            if event.keyCode == 36 && event.modifierFlags.contains(.command) {
                onSubmit()
                return true
            }

            return false
        }

        func textViewDidPasteImage(_ textView: InterceptingTextView, image: NSImage) {
            onImagePaste?(image)
        }
    }
}

protocol InterceptingTextViewDelegate: AnyObject {
    func textView(_ textView: InterceptingTextView, shouldHandleKeyDown event: NSEvent) -> Bool
    func textViewDidPasteImage(_ textView: InterceptingTextView, image: NSImage)
}

class InterceptingTextView: NSTextView {
    weak var interceptDelegate: InterceptingTextViewDelegate?

    /// Calculates the content height using TextKit layout for a specific available width,
    /// including text container insets. Restores the text container's live sizing mode
    /// afterwards so `widthTracksTextView` continues tracking resizes normally.
    func textContentHeight(forWidth width: CGFloat) -> CGFloat {
        guard let layoutManager = textContainer?.layoutManager,
              let textContainer = textContainer else { return 22 }
        let targetContainerWidth = max(width - textContainerInset.width * 2, 1)
        let previousWidthTracks = textContainer.widthTracksTextView
        let previousSize = textContainer.containerSize
        let needsTemporarySize = abs(previousSize.width - targetContainerWidth) > 0.5
            || previousSize.height < 10_000
        if needsTemporarySize {
            textContainer.widthTracksTextView = false
            textContainer.containerSize = NSSize(
                width: targetContainerWidth,
                height: CGFloat.greatestFiniteMagnitude
            )
        }
        layoutManager.ensureLayout(for: textContainer)
        let usedRect = layoutManager.usedRect(for: textContainer)
        if needsTemporarySize {
            textContainer.containerSize = previousSize
            textContainer.widthTracksTextView = previousWidthTracks
        }
        return max(ceil(usedRect.height) + textContainerInset.height * 2, 22)
    }

    /// Calculates the content height using TextKit layout, including text container insets.
    var textContentHeight: CGFloat {
        guard let layoutManager = textContainer?.layoutManager,
              let textContainer = textContainer else { return 22 }
        layoutManager.ensureLayout(for: textContainer)
        let usedRect = layoutManager.usedRect(for: textContainer)
        return max(ceil(usedRect.height) + textContainerInset.height * 2, 22)
    }

    override func resize(withOldSuperviewSize oldSize: NSSize) {
        invalidateIntrinsicContentSize()
        super.resize(withOldSuperviewSize: oldSize)
    }

    override func keyDown(with event: NSEvent) {
        if interceptDelegate?.textView(self, shouldHandleKeyDown: event) == true {
            return
        }
        super.keyDown(with: event)
    }

    // In a nonactivatingPanel, Cmd+key equivalents are consumed by the
    // frontmost app's Edit menu before reaching keyDown. Route them through
    // NSApp.sendAction so the responder chain handles them correctly.
    // See: https://blog.kulman.sk/making-copy-paste-work-with-nstextfield/
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown else {
            return super.performKeyEquivalent(with: event)
        }

        let flags = event.modifierFlags.rawValue & NSEvent.ModifierFlags.deviceIndependentFlagsMask.rawValue
        let commandOnly = NSEvent.ModifierFlags.command.rawValue
        let commandShift = NSEvent.ModifierFlags.command.rawValue | NSEvent.ModifierFlags.shift.rawValue

        if flags == commandOnly {
            switch event.charactersIgnoringModifiers {
            case "\r":
                if interceptDelegate?.textView(self, shouldHandleKeyDown: event) == true { return true }
            case "v":
                if NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: self) { return true }
            case "c":
                if NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: self) { return true }
            case "x":
                if NSApp.sendAction(#selector(NSText.cut(_:)), to: nil, from: self) { return true }
            case "a":
                if NSApp.sendAction(#selector(NSResponder.selectAll(_:)), to: nil, from: self) { return true }
            case "z":
                if NSApp.sendAction(Selector(("undo:")), to: nil, from: self) { return true }
            default:
                break
            }
        } else if flags == commandShift {
            if event.charactersIgnoringModifiers == "Z" {
                if NSApp.sendAction(Selector(("redo:")), to: nil, from: self) { return true }
            }
        }

        return super.performKeyEquivalent(with: event)
    }

    override func paste(_ sender: Any?) {
        let pasteboard = NSPasteboard.general
        // NSImage(pasteboard:) handles all image types (TIFF, PNG, JPEG, HEIC,
        // file URLs, clipboard manager formats, etc.).
        if let image = NSImage(pasteboard: pasteboard), image.isValid {
            interceptDelegate?.textViewDidPasteImage(self, image: image)
            return
        }
        super.paste(sender)
    }
}
