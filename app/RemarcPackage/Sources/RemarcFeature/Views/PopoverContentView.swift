import SwiftUI
import AppKit
#if canImport(FoundationModels)
import FoundationModels
#endif

struct PopoverContentView: View {
    var fillWidth: Bool = false
    /// Pushes the content down (used for the menu bar panel's arrow strip) while the
    /// background gradient keeps filling the full view, so the arrow matches the body color.
    var topInset: CGFloat = 0

    @ObservedObject private var toastManager = ToastManager.shared
    @ObservedObject private var persistence = PersistenceManager.shared
    @ObservedObject private var popoverController = MenuBarPopoverController.shared
    @ObservedObject private var detachedController = DetachedWindowController.shared
    @ObservedObject private var settings = SettingsManager.shared
    @Environment(\.colorScheme) private var colorScheme

    @State private var searchText = ""
    @State private var isSearching = false
    @State private var sortNewestFirst = true
    @State private var focusedCommentID: UUID?
    @ObservedObject private var mcpManager = MCPManager.shared
    @State private var showDeleteAllConfirmation = false
    @State private var showResolveAllConfirmation = false
    @State private var showClearPrompt = false
    @State private var clearPromptProgress: CGFloat = 0
    @State private var clearPromptCancelled = false
    @State private var showMCPPopover = false
    @State private var mcpSettingsIconHovered = false
    @State private var showAutoClearCountdown = false
    @State private var autoClearProgress: CGFloat = 0
    @State private var autoClearCancelled = false
    @State private var pendingExportReceipt: ExportReceipt?
    @State private var exportClearGeneration = UUID()
    @State private var showingHistory = false
    @State private var restoredCommentID: UUID?
    @State private var historySearchText = ""
    @State private var isHistorySearching = false
    @State private var historySortNewestFirst = true
    @State private var critModeActive = false
    @State private var showCritModeOnboarding = false
    @State private var historyTab: HistoryTab = .comments
    @AppStorage("commentListShowsAllSessions") private var showsAllSessions = false
    @AppStorage("commentListStatusFilter") private var statusFilter: CommentStatusFilter = .outstanding
    @State private var showsResolvedSection = false
    @State private var searchHiddenAt: Date?
    @State private var keyboardScrollTarget: UUID?
    @FocusState private var isSearchFieldFocused: Bool

    /// Reopening the panel within this window resumes the previous search.
    private static let searchRetention: TimeInterval = 60

    private enum HistoryTab {
        case comments, transcriptions
    }

    // MARK: - Computed Comments

    /// What the card list shows, derived once per render.
    private struct ListModel {
        /// Comments matching the status filter, in on-screen order.
        var primary: [Comment] = []
        /// Resolved matches folded under the list while "未完成" is selected.
        var resolved: [Comment] = []
        var counts: [CommentStatusFilter: Int] = [:]
        /// Search hits in other sessions while a single session is shown.
        var otherSessionMatches = 0
        var scopeIsEmpty = true

        func visibleComments(showsResolved: Bool) -> [Comment] {
            primary + (showsResolved ? resolved : [])
        }
    }

