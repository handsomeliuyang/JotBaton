import AppKit
import SwiftUI

struct SnapshotSyncView: View {
    @ObservedObject private var localization = LocalizationManager.shared
    @ObservedObject private var sync = SnapshotSyncManager.shared
    @Environment(\.colorScheme) private var colorScheme
    @State private var versionToApply: SnapshotVersion?
    @State private var applyingBackup = false
    @State private var confirmEnable = false
    @State private var reviewToken = UUID()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 6) {
                    Label(L10n.tr("iCloud Sync"), systemImage: "icloud").font(.system(size: 19, weight: .semibold))
                    Text(L10n.tr("Publish and apply directly from the task panel. This page keeps your setup, history, and recovery backups."))
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                GroupBox {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack {
                            Text(L10n.tr("This Mac")).fontWeight(.medium)
                            Spacer()
                            TextField(L10n.tr("e.g. Office Mac"), text: $sync.deviceName)
                                .textFieldStyle(.roundedBorder).frame(maxWidth: 260)
                                .accessibilityIdentifier("sync.deviceName")
                        }
                        Toggle(L10n.tr("iCloud snapshots"), isOn: Binding(
                            get: { sync.isEnabled },
                            set: { if $0 { confirmEnable = true } else { sync.disconnect() } }
                        )).toggleStyle(.switch).accessibilityIdentifier("sync.enable")
                        HStack {
                            Text(L10n.tr("Storage location")).fontWeight(.medium)
                            Spacer()
                            Text("\(AppIdentity.current.cloudDisplayPath)").foregroundStyle(.secondary)
                        }
                        HStack {
                            Text(L10n.tr("Directory access")).fontWeight(.medium)
                            Spacer()
                            Text(!sync.isEnabled ? L10n.tr("Not enabled") : sync.folder != nil ? L10n.tr("Accessible") : L10n.tr("Not verified"))
                                .foregroundStyle(.secondary)
                                .accessibilityIdentifier("sync.connection")
                        }
                        Text(L10n.tr("Directory access does not confirm a cloud upload. Upload status is shown separately below."))
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                        if let folder = sync.folder {
                            Button(L10n.tr("Show in Finder")) { NSWorkspace.shared.open(folder) }.font(.system(size: 11))
                        }
                    }.padding(10)
                }.disabled(sync.isBusy)

                GroupBox {
                    SnapshotSyncControls(compact: false).padding(10)
                }

                if sync.isEnabled && sync.folder != nil {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(L10n.tr("iCloud versions discovered on this Mac")).font(.system(size: 14, weight: .semibold))
                        Text(L10n.tr("A version appearing here is not proof that its archive has finished uploading. Applying downloads and verifies the complete archive."))
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                        if sync.versions.isEmpty {
                            Text(L10n.tr("No versions discovered yet. Publish from your first Mac, then check on your other Mac."))
                                .font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                        ForEach(sync.versions) { version in
                            HStack(alignment: .top) {
                                VStack(alignment: .leading, spacing: 4) {
                                    SnapshotVersionLabel(version: version)
                                    Text(L10n.tr("\(version.commentCount) tasks · \(version.imageCount) images"))
                                        .font(.system(size: 11)).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if sync.currentVersion?.id == version.id && !sync.hasLocalChanges {
                                    Label(L10n.tr("Current"), systemImage: "checkmark.circle")
                                        .font(.system(size: 11)).foregroundStyle(.secondary)
                                } else {
                                    Button(L10n.tr("Use This Version")) { applyingBackup = false; versionToApply = version }
                                        .accessibilityIdentifier("sync.apply.\(version.shortID)")
                                }
                            }.padding(12)
                                .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
                        }
                    }.disabled(sync.isBusy)
                }
                if !sync.backups.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(L10n.tr("Local recovery backups")).font(.system(size: 14, weight: .semibold))
                        Text(L10n.tr("A complete local backup is saved before every replacement. Restoring also backs up the current data."))
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                        ForEach(sync.backups) { version in
                            HStack {
                                SnapshotVersionLabel(version: version)
                                Spacer()
                                Button(L10n.tr("Restore…")) { applyingBackup = true; versionToApply = version }
                            }
                        }
                        Button(L10n.tr("Show Backups in Finder")) {
                            NSWorkspace.shared.open(remarcAppSupportURL.appendingPathComponent("snapshot-backups"))
                        }.font(.system(size: 11))
                    }.disabled(sync.isBusy)
                }
            }.padding(28)
        }
        .task { await sync.checkIfNeeded() }
        .onRemarcChange(of: versionToApply != nil || confirmEnable) { active in sync.holdAutomaticChecks(active, token: reviewToken) }
        .onDisappear { sync.holdAutomaticChecks(false, token: reviewToken) }
        .alert(L10n.tr("Replace local tasks?"), isPresented: Binding(get: { versionToApply != nil }, set: { if !$0 { versionToApply = nil } })) {
            Button(L10n.tr("Cancel"), role: .cancel) { versionToApply = nil }
            Button(L10n.tr("Back Up and Apply"), role: .destructive) {
                if let version = versionToApply {
                    let backup = applyingBackup
                    Task { await sync.apply(version, isBackup: backup) }
                }
                versionToApply = nil
            }.disabled(sync.isBusy)
        } message: {
            if let version = versionToApply { Text(SnapshotVersionLabel.replacementMessage(version)) }
        }
        .alert(L10n.tr("Enable iCloud snapshots?"), isPresented: $confirmEnable) {
            Button(L10n.tr("Cancel"), role: .cancel) {}
            Button(L10n.tr("Enable iCloud Snapshots")) { Task { await sync.enable() } }
        } message: { Text(L10n.tr("Remarc will create or reuse \(AppIdentity.current.cloudDisplayPath). Publishing and applying stay manual.")) }
    }
}

