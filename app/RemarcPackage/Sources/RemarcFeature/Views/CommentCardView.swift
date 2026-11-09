import SwiftUI
import UniformTypeIdentifiers

struct TypeLabelStyle: LabelStyle {
    let colorScheme: ColorScheme

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon
                .foregroundStyle(Color.remarcPrimary(for: colorScheme))
            configuration.title
                .foregroundStyle(.primary.opacity(0.6))
        }
    }
}

struct CommentCardView: View {
    let comment: Comment
    var isFocused: Bool = false
    /// Active search terms; matches are highlighted in the title and text.
    var searchTerms: [String] = []
    var onFocusChange: ((Bool) -> Void)?

    @ObservedObject private var persistence = PersistenceManager.shared
    @ObservedObject private var settings = SettingsManager.shared
    @State private var isHovered: Bool = false
    @State private var showDeleteConfirmation: Bool = false
    @State private var isMoveDropdownOpen: Bool = false
    @State private var moveAnchorRef = AnchorViewRef()
    @State private var isWebhookDropdownOpen: Bool = false
    @State private var webhookAnchorRef = AnchorViewRef()
    @State private var isResolvedExpanded = false
    @State private var isRenaming = false
    @State private var titleDraft = ""
    @FocusState private var isTitleFocused: Bool
    @Environment(\.colorScheme) private var colorScheme

    private var showActions: Bool { isHovered || isFocused || isRenaming || showDeleteConfirmation || isMoveDropdownOpen || isWebhookDropdownOpen }

    private var enabledWebhooks: [Webhook] { settings.webhooks.filter(\.isEnabled) }

    private var isCollapsed: Bool { comment.status == .resolved && !isResolvedExpanded }

    private var statusColor: Color {
        CommentStatus.color(for: comment.status, colorScheme: colorScheme)
    }

    private var statusHeaderOpacity: Double {
        switch comment.status {
        case .open: return colorScheme == .dark ? 0.18 : 0.10
        case .resolved: return colorScheme == .dark ? 0.06 : 0.035
        default: return colorScheme == .dark ? 0.14 : 0.08
        }
    }

