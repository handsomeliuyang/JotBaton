import AppKit
import CoreLocalization
import CoreTheme
import CoreUI
import FeatureComments
import SwiftUI

// MARK: - Shared Session Move Dropdown

/// Shared session move actions and dropdown presentation used by both
/// `SessionPickerPill` and `CommentCardView`.
@MainActor
enum SessionMoveDropdown {
    static func displayName(for session: Session) -> String {
        session.isInbox ? L10n.tr("Inbox") : session.name
    }

    /// Moves `comment` to `sessionID` when different, showing a toast with Undo.
    static func move(_ comment: Comment, to sessionID: UUID) {
        guard sessionID != comment.sessionID else { return }
        let persistence = AppServices.shared.comments
        let previousSessionID = comment.sessionID
        let targetName = persistence.activeSessions
            .first { $0.id == sessionID }
            .map(displayName(for:)) ?? L10n.tr("Inbox")

        persistence.moveComment(comment.id, to: sessionID)
        ToastManager.shared.show(L10n.tr("Moved to \(targetName)"), undo: {
            AppServices.shared.comments.moveComment(comment.id, to: previousSessionID)
        })
    }

    /// Creates a new session with `rawName` (if non-empty) and moves `comment` into it.
    static func createSessionAndMove(_ comment: Comment, name rawName: String) {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty,
              let session = AppServices.shared.comments.createSession(name: name) else { return }
        move(comment, to: session.id)
    }

    /// Prompts for a new session name in a lightweight dialog and moves `comment` into it.
    /// Used from native context menus where no inline popover anchor remains open.
    static func promptNewSessionAndMove(_ comment: Comment) {
        let alert = NSAlert()
        alert.messageText = L10n.tr("New Session\u{2026}")
        alert.addButton(withTitle: L10n.tr("Create"))
        alert.addButton(withTitle: L10n.tr("Cancel"))

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        field.placeholderString = L10n.tr("Session name")
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            createSessionAndMove(comment, name: field.stringValue)
        }
    }

    /// Presents the shared session dropdown anchored below `anchor` to move `comment`.
    static func show(
        for comment: Comment,
        anchor: AnchorViewRef,
        colorScheme: ColorScheme,
        onDismiss: @escaping () -> Void = {}
    ) {
        guard let screenFrame = anchor.screenFrame() else {
            onDismiss()
            return
        }
        let sessions = AppServices.shared.comments.activeSessions

        DropdownPanelController.shared.show(
            below: screenFrame,
            width: 180,
            colorScheme: colorScheme,
            anchorWindowLevel: anchor.windowLevel(),
            onDismiss: onDismiss
        ) {
            SessionDropdownPanel(
                sessions: sessions,
                currentSessionID: comment.sessionID,
                colorScheme: colorScheme,
                onSelect: { sessionID in
                    move(comment, to: sessionID)
                    DropdownPanelController.shared.dismiss()
                },
                onCreateSession: { name in
                    createSessionAndMove(comment, name: name)
                    DropdownPanelController.shared.dismiss()
                }
            )
        }
    }
}

struct SessionPickerPill: View {
    @ObservedObject private var localization = LocalizationManager.shared
    @Binding var selectedSessionID: UUID?
    let mode: Mode
    let comment: Comment?

    @ObservedObject private var persistence = AppServices.shared.comments
    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovered = false
    @State private var isOpen = false
    @State private var isCreatingNew = false
    @State private var newSessionName = ""
    @State private var anchorRef = AnchorViewRef()
    @FocusState private var isTextFieldFocused: Bool

    enum Mode {
        /// Creating a new comment — pill selects the draft target and the active session
        case create
        /// Editing an existing comment — pill moves comment immediately
        case edit
    }

    private var selectedSession: Session? {
        persistence.activeSessions.first { $0.id == selectedSessionID }
    }

    private var displayName: String {
        guard let session = selectedSession else { return L10n.tr("Inbox") }
        return SessionMoveDropdown.displayName(for: session)
    }

    var body: some View {
        if isCreatingNew {
            newSessionTextField
        } else {
            pillButton
        }
    }

    // MARK: - Pill Button