    private var sessionNames: [UUID: String] {
        Dictionary(persistence.appState.sessions.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
    }

    private var searchTerms: [String] {
        isSearching ? CommentListQuery.searchTerms(from: searchText) : []
    }

    /// Comments in every session shown in the session bar.
    private var listedComments: [Comment] {
        let listed = Set(persistence.activeSessions.map(\.id))
        return persistence.allComments.filter { listed.contains($0.sessionID) }
    }

    /// Outstanding comments across every listed session; matches the "全部" pill.
    private var allSessionsOutstandingCount: Int {
        CommentCountPolicy.unresolvedCount(in: listedComments)
    }

    private var scopeOutstandingCount: Int {
        showsAllSessions ? allSessionsOutstandingCount : CommentCountPolicy.unresolvedCount(in: persistence.activeComments)
    }

    private var listModel: ListModel {
        let names = sessionNames
        let terms = searchTerms
        let activeID = persistence.appState.activeSessionID
        let pool = listedComments
        let scoped = showsAllSessions ? pool : persistence.activeComments
        let matched = CommentListQuery.sorted(
            scoped.filter { CommentListQuery.matches($0, terms: terms, sessionName: names[$0.sessionID]) },
            newestFirst: sortNewestFirst
        )

        var model = ListModel()
        model.scopeIsEmpty = scoped.isEmpty
        model.counts = CommentListQuery.counts(of: matched)
        let primary = matched.filter { statusFilter.includes($0.status) }
        model.primary = showsAllSessions
            ? CommentListQuery.grouped(primary, sessions: persistence.activeSessions).flatMap(\.comments)
            : primary
        if statusFilter == .outstanding {
            model.resolved = matched.filter { $0.status == .resolved }
        }
        if !terms.isEmpty && !showsAllSessions {
            model.otherSessionMatches = pool.filter {
                $0.sessionID != activeID && CommentListQuery.matches($0, terms: terms, sessionName: names[$0.sessionID])
            }.count
        }
        return model
    }

    private var hasComments: Bool {
        !persistence.activeComments.isEmpty
    }

    // MARK: - Body

    var body: some View {
        ZStack(alignment: .top) {
            // Gradient fills the full panel area (sized by hosting view / VEV).
            // Separated from the content VStack so fittingSize returns the
            // content's ideal height, not infinity.
            // ignoresSafeArea lets it extend behind the titlebar in detached mode.
            Color.remarcBackgroundGradient(for: colorScheme)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                if showCritModeOnboarding {
                    critModeOnboardingContent
                } else if critModeActive {
                    critModeContent
                } else if showingHistory {
                    if isHistorySearching {
                        historySearchHeader
                    } else {
                        historyHeader
                    }
                    Divider()
                    if #available(macOS 26, *), historyTab == .transcriptions {
                        TranscriptionHistoryView(searchText: $historySearchText, sortNewestFirst: $historySortNewestFirst)
                    } else {
                        CommentHistoryView(showingHistory: $showingHistory, restoredCommentID: $restoredCommentID, searchText: $historySearchText, sortNewestFirst: $historySortNewestFirst)
                    }
                } else {
                    let model = listModel
                    if isSearching {
                        searchHeader(model: model)
                    } else {
                        normalHeader
                    }

                    Divider()

                    SessionBarView(showsAllSessions: $showsAllSessions, allSessionsCount: allSessionsOutstandingCount)

                    if model.scopeIsEmpty && !isSearching {
                        emptyState
                    } else {
                        statusFilterBar(counts: model.counts)
                        cardList(model)
                    }

                    if hasComments && !isSearching {
                        if showAutoClearCountdown {
                            Divider()
                            autoClearCountdown
                        } else if showClearPrompt {
                            Divider()
                            clearPrompt
                                .transition(.opacity.combined(with: .move(edge: .bottom)))
                        }
                    }
                }
                if !critModeActive && !showCritModeOnboarding {
                    Divider()
                    footer
                }
            }
            .frame(minHeight: AppConstants.popoverMinHeight)
            .padding(.top, topInset)
        }
        .frame(width: fillWidth ? nil : AppConstants.popoverWidth)
        .frame(maxWidth: fillWidth ? .infinity : nil)
        .overlay(alignment: .topTrailing) {
            if popoverController.isDetached {
                headerButton(icon: detachedController.isPinned ? "pin.fill" : "pin") {
                    detachedController.togglePin()
                }
                .help(detachedController.isPinned ? "Unpin window" : "Pin window")
                .padding(.top, 4 + topInset)
                .padding(.trailing, 10)
                .ignoresSafeArea()
            }
        }
        .overlay(alignment: .bottom) {
            if let toast = toastManager.currentToast {
                ToastOverlay(toast: toast)
                    .padding(.bottom, !critModeActive && !showCritModeOnboarding ? 52 : 12)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: toastManager.currentToast?.id)
        // Material background, rounded corners, and shadow provided by
        // NSVisualEffectView + maskImage in MenuBarPopoverController
        .remarcArrowKeys { direction in
            moveFocus(direction: direction)
        }
        .onRemarcChange(of: popoverController.isVisible) { visible in
            if visible {
                Task { await SnapshotSyncManager.shared.checkIfNeeded() }
                if let hiddenAt = searchHiddenAt, Date().timeIntervalSince(hiddenAt) > Self.searchRetention {
                    searchText = ""
                    isSearching = false
                }
                searchHiddenAt = nil
            }
            if !visible {
                searchHiddenAt = Date()
                showingHistory = false
                historySearchText = ""
                isHistorySearching = false
                historyTab = .comments
                showCritModeOnboarding = false
                if critModeActive {
                    if #available(macOS 26, *) {
                        CritModeService.shared.cancelRecording()
                    }
                    critModeActive = false
                    popoverController.preventDismiss = false
                }
            }
        }
        .onRemarcChange(of: persistence.appState.activeSessionID) { _ in
            popoverController.resizeAfterLayoutSettles()
        }
        .onRemarcChange(of: showsAllSessions) { _ in
            popoverController.resizeAfterLayoutSettles()
        }
        .onRemarcChange(of: statusFilter) { _ in
            popoverController.resizeAfterLayoutSettles()
        }
        .onRemarcChange(of: showsResolvedSection) { _ in
            popoverController.resizeAfterLayoutSettles()
        }
        .onRemarcChange(of: popoverController.requestCritMode) { requested in
            if requested {
                popoverController.requestCritMode = false
                startCritMode()
            }
        }
    }

    // MARK: - Normal Header

    private var normalHeader: some View {
        HStack(spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    showsAllSessions = true
                    statusFilter = .outstanding
                }
            } label: {
                HStack(spacing: 0) {
                    let scopeCount = scopeOutstandingCount
                    let totalCount = allSessionsOutstandingCount
                    Text("\(scopeCount) ")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Color.remarcAccent(for: colorScheme))
                    Text("条未完成")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.remarcPrimary(for: colorScheme))
                    if !showsAllSessions && totalCount != scopeCount {
                        Text(" · 共 \(totalCount)")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.primary.opacity(0.45))
                    }
                }
                .lineLimit(1)
                .fixedSize()
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("查看所有 session 的未完成评论")

            HStack(spacing: 8) {
                headerButton(icon: "magnifyingglass") {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        isSearching = true
                    }
                }
                .keyboardShortcut("f", modifiers: .command)
                .help("搜索 (⌘F)")

                headerButton(icon: AppConstants.historyIcon) {
                    withAnimation(.easeInOut(duration: 0.15)) { showingHistory = true }
                    popoverController.resizeAfterLayoutSettles()
                }
                .help("评论历史")
            }

            Spacer()

            creationButton(icon: RemarcSymbols.quickNote) {
                FloatingEditorController.shared.showForQuickNote()
            }
            .help("新建快速笔记")

            creationButton(icon: "camera.viewfinder") {
                MenuBarPopoverController.shared.dismiss()
                ScreenCaptureService.shared.startCapture(
                    onRegionSelected: { captureRect, sourceBundleID in
                        CommentInputController.shared.showForScreenshot(captureRect: captureRect, sourceBundleID: sourceBundleID)
                    },
                    onCancel: {
                        debugLog("PopoverHeader: screenshot capture cancelled")
                    }
                )
            }
            .help("截图评论")

            if #available(macOS 26, *) {
                creationButton(icon: "mic.fill") {
                    startCritMode()
                }
                .help("Crit Mode")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        // Negative top padding extends the wash into the arrow strip (topInset) so the
        // arrow reads as part of this band; inert when topInset is 0 (detached window).
        .background((colorScheme == .light ? Color.black.opacity(0.04) : Color.clear).padding(.top, -topInset))
    }

    // MARK: - History Header

    private func dismissHistory() {
        historySearchText = ""
        isHistorySearching = false
        historyTab = .comments
        withAnimation(.easeInOut(duration: 0.15)) { showingHistory = false }
        popoverController.resizeAfterLayoutSettles()
    }

    @available(macOS 26, *)
    private var historyTabPicker: some View {
        HStack(spacing: 0) {
            historyTabButton("Comments", tab: .comments)
            historyTabButton("Dictation", tab: .transcriptions)
        }
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.primary.opacity(colorScheme == .dark ? 0.08 : 0.06))
        )
    }

    @available(macOS 26, *)
    private func historyTabButton(_ title: String, tab: HistoryTab) -> some View {
        let isSelected = historyTab == tab
        return Button {
            withAnimation(.easeInOut(duration: 0.15)) { historyTab = tab }
            historySearchText = ""
        } label: {
            Text(title)
                .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? Color.remarcPrimary(for: colorScheme) : .primary.opacity(0.5))
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(isSelected ? Color.remarcPrimary(for: colorScheme).opacity(colorScheme == .dark ? 0.15 : 0.10) : .clear)
                )
        }
        .buttonStyle(.plain)
    }

    private var historyHeader: some View {
        ZStack {
            // Center: tab picker or title
            if #available(macOS 26, *) {
                historyTabPicker
            } else {
                HStack(spacing: 6) {
                    Image(systemName: AppConstants.historyIcon)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.remarcPrimary(for: colorScheme))
                    Text("History")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.remarcPrimary(for: colorScheme))
                }
            }

            // Left: back button
            HStack {
                headerButton(icon: "chevron.left") {
                    dismissHistory()
                }
                .help("Back to comments")
                Spacer()
            }

            // Right: search + sort
            HStack {
                Spacer()
                if hasHistoryContent {
                    headerButton(icon: "magnifyingglass") {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            isHistorySearching = true
                        }
                    }
                    .help("Search history")

                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            historySortNewestFirst.toggle()
                        }
                    } label: {
                        Image(systemName: "arrow.down")
                            .font(.system(size: 12, weight: .medium))
                            .rotationEffect(.degrees(historySortNewestFirst ? 0 : 180))
                            .foregroundStyle(.primary.opacity(0.6))
                            .frame(width: 26, height: 26)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(historySortNewestFirst ? "Sort oldest first" : "Sort newest first")
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var hasHistoryContent: Bool {
        if #available(macOS 26, *), historyTab == .transcriptions {
            return !persistence.transcriptions.isEmpty
        }
        return !persistence.deletedComments.isEmpty
    }

    private var historySearchHeader: some View {
        HStack(spacing: 8) {
            headerButton(icon: "chevron.left") {
                dismissHistory()
            }
            .help("Back to comments")

            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(.primary.opacity(0.6))

            TextField("Search history...", text: $historySearchText)
                .textFieldStyle(.plain)
                .font(.system(size: 13))

            Button(action: {
                historySearchText = ""
                withAnimation(.easeInOut(duration: 0.15)) {
                    isHistorySearching = false
                }
            }) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(.primary.opacity(0.6))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - Search Header

    private func searchHeader(model: ListModel) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(.primary.opacity(0.6))

            TextField("搜索标题、正文、引用、来源或 session", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($isSearchFieldFocused)
                .onSubmit { openSelectedComment(in: model) }
                .onExitCommand(perform: closeSearch)
                .modifier(SearchFieldArrowKeys(onMove: moveFocus(direction:)))

            Button(action: closeSearch) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(.primary.opacity(0.6))
            }
            .buttonStyle(.plain)
            .help("关闭搜索 (Esc)")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .onAppear {
            // Non-activating panels don't become key on their own, and the
            // field editor needs a key window to take focus.
            MenuBarPopoverController.shared.makeKey()
            DispatchQueue.main.async {
                isSearchFieldFocused = true
            }
        }
    }

    private func closeSearch() {
        searchText = ""
        withAnimation(.easeInOut(duration: 0.15)) {
            isSearching = false
        }
    }

    /// Enter in the search field opens the keyboard-selected card, or the first hit.
    private func openSelectedComment(in model: ListModel) {
        let visible = model.visibleComments(showsResolved: showsResolvedSection)
        let target = visible.first { $0.id == focusedCommentID } ?? visible.first
        if let target {
            FloatingEditorController.shared.showForEdit(comment: target)
        }
    }

    // MARK: - Status Filter

    private func statusFilterBar(counts: [CommentStatusFilter: Int]) -> some View {
        HStack(spacing: 4) {
            ForEach(CommentStatusFilter.allCases, id: \.self) { filter in
                StatusFilterChip(
                    title: filter.title,
                    count: counts[filter] ?? 0,
                    isSelected: statusFilter == filter,
                    colorScheme: colorScheme
                ) {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        statusFilter = filter
                    }
                }
                .help(filter.help)
            }

            Spacer(minLength: 0)

            headerButton(icon: sortNewestFirst ? "arrow.down" : "arrow.up") {
                sortNewestFirst.toggle()
            }
            .help(sortNewestFirst ? "最新在前，点击改为最早在前" : "最早在前，点击改为最新在前")
        }
        .padding(.leading, 12)
        .padding(.trailing, 8)
        .padding(.bottom, 2)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 16) {
            if AppIdentity.current.isDevelopment {
                RemarcBrandMark(size: 56)
            } else {
            ZStack {
                RemarcLogoShape(part: .outline)
                    .stroke(.primary.opacity(0.15), lineWidth: 1.5)
                RemarcLogoShape(part: .counter)
                    .stroke(.primary.opacity(0.15), lineWidth: 1.5)
            }
            .frame(width: 56, height: 56)
            }

            Text("Do something Remarcable")
                .font(.system(size: 12))
                .foregroundStyle(.primary.opacity(0.45))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Card List

    private func cardList(_ model: ListModel) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 8) {
                    if showsAllSessions {
                        ForEach(CommentListQuery.grouped(model.primary, sessions: persistence.activeSessions)) { group in
                            sessionGroupHeader(group)
                            ForEach(group.comments) { comment in
                                commentCard(for: comment)
                            }
                        }
                    } else {
                        ForEach(model.primary) { comment in
                            commentCard(for: comment)
                        }
                    }

                    if model.primary.isEmpty {
                        filteredEmptyState
                    }

                    if !model.resolved.isEmpty {
                        resolvedSectionToggle(count: model.resolved.count)
                        if showsResolvedSection {
                            ForEach(model.resolved) { comment in
                                commentCard(for: comment, showsSessionName: showsAllSessions)
                            }
                        }
                    }

                    if model.otherSessionMatches > 0 {
                        otherSessionMatchesHint(count: model.otherSessionMatches)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.top, 6)
                .padding(.bottom, 8)
            }
            .scrollIndicators(.never)
            .background(ScrollerHider())
            .onRemarcChange(of: keyboardScrollTarget) { target in
                guard let target else { return }
                withAnimation(.easeInOut(duration: 0.15)) {
                    proxy.scrollTo(target)
                }
            }
        }
    }

    private func sessionGroupHeader(_ group: CommentGroup) -> some View {
        Button {
            showsAllSessions = false
            persistence.setActiveSession(group.session.id)
        } label: {
            HStack(spacing: 4) {
                SessionOriginBadge(origin: group.session.origin)
                Text(group.session.name)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                Text("\(group.comments.count)")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .opacity(0.6)
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .semibold))
                    .opacity(0.5)
                Spacer(minLength: 0)
            }
            .foregroundStyle(.primary.opacity(0.6))
            .padding(.horizontal, 4)
            .padding(.top, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("切换到 \(group.session.name)")
    }

    private func resolvedSectionToggle(count: Int) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                showsResolvedSection.toggle()
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: showsResolvedSection ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                Image(systemName: CommentStatus.resolved.iconName)
                    .font(.system(size: 10))
                Text("已解决 \(count) 条")
                    .font(.system(size: 11, weight: .medium))
                Spacer(minLength: 0)
            }
            .foregroundStyle(.primary.opacity(0.5))
            .padding(.horizontal, 4)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(showsResolvedSection ? "收起已解决的评论" : "显示已解决的评论")
    }

    private var filteredEmptyState: some View {
        Text(searchTerms.isEmpty ? "没有\(statusFilter.title)的评论" : "没有匹配的\(statusFilter.title)评论")
            .font(.system(size: 12))
            .foregroundStyle(.primary.opacity(0.45))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 20)
    }

    private func otherSessionMatchesHint(count: Int) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                showsAllSessions = true
            }
        } label: {
            HStack(spacing: 4) {
                Text("其他 session 还有 \(count) 条匹配")
                Text("查看全部")
                    .foregroundStyle(Color.remarcPrimary(for: colorScheme))
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(Color.remarcPrimary(for: colorScheme))
            }
            .font(.system(size: 11))
            .foregroundStyle(.primary.opacity(0.5))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func commentCard(for comment: Comment, showsSessionName: Bool = false) -> some View {
        CommentCardView(
            comment: comment,
            isFocused: focusedCommentID == comment.id,
            searchTerms: searchTerms,
            sessionName: showsSessionName ? sessionNames[comment.sessionID] : nil,
            onFocusChange: { focused in
                focusedCommentID = focused ? comment.id : nil
            }
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppConstants.cardCornerRadius, style: .continuous)
                .fill(Color.remarcPrimary(for: colorScheme).opacity(restoredCommentID == comment.id ? 0.12 : 0))
                .allowsHitTesting(false)
                .animation(.easeOut(duration: 0.8), value: restoredCommentID)
        )
    }

    // MARK: - Footer

    /// Session-wide actions act on the active session only, so they are off
    /// while the list mixes sessions or is narrowed by a search.
    private var sessionActionsDisabled: Bool {
        !hasComments || isSearching || showingHistory || showsAllSessions
    }

    private var footer: some View {
        HStack(spacing: 6) {
            primaryFooterButton(icon: "doc.on.doc", title: "复制全部") {
                copyAll()
            }
            .help(showsAllSessions ? "选择一个 session 后可复制" : "复制当前 session 的全部评论")
            .disabled(sessionActionsDisabled)

            mcpButton

            Spacer()

            sessionActionsMenu
                .disabled(sessionActionsDisabled)

            SnapshotSyncToolbarButton()

            iconFooterButton(icon: "gearshape") {
                PreferencesWindowController.shared.show()
            }
            .help("设置")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(colorScheme == .light ? Color.black.opacity(0.04) : Color.clear)
    }

    /// Bulk actions for the active session, grouped so the footer stays readable.
    private var sessionActionsMenu: some View {
        Menu {
            Button {
                showResolveAllConfirmation = true
            } label: {
                Label("全部标为已解决", systemImage: "checkmark.bubble")
            }
            .disabled(unresolvedCommentCount == 0)

            Button {
                exportToFile()
            } label: {
                Label("导出到文件\u{2026}", systemImage: "arrow.down.doc")
            }

            Divider()

            Button(role: .destructive) {
                showDeleteAllConfirmation = true
            } label: {
                Label("删除全部评论", systemImage: "trash")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(showsAllSessions ? "选择一个 session 后可批量操作" : "批量操作当前 session")
        .popover(isPresented: $showResolveAllConfirmation, arrowEdge: .top) {
            resolveAllConfirmation
        }
        .background(
            Color.clear
                .popover(isPresented: $showDeleteAllConfirmation, arrowEdge: .top) {
                    deleteAllConfirmation
                }
        )
    }

    // MARK: - Clear Prompt (shown after Copy All / Export)

    private var clearPrompt: some View {
        VStack(spacing: 6) {
            HStack {
                Text("清除已导出的评论？")
                    .font(.system(size: 11))
                Spacer()
                ConfirmationButton(label: "保留", role: .cancel) {
                    dismissClearPrompt()
                }
                ConfirmationButton(label: "清除", role: .destructive) {
                    clearPromptCancelled = true
                    exportClearGeneration = UUID()
                    let receipt = pendingExportReceipt
                    pendingExportReceipt = nil
                    withAnimation(.easeInOut(duration: 0.25)) {
                        showClearPrompt = false
                    }
                    if let receipt {
                        Task { @MainActor in
                            if case .failure = persistence.clearExportedComments(receipt) {
                                ToastManager.shared.show("清除失败")
                            }
                        }
                    }
                }
            }
            HStack {
                Button {
                    PreferencesWindowController.shared.show(tab: "Export")
                } label: {
                    HStack(spacing: 4) {
                        Text("在设置中调整复制全部后的行为")
                        Image(systemName: "gearshape")
                    }
                    .font(.system(size: 10))
                    .contentShape(Rectangle())
                }
                .buttonStyle(TertiaryLinkButtonStyle())
                Spacer()
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 14)
        .background(alignment: .bottom) {
            GeometryReader { geo in
                Rectangle()
                    .fill(Color.remarcPrimary(for: colorScheme).opacity(0.4))
                    .frame(width: geo.size.width * (1 - clearPromptProgress))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 3)
            .frame(maxHeight: .infinity, alignment: .bottom)
        }
    }

    private func startClearPromptDismiss(generation: UUID) {
        clearPromptCancelled = false
        clearPromptProgress = 0
        withAnimation(.linear(duration: 5)) {
            clearPromptProgress = 1
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            guard !clearPromptCancelled, exportClearGeneration == generation else { return }
            pendingExportReceipt = nil
            withAnimation(.easeInOut(duration: 0.25)) {
                showClearPrompt = false
            }
        }
    }

    private func dismissClearPrompt() {
        clearPromptCancelled = true
        exportClearGeneration = UUID()
        pendingExportReceipt = nil
        withAnimation(.easeInOut(duration: 0.25)) {
            showClearPrompt = false
        }
    }

    // MARK: - Auto-Clear Countdown

    private var autoClearCountdown: some View {
        HStack {
            let count = pendingExportReceipt?.count ?? 0
            Text("正在清除 \(count) 条评论…")
                .font(.system(size: 11))
            Spacer()
            Button("Undo") {
                cancelAutoClear()
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Color.remarcPrimary(for: colorScheme))
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(alignment: .leading) {
            GeometryReader { geo in
                Rectangle()
                    .fill(Color.remarcPrimary(for: colorScheme).opacity(0.15))
                    .frame(width: geo.size.width * autoClearProgress)
            }
        }
    }

    private func startAutoClear(receipt: ExportReceipt, generation: UUID) {
        autoClearCancelled = false
        autoClearProgress = 0
        withAnimation(.linear(duration: 3)) {
            autoClearProgress = 1
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            guard !autoClearCancelled,
                  exportClearGeneration == generation,
                  pendingExportReceipt == receipt else { return }
            showAutoClearCountdown = false
            pendingExportReceipt = nil
            Task { @MainActor in
                switch persistence.clearExportedComments(receipt) {
                case .success(let clearedIDs):
                    ToastManager.shared.show("已清除 \(clearedIDs.count) 条评论")
                case .failure:
                    ToastManager.shared.show("清除失败")
                }
            }
        }
    }

    private func cancelAutoClear() {
        autoClearCancelled = true
        exportClearGeneration = UUID()
        pendingExportReceipt = nil
        withAnimation(.easeOut(duration: 0.2)) {
            autoClearProgress = 0
        }
        showAutoClearCountdown = false
    }

    // MARK: - Delete All Confirmation

    private var deleteAllConfirmation: some View {
        let sessionName = persistence.activeSession?.name ?? "Inbox"
        return VStack(spacing: 8) {
            Text("删除 \(sessionName) 中的全部评论？")
                .font(.system(size: 12, weight: .medium))
            HStack(spacing: 8) {
                ConfirmationButton(label: "取消", role: .cancel) {
                    showDeleteAllConfirmation = false
                }
                ConfirmationButton(label: "全部删除", role: .destructive) {
                    if let sessionID = persistence.appState.activeSessionID {
                        let clearedIDs = persistence.clearAllComments(in: sessionID)
                        showDeleteAllConfirmation = false
                        ToastManager.shared.show("已删除全部评论", undo: {
                            persistence.restoreComments(clearedIDs)
                        }, duration: 5.0)
                    }
                }
            }
        }
        .padding(12)
    }

    // MARK: - Resolve All Confirmation

    private var resolveAllConfirmation: some View {
        let sessionName = persistence.activeSession?.name ?? "Inbox"
        let unresolvedCount = unresolvedCommentCount
        return VStack(spacing: 8) {
            Text("将 \(sessionName) 中的 \(unresolvedCount) 条评论全部标为已解决？")
                .font(.system(size: 12, weight: .medium))
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                ConfirmationButton(label: "取消", role: .cancel) {
                    showResolveAllConfirmation = false
                }
                ConfirmationButton(label: "全部解决", role: .confirm) {
                    if let sessionID = persistence.appState.activeSessionID {
                        let comments = persistence.comments(for: sessionID)
                            .filter { $0.status != .resolved }
                        for comment in comments {
                            persistence.setCommentStatus(comment.id, to: .resolved)
                        }
                        showResolveAllConfirmation = false
                        ToastManager.shared.show("已解决 \(comments.count) 条评论", undo: {
                            for comment in comments {
                                persistence.setCommentStatus(comment.id, to: comment.status)
                            }
                        }, duration: 5.0)
                    }
                }
            }
        }
        .frame(maxWidth: 200)
        .padding(12)
    }

    private var unresolvedCommentCount: Int {
        guard let sessionID = persistence.appState.activeSessionID else { return 0 }
        return persistence.comments(for: sessionID).filter { $0.status != .resolved }.count
    }

    // MARK: - MCP Indicator

    private var mcpStatusColor: Color {
        if mcpManager.isEnabled { return Color.remarcSuccess(for: colorScheme) }
        if mcpManager.hasDependencyError { return Color.remarcWarning(for: colorScheme) }
        return Color.remarcError(for: colorScheme)
    }

    private var mcpStatusTooltip: String {
        if mcpManager.isEnabled {
            return "MCP connected\nAI agents can read your comments"
        }
        if mcpManager.hasDependencyError {
            return "MCP needs attention\nMissing dependencies - click for details"
        }
        return "MCP not connected\nClick to enable"
    }

    private var mcpButton: some View {
        Button {
            // Re-check dependencies each time the popover opens so the
            // error state clears after the user installs Node/Claude CLI.
            if mcpManager.hasDependencyError {
                mcpManager.checkDependencies()
            }
            showMCPPopover = true
        } label: {
            Label("MCP", systemImage: "powerplug")
                .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Color.remarcPrimary(for: colorScheme))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .overlay(alignment: .topTrailing) {
                Circle()
                    .fill(mcpStatusColor)
                    .frame(width: 6, height: 6)
                    .shadow(
                        color: mcpManager.isEnabled ? mcpStatusColor.opacity(0.6) : .clear,
                        radius: 3
                    )
                    .offset(x: 2, y: -2)
                    .animation(.easeInOut(duration: 0.2), value: mcpStatusColor)
            }
        }
        .buttonStyle(SecondaryFooterButtonStyle())
        .help(mcpStatusTooltip)
        .popover(isPresented: $showMCPPopover, arrowEdge: .top) {
            mcpPopoverContent
        }
    }

    @ViewBuilder
    private var mcpPopoverContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Circle()
                    .fill(mcpStatusColor)
                    .frame(width: 6, height: 6)
                    .shadow(color: mcpManager.isEnabled ? mcpStatusColor.opacity(0.6) : .clear, radius: 3)
                Text(mcpManager.isEnabled ? "Enabled" : (mcpManager.hasDependencyError ? "Missing Dependencies" : "Not Connected"))
                    .font(.system(size: 12, weight: .medium))
            }

            if mcpManager.hasDependencyError {
                VStack(alignment: .leading, spacing: 4) {
                    if mcpManager.nodeStatus == .notFound {
                        Label("Node.js not found", systemImage: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.remarcWarning(for: colorScheme))
                    }
                    if mcpManager.claudeStatus == .notFound {
                        Label("Claude Code CLI not found", systemImage: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.remarcWarning(for: colorScheme))
                    }
                }

                Text("Install the missing dependencies and relaunch Remarc to enable MCP.")
                    .font(.system(size: 12))
                    .foregroundStyle(.primary.opacity(0.6))
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(mcpManager.isEnabled
                     ? "Ask your AI agent to review and resolve your comments - no copy-paste needed."
                     : "Connect an AI agent so it can read and act on your comments directly.")
                    .font(.system(size: 12))
                    .foregroundStyle(.primary.opacity(0.6))
                    .fixedSize(horizontal: false, vertical: true)
            }

            if mcpManager.isEnabled {
                HStack(spacing: 8) {
                    Button {
                        let sessionName = persistence.activeSession?.name ?? "Inbox"
                        let prompt = "I left review comments in the '\(sessionName)' session using Remarc. Use remarc_list_sessions to find the session ID, then remarc_list_comments with that session_id to see them, and resolve each one."
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(prompt, forType: .string)
                        showMCPPopover = false
                        ToastManager.shared.show("Prompt copied")
                    } label: {
                        Text("Copy Sample Prompt")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Color.remarcPrimary(for: colorScheme))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .fill(Color.remarcPrimary(for: colorScheme).opacity(colorScheme == .dark ? 0.10 : 0.08))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .strokeBorder(Color.remarcPrimary(for: colorScheme).opacity(colorScheme == .dark ? 0.25 : 0.35), lineWidth: 0.5)
                            )
                    }
                    .buttonStyle(.plain)

                    Spacer(minLength: 0)

                    Button {
                        showMCPPopover = false
                        PreferencesWindowController.shared.show(tab: "MCP Integrations")
                    } label: {
                        Image(systemName: "gearshape")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(mcpSettingsIconHovered ? Color.remarcPrimary(for: colorScheme) : .primary.opacity(0.5))
                            .padding(.vertical, 5)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .onHover { hovering in
                        withAnimation(.easeInOut(duration: 0.15)) {
                            mcpSettingsIconHovered = hovering
                        }
                    }
                    .help("MCP Settings")
                }
            } else {
                Button {
                    showMCPPopover = false
                    PreferencesWindowController.shared.show()
                } label: {
                    Text("Open Preferences")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.remarcPrimary(for: colorScheme))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(Color.remarcPrimary(for: colorScheme).opacity(colorScheme == .dark ? 0.10 : 0.08))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .strokeBorder(Color.remarcPrimary(for: colorScheme).opacity(colorScheme == .dark ? 0.25 : 0.35), lineWidth: 0.5)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(12)
        .frame(width: 240)
    }

    // MARK: - Actions

    // MARK: - Crit Mode

    @ViewBuilder
    private var critModeContent: some View {
        if #available(macOS 26, *) {
            CritModeRecordingView(
                service: CritModeService.shared,
                onCancel: {
                    CritModeService.shared.cancelRecording()
                    withAnimation(.easeInOut(duration: 0.3)) {
                        critModeActive = false
                    }
                    popoverController.preventDismiss = false
                    popoverController.resizeAfterLayoutSettles()
                },
                onComplete: { newComments in
                    withAnimation(.easeInOut(duration: 0.4)) {
                        critModeActive = false
                    }
                    popoverController.preventDismiss = false
                    popoverController.resizeAfterLayoutSettles()
                    // Highlight new comments briefly
                    if let firstID = newComments.first?.id {
                        restoredCommentID = firstID
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                            restoredCommentID = nil
                        }
                    }
                    if newComments.isEmpty {
                        ToastManager.shared.show("No speech detected")
                    } else {
                        ToastManager.shared.show("Added \(newComments.count) comment\(newComments.count == 1 ? "" : "s")")
                    }
                }
            )
        }
    }

    @ViewBuilder
    private var critModeOnboardingContent: some View {
        if #available(macOS 26, *) {
            CritModeOnboardingView(
                onProceed: {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        showCritModeOnboarding = false
                        critModeActive = true
                    }
                    popoverController.preventDismiss = true
                    popoverController.resizeAfterLayoutSettles()
                    Task {
                        do {
                            try await CritModeService.shared.startRecording()
                        } catch {
                            debugLog("PopoverContentView: Failed to start crit mode: \(error)")
                            withAnimation(.easeInOut(duration: 0.3)) {
                                critModeActive = false
                            }
                            popoverController.preventDismiss = false
                            popoverController.resizeAfterLayoutSettles()
                            ToastManager.shared.show("Microphone access required")
                        }
                    }
                },
                onCancel: {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        showCritModeOnboarding = false
                    }
                    popoverController.resizeAfterLayoutSettles()
                }
            )
        }
    }

    private func startCritMode() {
        guard !critModeActive else { return }
        if #available(macOS 26, *) {
            #if canImport(FoundationModels)
            // Crit Mode requires Apple Intelligence for transcript segmentation.
            // Check fresh each time — the user may have just enabled it.
            let modelAvailable = SystemLanguageModel.default.isAvailable
            debugLog("PopoverContentView: SystemLanguageModel.isAvailable = \(modelAvailable)")
            guard modelAvailable else {
                ToastManager.shared.show("Requires Apple Intelligence (restart after enabling)")
                return
            }
            #endif

            if !settings.hasSeenCritModeOnboarding {
                withAnimation(.easeInOut(duration: 0.3)) {
                    showCritModeOnboarding = true
                }
                popoverController.resizeAfterLayoutSettles()
                return
            }

            withAnimation(.easeInOut(duration: 0.3)) {
                critModeActive = true
            }
            popoverController.preventDismiss = true
            popoverController.resizeAfterLayoutSettles()
            Task {
                do {
                    try await CritModeService.shared.startRecording()
                } catch {
                    debugLog("PopoverContentView: Failed to start crit mode: \(error)")
                    withAnimation(.easeInOut(duration: 0.3)) {
                        critModeActive = false
                    }
                    popoverController.preventDismiss = false
                    popoverController.resizeAfterLayoutSettles()
                    ToastManager.shared.show("Microphone access required")
                }
            }
        }
    }

    private func copyAll() {
        guard let session = persistence.activeSession else { return }
        let allComments = persistence.activeComments
        guard let receipt = ExportManager.shared.copySessionToClipboard(
            session,
            comments: allComments,
            format: .markdown
        ) else {
            ToastManager.shared.show("复制失败")
            return
        }
        ToastManager.shared.show("已复制 \(receipt.count) 条评论")
        presentPostExportAction(for: receipt)
    }

    private func presentPostExportAction(for receipt: ExportReceipt) {
        // Invalidate delayed work from any prior receipt before presenting the
        // next action. Each delayed closure also captures this generation.
        clearPromptCancelled = true
        autoClearCancelled = true
        exportClearGeneration = UUID()
        let generation = exportClearGeneration
        pendingExportReceipt = receipt
        showClearPrompt = false
        showAutoClearCountdown = false

        switch settings.clearAfterExportBehavior {
        case .delete:
            showAutoClearCountdown = true
            DispatchQueue.main.async {
                startAutoClear(receipt: receipt, generation: generation)
            }
        case .keep:
            pendingExportReceipt = nil
        case .ask:
            withAnimation(.easeInOut(duration: 0.25)) {
                showClearPrompt = true
            }
            DispatchQueue.main.async {
                startClearPromptDismiss(generation: generation)
            }
        }
    }

    private func exportToFile() {
        guard let session = persistence.activeSession else { return }
        let allComments = persistence.activeComments
        ExportManager.shared.saveSessionToFile(
            session,
            comments: allComments,
            format: SettingsManager.shared.outputFormat
        ) { receipt in
            guard let receipt else { return }
            ToastManager.shared.show("已导出 \(receipt.count) 条评论")
            presentPostExportAction(for: receipt)
        }
    }

    // MARK: - Keyboard Navigation

    private func moveFocus(direction: Int) {
        let list = listModel.visibleComments(showsResolved: showsResolvedSection)
        guard !list.isEmpty else { return }
        if let current = focusedCommentID,
           let idx = list.firstIndex(where: { $0.id == current }) {
            let newIdx = max(0, min(list.count - 1, idx + direction))
            focusedCommentID = list[newIdx].id
        } else {
            focusedCommentID = direction > 0 ? list.first?.id : list.last?.id
        }
        keyboardScrollTarget = focusedCommentID
    }

    // MARK: - Helpers

    private func headerButton(icon: String, action: @escaping () -> Void) -> some View {
        HoverTintButton(
            icon: icon, iconSize: 13, frameSize: 26,
            defaultColor: .primary.opacity(0.6),
            hoverColor: Color.remarcPrimary(for: colorScheme),
            action: action
        )
    }

    private func creationButton(icon: String, action: @escaping () -> Void) -> some View {
        CreationHeaderButton(
            icon: icon,
            brandColor: Color.remarcPrimary(for: colorScheme),
            colorScheme: colorScheme,
            action: action
        )
    }

    private func primaryFooterButton(icon: String, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.remarcPrimary(for: colorScheme))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
        }
        .buttonStyle(FooterButtonStyle(restOpacity: 0.08, hoverOpacity: 0.14))
    }

    private func footerButton(icon: String, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.system(size: 11))
                .foregroundStyle(.primary.opacity(0.5))
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
        }
        .buttonStyle(FooterButtonStyle(restOpacity: 0, hoverOpacity: 0.08))
    }

    private func iconFooterButton(icon: String, action: @escaping () -> Void) -> some View {
        HoverTintButton(
            icon: icon, iconSize: 12, frameSize: 26,
            defaultColor: .primary.opacity(0.5),
            hoverColor: Color.remarcPrimary(for: colorScheme),
            action: action
        )
    }
}

