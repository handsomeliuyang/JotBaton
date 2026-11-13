import CoreLocalization
import CorePlatform
import CoreTheme
import CoreUI
import FeatureComments
import SwiftUI

// MARK: - Session Sidebar

/// Permanent session navigation beside the original-width comment pane.
struct SessionSidebarView: View {
    var statusFilters: Set<CommentStatusFilter> = []
    var onSelect: () -> Void = {}
    @ObservedObject private var localization = LocalizationManager.shared
    @ObservedObject private var persistence = AppServices.shared.comments
    @ObservedObject private var popoverController = MenuBarPopoverController.shared
    @Environment(\.colorScheme) private var colorScheme

    @State private var renamingSessionID: UUID?
    @State private var renameText: String = ""
    @State private var pendingNewSessionID: UUID?
    @State private var deletingSessionIDs: Set<UUID> = []
    @State private var searchText = ""
    @FocusState private var isSearchFocused: Bool

    private var visibleSessions: [Session] {
        let ordered = persistence.activeSessions
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return ordered.filter {
            $0.id == renamingSessionID || query.isEmpty || displayName($0).localizedStandardContains(query)
        }
    }

    private func displayName(_ session: Session) -> String {
        session.isInbox ? L10n.tr("Inbox") : session.name
    }

    var body: some View {
        let counts = CommentListQuery.countsBySession(of: persistence.allComments, statuses: statusFilters)
        VStack(spacing: 0) {
            searchHeader

            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    LazyVStack(spacing: 2) {
                        ForEach(visibleSessions) { session in
                            if renamingSessionID == session.id {
                                inlineRenameField(for: session)
                                    .padding(.horizontal, 4)
                                    .frame(minHeight: 30)
                                    .id(session.id)
                            } else {
                                sessionRow(for: session, counts: counts)
                                    .id(session.id)
                            }
                        }
                        if visibleSessions.isEmpty {
                            Text(L10n.tr("No results"))
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .padding(.vertical, 12)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 8)
                }
                .onAppear {
                    if let activeID = persistence.appState.activeSessionID {
                        proxy.scrollTo(activeID)
                    }
                }
                .onRemarcChange(of: popoverController.isVisible) { visible in
                    if visible, let activeID = persistence.appState.activeSessionID {
                        proxy.scrollTo(activeID)
                    }
                }
                .onRemarcChange(of: persistence.appState.activeSessionID) { newID in
                    guard let newID else { return }
                    withAnimation(.easeInOut(duration: 0.2)) {
                        proxy.scrollTo(newID)
                    }
                }
                .onRemarcChange(of: renamingSessionID) { sessionID in
                    if let sessionID {
                        proxy.scrollTo(sessionID)
                    }
                }
            }
            .frame(maxHeight: .infinity)

            appVersionFooter
        }
        .frame(width: WorkspaceMetrics.sessionSidebarWidth)
        .frame(maxHeight: .infinity)
        .background(Color.remarcSidebarSurface(for: colorScheme))
        .onRemarcChange(of: isSearchFocused) { focused in
            if focused { popoverController.makeKey() }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("remarc.sessions.sidebar")
    }