    private var pillButton: some View {
        Button {
            if isOpen {
                DropdownPanelController.shared.dismiss()
            } else {
                showDropdown()
            }
        } label: {
            HStack(spacing: 3) {
                Text(displayName)
                    .font(.system(size: 11))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8, weight: .medium))
                    .foregroundStyle(chevronColor)
            }
            .foregroundStyle(textColor)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(
                Capsule()
                    .fill(backgroundColor)
            )
            .overlay(
                Capsule()
                    .strokeBorder(borderColor, lineWidth: 0.5)
            )
            .overlay(DropdownAnchor(ref: anchorRef))
        }
        .buttonStyle(.plain)
        .help(displayName)
        .accessibilityLabel(displayName)
        .accessibilityHint(L10n.tr("Move to session"))
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
    }

    // MARK: - New Session Text Field

    private var newSessionTextField: some View {
        TextField(L10n.tr("Session name"), text: $newSessionName)
            .font(.system(size: 11))
            .textFieldStyle(.plain)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(
                Capsule()
                    .fill(Color.remarcPrimary(for: colorScheme).opacity(0.12))
            )
            .overlay(
                Capsule()
                    .strokeBorder(Color.remarcPrimary(for: colorScheme).opacity(0.3), lineWidth: 0.5)
            )
            .frame(width: 100)
            .focused($isTextFieldFocused)
            .onSubmit {
                commitNewSession()
            }
            .onExitCommand {
                cancelNewSession()
            }
            .onRemarcChange(of: isTextFieldFocused) { focused in
                if !focused {
                    commitNewSession()
                }
            }
            .onAppear {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    isTextFieldFocused = true
                }
            }
    }

    // MARK: - Dropdown

    private func showDropdown() {
        guard let screenFrame = anchorRef.screenFrame() else { return }
        isOpen = true
        let cs = colorScheme
        let sessions = persistence.activeSessions
        let currentID = selectedSessionID

        DropdownPanelController.shared.show(
            below: screenFrame,
            width: 180,
            colorScheme: cs,
            anchorWindowLevel: anchorRef.windowLevel(),
            onDismiss: { isOpen = false }
        ) {
            SessionDropdownPanel(
                sessions: sessions,
                currentSessionID: currentID,
                colorScheme: cs,
                onSelect: { sessionID in
                    selectSession(sessionID)
                    DropdownPanelController.shared.dismiss()
                },
                onNewSession: {
                    DropdownPanelController.shared.dismiss()
                    startCreatingNewSession()
                }
            )
        }
    }

    // MARK: - Actions

    private func selectSession(_ sessionID: UUID) {
        if mode == .create {
            // Remember explicit choices immediately, even if the draft is cancelled.
            // Keep the draft's own target so later sidebar changes cannot redirect it.
            selectedSessionID = sessionID
            persistence.setActiveSession(sessionID)
            return
        }

        guard sessionID != selectedSessionID, let comment else { return }
        SessionMoveDropdown.move(comment, to: sessionID)
        selectedSessionID = sessionID
    }

    private func startCreatingNewSession() {
        MenuBarPopoverController.shared.makeKey()
        newSessionName = ""
        isCreatingNew = true
    }

    private func commitNewSession() {
        let name = newSessionName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            cancelNewSession()
            return
        }

        if let session = AppServices.shared.comments.createSession(name: name) {
            selectSession(session.id)
        }
        isCreatingNew = false
        newSessionName = ""
    }

    private func cancelNewSession() {
        isCreatingNew = false
        newSessionName = ""
    }

    // MARK: - Colors

    private var textColor: Color {
        if isOpen {
            return Color.remarcPrimary(for: colorScheme)
        } else {
            return .primary.opacity(0.6)
        }
    }

    private var chevronColor: Color {
        if isOpen {
            return Color.remarcPrimary(for: colorScheme)
        } else if isHovered {
            return .primary.opacity(0.6)
        } else {
            return .primary.opacity(0.45)
        }
    }

    private var backgroundColor: Color {
        if isOpen {
            return Color.remarcPrimary(for: colorScheme).opacity(0.12)
        } else if isHovered {
            return .primary.opacity(0.08)
        } else {
            return .primary.opacity(0.04)
        }
    }

    private var borderColor: Color {
        if isOpen {
            return Color.remarcPrimary(for: colorScheme).opacity(0.3)
        } else if isHovered {
            return .primary.opacity(0.12)
        } else {
            return .primary.opacity(0.08)
        }
    }
}