struct SnapshotVersionLabel: View {
    @ObservedObject private var localization = LocalizationManager.shared
    let version: SnapshotVersion
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(version.deviceName).font(.system(size: 12, weight: .medium))
            Text(version.contentModifiedAt.map { L10n.tr("Content: \($0.interfaceFormatted(date: .abbreviated, time: .standard))") } ?? L10n.tr("Content time not recorded"))
            Text(L10n.tr("Saved: \(version.createdAt.interfaceFormatted(date: .abbreviated, time: .standard))"))
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .fixedSize(horizontal: false, vertical: true)
    }
    static func replacementMessage(_ version: SnapshotVersion) -> String {
        L10n.tr("Use the data from \(version.deviceName)? Content time: \(version.contentModifiedAt.map { $0.interfaceFormatted(date: .abbreviated, time: .standard) } ?? L10n.tr("Not recorded")). This replaces all local tasks, including additions and deletions. Your current data will be backed up first.")
    }
}

/// Both surfaces render this same state and invoke the same operations.
/// Publishing/checking/recovery never navigates to Settings implicitly.
struct SnapshotSyncControls: View {
    @ObservedObject private var localization = LocalizationManager.shared
    let compact: Bool
    var onExpansionChanged: (Bool) -> Void = { _ in }
    @ObservedObject private var sync = SnapshotSyncManager.shared
    @Environment(\.colorScheme) private var colorScheme
    @State private var choosing = false
    @State private var versionToApply: SnapshotVersion?
    @State private var confirmPublish = false
    @State private var confirmEnable = false
    @State private var detailsExpanded = false
    @State private var reviewToken = UUID()

    @State private var showingDetails = false

    private var cards: SnapshotSyncCardPresentation {
        SnapshotSyncCardPresentation.make(enabled: sync.isEnabled, directoryReady: sync.folder != nil,
            busy: sync.isBusy, transfer: sync.cloudTransfer, comparison: sync.comparison,
            publication: sync.publication, issue: sync.issue, presentation: sync.presentation,
            cloudCount: sync.cloudHeads.count)
    }

