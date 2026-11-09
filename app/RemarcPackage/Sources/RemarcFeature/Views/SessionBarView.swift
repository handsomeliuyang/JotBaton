import SwiftUI

// MARK: - Session Bar View

/// Horizontal pill bar for switching between active sessions.
/// The scrolling strip holds one capsule per session. Hovering it reveals page
/// arrows, and a pinned "+" and session menu sit after it.
struct SessionBarView: View {
    @ObservedObject private var persistence = PersistenceManager.shared
    @ObservedObject private var popoverController = MenuBarPopoverController.shared
    @Environment(\.colorScheme) private var colorScheme

    @State private var renamingSessionID: UUID?
    @State private var renameText: String = ""
    @State private var pendingNewSessionID: UUID?
    @State private var deletingSessionIDs: Set<UUID> = []
    @State private var canScrollLeft = false
    @State private var canScrollRight = false
    @State private var isStripHovered = false
    @State private var stripScroller = HorizontalStripScroller()

    /// Pre-compute comment counts per session once per render instead of O(s*n) per pill.
    private var commentCountsBySession: [UUID: Int] {
        persistence.unresolvedCommentCountsBySession
    }

    var body: some View {
        let counts = commentCountsBySession
        HStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(persistence.activeSessions) { session in
                            if renamingSessionID == session.id {
                                inlineRenameField(for: session)
                                    .id(session.id)
                            } else {
                                sessionPill(for: session, counts: counts)
                                    .id(session.id)
                            }
                        }
                    }
                    .padding(.horizontal, 4)
                    .padding(.vertical, 8)
                    .background {
                        // Tap empty space in the bar to dismiss active rename
                        Color.clear
                            .contentShape(Rectangle())
                            .onTapGesture {
                                commitActiveRename()
                            }
                    }
                    .background(
                        HorizontalWheelScrollBridge(scroller: stripScroller) { left, right in
                            canScrollLeft = left
                            canScrollRight = right
                        }
                    )
                }
                .mask(edgeFadeMask)
                .overlay(alignment: .leading) {
                    if isStripHovered && canScrollLeft {
                        StripPageButton(direction: -1, colorScheme: colorScheme) {
                            stripScroller.page(-1)
                        }
                        .transition(.opacity)
                    }
                }
                .overlay(alignment: .trailing) {
                    if isStripHovered && canScrollRight {
                        StripPageButton(direction: 1, colorScheme: colorScheme) {
                            stripScroller.page(1)
                        }
                        .transition(.opacity)
                    }
                }
                .onHover { hovering in
                    withAnimation(.easeInOut(duration: 0.15)) {
                        isStripHovered = hovering
                    }
                }
                .onAppear {
                    if let activeID = persistence.appState.activeSessionID {
                        proxy.scrollTo(activeID, anchor: .center)
                    }
                }
                .onRemarcChange(of: popoverController.isVisible) { visible in
                    if visible, let activeID = persistence.appState.activeSessionID {
                        proxy.scrollTo(activeID, anchor: .center)
                    }
                }
                .onRemarcChange(of: persistence.appState.activeSessionID) { newID in
                    guard let newID else { return }
                    withAnimation(.easeInOut(duration: 0.2)) {
                        proxy.scrollTo(newID, anchor: .center)
                    }
                }
            }

            newSessionButton
                .padding(.leading, 4)

            if persistence.activeSessions.count > 1 {
                sessionMenu(counts: counts)
                    .padding(.leading, 2)
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, 8)
    }

    /// Fades whichever edge still has pills hidden behind it.
    private var edgeFadeMask: some View {
        HStack(spacing: 0) {
            LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing)
                .frame(width: canScrollLeft ? 20 : 0)
            Rectangle()
            LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                .frame(width: canScrollRight ? 20 : 0)
        }
        .animation(.easeInOut(duration: 0.15), value: canScrollLeft)
        .animation(.easeInOut(duration: 0.15), value: canScrollRight)
    }

    // MARK: - Selection

    private func select(_ session: Session) {
        commitActiveRename()
        persistence.setActiveSession(session.id)
    }

    // MARK: - Session Menu

    private func sessionMenu(counts: [UUID: Int]) -> some View {
        Menu {
            ForEach(persistence.activeSessions) { session in
                let isCurrent = persistence.appState.activeSessionID == session.id
                Toggle(isOn: Binding(get: { isCurrent }, set: { _ in select(session) })) {
                    Text("\(session.name) (\(counts[session.id] ?? 0))")
                }
            }
        } label: {
            Image(systemName: "chevron.down")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.primary.opacity(0.5))
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Switch session")
    }

    // MARK: - Session Pill

    private func sessionPill(for session: Session, counts: [UUID: Int] = [:]) -> some View {
        let isActive = persistence.appState.activeSessionID == session.id
        let count = counts[session.id] ?? 0

        return SessionPillView(
            session: session,
            isActive: isActive,
            commentCount: count,
            colorScheme: colorScheme,
            isBeingDeleted: deletingSessionIDs.contains(session.id),
            onTap: {
                select(session)
            },
            onDoubleClick: {
                guard !session.isInbox else { return }
                beginRename(session)
            },
            contextMenu: {
                sessionContextMenu(for: session)
            }
        )
    }

    // MARK: - Context Menu

    @ViewBuilder
    private func sessionContextMenu(for session: Session) -> some View {
        if !session.isInbox {
            Button {
                beginRename(session)
            } label: {
                Label("Rename", systemImage: "pencil")
            }
            Button(role: .destructive) {
                animateDeleteSession(session.id)
            } label: {
                Label("Delete", systemImage: "trash")
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

    /// Commit any active rename (called when clicking elsewhere in the bar).
    private func commitActiveRename() {
        guard let sessionID = renamingSessionID,
              let session = persistence.activeSessions.first(where: { $0.id == sessionID }) else { return }
        commitRename(session)
    }

    // MARK: - New Session Button

    private var newSessionButton: some View {
        NewSessionPillButton(
            colorScheme: colorScheme,
            canCreate: persistence.activeSessions.count < AppConstants.maxActiveSessions,
            suppressHover: renamingSessionID != nil,
            onCreate: {
                createNewSession()
            }
        )
    }

    private func createNewSession() {
        let name = SessionNaming.nextName()
        guard let session = persistence.createSession(name: name) else { return }
        persistence.setActiveSession(session.id)
        pendingNewSessionID = session.id
        beginRename(session)
    }
}

// MARK: - Mouse Wheel Bridge

/// Handle the page arrows use to reach the strip's AppKit scroll view.
@MainActor
final class HorizontalStripScroller {
    fileprivate weak var bridge: HorizontalWheelScrollBridge.BridgeView?

    func page(_ direction: Int) {
        bridge?.page(direction)
    }
}

/// Lets a plain mouse wheel scroll the horizontal session strip, and reports
/// which edges still hide pills.
///
/// A SwiftUI horizontal `ScrollView` on macOS only follows horizontal deltas.
/// A classic wheel only produces vertical ones, so without this the strip can
/// only be moved with a trackpad or Shift+wheel. Trackpads and other devices
/// with precise deltas keep their native behavior.
private struct HorizontalWheelScrollBridge: NSViewRepresentable {
    let scroller: HorizontalStripScroller
    var onEdgesChange: (_ canScrollLeft: Bool, _ canScrollRight: Bool) -> Void

    func makeNSView(context: Context) -> BridgeView {
        let view = BridgeView(onEdgesChange: onEdgesChange)
        scroller.bridge = view
        return view
    }

    func updateNSView(_ view: BridgeView, context: Context) {
        view.onEdgesChange = onEdgesChange
        scroller.bridge = view
        view.reportEdges()
    }

    static func dismantleNSView(_ view: BridgeView, coordinator: ()) {
        view.stopMonitoring()
    }

    final class BridgeView: NSView {
        var onEdgesChange: (Bool, Bool) -> Void
        private var monitor: Any?
        private weak var observedScrollView: NSScrollView?
        private var reportedEdges: (left: Bool, right: Bool)?

        /// Points scrolled per wheel line.
        private static let lineStep: CGFloat = 16

        init(onEdgesChange: @escaping (Bool, Bool) -> Void) {
            self.onEdgesChange = onEdgesChange
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopMonitoring()
            guard window != nil, let scrollView = enclosingScrollView else { return }
            observedScrollView = scrollView
            scrollView.contentView.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(
                self, selector: #selector(geometryChanged),
                name: NSView.boundsDidChangeNotification, object: scrollView.contentView
            )
            NotificationCenter.default.addObserver(
                self, selector: #selector(geometryChanged),
                name: NSView.frameDidChangeNotification, object: scrollView.documentView
            )
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self, self.scrollHorizontally(with: event) else { return event }
                return nil
            }
            reportEdges()
        }

        override func layout() {
            super.layout()
            reportEdges()
        }

        func stopMonitoring() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
            NotificationCenter.default.removeObserver(self)
            observedScrollView = nil
        }

        @objc private func geometryChanged(_ notification: Notification) {
            reportEdges()
        }

        /// Returns true when the event was consumed.
        private func scrollHorizontally(with event: NSEvent) -> Bool {
            guard let scrollView = observedScrollView, let window,
                  event.window === window, !isHiddenOrHasHiddenAncestor,
                  !event.hasPreciseScrollingDeltas,
                  abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX),
                  let documentView = scrollView.documentView
            else { return false }
            let pointer = scrollView.convert(event.locationInWindow, from: nil)
            guard scrollView.bounds.contains(pointer) else { return false }
            let clipView = scrollView.contentView
            let maxX = documentView.frame.width - clipView.bounds.width
            guard maxX > 0 else { return false }
            var origin = clipView.bounds.origin
            origin.x = min(max(origin.x - event.scrollingDeltaY * Self.lineStep, 0), maxX)
            clipView.scroll(to: origin)
            scrollView.reflectScrolledClipView(clipView)
            return true
        }

        /// Scrolls most of a visible width in `direction` (-1 left, 1 right), animated.
        func page(_ direction: Int) {
            guard let scrollView = observedScrollView, let documentView = scrollView.documentView else { return }
            let clipView = scrollView.contentView
            let maxX = documentView.frame.width - clipView.bounds.width
            guard maxX > 0 else { return }
            var origin = clipView.bounds.origin
            origin.x = min(max(origin.x + CGFloat(direction) * clipView.bounds.width * 0.7, 0), maxX)
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.25
                context.allowsImplicitAnimation = true
                clipView.animator().setBoundsOrigin(origin)
            }
            scrollView.reflectScrolledClipView(clipView)
        }

        func reportEdges() {
            guard let scrollView = observedScrollView, let documentView = scrollView.documentView else { return }
            let visible = scrollView.contentView.bounds
            let edges = (left: visible.minX > 1, right: visible.maxX < documentView.frame.width - 1)
            guard reportedEdges?.left != edges.left || reportedEdges?.right != edges.right else { return }
            reportedEdges = edges
            // Deferred: this can run inside a SwiftUI update pass.
            DispatchQueue.main.async { [weak self] in
                self?.onEdgesChange(edges.left, edges.right)
            }
        }
    }
}