    private var collapsedSummary: String {
        let text = comment.meaningfulCommentText ?? comment.truncatedTypeLabel
        let firstLine = text.split(whereSeparator: { $0.isNewline }).first.map(String.init) ?? text
        let summary = firstLine.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return summary.isEmpty ? comment.type.displayName : summary
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerView
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(statusColor.opacity(statusHeaderOpacity))

            VStack(alignment: .leading, spacing: 8) {
                if isCollapsed {
                    Text(highlighted(collapsedSummary))
                        .font(.system(size: 12))
                        .foregroundStyle(.primary.opacity(0.8))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            FloatingEditorController.shared.showForEdit(comment: comment)
                        }
                        .help("Open details")
                } else {
                    contextBadges
                    referenceView
                    if !comment.attachments.isEmpty {
                        AttachmentStripView(attachments: comment.attachments, commentText: Comment.normalizedCommentText(comment.commentText), isEditable: false, maxThumbnailWidth: 140, maxThumbnailHeight: 200)
                            .padding(.leading, 8)
                            .quoteBorder()
                    }
                    if let commentText = comment.meaningfulCommentText {
                        commentTextView(commentText)
                    }
                }

                metadataView
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
        .clipShape(RoundedRectangle(cornerRadius: AppConstants.cardCornerRadius, style: .continuous))
        .modifier(CardSurfaceModifier(isHovered: isHovered))
        .onHover { hovering in
            isHovered = hovering
            onFocusChange?(hovering)
        }
        .onRemarcChange(of: comment.status) { _ in
            // Newly resolved cards collapse; reopening always reveals the body.
            isResolvedExpanded = false
        }
        .animation(.easeInOut(duration: 0.2), value: isCollapsed)
        .animation(.easeInOut(duration: 0.2), value: comment.status)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isHovered)
        .animation(.easeInOut(duration: 0.15), value: showActions)
    }

    // MARK: - Header

    private var headerView: some View {
        HStack(spacing: 8) {
            if isRenaming {
                TextField("任务名称", text: $titleDraft)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11))
                    .focused($isTitleFocused)
                    .onSubmit(saveTitle)
                    .onExitCommand {
                        isRenaming = false
                        isTitleFocused = false
                    }
                    .accessibilityIdentifier("remarc.card.titleEditor")
            } else if comment.status == .resolved {
                Button {
                    isResolvedExpanded.toggle()
                } label: {
                    HStack(spacing: 6) {
                        headerTitle
                        Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(isCollapsed ? "Expand completed comment" : "Collapse completed comment")
                .accessibilityLabel(comment.taskTitle)
                .accessibilityValue(isCollapsed ? "Collapsed" : "Expanded")
            } else {
                headerTitle
                    .onTapGesture(count: 2, perform: beginRenaming)
                Spacer(minLength: 0)
            }

            if !isRenaming {
                Button(action: beginRenaming) {
                    Image(systemName: "pencil")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.remarcPrimary(for: colorScheme))
                        .frame(width: 20, height: 22)
                }
                .buttonStyle(.plain)
                .opacity(isHovered || isFocused ? 1 : 0)
                .allowsHitTesting(isHovered || isFocused)
                .accessibilityLabel("修改任务标题")
                .help("修改任务标题")
            }

            StatusDotView(comment: comment)
                .fixedSize()
        }
        .onRemarcChange(of: isTitleFocused) { focused in
            if !focused && isRenaming { saveTitle() }
        }
    }

    private func beginRenaming() {
        titleDraft = comment.taskTitle
        isRenaming = true
        isTitleFocused = true
    }

    private func saveTitle() {
        guard persistence.renameComment(comment.id, title: titleDraft) else {
            ToastManager.shared.show("标题未能保存")
            return
        }
        isRenaming = false
        isTitleFocused = false
    }

    private var headerTitle: some View {
        Text(highlighted(comment.taskTitle))
                .fontWeight(.medium)
                .foregroundStyle(.primary.opacity(0.85))
                .lineLimit(1)
                .truncationMode(.tail)
                .font(.system(size: 11))
                .help(comment.taskTitle)
    }

    @ViewBuilder
    private var contextBadges: some View {
        if let webContext = comment.webContext {
            HStack(spacing: 6) {
                WebContextBadge(webContext: webContext, regionElements: comment.regionElements, colorScheme: colorScheme)
                if let hfCtx = webContext.hyperframesContext, !hfCtx.isEmpty {
                    HyperframesContextBadge(hyperframesContext: hfCtx, colorScheme: colorScheme)
                }
            }
        }
    }

    // MARK: - Reference Container

    @ViewBuilder
    private var referenceView: some View {
        switch comment.type {
        case .comment(let text):
            TruncatingQuoteText(
                text: highlighted("\u{201C}\(text.replacingOccurrences(of: "\n", with: " "))\u{201D}"),
                accentColor: Color.remarcAccent(for: colorScheme)
            )
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 8)
                .padding(.trailing, 12)
                .quoteBorder()
                .contentShape(Rectangle())
                .onTapGesture {
                    FloatingEditorController.shared.showForEdit(comment: comment)
                }

        case .screenshot(let imagePath):
            ScreenshotThumbnailView(imagePath: imagePath, maxWidth: 140)
                .padding(.leading, 8)
                .quoteBorder()
                .contentShape(Rectangle())
                .onTapGesture {
                    ScreenshotPreviewController.shared.show(
                        imagePath: imagePath,
                        commentText: Comment.normalizedCommentText(comment.commentText)
                    )
                }
                .contextMenu {
                    Button {
                        if let nsImage = loadScreenshotImage(imagePath) {
                            let pasteboard = NSPasteboard.general
                            pasteboard.clearContents()
                            pasteboard.writeObjects([nsImage])
                            ToastManager.shared.show("Image copied")
                        }
                    } label: {
                        Label("Copy Image", systemImage: "doc.on.doc")
                    }

                    Button {
                        saveScreenshotAs(imagePath: imagePath)
                    } label: {
                        Label("Save Image As\u{2026}", systemImage: "square.and.arrow.down")
                    }
                }

        case .webElement(let name, let path):
            // Smart-id fallback: when the React component name is missing or
            // minified, render the text-content-based elementName so the card
            // always has a meaningful label (e.g. "button [Play]").
            let displayName = WebContext.smartLabel(
                componentName: name,
                elementName: comment.webContext?.elementName
            )
            if displayName != nil || path != nil {
                WebElementReferenceView(name: displayName, path: path, colorScheme: colorScheme)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        FloatingEditorController.shared.showForEdit(comment: comment)
                    }
            }

        case .quickNote, .critMode:
            EmptyView()
        }
    }

    // MARK: - Save Screenshot

    private func saveScreenshotAs(imagePath: String) {
        let sourceURL = resolveImagePath(imagePath)
        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [.png]
        savePanel.nameFieldStringValue = sourceURL.lastPathComponent
        savePanel.canCreateDirectories = true
        savePanel.level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue + 4)

        savePanel.begin { response in
            guard response == .OK, let destinationURL = savePanel.url else { return }
            do {
                try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
                Task { @MainActor in
                    ToastManager.shared.show("Image saved")
                }
            } catch {
                debugLog("Failed to save screenshot: \(error.localizedDescription)")
                Task { @MainActor in
                    ToastManager.shared.show("Failed to save image")
                }
            }
        }
    }

    // MARK: - Comment Text

    private func commentTextView(_ commentText: String) -> some View {
        Text(highlighted(commentText))
            .font(.system(size: 13))
            .foregroundStyle(.primary)
            .lineLimit(3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture {
                FloatingEditorController.shared.showForEdit(comment: comment)
            }
    }

    // MARK: - Metadata + Actions

    private var metadataView: some View {
        HStack(spacing: 4) {
            TimelineView(.periodic(from: .now, by: AppConstants.cardTimestampRefreshInterval)) { context in
                Text(metadataText(now: context.date))
                    .font(.system(size: 10))
                    .foregroundStyle(.primary.opacity(0.45))
                    .lineLimit(1)
                    .help(comment.createdAt.formatted(date: .abbreviated, time: .shortened))
            }

            Text(comment.shortID)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.primary.opacity(0.4))
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 4))
                .onTapGesture {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(comment.shortID, forType: .string)
                    ToastManager.shared.show("ID copied")
                }

            Spacer(minLength: 0)

            cardActions
                .opacity(showActions ? 1 : 0)
                .allowsHitTesting(showActions)
                .accessibilityHidden(!showActions)
        }
        .frame(minHeight: 22)
    }

    private func metadataText(now: Date) -> String {
        let date = comment.createdAt.remarcCompactTimestamp(
            dateFormat: settings.exportDateFormat,
            use24Hour: settings.timeFormat.use24Hour,
            now: now
        )
        if let app = appDisplayName(for: comment) {
            return "\(app) · \(date)"
        }
        return date
    }

    /// Show move button when there are other sessions to move to, or room to create a new one.
    private var canMoveComment: Bool {
        let sessions = persistence.activeSessions
        let otherSessions = sessions.filter { $0.id != comment.sessionID }
        let canCreateNew = sessions.count < AppConstants.maxActiveSessions
        return !otherSessions.isEmpty || canCreateNew
    }

    private var cardActions: some View {
        HStack(spacing: 4) {
            cardActionButton(icon: "doc.on.doc", tooltip: "Copy", tint: Color.remarcPrimary(for: colorScheme)) {
                if ExportManager.shared.copyCommentToClipboard(comment) != nil {
                    ToastManager.shared.show("Copied to clipboard")
                } else {
                    ToastManager.shared.show("Couldn’t copy comment")
                }
            }
            cardActionButton(icon: "play.fill", tooltip: "复制并开发", tint: Color.remarcPrimary(for: colorScheme)) {
                if ExportManager.shared.copyCommentAndStartDevelopment(comment) {
                    ToastManager.shared.show("已复制，已标记为正在开发中")
                } else {
                    ToastManager.shared.show("复制失败，状态未修改")
                }
            }
            cardActionButton(icon: "pencil", tooltip: "Edit", tint: Color.remarcPrimary(for: colorScheme)) {
                FloatingEditorController.shared.showForEdit(comment: comment)
            }
            if !enabledWebhooks.isEmpty {
                cardActionButton(icon: "paperplane", tooltip: "Send to webhook", tint: Color.remarcPrimary(for: colorScheme)) {
                    if enabledWebhooks.count == 1 {
                        WebhookService.shared.sendManually(enabledWebhooks[0], comment: comment)
                    } else if isWebhookDropdownOpen {
                        DropdownPanelController.shared.dismiss()
                    } else {
                        showWebhookDropdown()
                    }
                }
                .overlay(DropdownAnchor(ref: webhookAnchorRef).allowsHitTesting(false))
            }
            if canMoveComment {
                cardActionButton(icon: RemarcSymbols.moveToSession, tooltip: "Move to session", tint: Color.remarcPrimary(for: colorScheme)) {
                    if isMoveDropdownOpen {
                        DropdownPanelController.shared.dismiss()
                    } else {
                        showMoveDropdown()
                    }
                }
                .overlay(DropdownAnchor(ref: moveAnchorRef).allowsHitTesting(false))
            }
            cardActionButton(icon: "trash", tooltip: "Delete", tint: Color.remarcError(for: colorScheme)) {
                showDeleteConfirmation = true
            }
            .popover(isPresented: $showDeleteConfirmation, arrowEdge: .bottom) {
                deleteConfirmationPopover
            }
        }
    }

    private func showMoveDropdown() {
        guard let screenFrame = moveAnchorRef.screenFrame() else { return }
        isMoveDropdownOpen = true
        let cs = colorScheme
        let commentID = comment.id
        let oldSessionID = comment.sessionID

        let sessions = persistence.activeSessions
        let otherSessions = sessions.filter { $0.id != oldSessionID }
        let canCreateNew = sessions.count < AppConstants.maxActiveSessions

        DropdownPanelController.shared.show(
            below: screenFrame,
            width: 180,
            colorScheme: cs,
            anchorWindowLevel: moveAnchorRef.windowLevel(),
            onDismiss: { isMoveDropdownOpen = false }
        ) {
            MoveDropdownPanel(
                sessions: otherSessions,
                canCreateNew: canCreateNew,
                colorScheme: cs
            ) { targetSessionID, targetSessionName in
                PersistenceManager.shared.moveComment(commentID, to: targetSessionID)
                DropdownPanelController.shared.dismiss()
                ToastManager.shared.show("Moved to \(targetSessionName)", undo: {
                    PersistenceManager.shared.moveComment(commentID, to: oldSessionID)
                })
            } onNewSession: {
                let name = SessionNaming.nextName()
                if let newSession = PersistenceManager.shared.createSession(name: name) {
                    PersistenceManager.shared.moveComment(commentID, to: newSession.id)
                    DropdownPanelController.shared.dismiss()
                    ToastManager.shared.show("Moved to \(newSession.name)", undo: {
                        PersistenceManager.shared.moveComment(commentID, to: oldSessionID)
                    })
                }
            }
        }
    }

    private func showWebhookDropdown() {
        guard let screenFrame = webhookAnchorRef.screenFrame() else { return }
        isWebhookDropdownOpen = true
        let cs = colorScheme
        let hooks = enabledWebhooks
        let target = comment

        DropdownPanelController.shared.show(
            below: screenFrame,
            width: 180,
            colorScheme: cs,
            anchorWindowLevel: webhookAnchorRef.windowLevel(),
            onDismiss: { isWebhookDropdownOpen = false }
        ) {
            WebhookDropdownPanel(webhooks: hooks, colorScheme: cs) { hook in
                DropdownPanelController.shared.dismiss()
                WebhookService.shared.sendManually(hook, comment: target)
            }
        }
    }

    private func highlighted(_ text: String) -> AttributedString {
        SearchHighlight.attributed(text, terms: searchTerms, color: Color.remarcWarning(for: colorScheme).opacity(0.35))
    }

    private func cardActionButton(icon: String, tooltip: String, tint: Color, action: @escaping () -> Void) -> some View {
        CardActionButton(icon: icon, tooltip: tooltip, tint: tint, action: action)
    }

    // MARK: - Delete Confirmation

    private var deleteConfirmationPopover: some View {
        VStack(spacing: 8) {
            Text("Delete this comment?")
                .font(.system(size: 12, weight: .medium))
            HStack(spacing: 8) {
                ConfirmationButton(label: "Cancel", role: .cancel) {
                    showDeleteConfirmation = false
                }
                ConfirmationButton(label: "Delete", role: .destructive) {
                    showDeleteConfirmation = false
                    let commentID = comment.id
                    let originalSessionID = comment.sessionID
                    PersistenceManager.shared.deleteComment(commentID)
                    ToastManager.shared.show("Deleted", undo: {
                        // The card may come from another session in the "All" view,
                        // so restore it where it was rather than into the active one.
                        let persistence = PersistenceManager.shared
                        let sessionID = persistence.activeSessions.contains { $0.id == originalSessionID }
                            ? originalSessionID
                            : persistence.appState.activeSessionID
                        if let sessionID {
                            persistence.restoreComment(commentID, to: sessionID)
                        }
                    }, duration: 5.0)
                }
            }
        }
        .padding(12)
    }
}