// MARK: - Status Filter Chip

private struct StatusFilterChip: View {
    let title: String
    let count: Int
    let isSelected: Bool
    let colorScheme: ColorScheme
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        let brandColor = Color.remarcPrimary(for: colorScheme)

        Button(action: action) {
            HStack(spacing: 3) {
                Text(title)
                    .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                Text("\(count)")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .opacity(0.7)
            }
            .lineLimit(1)
            .fixedSize()
            .foregroundStyle(isSelected ? brandColor : .primary.opacity(0.55))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(isSelected ? brandColor.opacity(0.12) : Color.primary.opacity(isHovered ? 0.05 : 0))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(.easeInOut(duration: 0.15), value: isHovered)
    }
}

// MARK: - Search Field Arrow Keys

/// Up/Down in the search field move the card selection instead of the caret.
/// Ventura keeps plain text-field behavior; `onKeyPress` is macOS 14+.
private struct SearchFieldArrowKeys: ViewModifier {
    let onMove: (Int) -> Void

    func body(content: Content) -> some View {
        if #available(macOS 14, *) {
            content
                .onKeyPress(.downArrow) {
                    onMove(1)
                    return .handled
                }
                .onKeyPress(.upArrow) {
                    onMove(-1)
                    return .handled
                }
        } else {
            content
        }
    }
}

