import CoreLocalization
import CorePlatform
import CoreTheme
import CoreUI
import FeatureComments
import SwiftUI
import UniformTypeIdentifiers

struct CommentEditorView: View {
    @ObservedObject private var localization = LocalizationManager.shared
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var floatingController = FloatingEditorController.shared
    @Binding var commentText: String
    @Binding var attachments: [String]
    @FocusState private var isFocused: Bool
    @State private var isCloseHovered = false
    @State private var isSaveHovered = false
    @State private var isAttachHovered = false
    @State private var editorSessionID: UUID?

    let screenshotImagePath: String?
    let referenceText: String?
    let comment: Comment?
    let presentationGeneration: UInt64
    let onSave: (String, [String]) -> Void
    let onCancel: () -> Void

    private var leadMedia: CardMediaPolicy.LeadMedia? {
        CardMediaPolicy.leadImage(screenshotPath: screenshotImagePath, attachments: attachments)
    }

    private var leadImageIsAttachment: Bool {
        screenshotImagePath == nil && !attachments.isEmpty
    }

    private var trailingAttachments: [String] {
        if screenshotImagePath != nil {
            return attachments
        }
        return attachments.count > 1 ? Array(attachments.dropFirst()) : []
    }

    private var leadImageAvailableWidth: CGFloat {
        max(120, floatingController.editorWidth - 32)
    }

    private var leadImageMaxHeight: CGFloat {
        min(320, max(120, floatingController.visibleScreenHeight * 0.35))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Dedicated top bar keeps the close button clear of full-width lead images.
            HStack(spacing: 8) {
                if AppIdentity.current.isDevelopment {
                    DevelopmentIdentityBadge()
                }
                if screenshotImagePath != nil {
                    Label(L10n.tr("Screenshot"), systemImage: "camera.viewfinder")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                } else if referenceText == nil {
                    Label(L10n.tr("Quick Note"), systemImage: "note.text")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Button(action: onCancel) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(isCloseHovered ? Color.remarcPrimary(for: colorScheme) : .primary.opacity(0.35))
                        .frame(width: 26, height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { hovering in isCloseHovered = hovering }
                .animation(.easeInOut(duration: 0.15), value: isCloseHovered)
            }

            // Reference text (read-only)
            if screenshotImagePath == nil, let ref = referenceText {
                VStack(alignment: .leading, spacing: 4) {
                    Button(action: {
                        floatingController.showFullReference(ref, presentationGeneration: presentationGeneration)
                    }) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\u{201C}\(ref)\u{201D}")
                                .font(.system(size: 11))
                                .italic()
                                .foregroundStyle(Color.remarcAccent(for: colorScheme))
                                .lineLimit(10)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.leading, 8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .quoteBorder()
                            Label(L10n.tr("Show full quote"), systemImage: "arrow.up.left.and.arrow.down.right")
                                .font(.system(size: 10))
                                .foregroundStyle(Color.remarcPrimary(for: colorScheme))
                                .padding(.leading, 8)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(ref)
                    .accessibilityLabel(L10n.tr("Show full quote"))
                    .accessibilityIdentifier("remarc.commentEditor.showFullQuote")
                    if let comment {
                        HStack(spacing: 4) {
                            Text({
                                let date = comment.createdAt.interfaceFormatted(date: .abbreviated, time: .shortened)
                                if let app = appDisplayName(for: comment) {
                                    return "\(app) — \(date)"
                                }
                                return date
                            }())
                                .font(.system(size: 10))
                                .foregroundStyle(.primary.opacity(0.45))
                                .lineLimit(1)
                            Text(comment.shortID)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.primary.opacity(0.4))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 4))
                        }
                    }
                }
            }

            // Lead image at full editor width (read-only for screenshots, removable for attachments)
            if let leadMedia {
                EditorLeadImageView(
                    imagePath: leadMedia.imagePath,
                    availableWidth: leadImageAvailableWidth,
                    maxHeight: leadImageMaxHeight,
                    isRemovable: leadImageIsAttachment,
                    onRemove: leadImageIsAttachment ? {
                        guard !attachments.isEmpty else { return }
                        attachments.remove(at: 0)
                    } : nil,
                    onImageLoaded: {
                        floatingController.notifyContentHeightChanged(presentationGeneration: presentationGeneration)
                    }
                )
            }

            // Remaining attachments strip (above text editor)
            if !trailingAttachments.isEmpty {
                AttachmentStripView(attachments: trailingAttachments, isEditable: true) { index in
                    let actualIndex = screenshotImagePath != nil ? index : index + 1
                    guard attachments.indices.contains(actualIndex) else { return }
                    attachments.remove(at: actualIndex)
                }
            }

            // Text editor
            CommentTextEditor(
                text: $commentText,
                onSubmit: { onSave(commentText, attachments) },
                onCancel: onCancel,
                onImagePaste: { image in
                    if let path = AppServices.shared.comments.saveAttachmentImage(image) {
                        attachments.append(path)
                    }
                },
                lineSpacing: 3,
                showsVerticalScroller: true
            )
            .focused($isFocused)
            .frame(minHeight: 30, maxHeight: 480)
            .clipped()

