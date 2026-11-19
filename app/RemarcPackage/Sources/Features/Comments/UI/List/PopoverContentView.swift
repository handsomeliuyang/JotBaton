import CoreLocalization
import CorePlatform
import CoreTheme
import CoreUI
import FeatureComments
import FeatureSettings
import SwiftUI
import AppKit

struct PopoverContentView: View {
    @ObservedObject private var localization = LocalizationManager.shared
    var fillWidth: Bool = false
    /// Pushes the content down (used for the menu bar panel's arrow strip) while the
    /// background gradient keeps filling the full view, so the arrow matches the body color.
    var topInset: CGFloat = 0

    @ObservedObject private var toastManager = ToastManager.shared
    @ObservedObject private var persistence = AppServices.shared.comments
    @ObservedObject private var popoverController = MenuBarPopoverController.shared
    @ObservedObject private var detachedController = DetachedWindowController.shared
    @ObservedObject private var settings = SettingsManager.shared
    @Environment(\.colorScheme) private var colorScheme

    @State private var searchText = ""
    @State private var isSearching = false
    @AppStorage("commentListNewestFirst") private var sortNewestFirst = true
    @State private var focusedCommentID: UUID?
    @State private var showDeleteAllConfirmation = false
    @State private var showResolveAllConfirmation = false
    @State private var showClearPrompt = false
    @State private var clearPromptProgress: CGFloat = 0
    @State private var clearPromptCancelled = false
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
    @State private var historyTab: HistoryTab = .comments
    /// Selected status chips, comma-separated; empty shows every status.
    @AppStorage("commentListStatusFilters") private var statusFilterStorage = ""
    @State private var searchHiddenAt: Date?
    @State private var keyboardScrollTarget: UUID?
    @FocusState private var isSearchFieldFocused: Bool

    /// Reopening the panel within this window resumes the previous search.
    private static let searchRetention: TimeInterval = 60
    /// Keep the content boundary stable when switching header modes.
    private static let headerHeight: CGFloat = 44

    private var statusFilters: Set<CommentStatusFilter> {
        CommentStatusFilter.selection(from: statusFilterStorage)
    }

    private func toggleStatusFilter(_ filter: CommentStatusFilter) {
        var selection = statusFilters
        if selection.contains(filter) {
            selection.remove(filter)
        } else {
            selection.insert(filter)
        }
        statusFilterStorage = CommentStatusFilter.storageValue(of: selection)
    }

    private enum HistoryTab: String {
        case comments, sessions
    }

    // MARK: - Computed Comments

    /// What the card list shows, derived once per render.
    private struct ListModel {
        /// Comments to show, in on-screen order.
        var comments: [Comment] = []
        var counts: [CommentStatusFilter: Int] = [:]
        var scopeIsEmpty = true
    }

    private var searchTerms: [String] {
        isSearching ? CommentListQuery.searchTerms(from: searchText) : []
    }

    private var listModel: ListModel {
        let terms = searchTerms
        let scoped = persistence.activeComments
        let sessionName = persistence.activeSession?.name

        var model = ListModel()
        model.scopeIsEmpty = scoped.isEmpty
        model.counts = CommentListQuery.counts(of: scoped)

        model.comments = CommentListQuery.visibleComments(
            in: scoped, statuses: statusFilters, terms: terms,
            sessionName: sessionName, newestFirst: sortNewestFirst
        )
        return model
    }

    private var hasComments: Bool {
        !persistence.activeComments.isEmpty
    }

    /// Match the displayed IDs while preserving the existing chronological export order.
    private var visibleActionComments: [Comment] {
        let visibleIDs = Set(listModel.comments.map(\.id))
        return persistence.activeComments.filter { visibleIDs.contains($0.id) }
    }

    // MARK: - Body