    private var searchHeader: some View {
        HStack(spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField(L10n.tr("Search sessions…"), text: $searchText)
                    .textFieldStyle(.plain)
                    .frame(minWidth: 0)
                    .focused($isSearchFocused)
                    .onExitCommand {
                        searchText = ""
                        isSearchFocused = false
                    }
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(L10n.tr("Clear search"))
                }
            }
            .font(.system(size: 11))
            .padding(.horizontal, 7)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.remarcNeutralFill(for: colorScheme)))
            .accessibilityIdentifier("remarc.sessions.search")

            newSessionButton
        }
        .padding(.horizontal, 8)
        .padding(.top, 10)
        .padding(.bottom, 6)
    }

    /// Fixed below the scrolling session list in both panel and detached modes.
    private var appVersionFooter: some View {
        HStack(spacing: 6) {
            RemarcBrandMark(size: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(AppIdentity.current.displayName)
                    .font(.system(size: 10, weight: .medium))
                if let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String {
                    let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
                    Text("v\(version)")
                        .font(.system(size: 9, design: .monospaced))
                        .help("\(AppIdentity.current.displayName) v\(version) (\(build ?? "—"))")
                        .accessibilityIdentifier("remarc.app.version")
                }
            }
            .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    // MARK: - Selection

    private func select(_ session: Session) {
        commitActiveRename()
        persistence.setActiveSession(session.id)
        onSelect()
    }

    // MARK: - Session Row

    private func sessionRow(for session: Session, counts: [UUID: Int]) -> some View {
        SessionSidebarRow(
            session: session,
            title: displayName(session),
            isActive: persistence.appState.activeSessionID == session.id,
            commentCount: counts[session.id] ?? 0,
            colorScheme: colorScheme,
            isBeingDeleted: deletingSessionIDs.contains(session.id),
            onTap: { select(session) },
            onDoubleClick: {
                guard !session.isInbox else { return }
                beginRename(session)
            },
            contextMenu: { sessionContextMenu(for: session) }
        )
    }

    // MARK: - Context Menu

    @ViewBuilder
    private func sessionContextMenu(for session: Session) -> some View {
        if !session.isInbox {
            Button {
                persistence.setSessionPinned(session.id, to: !session.isPinned)
            } label: {
                Label(session.isPinned ? L10n.tr("Unpin session") : L10n.tr("Pin session"),
                      systemImage: session.isPinned ? "pin.slash" : "pin")
            }
            Divider()
            Button {
                beginRename(session)
            } label: {
                Label(L10n.tr("Rename"), systemImage: "pencil")
            }
            Button(role: .destructive) {
                animateDeleteSession(session.id)
            } label: {
                Label(L10n.tr("Delete"), systemImage: "trash")
            }
        }
    }

    // MARK: - Animated Delete

    private func animateDeleteSession(_ sessionID: UUID) {
        let finishDeletion = {
            deletingSessionIDs.remove(sessionID)
            persistence.deleteSession(sessionID)
        }
        if #available(macOS 14, *) {
            withAnimation(.easeOut(duration: 0.2)) {
                _ = deletingSessionIDs.insert(sessionID)
            } completion: {
                finishDeletion()
            }
        } else {
            withAnimation(.easeOut(duration: 0.2)) {
                _ = deletingSessionIDs.insert(sessionID)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                finishDeletion()
            }
        }
    }

    // MARK: - Inline Rename

    private func inlineRenameField(for session: Session) -> some View {
        SessionRenameField(
            text: $renameText,
            brandColor: Color.remarcPrimary(for: colorScheme),
            colorScheme: colorScheme,
            onCommit: {
                commitRename(session)
            },
            onCancel: {
                cancelRename()
            }
        )
    }

    private func beginRename(_ session: Session) {
        renameText = session.name
        renamingSessionID = session.id
    }

    private func commitRename(_ session: Session) {
        let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            persistence.renameSession(session.id, to: trimmed)
        }
        renamingSessionID = nil
        pendingNewSessionID = nil
    }

    private func cancelRename() {
        // If this was a pending new session with no name committed, delete it
        if let newID = pendingNewSessionID, newID == renamingSessionID {
            persistence.deleteSession(newID)
            pendingNewSessionID = nil
        }
        renamingSessionID = nil
    }

    /// Commit any active rename before switching or creating a session.
    private func commitActiveRename() {
        guard let sessionID = renamingSessionID,
              let session = persistence.activeSessions.first(where: { $0.id == sessionID }) else { return }
        commitRename(session)
    }

    // MARK: - New Session Button

    private var newSessionButton: some View {
        NewSessionButton(
            colorScheme: colorScheme,
            suppressHover: renamingSessionID != nil,
            onCreate: {
                createNewSession()
            }
        )
    }

    private func createNewSession() {
        commitActiveRename()
        searchText = ""
        isSearchFocused = false
        let name = SessionNaming.nextName()
        guard let session = persistence.createSession(name: name) else { return }
        persistence.setActiveSession(session.id)
        pendingNewSessionID = session.id
        beginRename(session)
        onSelect()
    }
}

