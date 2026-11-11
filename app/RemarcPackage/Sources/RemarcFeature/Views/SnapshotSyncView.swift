import SwiftUI
import AppKit

struct SnapshotSyncView: View {
    @ObservedObject private var localization = LocalizationManager.shared
    @ObservedObject private var sync = SnapshotSyncManager.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text(L10n.tr("iCloud Data")).font(.title2.bold())
                Text(L10n.tr("One current cloud copy and one local undo for the last application."))
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                HStack {
                    Text(L10n.tr("This Mac"))
                    TextField(L10n.tr("Device name"), text: $sync.deviceName)
                        .textFieldStyle(.roundedBorder)
                }
                SnapshotSyncControls(compact: false)
                HStack {
                    Button(L10n.tr("Show iCloud Folder")) {
                        if let folder = sync.folder { NSWorkspace.shared.open(folder) }
                    }.disabled(sync.folder == nil)
                    if sync.isEnabled {
                        Button(L10n.tr("Disconnect")) { sync.disconnect() }.disabled(sync.isBusy)
                    }
                }.font(.system(size: 12))
            }.padding(28)
        }
    }
}

struct SnapshotSyncControls: View {
    var compact = false
    var onExpansionChanged: (Bool) -> Void = { _ in }
    @ObservedObject private var localization = LocalizationManager.shared
    @ObservedObject private var sync = SnapshotSyncManager.shared
    @Environment(\.colorScheme) private var colorScheme
    @State private var confirmPublish = false
    @State private var versionToApply: SnapshotVersion?
    @State private var confirmUndo = false
    @State private var confirmEnable = false
    @State private var reviewToken = UUID()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(L10n.tr("iCloud Data"), systemImage: "icloud")
                    .font(.system(size: 12, weight: .semibold))
                DevelopmentIdentityBadge()
                Spacer()
                if sync.isBusy { ProgressView().controlSize(.small) }
                Button { Task { await sync.check() } } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain).disabled(sync.isBusy || !sync.isEnabled)
                .help(L10n.tr("Check iCloud"))
                .accessibilityIdentifier("sync.check")
            }
            Text(sync.summary).font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let version = sync.cloudData {
                SnapshotVersionLabel(version: version)
                Text(L10n.tr("\(version.commentCount) tasks · \(version.imageCount) images"))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            if let notice = sync.notice {
                Text(notice).font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 10) {
                if sync.isEnabled {
                    Button(L10n.tr("Publish")) { confirmPublish = true }
                        .disabled(!sync.canPublish).accessibilityIdentifier("sync.publish")
                    Button(L10n.tr("Apply")) { versionToApply = sync.cloudData }
                        .disabled(!sync.canApply).accessibilityIdentifier("sync.apply")
                } else {
                    Button(L10n.tr("Enable iCloud Data")) { confirmEnable = true }
                        .disabled(sync.isBusy)
                }
                if compact {
                    Spacer(minLength: 0)
                    Button {
                        PreferencesWindowController.shared.show(tab: L10n.tr("iCloud Sync"))
                    } label: { Image(systemName: "gearshape") }
                    .help(L10n.tr("Settings"))
                }
            }
            .buttonStyle(.bordered).controlSize(.small)
            .tint(Color.remarcPrimary(for: colorScheme))
            Divider()
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.tr("Undo Last Apply")).font(.system(size: 11, weight: .semibold))
                    if let undo = sync.rollback {
                        Text(undo.createdAt.interfaceFormatted(date: .abbreviated, time: .standard))
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                    } else {
                        Text(L10n.tr("No application to undo")).font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button(L10n.tr("Undo")) { confirmUndo = true }
                    .buttonStyle(.bordered).controlSize(.small)
                    .disabled(sync.rollback == nil || sync.isBusy)
                    .accessibilityIdentifier("sync.undo")
            }
            if let issue = sync.issue {
                HStack {
                    if issue.needsAuthorization {
                        Button(L10n.tr("Allow Access")) { Task { await sync.authorizeAccess() } }
                    }
                    if issue.needsICloudSettings {
                        Button(L10n.tr("iCloud Settings")) { sync.openICloudSettings() }
                    }
                    Button(L10n.tr("Copy diagnostic details")) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(issue.diagnostic, forType: .string)
                    }
                }.font(.system(size: 10)).disabled(sync.isBusy)
            }
        }
        .alert(L10n.tr("Publish to iCloud?"), isPresented: $confirmPublish) {
            Button(L10n.tr("Cancel"), role: .cancel) {}
            Button(L10n.tr("Publish")) { Task { await sync.publish() } }
        } message: {
            Text(L10n.tr("Replace the current cloud copy with this Mac's latest comments, images and sessions? Only one cloud copy is kept."))
        }
        .alert(L10n.tr("Apply cloud data?"), isPresented: Binding(get: { versionToApply != nil }, set: { if !$0 { versionToApply = nil } })) {
            Button(L10n.tr("Cancel"), role: .cancel) { versionToApply = nil }
            Button(L10n.tr("Apply"), role: .destructive) {
                if let version = versionToApply { Task { await sync.apply(version) } }
                versionToApply = nil
            }
        } message: {
            Text(L10n.tr("Replace this Mac's comments, images and sessions with the cloud copy? Your current data is saved for one undo."))
        }
        .alert(L10n.tr("Undo last application?"), isPresented: $confirmUndo) {
            Button(L10n.tr("Cancel"), role: .cancel) {}
            Button(L10n.tr("Undo"), role: .destructive) { Task { await sync.undoLastApply() } }
        } message: {
            Text(L10n.tr("Restore this Mac's complete data from before the last application? Changes made since then will be replaced. Cloud data stays unchanged."))
        }
        .alert(L10n.tr("Enable iCloud Data?"), isPresented: $confirmEnable) {
            Button(L10n.tr("Cancel"), role: .cancel) {}
            Button(L10n.tr("Enable")) { Task { await sync.enable() } }
        } message: {
            Text(L10n.tr("Publishing and applying are manual. One current cloud copy is kept in \(AppIdentity.current.cloudDisplayPath)."))
        }
        .onRemarcChange(of: confirmPublish || versionToApply != nil || confirmUndo || confirmEnable) { active in
            sync.holdAutomaticChecks(active, token: reviewToken)
        }
        .task { await sync.observeCloud() }
        .onDisappear { sync.holdAutomaticChecks(false, token: reviewToken) }
    }
}