// MARK: - Session Dropdown Panel

struct SessionDropdownPanel: View {
    @ObservedObject private var localization = LocalizationManager.shared
    let sessions: [Session]
    let currentSessionID: UUID?
    let colorScheme: ColorScheme
    let onSelect: (UUID) -> Void
    let onNewSession: (() -> Void)?
    let onCreateSession: ((String) -> Void)?

    @State private var isCreatingInline = false
    @State private var newSessionName = ""
    @FocusState private var isInlineFieldFocused: Bool

    init(
        sessions: [Session],
        currentSessionID: UUID?,
        colorScheme: ColorScheme,
        onSelect: @escaping (UUID) -> Void,
        onNewSession: (() -> Void)? = nil,
        onCreateSession: ((String) -> Void)? = nil
    ) {
        self.sessions = sessions
        self.currentSessionID = currentSessionID
        self.colorScheme = colorScheme
        self.onSelect = onSelect
        self.onNewSession = onNewSession
        self.onCreateSession = onCreateSession
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(sessions) { session in
                            SessionOptionRow(
                                name: SessionMoveDropdown.displayName(for: session),
                                isSelected: session.id == currentSessionID,
                                colorScheme: colorScheme,
                                onSelect: { onSelect(session.id) }
                            )
                            .frame(height: 28)
                            .id(session.id)
                        }
                    }
                }
                .frame(height: min(CGFloat(sessions.count) * 28, 240))
                .onAppear {
                    if let currentSessionID { proxy.scrollTo(currentSessionID) }
                }
            }

            Divider()
                .padding(.horizontal, 6)
                .padding(.vertical, 2)

            if isCreatingInline {
                inlineNewSessionField
            } else {
                NewSessionRow(
                    colorScheme: colorScheme,
                    onTap: {
                        if let onNewSession {
                            onNewSession()
                        } else {
                            startInlineCreation()
                        }
                    }
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

    private var inlineNewSessionField: some View {
        TextField(L10n.tr("Session name"), text: $newSessionName)
            .font(.system(size: 12))
            .textFieldStyle(.plain)
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color.remarcPrimary(for: colorScheme).opacity(0.10))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(Color.remarcPrimary(for: colorScheme).opacity(0.35), lineWidth: 0.5)
            )
            .focused($isInlineFieldFocused)
            .onSubmit {
                commitInlineCreation()
            }
            .onExitCommand {
                cancelInlineCreation()
            }
            .onAppear {
                DropdownPanelController.shared.makeKey()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    isInlineFieldFocused = true
                }
            }
    }

    private func startInlineCreation() {
        newSessionName = ""
        isCreatingInline = true
    }

    private func commitInlineCreation() {
        let name = newSessionName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            cancelInlineCreation()
            return
        }
        isCreatingInline = false
        newSessionName = ""
        onCreateSession?(name)
    }

    private func cancelInlineCreation() {
        isCreatingInline = false
        newSessionName = ""
    }
}

private struct SessionOptionRow: View {
    @ObservedObject private var localization = LocalizationManager.shared
    let name: String
    let isSelected: Bool
    let colorScheme: ColorScheme
    let onSelect: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 6) {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.remarcPrimary(for: colorScheme))
                    .frame(width: 14)
                    .opacity(isSelected ? 1 : 0)
                Text(name)
                    .font(.system(size: 12))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(rowBackground)
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

    private var rowBackground: Color {
        if isHovered {
            return Color.remarcPrimary(for: colorScheme).opacity(0.15)
        } else if isSelected {
            return Color.remarcPrimary(for: colorScheme).opacity(0.06)
        } else {
            return .clear
        }
    }
}

private struct NewSessionRow: View {
    @ObservedObject private var localization = LocalizationManager.shared
    let colorScheme: ColorScheme
    let onTap: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 6) {
                Image(systemName: "plus")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.remarcPrimary(for: colorScheme))
                    .frame(width: 14)
                Text(L10n.tr("New Session\u{2026}"))
                    .font(.system(size: 12))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(rowBackground)
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

    private var rowBackground: Color {
        isHovered ? Color.remarcPrimary(for: colorScheme).opacity(0.15) : .clear
    }
}