// MARK: - Session Row

private struct SessionSidebarRow<MenuContent: View>: View {
    let session: Session
    let title: String
    let isActive: Bool
    let commentCount: Int
    let colorScheme: ColorScheme
    var isBeingDeleted: Bool = false
    let onTap: () -> Void
    let onDoubleClick: () -> Void
    @ViewBuilder let contextMenu: () -> MenuContent

    @State private var isHovered = false
    @State private var lastClickDate: Date?

    var body: some View {
        let brandColor = Color.remarcPrimary(for: colorScheme)
        Button(action: handleClick) {
            HStack(spacing: 6) {
                leadingIcon(brandColor: brandColor)

                Text(title)
                    .font(.system(size: 11.5, weight: isActive ? .semibold : .regular))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)

                countBadge
            }
            .foregroundStyle(isActive ? brandColor : .primary.opacity(0.82))
            .padding(.leading, 8)
            .padding(.trailing, 6)
            .frame(height: 28)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityLabel(title)
        .accessibilityValue(L10n.tr("\(commentCount) comments"))
        .accessibilityHint(session.isPinned ? L10n.tr("Pinned session") : "")
        .accessibilityAddTraits(isActive ? .isSelected : [])
        .accessibilityIdentifier("remarc.session.\(session.id.uuidString)")
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isActive ? brandColor.opacity(0.13) : Color.primary.opacity(isHovered ? 0.05 : 0))
        )
        .overlay(alignment: .leading) {
            if isActive {
                RoundedRectangle(cornerRadius: 1)
                    .fill(brandColor)
                    .frame(width: 2.5)
                    .padding(.vertical, 7)
            }
        }
        .contentShape(Rectangle())
        .contextMenu { contextMenu() }
        .accessibilityElement(children: .contain)
        .onHover { isHovered = $0 }
        .animation(.easeInOut(duration: 0.15), value: isHovered)
        .opacity(isBeingDeleted ? 0 : 1)
        .frame(height: isBeingDeleted ? 0 : nil)
        .clipped()
    }

    /// Session icon with the pinned mark laid over its corner, so pinning
    /// costs the title no width.
    private func leadingIcon(brandColor: Color) -> some View {
        Group {
            if session.isInbox {
                Image(systemName: "tray")
                    .font(.system(size: 11))
            } else if session.origin == .manual {
                Image(systemName: "folder")
                    .font(.system(size: 11))
            } else {
            }
        }
        .foregroundStyle(isActive ? brandColor : .secondary)
        .frame(width: 16, height: 16)
        .overlay(alignment: .bottomTrailing) {
            if session.isPinned && !session.isInbox {
                Image(systemName: "pin.fill")
                    .font(.system(size: 5.5, weight: .bold))
                    .foregroundStyle(.white)
                    .rotationEffect(.degrees(35))
                    .frame(width: 9, height: 9)
                    .background(Circle().fill(isActive ? Color.remarcButtonBase(for: colorScheme) : Color.remarcSecondary(for: colorScheme)))
                    .overlay(Circle().strokeBorder(Color.remarcSidebarRowKnockout(for: colorScheme), lineWidth: 1))
                    .offset(x: 3, y: 2)
                    .accessibilityHidden(true)
            }
        }
    }

    private var countBadge: some View {
        Text("\(commentCount)")
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(commentCount == 0
                ? AnyShapeStyle(.primary.opacity(0.28))
                : isActive ? AnyShapeStyle(Color.white) : AnyShapeStyle(.primary.opacity(0.6)))
            .padding(.horizontal, 5)
            .frame(minWidth: 18, minHeight: 15)
            .background(
                Capsule().fill(commentCount == 0
                    ? Color.clear
                    : isActive ? Color.remarcButtonBase(for: colorScheme) : Color.remarcNeutralFill(for: colorScheme))
            )
            .fixedSize()
            .accessibilityHidden(true)
    }

    /// A single click selects immediately; a following click opens rename.
    private func handleClick() {
        let now = Date()
        if let last = lastClickDate, now.timeIntervalSince(last) < NSEvent.doubleClickInterval {
            lastClickDate = nil
            onDoubleClick()
        } else {
            lastClickDate = now
            onTap()
        }
    }
}