// MARK: - Hover Tint Button

private struct HoverTintButton: View {
    let icon: String
    let iconSize: CGFloat
    let frameSize: CGFloat
    let defaultColor: Color
    let hoverColor: Color
    let action: () -> Void

    @State private var isHovered = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let fill: Color = colorScheme == .dark
            ? .white.opacity(isHovered ? 0.08 : 0)
            : .white.opacity(isHovered ? 0.65 : 0)
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: iconSize))
                .foregroundStyle(isHovered ? hoverColor : defaultColor)
                .frame(width: frameSize, height: frameSize)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(fill)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(.easeInOut(duration: 0.15), value: isHovered)
    }
}

// MARK: - Footer Button Style

private struct FooterHoverView<Label: View>: View {
    let restOpacity: Double
    let hoverOpacity: Double
    let isPressed: Bool
    let label: Label
    @State private var isHovered = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let fill: Color = colorScheme == .dark
            ? .white.opacity(isHovered ? hoverOpacity : restOpacity)
            : .white.opacity(isHovered ? 0.65 : 0.45)
        label
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(fill)
            )
            .contentShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            .opacity(isPressed ? 0.7 : 1.0)
            .onHover { hovering in
                isHovered = hovering
            }
            .animation(.easeInOut(duration: 0.15), value: isHovered)
    }
}