            // Footer
            HStack {
                SessionPickerPill(
                    selectedSessionID: $editorSessionID,
                    mode: comment != nil ? .edit : .create,
                    comment: comment
                )

                Button(action: pickAttachmentImage) {
                    Image(systemName: "paperclip")
                        .font(.system(size: 12))
                        .foregroundStyle(.primary.opacity(isAttachHovered ? 0.6 : 0.3))
                }
                .buttonStyle(.plain)
                .onHover { hovering in isAttachHovered = hovering }
                .animation(.easeInOut(duration: 0.15), value: isAttachHovered)
                .help(L10n.tr("Attach image"))

                Spacer()

                Button(action: { onSave(commentText, attachments) }) {
                    HStack(spacing: 6) {
                        Text(L10n.tr("Save"))
                            .font(.system(size: 12, weight: .medium))
                        HStack(spacing: 1) {
                            Image(systemName: "command")
                            Image(systemName: "return")
                        }
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white.opacity(0.5))
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(
                        Color.remarcBrandGradient(for: colorScheme),
                        in: RoundedRectangle(cornerRadius: 6)
                    )
                    .opacity(isSaveHovered ? 1.0 : 0.85)
                }
                .buttonStyle(.plain)
                .onHover { hovering in isSaveHovered = hovering }
                .animation(.easeInOut(duration: 0.15), value: isSaveHovered)
                .modifier(SaveButtonFeedbackModifier(trigger: floatingController.saveFeedbackTrigger))
                .accessibilityIdentifier("remarc.commentInput.submitButton")
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 14)
        .onAppear {
            guard floatingController.isCurrentPresentation(presentationGeneration) else { return }
            isFocused = true
            editorSessionID = comment?.sessionID ?? FloatingEditorController.shared.targetSessionID
        }
        .onRemarcChange(of: editorSessionID) { newValue in
            guard floatingController.isCurrentPresentation(presentationGeneration) else { return }
            if comment == nil {
                FloatingEditorController.shared.targetSessionID = newValue
            }
        }
        .onRemarcChange(of: commentText) { newValue in
            guard floatingController.isCurrentPresentation(presentationGeneration) else { return }
            floatingController.currentText = newValue
        }
        .onRemarcChange(of: floatingController.validationFeedbackTrigger) { trigger in
            guard floatingController.isCurrentPresentation(presentationGeneration) else { return }
            guard trigger > 0 else { return }
            refocusEditor()
        }
    }

    private func refocusEditor() {
        isFocused = false
        Task { @MainActor in
            await Task.yield()
            isFocused = true
        }
    }

    private func pickAttachmentImage() {
        FloatingEditorController.shared.suppressClickOutside = true
        MenuBarPopoverController.shared.preventDismiss = true

        // Temporarily hide editor panels so the system file picker appears unobstructed.
        // NSOpenPanel runs out-of-process and its z-level cannot be controlled by the host app.
        FloatingEditorController.shared.orderOutForSystemDialog()

        NSApp.activate(ignoringOtherApps: true)

        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .heic, .webP]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false

        let response = panel.runModal()

        // Re-show editor panels and restore state
        FloatingEditorController.shared.orderFrontAfterSystemDialog()
        FloatingEditorController.shared.suppressClickOutside = false
        MenuBarPopoverController.shared.preventDismiss = false

        guard response == .OK else { return }
        for url in panel.urls {
            guard let image = NSImage(contentsOf: url) else { continue }
            if let path = AppServices.shared.comments.saveAttachmentImage(image) {
                attachments.append(path)
            }
        }
    }
}

private struct EditorLeadImageView: View {
    @ObservedObject private var localization = LocalizationManager.shared
    let imagePath: String
    let availableWidth: CGFloat
    let maxHeight: CGFloat
    let isRemovable: Bool
    let onRemove: (() -> Void)?
    let onImageLoaded: @MainActor () -> Void

    private var cacheMaxWidth: CGFloat {
        Self.bucketedCacheWidth(for: availableWidth)
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            ScreenshotThumbnailView(
                imagePath: imagePath,
                maxWidth: availableWidth,
                maxHeight: maxHeight,
                cacheMaxWidth: cacheMaxWidth,
                onImageLoaded: onImageLoaded
            )
            .modifier(ImagePreviewAffordance())
            .contentShape(Rectangle())
            .onTapGesture {
                ScreenshotPreviewController.shared.show(imagePath: imagePath)
            }
            .imageContextMenu(imagePath: imagePath)

            if isRemovable, let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .black.opacity(0.6))
                }
                .buttonStyle(.plain)
                .offset(x: 4, y: -4)
                .accessibilityLabel(L10n.tr("Delete"))
            }
        }
        .padding(.top, isRemovable ? 4 : 0)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    static func bucketedCacheWidth(for width: CGFloat, step: CGFloat = 80) -> CGFloat {
        guard width.isFinite, width > 0 else { return step }
        return ceil(width / step) * step
    }
}