    private var cloudRecovery: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()
            if let issue = sync.issue, sync.isEnabled {
                Text(L10n.lookup(issue.message)).font(.system(size: compact ? 11 : 12, weight: .medium))
                Text(issue.recovery).font(.system(size: compact ? 10 : 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if sync.cloudTransfer == .failed {
                Text(L10n.tr("iCloud transfer could not be confirmed. Check again or open iCloud settings."))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            if sync.isEnabled && (sync.issue != nil || sync.publication?.isPending == true || sync.cloudTransfer == .failed) {
                HStack(spacing: 8) {
                    iconAction(L10n.tr("Retry the pending operation"), symbol: "arrow.clockwise") { Task { await sync.retry() } }
                    if sync.issue?.needsAuthorization == true {
                        iconAction(L10n.tr("Authorize iCloud Drive access"), symbol: "folder.badge.plus") { Task { await sync.authorizeAccess() } }
                    }
                    if sync.issue?.needsICloudSettings == true || sync.cloudTransfer == .failed {
                        iconAction(L10n.tr("Open iCloud settings"), symbol: "gearshape") { sync.openICloudSettings() }
                    }
                }.disabled(sync.isBusy)
            }
            if let message = sync.uploadMessage, sync.publication?.isPending == true {
                Text(message).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            if let notice = sync.notice { Text(notice).font(.system(size: compact ? 10 : 12)).foregroundStyle(.secondary) }
            dataRow(L10n.tr("Content"), value: contentTime(sync.cloudData?.contentModifiedAt))
            dataRow(L10n.tr("Published"), value: contentTime(sync.cloudData?.createdAt))
            dataRow(L10n.tr("Transfer"), value: sync.cloudTransferTitle)
            dataRow(L10n.tr("Checked"), value: contentTime(sync.lastCheckedAt))
            dataRow(L10n.tr("Local"), value: contentTime(sync.localUpdatedAt))
            if let issue = sync.issue {
                DisclosureGroup(L10n.tr("Diagnostic Details"), isExpanded: $detailsExpanded) {
                    HStack(alignment: .top) {
                        Text(issue.diagnostic).font(.system(size: compact ? 9 : 11, design: .monospaced))
                            .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 4)
                        iconAction(L10n.tr("Copy diagnostic details"), symbol: "doc.on.doc") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(issue.diagnostic, forType: .string)
                        }
                    }
                }.font(.system(size: compact ? 10 : 11))
            }
        }
    }
    private var cloudChoices: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()
            Text(L10n.tr("Choose the complete state to keep")).font(.system(size: 11, weight: .semibold))
            VStack(alignment: .leading, spacing: 10) {
                ForEach(sync.cloudHeads) { version in
                    HStack(alignment: .top) {
                        SnapshotVersionLabel(version: version)
                        Spacer(minLength: 4)
                        iconAction(L10n.tr("Review and apply this copy"), symbol: "arrow.down.circle") { versionToApply = version }
                            .disabled(sync.isBusy)
                            .accessibilityIdentifier("sync.quickApply.\(version.shortID)")
                    }
                }
            }
            HStack {
                iconAction(L10n.tr("Publish this Mac's copy instead"), symbol: "arrow.up.circle") { confirmPublish = true }.disabled(sync.isBusy)
                Spacer()
                iconAction(L10n.tr("Close version review"), symbol: "xmark") { choosing = false }
            }.font(.system(size: 11))
        }
    }

    var body: some View {
        let state = cards
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label(L10n.tr("iCloud Data"), systemImage: "icloud").font(.system(size: 12, weight: .semibold))
                    Spacer()
                    Menu {
                        if sync.isEnabled {
                            Button { Task { await sync.check() } } label: {
                                Label(L10n.tr("Refresh iCloud Status"), systemImage: "arrow.clockwise")
                            }.disabled(sync.isBusy)
                        }
                        Button { showingDetails.toggle() } label: {
                            Label(showingDetails ? L10n.tr("Hide Sync Details") : L10n.tr("Show Sync Details"), systemImage: "info.circle")
                        }
                        Divider()
                        Button(L10n.tr("Sync Settings and History…")) { PreferencesWindowController.shared.show(tab: L10n.tr("iCloud Sync")) }
                        if let folder = sync.folder { Button(L10n.tr("Show in Finder")) { NSWorkspace.shared.open(folder) } }
                        if sync.isEnabled {
                            Button(L10n.tr("Authorize iCloud Drive Access…")) { Task { await sync.authorizeAccess() } }.disabled(sync.isBusy)
                            Button(L10n.tr("Open iCloud Settings…")) { sync.openICloudSettings() }
                        }
                    } label: { Image(systemName: "ellipsis") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .help(L10n.tr("iCloud actions and details"))
                    .accessibilityLabel(L10n.tr("iCloud actions and details"))
                    .accessibilityIdentifier("sync.more")
                }
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(!sync.isEnabled ? L10n.tr("Not enabled") : sync.folder == nil ? L10n.tr("Not checked") : sync.cloudSource)
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("sync.data.Source")
                        if state.showsContentTimes, let date = sync.cloudData?.contentModifiedAt {
                            contentUpdated(date).accessibilityIdentifier("sync.cloudUpdated")
                        }
                    }
                    Spacer(minLength: 0)
                    SnapshotSyncStatusControl(control: state.cloud, action: perform)
                        .accessibilityIdentifier("sync.cloudStatus")
                }
                if showingDetails { cloudRecovery }
                if choosing { cloudChoices }
            }.padding(12)
                .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))

            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Label(L10n.tr("Local Data"), systemImage: "internaldrive").font(.system(size: 12, weight: .semibold))
                    if state.showsContentTimes, let date = sync.localUpdatedAt {
                        contentUpdated(date).accessibilityIdentifier("sync.localUpdated")
                    }
                }
                Spacer(minLength: 0)
                SnapshotSyncStatusControl(control: state.local, action: perform)
                    .accessibilityIdentifier("sync.localStatus")
            }.padding(12)
                .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
        }
        .alert(L10n.tr("Replace local tasks?"), isPresented: Binding(get: { versionToApply != nil }, set: { if !$0 { versionToApply = nil } })) {
            Button(L10n.tr("Cancel"), role: .cancel) { versionToApply = nil }
            Button(L10n.tr("Back Up and Apply"), role: .destructive) {
                if let version = versionToApply { Task { await sync.apply(version) } }
                versionToApply = nil; choosing = false
            }.disabled(sync.isBusy)
        } message: {
            if let version = versionToApply { Text(SnapshotVersionLabel.replacementMessage(version)) }
        }
        .alert(L10n.tr("Publish to iCloud?"), isPresented: $confirmPublish) {
            Button(L10n.tr("Cancel"), role: .cancel) {}
            Button(L10n.tr("Publish and Replace")) { choosing = false; Task { await sync.publish(allowReplacingRemote: true) } }.disabled(sync.isBusy)
        } message: {
            Text(L10n.tr("Replace the current cloud data with all data from \(sync.deviceName), including deletions? Previous copies remain in history."))
        }
        .alert(L10n.tr("Enable iCloud snapshots?"), isPresented: $confirmEnable) {
            Button(L10n.tr("Cancel"), role: .cancel) {}
            Button(L10n.tr("Enable iCloud Snapshots")) { Task { await sync.enable() } }
        } message: { Text(L10n.tr("Remarc will create or reuse \(AppIdentity.current.cloudDisplayPath). Publishing and applying stay manual.")) }
        .onRemarcChange(of: choosing || versionToApply != nil || confirmPublish || confirmEnable) { active in
            sync.holdAutomaticChecks(active, token: reviewToken)
        }
        .onRemarcChange(of: choosing || showingDetails) { onExpansionChanged($0) }
        .task { await sync.observeCloud() }
        .onDisappear { sync.holdAutomaticChecks(false, token: reviewToken) }
    }

    private func contentTime(_ date: Date?) -> String {
        date?.interfaceFormatted(date: .abbreviated, time: .standard) ?? L10n.tr("Not recorded")
    }
    private func dataRow(_ title: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).foregroundStyle(.secondary).frame(width: 64, alignment: .leading)
            Text(value).frame(maxWidth: .infinity, alignment: .trailing)
                .fixedSize(horizontal: false, vertical: true)
        }.font(.system(size: 11)).accessibilityIdentifier("sync.data.\(title)")
    }
    private func applyCloud() {
        if let version = sync.cloudData { versionToApply = version }
        else { choosing = true }
    }
    private func publishLocal() {
        confirmPublish = true
    }
    private func perform(_ action: SnapshotSyncCardPresentation.Action) {
        guard !sync.isBusy else { return }
        switch action {
        case .enable: confirmEnable = true
        case .publish: publishLocal()
        case .retry: Task { await sync.retry() }
        case .check: Task { await sync.check() }
        case .apply: applyCloud()
        case .choose: choosing.toggle()
        case .recover: showingDetails.toggle()
        }
    }

    private func contentUpdated(_ date: Date) -> some View {
        let time = Calendar.current.isDateInToday(date)
            ? L10n.tr("today at \(date.interfaceFormatted(date: .omitted, time: .shortened))")
            : date.formatted(.dateTime.month(.abbreviated).day().hour().minute())
        return Text(L10n.tr("Updated \(time)"))
            .font(.system(size: 10)).foregroundStyle(.secondary)
            .help(L10n.tr("Content updated: \(contentTime(date))"))
    }

    private func iconAction(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol).labelStyle(.iconOnly)
                .frame(width: 26, height: 26).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.remarcPrimary(for: colorScheme))
        .help(title)
    }

}