// MARK: - Card Surface Modifier

struct CardSurfaceModifier: ViewModifier {
    let isHovered: Bool
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: AppConstants.cardCornerRadius, style: .continuous)
                    .fill(colorScheme == .dark
                        ? Color.white.opacity(isHovered ? 0.14 : 0.1)
                        : Color.white.opacity(isHovered ? 0.85 : 0.7))
                    .shadow(
                        color: .black.opacity(colorScheme == .dark
                            ? (isHovered ? 0.5 : 0.35)
                            : (isHovered ? 0.14 : 0.08)),
                        radius: isHovered ? 12 : 6,
                        y: isHovered ? 6 : 3
                    )
                    .shadow(
                        color: .black.opacity(colorScheme == .dark
                            ? (isHovered ? 0.2 : 0.15)
                            : (isHovered ? 0.05 : 0.03)),
                        radius: isHovered ? 2 : 1,
                        y: isHovered ? 2 : 1
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: AppConstants.cardCornerRadius, style: .continuous)
                    .strokeBorder(
                        colorScheme == .dark
                            ? Color.white.opacity(isHovered ? 0.18 : 0.12)
                            : Color.black.opacity(isHovered ? 0.1 : 0.06),
                        lineWidth: 0.5
                    )
            )
    }
}

// MARK: - Truncating Quote Text