// MARK: - Session Pill View

/// Individual session pill with hover, tap, double-click, and context menu support.
/// Uses manual double-click detection to avoid SwiftUI's tap disambiguation delay.
private struct SessionPillView<MenuContent: View>: View {
    let session: Session
    let isActive: Bool
    let commentCount: Int
    let colorScheme: ColorScheme
    var isBeingDeleted: Bool = false
    let onTap: () -> Void
    let onDoubleClick: () -> Void
    @ViewBuilder let contextMenu: () -> MenuContent

    @State private var isHovered = false
    @State private var lastClickDate: Date?

    private var isMuted: Bool {
        !isActive && commentCount == 0
    }

    var body: some View {
        let brandColor = Color.remarcPrimary(for: colorScheme)

        Button(action: handleClick) {
            HStack(spacing: 4) {
                SessionOriginBadge(origin: session.origin)

                Text(session.name)
                    .font(.system(size: 11, weight: isActive ? .semibold : .medium))
                    .foregroundStyle(
                        isActive
                            ? brandColor
                            : .primary.opacity(isMuted ? 0.35 : 0.6)
                    )
                    .lineLimit(1)

                Text("\(commentCount)")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(
                        isActive
                            ? brandColor.opacity(0.7)
                            : .primary.opacity(isMuted ? 0.25 : 0.4)
                    )
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(pillBackground(isActive: isActive, brandColor: brandColor))
            .overlay(pillBorder(isActive: isActive, brandColor: brandColor))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .contextMenu {
            contextMenu()
        }
        .onHover { hovering in
            isHovered = hovering
        }
        .animation(.easeInOut(duration: 0.15), value: isHovered)
        .animation(.easeInOut(duration: 0.15), value: isActive)
        // Delete animation — below implicit animations so they don't block it
        .opacity(isBeingDeleted ? 0 : 1)
        .scaleEffect(isBeingDeleted ? 0.01 : 1.0)
        .frame(width: isBeingDeleted ? 0 : nil)
        .clipped()
    }

    private func handleClick() {
        let now = Date()
        if let last = lastClickDate, now.timeIntervalSince(last) < 0.3 {
            lastClickDate = nil
            onDoubleClick()
        } else {
            lastClickDate = now
            onTap()
        }
    }

    private func pillBackground(isActive: Bool, brandColor: Color) -> some View {
        Capsule()
            .fill(
                isActive
                    ? brandColor.opacity(0.12)
                    : Color.primary.opacity(isHovered ? 0.06 : 0)
            )
    }

    private func pillBorder(isActive: Bool, brandColor: Color) -> some View {
        Capsule()
            .strokeBorder(
                isActive ? brandColor.opacity(0.25) : Color.clear,
                lineWidth: 1
            )
    }
}

// MARK: - Inline Rename Field

/// A text field that replaces a pill during inline rename.
/// Commits on Enter or focus loss, cancels on Esc or empty text.
private struct SessionRenameField: View {
    @Binding var text: String
    let brandColor: Color
    let colorScheme: ColorScheme
    let onCommit: () -> Void
    let onCancel: () -> Void

    @FocusState private var isFocused: Bool
    @State private var clickMonitor: Any?

    var body: some View {
        TextField("Session name", text: $text)
            .textFieldStyle(.plain)
            .font(.system(size: 11, weight: .medium))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(
                Capsule()
                    .fill(brandColor.opacity(0.12))
            )
            .overlay(
                Capsule()
                    .strokeBorder(brandColor.opacity(0.4), lineWidth: 1)
            )
            .frame(minWidth: 60, maxWidth: 140)
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

// MARK: - New Session Pill Button

/// Compact "+" pinned after the session strip so it never scrolls out of view.
/// At the session limit it stays muted and shows a toast on click.
private struct NewSessionPillButton: View {
    let colorScheme: ColorScheme
    let canCreate: Bool
    var suppressHover: Bool = false
    let onCreate: () -> Void

    @State private var isHovered = false

    private var effectiveHover: Bool { isHovered && !suppressHover && canCreate }

    var body: some View {
        let brandColor = Color.remarcPrimary(for: colorScheme)

        Button {
            if canCreate {
                onCreate()
            } else {
                ToastManager.shared.show("Session limit reached")
            }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(canCreate
                    ? (effectiveHover ? brandColor : .primary.opacity(0.55))
                    : .primary.opacity(0.2))
                .frame(width: 22, height: 22)
                .background(
                    Circle()
                        .fill(effectiveHover ? brandColor.opacity(0.12) : Color.primary.opacity(0.05))
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(.easeInOut(duration: 0.15), value: effectiveHover)
        .help(canCreate ? "New session" : "Session limit reached")
    }
}

// MARK: - Strip Page Button

/// Arrow shown over an overflowing strip edge while the pointer is on the
/// strip, so a mouse user can tell there is more to scroll and page to it.
private struct StripPageButton: View {
    /// -1 pages left, 1 pages right.
    let direction: Int
    let colorScheme: ColorScheme
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        let brandColor = Color.remarcPrimary(for: colorScheme)

        Button(action: action) {
            Image(systemName: direction < 0 ? "chevron.left" : "chevron.right")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(isHovered ? brandColor : .primary.opacity(0.7))
                .frame(width: 20, height: 20)
                .background(
                    Circle()
                        .fill(Color.remarcDropdownBackground(for: colorScheme))
                )
                .overlay(
                    Circle()
                        .strokeBorder(isHovered ? brandColor.opacity(0.35) : Color.primary.opacity(0.12), lineWidth: 0.5)
                )
                .shadow(color: .black.opacity(0.12), radius: 2, y: 1)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 2)
        .onHover { isHovered = $0 }
        .animation(.easeInOut(duration: 0.15), value: isHovered)
        .help(direction < 0 ? "Scroll left" : "Scroll right")
    }
}

// MARK: - Session Naming

/// Generates sequential session names: "Session A", "Session B", ..., "Session Z", "Session AA", ...
@MainActor
enum SessionNaming {
    static func nextName() -> String {
        let existingNames = Set(PersistenceManager.shared.activeSessions.map(\.name))
        for i in 0... {
            let name = "Session \(letterLabel(for: i))"
            if !existingNames.contains(name) { return name }
        }
        return "Session" // Fallback (unreachable)
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