/// Passive states stay readable without becoming permanently disabled buttons.
private struct SnapshotSyncStatusControl: View {
    @ObservedObject private var localization = LocalizationManager.shared
    let control: SnapshotSyncCardPresentation.Control
    let action: (SnapshotSyncCardPresentation.Action) -> Void
    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovered = false

    private var tint: Color {
        switch control.tone {
        case .success: return .remarcSuccess(for: colorScheme)
        case .warning: return .remarcWarning(for: colorScheme)
        case .error: return .remarcError(for: colorScheme)
        case .neutral: return control.action == nil ? .primary.opacity(0.45) : .remarcPrimary(for: colorScheme)
        }
    }

    var body: some View {
        Group {
            if control.isWorking {
                ProgressView().controlSize(.small)
                    .frame(width: 30, height: 30)
                    .accessibilityLabel(control.description)
            } else if let operation = control.action {
                Button { action(operation) } label: {
                    Label(control.description, systemImage: control.symbol)
                        .labelStyle(.iconOnly)
                        .font(.system(size: 18))
                        .frame(width: 30, height: 30)
                        .background(tint.opacity(isHovered ? 0.10 : 0), in: RoundedRectangle(cornerRadius: 6))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { isHovered = $0 }
            } else {
                Image(systemName: control.symbol)
                    .font(.system(size: 18)).frame(width: 30, height: 30)
                    .accessibilityLabel(control.description)
            }
        }
        .foregroundStyle(tint)
        .help(control.description)
    }
}

struct SnapshotSyncToolbarButton: View {
    @ObservedObject private var localization = LocalizationManager.shared
    @ObservedObject private var sync = SnapshotSyncManager.shared
    @ObservedObject private var panel = MenuBarPopoverController.shared
    @Environment(\.colorScheme) private var colorScheme
    @State private var showing = false
    @State private var isHovered = false
    @State private var anchorRef = AnchorViewRef()