    var body: some View {
        ZStack(alignment: .top) {
            // Gradient fills the full panel area supplied by the hosting view.
            // ignoresSafeArea lets it extend behind the titlebar in detached mode.
            Color.remarcBackgroundGradient(for: colorScheme)
                .ignoresSafeArea()

            HStack(spacing: 0) {
                // Navigation fills the height chosen by the comment pane;
                // its session count must not increase the panel's ideal size.
                Color.clear
                    .frame(width: WorkspaceMetrics.sessionSidebarWidth)
                    .overlay {
                        SessionSidebarView(statusFilters: statusFilters) {
                            if showingHistory { dismissHistory() }
                        }
                    }

                Rectangle()
                    .fill(Color.remarcHairline(for: colorScheme))
                    .frame(width: WorkspaceMetrics.paneDividerWidth)

                commentPane
                    .frame(minWidth: WorkspaceMetrics.commentPaneWidth,
                           maxWidth: fillWidth ? .infinity : WorkspaceMetrics.commentPaneWidth)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("remarc.comments.pane")
            }
            .frame(minHeight: fillWidth ? WorkspaceMetrics.popoverMinHeight : nil)
            .padding(.top, topInset)
        }
        .frame(width: fillWidth ? nil : WorkspaceMetrics.popoverWidth)
        .frame(minWidth: fillWidth ? WorkspaceMetrics.popoverWidth : nil,
               maxWidth: fillWidth ? .infinity : nil)
        .overlay(alignment: .topTrailing) {
            if popoverController.isDetached {
                headerButton(icon: detachedController.isPinned ? "pin.fill" : "pin") {
                    detachedController.togglePin()
                }
                .help(detachedController.isPinned ? L10n.tr("Unpin window") : L10n.tr("Pin window"))
                .padding(.top, 4 + topInset)
                .padding(.trailing, 10)
                .ignoresSafeArea()
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if let toast = toastManager.currentToast {
                ToastOverlay(toast: toast)
                    .frame(width: WorkspaceMetrics.commentPaneWidth)
                    .padding(.bottom, 52)
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
            }
        }
        .onRemarcChange(of: persistence.appState.activeSessionID) { _ in
            focusedCommentID = nil
            keyboardScrollTarget = nil
        }
    }

    /// All comment/history controls keep the original pane width; session
    /// navigation takes its own additional space on the leading side.
    private var commentPane: some View {
        VStack(spacing: 0) {
            if showingHistory {
                if isHistorySearching {
                    historySearchHeader
                } else {
                    historyHeader
                }
                Divider()
                if historyTab == .sessions {
                    SessionHistoryView(showingHistory: $showingHistory, searchText: $historySearchText, sortNewestFirst: $historySortNewestFirst)
                } else {
                    CommentHistoryView(showingHistory: $showingHistory, restoredCommentID: $restoredCommentID, searchText: $historySearchText, sortNewestFirst: $historySortNewestFirst)
                }
            } else {
                let model = listModel
                if isSearching {
                    searchHeader(model: model)
                } else {
                    normalHeader(counts: model.counts)
                }
                Divider()
                CloudSyncBanner()

                if model.scopeIsEmpty && !isSearching {
                    emptyState
                } else {
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
            Divider()
            footer
        }
        .background(searchShortcut)
    }

    // MARK: - Normal Header

    private func normalHeader(counts: [CommentStatusFilter: Int]) -> some View {
        HStack(spacing: 8) {
            HStack(spacing: 2) {
                ForEach(CommentStatusFilter.allCases, id: \.self) { filter in
                    StatusFilterChip(
                        filter: filter,
                        count: counts[filter] ?? 0,
                        isSelected: statusFilters.contains(filter),
                        colorScheme: colorScheme
                    ) {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            toggleStatusFilter(filter)
                        }
                    }
                    .help(L10n.tr("\(filter.title): \(filter.help). Click to toggle; with none selected, every status shows."))
                }
            }
            .padding(2)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.remarcNeutralFill(for: colorScheme))
            )

            Spacer(minLength: 0)

            headerButton(icon: "magnifyingglass", action: startSearch)
                .help(L10n.tr("Search this session") + " (⌘F)")
                .accessibilityLabel(L10n.tr("Search this session"))
                .accessibilityIdentifier("remarc.comments.search.open")

            creationButtons
        }
        .padding(.leading, 10)
        .padding(.trailing, popoverController.isDetached ? 46 : 14)
        .frame(height: Self.headerHeight)
    }

