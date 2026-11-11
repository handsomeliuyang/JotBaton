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
    var onReviewChanged: (Bool) -> Void = { _ in }
    @ObservedObject private var localization = LocalizationManager.shared
    @ObservedObject private var sync = SnapshotSyncManager.shared
    @Environment(\.colorScheme) private var colorScheme
    @State private var confirmPublish = false
    @State private var versionToApply: SnapshotVersion?
    @State private var confirmUndo = false
    @State private var confirmEnable = false
    @State private var reviewToken = UUID()

    private var rollbackHelp: String {
        guard let undo = sync.rollback else { return L10n.tr("No application to undo") }
        return L10n.tr("Restore data saved before applying at \(undo.createdAt.interfaceFormatted(date: .abbreviated, time: .standard))")
    }

    private func setReviewing(_ active: Bool) {
        sync.holdAutomaticChecks(active, token: reviewToken)
        onReviewChanged(active)
    }

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
            HStack(spacing: 6) {
                if sync.isEnabled {
                    Button { setReviewing(true); confirmPublish = true } label: {
                        Label(L10n.tr("Publish"), systemImage: "arrow.up")
                    }
                    .disabled(!sync.canPublish).accessibilityIdentifier("sync.publish")
                    Button {
                        guard let version = sync.cloudData else { return }
                        setReviewing(true)
                        versionToApply = version
                    } label: {
                        Label(L10n.tr("Apply"), systemImage: "arrow.down")
                    }
                    .disabled(!sync.canApply).accessibilityIdentifier("sync.apply")
                } else {
                    Button(L10n.tr("Enable iCloud Data")) { setReviewing(true); confirmEnable = true }
                        .disabled(sync.isBusy)
                }
                Button { setReviewing(true); confirmUndo = true } label: {
                    Label(L10n.tr("Roll Back"), systemImage: "arrow.uturn.backward")
                }
                .disabled(sync.rollback == nil || sync.isBusy)
                .help(rollbackHelp)
                .accessibilityIdentifier("sync.undo")
                if compact {
                    Spacer(minLength: 0)
                    Button {
                        PreferencesWindowController.shared.show(tab: L10n.tr("iCloud Sync"))
                    } label: {
                        Image(systemName: "gearshape").frame(width: 12)
                    }
                    .help(L10n.tr("Settings"))
                    .accessibilityLabel(L10n.tr("Settings"))
                }
            }
            .buttonStyle(SnapshotSyncActionButtonStyle())
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
            Button(L10n.tr("Roll Back"), role: .destructive) { Task { await sync.undoLastApply() } }
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
            setReviewing(active)
        }
        .task { await sync.observeCloud() }
        .onDisappear { setReviewing(false) }
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
        .background(SnapshotSyncPopoverAnchor(isPresented: $showing, colorScheme: colorScheme))
        .help(L10n.tr("iCloud · \(sync.summary)"))
        .accessibilityLabel(L10n.tr("iCloud · \(sync.shortStatus)"))
        .accessibilityIdentifier("sync.toolbar")
        .task { await sync.checkIfNeeded() }
        .onRemarcChange(of: panel.isVisible) { visible in
            if !visible && !panel.isDetached { showing = false }
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)) { _ in
            Task { await sync.checkIfNeeded() }
        }
    }
}

/// A consistent action row whose disabled controls still explain their purpose.
private struct SnapshotSyncActionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        SnapshotSyncActionButtonBody(label: configuration.label, isPressed: configuration.isPressed)
    }
}

private struct SnapshotSyncActionButtonBody<Label: View>: View {
    let label: Label
    let isPressed: Bool
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    var body: some View {
        let brand = Color.remarcPrimary(for: colorScheme)
        label
            .font(.system(size: 11, weight: .medium))
            .labelStyle(.titleAndIcon)
            .padding(.horizontal, 10)
            .frame(height: 28)
            .foregroundStyle(isEnabled ? (isHovered ? brand : .primary.opacity(0.8)) : .secondary.opacity(0.55))
            .background {
                RoundedRectangle(cornerRadius: 7)
                    .fill(isEnabled && (isHovered || isPressed)
                          ? brand.opacity(isPressed ? 0.18 : 0.10) : Color.primary.opacity(isEnabled ? 0.055 : 0.025))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(isEnabled && isHovered ? brand.opacity(0.22) : Color.primary.opacity(0.06), lineWidth: 0.5)
            }
            .contentShape(RoundedRectangle(cornerRadius: 7))
            .onHover { isHovered = $0 }
            .animation(.easeOut(duration: 0.12), value: isHovered)
            .animation(.easeOut(duration: 0.08), value: isPressed)
    }
}