private struct FooterButtonStyle: ButtonStyle {
    let restOpacity: Double
    let hoverOpacity: Double

    func makeBody(configuration: Configuration) -> some View {
        FooterHoverView(
            restOpacity: restOpacity,
            hoverOpacity: hoverOpacity,
            isPressed: configuration.isPressed,
            label: configuration.label
        )
    }
}

// MARK: - Tertiary Link Button Style

/// Low-emphasis inline text link: tints to the brand color on hover and press,
/// no background fill. Used for secondary "go to settings" style affordances.
private struct TertiaryLinkButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        TertiaryLinkView(isPressed: configuration.isPressed, label: configuration.label)
    }
}

private struct TertiaryLinkView<Label: View>: View {
    let isPressed: Bool
    let label: Label
    @State private var isHovered = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        label
            .foregroundStyle(isHovered || isPressed
                ? Color.remarcPrimary(for: colorScheme)
                : .primary.opacity(0.5))
            .opacity(isPressed ? 0.7 : 1.0)
            .onHover { isHovered = $0 }
            .animation(.easeInOut(duration: 0.15), value: isHovered)
    }
}

// MARK: - Secondary Footer Button Style (outline only)

private struct SecondaryFooterHoverView<Label: View>: View {
    let isPressed: Bool
    let label: Label
    @State private var isHovered = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let hoverFill: Color = colorScheme == .dark
            ? .white.opacity(isHovered ? 0.08 : 0)
            : .white.opacity(isHovered ? 0.55 : 0)
        let borderColor: Color = colorScheme == .dark
            ? .white.opacity(0.12)
            : .black.opacity(0.08)
        label
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(hoverFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(borderColor, lineWidth: 0.5)
            )
            .contentShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            .opacity(isPressed ? 0.7 : 1.0)
            .onHover { isHovered = $0 }
            .animation(.easeInOut(duration: 0.15), value: isHovered)
    }
}