    @ViewBuilder
    private var creationButtons: some View {
        creationButton(icon: RemarcSymbols.quickNote) {
            FloatingEditorController.shared.showForQuickNote()
        }
        .help(L10n.tr("New quick note"))

        creationButton(icon: "camera.viewfinder") {
            MenuBarPopoverController.shared.dismiss()
            AppServices.shared.capture.startCapture(
                onRegionSelected: { captureRect, sourceBundleID in
                    CommentInputController.shared.showForScreenshot(captureRect: captureRect, sourceBundleID: sourceBundleID)
                },
                onCancel: {
                    debugLog("PopoverHeader: screenshot capture cancelled")
                }
            )
        }
        .help(L10n.tr("Screenshot comment"))

    }

    /// Keep ⌘F available in every header, including History and active searches.
    private var searchShortcut: some View {
        Button(action: startSearch) { EmptyView() }
            .keyboardShortcut("f", modifiers: .command)
            .buttonStyle(.plain)
            .frame(width: 0, height: 0)
            .opacity(0)
            .accessibilityHidden(true)
    }

    private func startSearch() {
        withAnimation(.easeInOut(duration: 0.15)) {
            if showingHistory {
                isHistorySearching = true
            } else {
                isSearching = true
            }
        }
        focusSearchField()
    }

    private func showHistory() {
        withAnimation(.easeInOut(duration: 0.15)) { showingHistory = true }
    }

    // MARK: - History Header

    private func dismissHistory() {
        historySearchText = ""
        isHistorySearching = false
        historyTab = .comments
        withAnimation(.easeInOut(duration: 0.15)) { showingHistory = false }
    }