// MARK: - Inline Rename Field

/// A text field that replaces a sidebar row during inline rename.
/// Commits on Enter or focus loss, cancels on Esc or empty text.
private struct SessionRenameField: View {
    @ObservedObject private var localization = LocalizationManager.shared
    @Binding var text: String
    let brandColor: Color
    let colorScheme: ColorScheme
    let onCommit: () -> Void
    let onCancel: () -> Void

    @FocusState private var isFocused: Bool
    @State private var clickMonitor: Any?

    var body: some View {
        TextField(L10n.tr("Session name"), text: $text)
            .textFieldStyle(.plain)
            .font(.system(size: 11, weight: .medium))
            .padding(.horizontal, 7)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(brandColor.opacity(0.12))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(brandColor.opacity(0.4), lineWidth: 1)
            )
            .frame(maxWidth: .infinity)
            .focused($isFocused)
            .onAppear {
                // Ensure the panel is key so the field editor draws the caret.
                // Non-activating panels don't auto-become-key from button clicks.
                MenuBarPopoverController.shared.makeKey()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    isFocused = true
                }
                // Install click-outside monitor: any click not on a text field
                // resigns first responder, triggering focus-loss commit.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    clickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
                        if let window = event.window,
                           let hitView = window.contentView?.hitTest(event.locationInWindow) {
                            var view: NSView? = hitView
                            while let v = view {
                                if v is NSTextField { return event }
                                view = v.superview
                            }
                        }
                        NSApp.keyWindow?.makeFirstResponder(nil)
                        return event
                    }
                }
            }
            .onDisappear {
                if let monitor = clickMonitor {
                    NSEvent.removeMonitor(monitor)
                    clickMonitor = nil
                }
            }
            .onSubmit {
                handleCommit()
            }
            .onExitCommand(perform: onCancel)
            .onRemarcChange(of: isFocused) { focused in
                if !focused {
                    handleCommit()
                }
            }
    }

    private func handleCommit() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            onCancel()
        } else {
            onCommit()
        }
    }
}

// MARK: - New Session Button

/// Compact "+" in the fixed sidebar header.
private struct NewSessionButton: View {
    @ObservedObject private var localization = LocalizationManager.shared
    let colorScheme: ColorScheme
    var suppressHover: Bool = false
    let onCreate: () -> Void

    @State private var isHovered = false

    private var effectiveHover: Bool { isHovered && !suppressHover }

    var body: some View {
        let brandColor = Color.remarcPrimary(for: colorScheme)

        Button(action: onCreate) {
            Image(systemName: "plus")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(effectiveHover ? brandColor : .primary.opacity(0.55))
                .frame(width: 22, height: 22)
                .background(
                    Circle()
                        .fill(effectiveHover ? brandColor.opacity(0.12) : Color.primary.opacity(0.05))
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L10n.tr("New session"))
        .accessibilityIdentifier("remarc.sessions.new")
        .onHover { isHovered = $0 }
        .animation(.easeInOut(duration: 0.15), value: effectiveHover)
        .help(L10n.tr("New session"))
    }
}

// MARK: - Session Naming

/// Generates sequential session names: "Session A", "Session B", ..., "Session Z", "Session AA", ...
@MainActor
enum SessionNaming {
    static func nextName() -> String {
        let existingNames = Set(AppServices.shared.comments.activeSessions.map(\.name))
        for i in 0... {
            let name = "Session \(letterLabel(for: i))"
            if !existingNames.contains(name) { return name }
        }
        return L10n.tr("Session") // Fallback (unreachable)
    }

    private static func letterLabel(for index: Int) -> String {
        var n = index
        var result = ""
        repeat {
            result = String(Character(UnicodeScalar(65 + (n % 26))!)) + result
            n = n / 26 - 1
        } while n >= 0
        return result
    }
}