    private var cards: SnapshotSyncCardPresentation {
        SnapshotSyncCardPresentation.make(enabled: sync.isEnabled, directoryReady: sync.folder != nil,
            busy: sync.isBusy, transfer: sync.cloudTransfer, comparison: sync.comparison,
            publication: sync.publication, issue: sync.issue, presentation: sync.presentation,
            cloudCount: sync.cloudHeads.count)
    }

    private var tint: Color {
        switch cards.cloud.tone {
        case .success: return .remarcSuccess(for: colorScheme)
        case .warning: return .remarcWarning(for: colorScheme)
        case .error: return .remarcError(for: colorScheme)
        case .neutral: return .remarcPrimary(for: colorScheme)
        }
    }
    var body: some View {
        let state = cards
        Button { showing.toggle() } label: {
            ZStack {
                Image(systemName: RemarcSymbols.syncToolbar(state.toolbarSymbol))
                    .font(.system(size: 12))
                    .opacity(state.cloud.isWorking ? 0 : 1)
                if state.cloud.isWorking { ProgressView().controlSize(.mini) }
            }
            .foregroundStyle(tint).frame(width: 26, height: 26)
            .background(tint.opacity(isHovered ? 0.08 : 0), in: RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(DropdownAnchor(ref: anchorRef))
        .onHover { isHovered = $0 }
        .help(L10n.tr("iCloud · \(sync.summary)"))
        .accessibilityLabel(L10n.tr("iCloud · \(sync.shortStatus)"))
        .accessibilityIdentifier("sync.toolbar")
        .popover(isPresented: $showing, arrowEdge: .top) {
            SnapshotSyncPopoverContent(
                screenSize: NSScreen.bestScreen(for: anchorRef.view?.window).visibleFrame.size
            )
        }
        .task { await sync.checkIfNeeded() }
        .onRemarcChange(of: panel.isVisible) { visible in
            if !visible && !panel.isDetached { showing = false }
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)) { _ in
            Task { await sync.checkIfNeeded() }
        }
    }
}

/// Measure the full content inside a single scroll view. An explicit viewport
/// size lets the popover grow and shrink instead of preserving its initial height.
private struct SnapshotSyncPopoverContent: View {
    let screenSize: CGSize
    @State private var expanded = false
    @State private var contentSize: CGSize = .zero

    private var width: CGFloat {
        min(expanded ? 460 : 340, max(1, screenSize.width - 32))
    }

    private var height: CGFloat {
        min(contentSize.height > 0 ? contentSize.height : 180, screenSize.height * 0.8)
    }

    var body: some View {
        ScrollView {
            SnapshotSyncControls(compact: true, onExpansionChanged: { expanded = $0 })
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .background {
                    GeometryReader { geometry in
                        Color.clear
                            .onAppear { updateContentSize(geometry.size) }
                            .onRemarcChange(of: geometry.size) { updateContentSize($0) }
                    }
                }
        }
        .frame(width: width, height: height)
        .fixedSize()
        .animation(.easeInOut(duration: 0.18), value: expanded)
        .animation(.easeInOut(duration: 0.18), value: contentSize.height)
        .accessibilityIdentifier("sync.popover")
    }

    private func updateContentSize(_ size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        contentSize = CGSize(width: ceil(size.width), height: ceil(size.height))
    }
}