/// Displays quote text with `lineLimit(3)` and a bottom fade when truncated.
/// Each instance owns its own measurement state, so multiple cards in a list don't interfere.
private struct TruncatingQuoteText: View {
    let text: AttributedString
    let accentColor: Color

    var body: some View {
        Text(text)
            .font(.system(size: 11))
            .italic()
            .foregroundStyle(accentColor)
            .lineLimit(3)
            .truncationMode(.tail)
    }
}

// MARK: - Search Highlight

enum SearchHighlight {
    /// Builds the text segment by segment, so no index conversion between
    /// `String` and `AttributedString` is needed.
    static func attributed(_ text: String, terms: [String], color: Color) -> AttributedString {
        let ranges = CommentListQuery.matchRanges(of: terms, in: text).sorted { $0.lowerBound < $1.lowerBound }
        guard !ranges.isEmpty else { return AttributedString(text) }
        var result = AttributedString()
        var cursor = text.startIndex
        for range in ranges where range.upperBound > cursor {
            let start = max(range.lowerBound, cursor)
            if cursor < start {
                result += AttributedString(String(text[cursor..<start]))
            }
            var hit = AttributedString(String(text[start..<range.upperBound]))
            hit.swiftUI.backgroundColor = color
            result += hit
            cursor = range.upperBound
        }
        if cursor < text.endIndex {
            result += AttributedString(String(text[cursor...]))
        }
        return result
    }
}