    private var historyTabPicker: some View {
        HStack(spacing: 0) {
            historyTabButton(L10n.tr("Comments"), tab: .comments)
            historyTabButton(L10n.tr("Sessions"), tab: .sessions)
        }
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.primary.opacity(colorScheme == .dark ? 0.08 : 0.06))
        )
    }

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
        .accessibilityIdentifier("remarc.history.\(tab.rawValue)")
    }

    private var historyHeader: some View {
        ZStack {
            historyTabPicker

            // Left: back button
            HStack {
                headerButton(icon: "chevron.left") {
                    dismissHistory()
                }
                .help(L10n.tr("Back to comments"))
                Spacer()
            }

            // Right: search + sort
            HStack {
                Spacer()
                headerButton(icon: "magnifyingglass", action: startSearch)
                    .help(L10n.tr("Search history") + " (⌘F)")
                    .accessibilityLabel(L10n.tr("Search history"))
                    .accessibilityIdentifier("remarc.history.search.open")

                if hasHistoryContent {
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
                    .help(historySortNewestFirst ? L10n.tr("Sort oldest first") : L10n.tr("Sort newest first"))
                }
            }
        }
        .padding(.horizontal, 14)
        .frame(height: Self.headerHeight)
        .padding(.trailing, popoverController.isDetached ? 32 : 0)
    }

    private var hasHistoryContent: Bool {
        if historyTab == .sessions { return !persistence.deletedSessions.isEmpty }
        return !persistence.deletedComments.isEmpty
    }

    private var historySearchHeader: some View {
        HStack(spacing: 8) {
            headerButton(icon: "chevron.left") {
                dismissHistory()
            }
            .help(L10n.tr("Back to comments"))

            contentSearchControls(
                text: $historySearchText,
                prompt: historyTab == .comments ? L10n.tr("Search history comments") : L10n.tr("Search history sessions"),
                onClose: closeHistorySearch
            )
        }
        .padding(.horizontal, 14)
        .frame(height: Self.headerHeight)
        .padding(.trailing, popoverController.isDetached ? 32 : 0)
    }

    private func closeHistorySearch() {
        historySearchText = ""
        withAnimation(.easeInOut(duration: 0.15)) {
            isHistorySearching = false
        }
    }

    // MARK: - Search Header

    private func searchHeader(model: ListModel) -> some View {
        HStack(spacing: 8) {
            contentSearchControls(
                text: $searchText,
                prompt: L10n.tr("Search this session"),
                onClose: closeSearch,
                onSubmit: { openSelectedComment(in: model) }
            )
                .modifier(SearchFieldArrowKeys(onMove: moveFocus(direction:)))

            creationButtons
        }
        .padding(.horizontal, 14)
        .frame(height: Self.headerHeight)
        .padding(.trailing, popoverController.isDetached ? 32 : 0)
    }

    private func contentSearchControls(
        text: Binding<String>, prompt: String,
        onClose: @escaping () -> Void, onSubmit: @escaping () -> Void = {}
    ) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(.primary.opacity(0.6))

            TextField(prompt, text: text)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($isSearchFieldFocused)
                .onSubmit(onSubmit)
                .onExitCommand(perform: onClose)
                .accessibilityLabel(prompt)
                .accessibilityIdentifier("remarc.content.search")

            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(.primary.opacity(0.6))
            }
            .buttonStyle(.plain)
            .help(L10n.tr("Close search (Esc)"))
            .accessibilityLabel(L10n.tr("Close search (Esc)"))
            .accessibilityIdentifier("remarc.content.search.close")
        }
        .onAppear(perform: focusSearchField)
    }

    private func focusSearchField() {
        // The field editor needs a key window in the non-activating panel.
        MenuBarPopoverController.shared.makeKey()
        DispatchQueue.main.async {
            isSearchFieldFocused = true
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
        let target = model.comments.first { $0.id == focusedCommentID } ?? model.comments.first
        if let target {
            FloatingEditorController.shared.showForEdit(comment: target)
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 16) {
            RemarcBrandMark(size: 56)

            Text(L10n.tr("Capture an idea. Hand it to AI."))
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
                    ForEach(model.comments) { comment in
                        commentCard(for: comment)
                    }
                    cardListFooter(model)
                }
                .padding(.horizontal, 10)
                .padding(.top, 6)
                .padding(.bottom, 8)
                // Attach inside the document so the bridge finds this exact
                // scroll view, including when the pointer is over a thumbnail.
                .background(MouseWheelScrolling(commentIDs: model.comments.map(\.id)))
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

    @ViewBuilder
    private func cardListFooter(_ model: ListModel) -> some View {
        if model.comments.isEmpty {
            filteredEmptyState
        }
    }

    private var filteredEmptyState: some View {
        Text(emptyFilterMessage)
            .font(.system(size: 12))
            .foregroundStyle(.primary.opacity(0.45))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 20)
    }

    private var emptyFilterMessage: String {
        let selection = statusFilters
        if searchTerms.isEmpty, selection.count == 1, let only = selection.first {
            return only.emptyStateTitle
        }
        return L10n.tr("No matching comments")
    }

    private func commentCard(for comment: Comment) -> some View {
        CommentCardView(
            comment: comment,
            isFocused: focusedCommentID == comment.id,
            searchTerms: searchTerms
        )
        .overlay(
            RoundedRectangle(cornerRadius: WorkspaceMetrics.cardCornerRadius, style: .continuous)
                .fill(Color.remarcPrimary(for: colorScheme).opacity(restoredCommentID == comment.id ? 0.12 : 0))
                .allowsHitTesting(false)
                .animation(.easeOut(duration: 0.8), value: restoredCommentID)
        )
        .overlay(alignment: .topTrailing) {
            SyncConflictBadge(commentID: comment.id)
                .offset(x: 5, y: -5)
        }
    }

    // MARK: - Footer

    /// Session-wide actions are off while searching or viewing history.
    private var sessionActionsDisabled: Bool {
        !hasComments || isSearching || showingHistory || persistence.taskCompletionInFlight
    }

    private var footer: some View {
        let comments = visibleActionComments
        let visibleActionsDisabled = sessionActionsDisabled || comments.isEmpty
        let inProgressTaskCount = comments.filter { $0.status == .inProgress }.count
        return HStack(spacing: 6) {
            primaryFooterButton(icon: "doc.on.doc", title: L10n.tr("Copy All")) {
                copyAll()
            }
            .help(L10n.tr("Copy all visible comments"))
            .disabled(visibleActionsDisabled)
            .accessibilityIdentifier("remarc.footer.copyAll")

            primaryFooterButton(icon: "play.fill", title: L10n.tr("Copy and Start"), prominent: true) {
                copyAllAndStartDevelopment()
            }
            .help(L10n.tr("Copy visible Open, Reusable and In Progress comments; set Open to In Progress and keep comments"))
            .disabled(visibleActionsDisabled || !comments.contains { $0.status.canStartDevelopment })
            .accessibilityIdentifier("remarc.footer.copyAndStart")

            primaryFooterButton(icon: "checkmark.circle", title: L10n.tr("Complete in-progress tasks"),
                                isWorking: persistence.taskCompletionInFlight) {
                let ids = Set(visibleActionComments.filter { $0.status == .inProgress }.map(\.id))
                completeTasks(scope: .inProgress, commentIDs: ids)
            }
            .help(persistence.taskCompletionInFlight
                  ? L10n.tr("Updating tasks...")
                  : L10n.tr("Complete visible in-progress tasks (\(inProgressTaskCount))"))
            .disabled(visibleActionsDisabled || inProgressTaskCount == 0)
            .accessibilityIdentifier("remarc.footer.completeInProgress")

            Spacer()

            moreMenu

            CloudSyncToolbarButton()

            iconFooterButton(icon: "gearshape") {
                PreferencesWindowController.shared.show()
            }
            .help(L10n.tr("Settings"))
            .accessibilityLabel(L10n.tr("Settings"))
            .accessibilityIdentifier("remarc.footer.settings")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.remarcSidebarSurface(for: colorScheme))
    }

    /// Search, history, sorting and the active session's bulk actions, grouped
    /// so the header can hold the status filters.
    private var moreMenu: some View {
        Menu {
            Button(action: startSearch) {
                Label(L10n.tr("Search\u{2026}  \u{2318}F"), systemImage: "magnifyingglass")
            }
            Button(action: showHistory) {
                Label(L10n.tr("History"), systemImage: RemarcSymbols.history)
            }
            .accessibilityIdentifier("remarc.history.open")
            Toggle(L10n.tr("Newest First"), isOn: $sortNewestFirst)

            Divider()

            Button {
                showResolveAllConfirmation = true
            } label: {
                Label(L10n.tr("Resolve All"), systemImage: "checkmark.bubble")
            }
            .disabled(sessionActionsDisabled || batchCompletableCommentCount == 0)

            Button {
                exportToFile()
            } label: {
                Label(L10n.tr("Export to File\u{2026}"), systemImage: "arrow.down.doc")
            }
            .disabled(sessionActionsDisabled)

            Button(role: .destructive) {
                showDeleteAllConfirmation = true
            } label: {
                Label(L10n.tr("Delete All"), systemImage: "trash")
            }
            .disabled(sessionActionsDisabled)
        } label: {
            Image(systemName: "ellipsis")
        }
        .menuStyle(.button)
        .buttonStyle(RemarcToolbarButtonStyle())
        .menuIndicator(.hidden)
        .fixedSize()
        .help(L10n.tr("More"))
        .accessibilityLabel(L10n.tr("More"))
        .accessibilityIdentifier("remarc.footer.more")
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
                Text(L10n.tr("Clear exported comments?"))
                    .font(.system(size: 11))
                Spacer()
                ConfirmationButton(label: L10n.tr("Keep"), role: .cancel) {
                    dismissClearPrompt()
                }
                ConfirmationButton(label: L10n.tr("Clear"), role: .destructive) {
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
                                ToastManager.shared.show(L10n.tr("Couldn’t clear exported comments"))
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
                        Text(L10n.tr("Adjust copy all behavior in settings"))
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
            Text(L10n.tr("Clearing \(count) comment\(count == 1 ? "" : "s")..."))
                .font(.system(size: 11))
            Spacer()
            Button(L10n.tr("Undo")) {
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
                    ToastManager.shared.show(L10n.tr("Cleared \(clearedIDs.count) comment\(clearedIDs.count == 1 ? "" : "s")"))
                case .failure:
                    ToastManager.shared.show(L10n.tr("Couldn’t clear exported comments"))
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
            Text(L10n.tr("Delete all comments in \(sessionName)?"))
                .font(.system(size: 12, weight: .medium))
            HStack(spacing: 8) {
                ConfirmationButton(label: L10n.tr("Cancel"), role: .cancel) {
                    showDeleteAllConfirmation = false
                }
                ConfirmationButton(label: L10n.tr("Delete All"), role: .destructive) {
                    if let sessionID = persistence.appState.activeSessionID {
                        let clearedIDs = persistence.clearAllComments(in: sessionID)
                        showDeleteAllConfirmation = false
                        ToastManager.shared.show(L10n.tr("All comments deleted"), undo: {
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
        let unresolvedCount = batchCompletableCommentCount
        return VStack(spacing: 8) {
            Text(L10n.tr("Resolve all \(unresolvedCount) comments in \(sessionName)?"))
                .font(.system(size: 12, weight: .medium))
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                ConfirmationButton(label: L10n.tr("Cancel"), role: .cancel) {
                    showResolveAllConfirmation = false
                }
                ConfirmationButton(label: L10n.tr("Resolve All"), role: .confirm) {
                    showResolveAllConfirmation = false
                    completeTasks(scope: .allUnresolved)
                }
            }
        }
        .frame(maxWidth: 200)
        .padding(12)
    }

    private func completeTasks(scope: CommentCompletionScope, commentIDs: Set<UUID>? = nil) {
        guard !persistence.taskCompletionInFlight,
              let sessionID = persistence.appState.activeSessionID else { return }
        Task { @MainActor in
            await performCompletion(in: sessionID, scope: scope, commentIDs: commentIDs)
        }
    }

    private func performCompletion(in sessionID: UUID, scope: CommentCompletionScope, commentIDs: Set<UUID>?) async {
        switch await persistence.completeComments(in: sessionID, scope: scope, commentIDs: commentIDs) {
        case .failure(let error):
            ToastManager.shared.show(error.userMessage)
        case .success(let receipt):
            guard receipt.count > 0 else {
                ToastManager.shared.show(L10n.tr("No in-progress comments"))
                return
            }
            resetPostExportAction()
            ToastManager.shared.show(
                L10n.tr("Completed \(receipt.count) task\(receipt.count == 1 ? "" : "s")"),
                undo: {
                    Task { @MainActor in
                        switch await persistence.undoCompletion(receipt) {
                        case .failure(let error): ToastManager.shared.show(error.userMessage)
                        case .success(let count):
                            if count == 0 {
                                ToastManager.shared.show(L10n.tr("Tasks or their session changed; nothing was undone"))
                            } else {
                                ToastManager.shared.show(L10n.tr("Undid completion for \(count) task\(count == 1 ? "" : "s")"))
                            }
                        }
                    }
                },
                duration: 5
            )
        }
    }

    private var batchCompletableCommentCount: Int {
        guard let sessionID = persistence.appState.activeSessionID else { return 0 }
        return persistence.comments(for: sessionID).filter { CommentCompletionScope.allUnresolved.includes($0.status) }.count
    }

    // MARK: - Actions

    private func copyAll() {
        guard let session = persistence.activeSession else { return }
        let comments = visibleActionComments
        guard !comments.isEmpty else { return }
        guard let receipt = ExportManager.shared.copySessionToClipboard(
            session,
            comments: comments,
            format: .markdown
        ) else {
            ToastManager.shared.show(L10n.tr("Couldn’t copy comments"))
            return
        }
        ToastManager.shared.show(L10n.tr("Copied \(receipt.count) comment\(receipt.count == 1 ? "" : "s")"))
        presentPostExportAction(for: receipt)
    }

    private func copyAllAndStartDevelopment() {
        let comments = visibleActionComments
        let hasPendingComments = comments.contains { $0.status == .open }
        guard let session = persistence.activeSession,
              let receipt = ExportManager.shared.copySessionAndStartDevelopment(
                session, comments: comments
              ) else {
            ToastManager.shared.show(L10n.tr("Copy failed; status unchanged"))
            return
        }
        // A development handoff keeps comments for tracking, including when an
        // earlier ordinary Copy All has a delayed clear action still pending.
        resetPostExportAction()
        ToastManager.shared.show(hasPendingComments
            ? L10n.tr("Copied \(receipt.count) comment\(receipt.count == 1 ? "" : "s"); pending comments set to In Progress")
            : L10n.tr("Copied \(receipt.count) comment\(receipt.count == 1 ? "" : "s")"))
    }

    private func resetPostExportAction() {
        clearPromptCancelled = true
        autoClearCancelled = true
        exportClearGeneration = UUID()
        pendingExportReceipt = nil
        showClearPrompt = false
        showAutoClearCountdown = false
    }

    private func presentPostExportAction(for receipt: ExportReceipt) {
        // Invalidate delayed work from any prior receipt before presenting the
        // next action. Each delayed closure also captures this generation.
        resetPostExportAction()
        let generation = exportClearGeneration
        guard !receipt.clearableCommentIDs(in: persistence.activeComments).isEmpty else { return }
        pendingExportReceipt = receipt

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
            ToastManager.shared.show(L10n.tr("Exported \(receipt.count) comment\(receipt.count == 1 ? "" : "s")"))
            presentPostExportAction(for: receipt)
        }
    }

    // MARK: - Keyboard Navigation

    private func moveFocus(direction: Int) {
        let list = listModel.comments
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

    /// Session actions share one neutral look; the single `prominent` action
    /// carries the brand fill so the footer has an obvious next step.
    private func primaryFooterButton(icon: String, title: String, isWorking: Bool = false,
                                     prominent: Bool = false,
                                     action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Group {
                if isWorking {
                    ProgressView().controlSize(.small)
                } else {
                    Label(title, systemImage: icon)
                        .labelStyle(.iconOnly)
                }
            }
        }
        .buttonStyle(RemarcToolbarButtonStyle(prominent: prominent, isWorking: isWorking))
        .accessibilityLabel(title)
    }

    private func iconFooterButton(icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
        }
        .buttonStyle(RemarcToolbarButtonStyle())
    }
}

// MARK: - Status Filter Chip

private struct StatusFilterChip: View {
    @ObservedObject private var localization = LocalizationManager.shared
    let filter: CommentStatusFilter
    let count: Int
    let isSelected: Bool
    let colorScheme: ColorScheme
    let action: () -> Void

    @State private var isHovered = false

    private var status: CommentStatus {
        switch filter {
        case .open: return .open
        case .reusable: return .reusable
        case .inProgress: return .inProgress
        case .deferred: return .deferred
        }
    }

    private var selectedFill: Color {
        switch filter {
        case .open: return Color.remarcButtonBase(for: colorScheme)
        case .reusable: return Color.remarcInfoButtonFill(for: colorScheme)
        case .inProgress: return Color.remarcWarningButtonFill(for: colorScheme)
        case .deferred: return Color.remarcDeferredButtonFill(for: colorScheme)
        }
    }

    var body: some View {
        let statusColor = CommentStatus.color(for: status, colorScheme: colorScheme)

        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: status.iconName)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(isSelected ? Color.white : statusColor)
                Text("\(count)")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(isSelected ? Color.white : Color.remarcIconRest(for: colorScheme))
            }
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 8)
            .frame(minWidth: 40, minHeight: 24)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isSelected ? selectedFill : (isHovered ? Color.remarcNeutralFill(for: colorScheme) : Color.clear))
                    .overlay {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.white.opacity(isSelected && isHovered ? 0.04 : 0))
                    }
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(L10n.tr("\(filter.title), \(count) comments")))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .onHover { isHovered = $0 }
        .animation(.easeInOut(duration: 0.15), value: isHovered)
        .animation(.easeInOut(duration: 0.15), value: isSelected)
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
    @ObservedObject private var localization = LocalizationManager.shared
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
            : .black.opacity(isHovered ? 0.06 : 0)
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

// MARK: - Tertiary Link Button Style

/// Low-emphasis inline text link: tints to the brand color on hover and press,
/// no background fill. Used for secondary "go to settings" style affordances.
private struct TertiaryLinkButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        TertiaryLinkView(isPressed: configuration.isPressed, label: configuration.label)
    }
}

private struct TertiaryLinkView<Label: View>: View {
    @ObservedObject private var localization = LocalizationManager.shared
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

// MARK: - Scroller Hider

/// Custom NSView that disables the enclosing NSScrollView's scrollers during
/// `viewDidMoveToWindow()` and `layout()` — before the first display pass.
/// This prevents the scroller from reserving width on the initial tile().
/// Hiding indicators must preserve native momentum and vertical edge bounce.
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
                    scrollView.verticalScrollElasticity = .allowed
                    scrollView.horizontalScrollElasticity = .none
                    scrollView.usesPredominantAxisScrolling = true
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
