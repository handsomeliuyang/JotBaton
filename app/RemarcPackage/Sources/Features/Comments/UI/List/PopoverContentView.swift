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
    @State private var historyTab: HistoryTab = .comments
    /// Selected status chips, comma-separated; empty shows every status.
    @AppStorage("commentListStatusFilters") private var statusFilterStorage = ""
    @State private var searchHiddenAt: Date?
    @State private var keyboardScrollTarget: UUID?
    @FocusState private var isSearchFieldFocused: Bool

    /// Reopening the panel within this window resumes the previous search.
    private static let searchRetention: TimeInterval = 60

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

        // A search looks across every status; the cards show each one's status.
        let matched = CommentListQuery.sorted(
            scoped.filter { CommentListQuery.matches($0, terms: terms, sessionName: sessionName) },
            newestFirst: sortNewestFirst
        )
        model.comments = CommentListQuery.unresolvedFirst(
            terms.isEmpty ? CommentListQuery.filtered(matched, statuses: statusFilters) : matched
        )
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

            HStack(spacing: 0) {
                SessionSidebarView(statusFilters: statusFilters) {
                    if showingHistory { dismissHistory() }
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
            .frame(minHeight: WorkspaceMetrics.popoverMinHeight)
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
            popoverController.resizeAfterLayoutSettles()
        }
        .onRemarcChange(of: statusFilterStorage) { _ in
            popoverController.resizeAfterLayoutSettles()
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

            creationButtons
        }
        .padding(.leading, 10)
        .padding(.trailing, popoverController.isDetached ? 46 : 14)
        .padding(.vertical, 8)
        .background(searchShortcut)
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

    /// Invisible button that owns ⌘F now that search has no header icon.
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
            isSearching = true
        }
    }

    private func showHistory() {
        withAnimation(.easeInOut(duration: 0.15)) { showingHistory = true }
        popoverController.resizeAfterLayoutSettles()
    }

    // MARK: - History Header

    private func dismissHistory() {
        historySearchText = ""
        isHistorySearching = false
        historyTab = .comments
        withAnimation(.easeInOut(duration: 0.15)) { showingHistory = false }
        popoverController.resizeAfterLayoutSettles()
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
            popoverController.resizeAfterLayoutSettles()
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
                if hasHistoryContent {
                    headerButton(icon: "magnifyingglass") {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            isHistorySearching = true
                        }
                    }
                    .help(L10n.tr("Search history"))

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
        .padding(.vertical, 10)
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

            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(.primary.opacity(0.6))

            TextField(L10n.tr("Search history..."), text: $historySearchText)
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

            TextField(L10n.tr("Search this session"), text: $searchText)
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
            .help(L10n.tr("Close search (Esc)"))

            creationButtons
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .padding(.trailing, popoverController.isDetached ? 32 : 0)
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
        let target = model.comments.first { $0.id == focusedCommentID } ?? model.comments.first
        if let target {
            FloatingEditorController.shared.showForEdit(comment: target)
        }
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

            Text(L10n.tr("Do something Remarcable"))
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
            searchTerms: searchTerms,
            onFocusChange: { focused in
                focusedCommentID = focused ? comment.id : nil
            }
        )
        .overlay(
            RoundedRectangle(cornerRadius: WorkspaceMetrics.cardCornerRadius, style: .continuous)
                .fill(Color.remarcPrimary(for: colorScheme).opacity(restoredCommentID == comment.id ? 0.12 : 0))
                .allowsHitTesting(false)
                .animation(.easeOut(duration: 0.8), value: restoredCommentID)
        )
    }

    // MARK: - Footer

    /// Session-wide actions are off while searching or viewing history.
    private var sessionActionsDisabled: Bool {
        !hasComments || isSearching || showingHistory || persistence.taskCompletionInFlight
    }

    private var footer: some View {
        HStack(spacing: 6) {
            primaryFooterButton(icon: "doc.on.doc", title: L10n.tr("Copy All")) {
                copyAll()
            }
            .help(L10n.tr("Copy all comments in this session"))
            .disabled(sessionActionsDisabled)
            .accessibilityIdentifier("remarc.footer.copyAll")

            primaryFooterButton(icon: "play.fill", title: L10n.tr("Copy and Start"), prominent: true) {
                copyAllAndStartDevelopment()
            }
            .help(L10n.tr("Copy all comments in this session and set pending comments to In Progress; keep comments"))
            .disabled(sessionActionsDisabled)
            .accessibilityIdentifier("remarc.footer.copyAndStart")

            primaryFooterButton(icon: "checkmark.circle", title: L10n.tr("Complete in-progress tasks"),
                                isWorking: persistence.taskCompletionInFlight) {
                completeTasks(scope: .inProgress)
            }
            .help(persistence.taskCompletionInFlight
                  ? L10n.tr("Updating tasks...")
                  : L10n.tr("Mark in-progress tasks as complete (\(inProgressTaskCount))"))
            .disabled(sessionActionsDisabled || inProgressTaskCount == 0)
            .opacity(!persistence.taskCompletionInFlight && (sessionActionsDisabled || inProgressTaskCount == 0) ? 0.4 : 1)
            .accessibilityIdentifier("remarc.footer.completeInProgress")

            mcpButton

            Spacer()

            moreMenu

            SnapshotSyncToolbarButton()

            iconFooterButton(icon: "gearshape") {
                PreferencesWindowController.shared.show()
            }
            .help(L10n.tr("Settings"))
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
            .disabled(sessionActionsDisabled || unresolvedCommentCount == 0)

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
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.remarcIconRest(for: colorScheme))
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .tint(Color.remarcIconRest(for: colorScheme))
        .menuIndicator(.hidden)
        .fixedSize()
        .help(L10n.tr("More"))
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
        let unresolvedCount = unresolvedCommentCount
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

    private var inProgressTaskCount: Int {
        persistence.activeComments.filter { $0.status == .inProgress }.count
    }

    private func completeTasks(scope: CommentCompletionScope) {
        guard !persistence.taskCompletionInFlight,
              let sessionID = persistence.appState.activeSessionID else { return }
        Task { @MainActor in
            await performCompletion(in: sessionID, scope: scope)
        }
    }

    private func performCompletion(in sessionID: UUID, scope: CommentCompletionScope) async {
        switch await persistence.completeComments(in: sessionID, scope: scope) {
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
            return L10n.tr("MCP connected\nAI agents can read your comments")
        }
        if mcpManager.hasDependencyError {
            return L10n.tr("MCP needs attention\nMissing dependencies - click for details")
        }
        return L10n.tr("MCP not connected\nClick to enable")
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
            Label(L10n.tr("MCP"), systemImage: "powerplug")
                .labelStyle(.iconOnly)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.remarcIconRest(for: colorScheme))
                .frame(width: 30, height: 28)
                .overlay(alignment: .topTrailing) {
                    Circle()
                        .fill(mcpStatusColor)
                        .frame(width: 6, height: 6)
                        .shadow(
                            color: mcpManager.isEnabled ? mcpStatusColor.opacity(0.6) : .clear,
                            radius: 3
                        )
                        .offset(x: -2, y: 2)
                        .animation(.easeInOut(duration: 0.2), value: mcpStatusColor)
                }
        }
        .buttonStyle(FooterButtonStyle(restOpacity: 0.08, hoverOpacity: 0.14))
        .help(mcpStatusTooltip)
        .accessibilityValue(mcpStatusTooltip)
        .accessibilityIdentifier("remarc.footer.mcp")
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
                Text(mcpManager.isEnabled ? L10n.tr("Enabled") : (mcpManager.hasDependencyError ? L10n.tr("Missing Dependencies") : L10n.tr("Not Connected")))
                    .font(.system(size: 12, weight: .medium))
            }

            if mcpManager.hasDependencyError {
                VStack(alignment: .leading, spacing: 4) {
                    if mcpManager.nodeStatus == .notFound {
                        Label(L10n.tr("Node.js not found"), systemImage: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.remarcWarning(for: colorScheme))
                    }
                    if mcpManager.claudeStatus == .notFound {
                        Label(L10n.tr("Claude Code CLI not found"), systemImage: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.remarcWarning(for: colorScheme))
                    }
                }

                Text(L10n.tr("Install the missing dependencies and relaunch Remarc to enable MCP."))
                    .font(.system(size: 12))
                    .foregroundStyle(.primary.opacity(0.6))
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(mcpManager.isEnabled
                     ? L10n.tr("Ask your AI agent to review and resolve your comments - no copy-paste needed.")
                     : L10n.tr("Connect an AI agent so it can read and act on your comments directly."))
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
                        ToastManager.shared.show(L10n.tr("Prompt copied"))
                    } label: {
                        Text(L10n.tr("Copy Sample Prompt"))
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
                    .help(L10n.tr("MCP Settings"))
                }
            } else {
                Button {
                    showMCPPopover = false
                    PreferencesWindowController.shared.show()
                } label: {
                    Text(L10n.tr("Open Preferences"))
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

    private func copyAll() {
        guard let session = persistence.activeSession else { return }
        let allComments = persistence.activeComments
        guard let receipt = ExportManager.shared.copySessionToClipboard(
            session,
            comments: allComments,
            format: .markdown
        ) else {
            ToastManager.shared.show(L10n.tr("Couldn’t copy comments"))
            return
        }
        ToastManager.shared.show(L10n.tr("Copied \(receipt.count) comment\(receipt.count == 1 ? "" : "s")"))
        presentPostExportAction(for: receipt)
    }

    private func copyAllAndStartDevelopment() {
        guard let session = persistence.activeSession,
              let receipt = ExportManager.shared.copySessionAndStartDevelopment(
                session, comments: persistence.activeComments
              ) else {
            ToastManager.shared.show(L10n.tr("Copy failed; status unchanged"))
            return
        }
        // A development handoff keeps comments for tracking, including when an
        // earlier ordinary Copy All has a delayed clear action still pending.
        resetPostExportAction()
        ToastManager.shared.show(L10n.tr("Copied \(receipt.count) comment\(receipt.count == 1 ? "" : "s"); pending comments set to In Progress"))
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
                        .font(.system(size: 13, weight: .medium))
                }
            }
            .foregroundStyle(prominent ? Color.white : Color.remarcIconRest(for: colorScheme))
            .frame(width: 30, height: 28)
        }
        .buttonStyle(FooterButtonStyle(restOpacity: 0.08, hoverOpacity: 0.14, prominent: prominent))
        .accessibilityLabel(title)
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
            icon: icon, iconSize: 13, frameSize: 26,
            defaultColor: Color.remarcIconRest(for: colorScheme),
            hoverColor: Color.remarcPrimary(for: colorScheme),
            action: action
        )
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
        case .inProgress: return .inProgress
        case .resolved: return .resolved
        }
    }

    /// Selected segment: a raised neutral tab carrying a faint status tint.
    private func segmentFill(_ statusColor: Color) -> Color {
        colorScheme == .dark ? statusColor.opacity(0.22) : statusColor.opacity(0.14)
    }

    var body: some View {
        let statusColor = CommentStatus.color(for: status, colorScheme: colorScheme)

        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: status.iconName)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(statusColor.opacity(isSelected || count > 0 ? 1 : 0.55))
                Text("\(count)")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(isSelected ? AnyShapeStyle(statusColor) : AnyShapeStyle(.primary.opacity(count > 0 ? 0.7 : 0.35)))
            }
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 8)
            .frame(minWidth: 40, minHeight: 24)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isSelected ? segmentFill(statusColor) : Color.primary.opacity(isHovered ? 0.05 : 0))
                    .shadow(color: .black.opacity(isSelected && colorScheme == .light ? 0.06 : 0), radius: 1, y: 0.5)
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