// MARK: - Card Action Button

struct CardActionButton: View {
    let icon: String
    let tooltip: String
    let tint: Color
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundStyle(isHovered ? tint : .primary.opacity(0.45))
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(tooltip)
        .accessibilityLabel(tooltip)
        .onHover { hovering in
            isHovered = hovering
        }
        .animation(.easeInOut(duration: 0.15), value: isHovered)
    }
}

// MARK: - Web Context Badge

struct WebContextBadge: View {
    let webContext: WebContext
    var regionElements: [WebContext]?
    let colorScheme: ColorScheme
    @State private var showPopover = false

    private var elementCount: Int? {
        guard let elements = regionElements, elements.count > 1 else { return nil }
        return elements.count
    }

    var body: some View {
        HStack(spacing: 2) {
            Image(systemName: "chevron.left.forwardslash.chevron.right")
                .font(.system(size: 8, weight: .medium))
                .foregroundStyle(Color.remarcPrimary(for: colorScheme))
            if let count = elementCount {
                Text("\(count)")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(Color.remarcPrimary(for: colorScheme))
            }
        }
        .frame(minWidth: 16, minHeight: 16)
        .padding(.horizontal, elementCount != nil ? 4 : 0)
        .background(Color.remarcPrimary(for: colorScheme).opacity(0.12), in: RoundedRectangle(cornerRadius: 3))
        .onHover { hovering in
            showPopover = hovering
        }
        .popover(isPresented: $showPopover, arrowEdge: .bottom) {
            webContextPopoverContent
        }
    }