private struct SecondaryFooterButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        SecondaryFooterHoverView(
            isPressed: configuration.isPressed,
            label: configuration.label
        )
    }
}

// MARK: - Scroller Hider

/// Custom NSView that disables the enclosing NSScrollView's scrollers during
/// `viewDidMoveToWindow()` and `layout()` — before the first display pass.
/// This prevents the scroller from reserving width on the initial tile().
struct ScrollerHider: NSViewRepresentable {
    final class ScrollerKillerView: NSView {
        private var didDisable = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            disableEnclosingScroller()
        }

        override func layout() {
            super.layout()
            disableEnclosingScroller()
        }

        private func disableEnclosingScroller() {
            guard !didDisable else { return }
            var current: NSView? = superview
            while let v = current {
                if let scrollView = v as? NSScrollView {
                    scrollView.hasVerticalScroller = false
                    scrollView.hasHorizontalScroller = false
                    scrollView.scrollerStyle = .overlay
                    scrollView.automaticallyAdjustsContentInsets = false
                    scrollView.contentInsets = NSEdgeInsetsZero
                    scrollView.scrollerInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
                    scrollView.verticalScroller?.removeFromSuperview()
                    scrollView.horizontalScroller?.removeFromSuperview()
                    scrollView.tile()
                    didDisable = true
                    return
                }
                current = v.superview
            }
        }
    }

    func makeNSView(context: Context) -> NSView {
        let view = ScrollerKillerView(frame: .zero)
        view.setAccessibilityElement(false)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