// MARK: - Footer Button Style

private struct FooterHoverView<Label: View>: View {
    @ObservedObject private var localization = LocalizationManager.shared
    let restOpacity: Double
    let hoverOpacity: Double
    var prominent = false
    let isPressed: Bool
    let label: Label
    @State private var isHovered = false
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        let fill: Color = prominent
            ? Color.remarcButtonBase(for: colorScheme).opacity(isHovered && isEnabled ? 0.88 : 1)
            : colorScheme == .dark
                ? .white.opacity(isHovered ? hoverOpacity : restOpacity * 0.75)
                : .black.opacity(isHovered ? 0.08 : (restOpacity > 0 ? 0.045 : 0))
        label
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(fill)
            )
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .opacity(isPressed ? 0.7 : (prominent && !isEnabled ? 0.4 : 1.0))
            .onHover { hovering in
                isHovered = hovering
            }
            .animation(.easeInOut(duration: 0.15), value: isHovered)
    }
}

private struct FooterButtonStyle: ButtonStyle {
    let restOpacity: Double
    let hoverOpacity: Double
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        FooterHoverView(
            restOpacity: restOpacity,
            hoverOpacity: hoverOpacity,
            prominent: prominent,
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

// MARK: - Secondary Footer Button Style (outline only)

private struct SecondaryFooterHoverView<Label: View>: View {
    @ObservedObject private var localization = LocalizationManager.shared
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