    private var webContextPopoverContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.left.forwardslash.chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.remarcPrimary(for: colorScheme))
                Text("Web Context")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.primary)
                Spacer(minLength: 0)
            }

            if let name = webContext.componentName {
                row(label: "Component", value: name)
            }
            if let path = webContext.filePath {
                row(label: "Source", value: path)
            }
            if let chain = webContext.reactComponents, !chain.isEmpty {
                row(label: "Via", value: chain)
            }
            if let elementName = webContext.elementName {
                row(label: "Element", value: elementName)
            }
            if let elementPath = webContext.elementPath {
                row(label: "Element Path", value: elementPath)
            }
            if let selector = webContext.selector {
                row(label: "Selector", value: selector)
            }
            if let selectedText = webContext.selectedText {
                row(label: "Selected Text", value: selectedText)
            }
            if let cssClasses = webContext.cssClasses, !cssClasses.isEmpty {
                row(label: "Classes", value: cssClasses)
            }

            if let url = webContext.pageUrl {
                row(label: "URL", value: url)
            }

            if let styles = webContext.computedStyles, !styles.isEmpty {
                row(label: "Computed Styles", value: styles)
            }

            if let a11y = webContext.accessibility, !a11y.isEmpty {
                row(label: "Accessibility", value: a11y)
            }

            if let nearby = webContext.nearbyText, !nearby.isEmpty {
                row(label: "Nearby Text", value: nearby)
            }

            if let bbox = webContext.boundingBox {
                let parts = [
                    bbox.x.map { "x: \($0)" },
                    bbox.y.map { "y: \($0)" },
                    bbox.width.map { "w: \($0)" },
                    bbox.height.map { "h: \($0)" },
                ].compactMap { $0 }
                if !parts.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Bounding Box")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.primary.opacity(0.45))
                            .textCase(.uppercase)
                        WrapLayout(horizontalSpacing: 4, verticalSpacing: 4) {
                            ForEach(Array(parts.enumerated()), id: \.offset) { _, p in
                                TagChip(text: p)
                            }
                        }
                    }
                }
            }

            if let nearbyEls = webContext.nearbyElements, !nearbyEls.isEmpty {
                row(label: "Nearby Elements", value: nearbyEls)
            }

            if let elements = regionElements, elements.count > 1 {
                Text("Region Elements (\(elements.count))")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.primary.opacity(0.45))
                    .textCase(.uppercase)
                ForEach(Array(elements.prefix(5).enumerated()), id: \.offset) { _, el in
                    Text(el.displaySummary ?? el.elementName ?? el.selector ?? "unknown")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.primary.opacity(0.8))
                        .lineLimit(1)
                }
                if elements.count > 5 {
                    Text("+\(elements.count - 5) more")
                        .font(.system(size: 10))
                        .foregroundStyle(.primary.opacity(0.4))
                }
            }
        }
        .padding(14)
        .frame(maxWidth: 320)
    }

    private func row(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.primary.opacity(0.45))
                .textCase(.uppercase)
            Text(value)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .textSelection(.enabled)
        }
    }
}