struct SnapshotVersionLabel: View {
    let version: SnapshotVersion
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(version.deviceName).font(.system(size: 12, weight: .medium))
            Text(version.createdAt.interfaceFormatted(date: .abbreviated, time: .standard))
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }
}

struct SnapshotSyncToolbarButton: View {
    @ObservedObject private var localization = LocalizationManager.shared
    @ObservedObject private var sync = SnapshotSyncManager.shared
    @ObservedObject private var panel = MenuBarPopoverController.shared
    @Environment(\.colorScheme) private var colorScheme
    @State private var showing = false
    @State private var anchorRef = AnchorViewRef()

    private var tint: Color {
        if sync.issue != nil { return .remarcWarning(for: colorScheme) }
        if sync.isEnabled && sync.comparison == .same && sync.publication?.isPending != true { return .remarcSuccess(for: colorScheme) }
        return .remarcPrimary(for: colorScheme)
    }
    var body: some View {
        Button { showing.toggle() } label: {
            Group {
                if sync.isBusy { ProgressView().controlSize(.mini) }
                else { Image(systemName: sync.isEnabled ? "icloud" : "icloud.slash").font(.system(size: 12)) }
            }
            .foregroundStyle(tint).frame(width: 26, height: 26).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(DropdownAnchor(ref: anchorRef))
        .help(L10n.tr("iCloud · \(sync.summary)"))
        .accessibilityLabel(L10n.tr("iCloud · \(sync.shortStatus)"))
        .accessibilityIdentifier("sync.toolbar")
        .popover(isPresented: $showing, arrowEdge: .top) {
            SnapshotSyncPopoverContent(screenSize: NSScreen.bestScreen(for: anchorRef.view?.window).visibleFrame.size)
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