/// Badge surfaced alongside `WebContextBadge` when a comment carries
/// HyperFrames composition context. Renders the official HyperFrames mark
/// (cyan-to-green wedges) and reveals the full structured prompt on hover
/// so the user can see what the agent will receive.
///
/// This is a debug-only / experimental visualization. It only appears when
/// `webContext.hyperframesContext` is non-empty, which itself depends on the
/// `webContextHyperframesEnabled` toggle in Preferences → Experimental.
struct HyperframesContextBadge: View {
    let hyperframesContext: String
    let colorScheme: ColorScheme
    @State private var showPopover = false

    /// Bridge emits `Label: value` lines (same shape as Web Context). Parse so
    /// the popover renders rows identical to `WebContextBadge`.
    private var parsedRows: [(label: String, value: String)] {
        hyperframesContext.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line in
            let raw = String(line).trimmingCharacters(in: .whitespaces)
            guard let colon = raw.firstIndex(of: ":") else { return nil }
            let label = String(raw[raw.startIndex..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(raw[raw.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if label.isEmpty || value.isEmpty { return nil }
            return (label, value)
        }
    }

    var body: some View {
        Image("HyperFramesLogo")
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: 12, height: 12)
            .padding(2)
            .background(
                Color.remarcAccent(for: colorScheme).opacity(0.12),
                in: RoundedRectangle(cornerRadius: 3)
            )
            .contentShape(Rectangle())
            // Hover-driven popover, matching WebContextBadge. With the
            // compact Label:value format the popover fits without scrolling,
            // so dismiss-on-mouseout is fine. Text selection is the only
            // affordance lost vs click-to-pin.
            .onHover { hovering in
                showPopover = hovering
            }
            .popover(isPresented: $showPopover, arrowEdge: .bottom) {
                hyperframesPopoverContent
            }
            .help("HyperFrames composition context attached")
            .accessibilityLabel("HyperFrames context attached")
    }

    private var hyperframesPopoverContent: some View {
        let rows = parsedRows
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image("HyperFramesLogo")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 14, height: 14)
                Text("HyperFrames Context")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.primary)
                Spacer(minLength: 0)
            }

            if rows.isEmpty {
                // Fallback for unexpected non-Label:value content — show raw,
                // selectable, scrollable.
                ScrollView(.vertical) {
                    Text(hyperframesContext)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.primary.opacity(0.9))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxHeight: 320)
            } else {
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(rows.enumerated()), id: \.offset) { _, entry in
                            row(label: entry.label, value: entry.value)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 320)
            }
        }
        .padding(14)
        .frame(width: 320)
    }

    /// Mirrors `WebContextBadge.row(label:value:)` for style parity. Multi-part
    /// values (separator " · ") render as outlined tag chips in a flow layout
    /// so wrapped lines never start with a stray separator. Single-string
    /// values render as plain text like the Web Context popover.
    @ViewBuilder
    private func row(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.primary.opacity(0.45))
                .textCase(.uppercase)

            let parts = value.components(separatedBy: " · ")
            if parts.count > 1 {
                WrapLayout(horizontalSpacing: 4, verticalSpacing: 4) {
                    ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                        tagChip(part)
                    }
                }
            } else {
                Text(value)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func tagChip(_ text: String) -> some View {
        TagChip(text: text)
    }
}

/// Small outlined chip for discrete metadata values. Used in the WrapLayout
/// inside `HyperframesContextBadge` and `WebContextBadge` so multi-part
/// values render as a flow of selectable pills rather than a single
/// punctuation-separated line that can break awkwardly on wrap.
struct TagChip: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 10.5, design: .monospaced))
            .foregroundStyle(.primary.opacity(0.88))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(Color.primary.opacity(0.18), lineWidth: 0.5)
            )
            .textSelection(.enabled)
    }
}

/// Simple flow / wrap layout — places subviews horizontally until they
/// exceed the proposed width, then breaks to a new line. Used for tag
/// chips in `HyperframesContextBadge` so multi-part values never end up
/// with a separator character at the start of a wrap line.
struct WrapLayout: Layout {
    var horizontalSpacing: CGFloat = 6
    var verticalSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        let rows = computeRows(subviews: subviews, maxWidth: maxWidth)
        let totalHeight = rows.reduce(0) { acc, r in acc + r.height } + verticalSpacing * CGFloat(max(0, rows.count - 1))
        let widest = rows.map(\.width).max() ?? 0
        return CGSize(width: min(maxWidth, widest), height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = computeRows(subviews: subviews, maxWidth: bounds.width)
        var y = bounds.minY
        for r in rows {
            var x = bounds.minX
            for idx in r.indices {
                let size = subviews[idx].sizeThatFits(.unspecified)
                subviews[idx].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + horizontalSpacing
            }
            y += r.height + verticalSpacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func computeRows(subviews: Subviews, maxWidth: CGFloat) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for (i, sv) in subviews.enumerated() {
            let s = sv.sizeThatFits(.unspecified)
            let wouldExceed = current.width + (current.indices.isEmpty ? 0 : horizontalSpacing) + s.width > maxWidth
            if wouldExceed && !current.indices.isEmpty {
                rows.append(current)
                current = Row()
            }
            if !current.indices.isEmpty { current.width += horizontalSpacing }
            current.indices.append(i)
            current.width += s.width
            current.height = max(current.height, s.height)
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}

// MARK: - Webhook Dropdown Panel

private struct WebhookDropdownPanel: View {
    let webhooks: [Webhook]
    let colorScheme: ColorScheme
    let onSelect: (Webhook) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ForEach(webhooks) { hook in
                MoveSessionRow(
                    name: hook.name,
                    icon: "paperplane",
                    colorScheme: colorScheme,
                    onSelect: { onSelect(hook) }
                )
            }
        }
        .padding(5)
        .frame(width: 180)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.remarcDropdownBackground(for: colorScheme))
        )
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(.primary.opacity(0.15), lineWidth: 0.5)
        )
    }
}

// MARK: - Move Dropdown Panel

private struct MoveDropdownPanel: View {
    let sessions: [Session]
    let canCreateNew: Bool
    let colorScheme: ColorScheme
    let onSelect: (_ sessionID: UUID, _ sessionName: String) -> Void
    let onNewSession: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ForEach(sessions) { session in
                MoveSessionRow(
                    name: session.name,
                    colorScheme: colorScheme,
                    onSelect: { onSelect(session.id, session.name) }
                )
            }
            if canCreateNew {
                MoveSessionRow(
                    name: "New Session\u{2026}",
                    icon: "plus",
                    colorScheme: colorScheme,
                    onSelect: onNewSession
                )
            }
        }
        .padding(5)
        .frame(width: 180)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.remarcDropdownBackground(for: colorScheme))
        )
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(.primary.opacity(0.15), lineWidth: 0.5)
        )
    }
}

private struct MoveSessionRow: View {
    let name: String
    var icon: String? = nil
    let colorScheme: ColorScheme
    let onSelect: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 6) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Color.remarcPrimary(for: colorScheme))
                        .frame(width: 14)
                }
                Text(name)
                    .font(.system(size: 12))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(isHovered ? Color.remarcPrimary(for: colorScheme).opacity(0.15) : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.1)) {
                isHovered = hovering
            }
        }
    }
}
