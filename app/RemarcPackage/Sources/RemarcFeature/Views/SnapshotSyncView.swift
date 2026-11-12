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

    private func dataSection<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 9, content: content)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.remarcSnapshotSurface(for: colorScheme), in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.remarcSnapshotBorder(for: colorScheme), lineWidth: 0.75)
                    .allowsHitTesting(false)
            }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            dataSection {
                HStack {
                    Text(L10n.tr("iCloud Cloud Copy"))
                        .font(.system(size: 12, weight: .semibold))
                    Spacer()
                    if sync.isBusy { ProgressView().controlSize(.small) }
                    Button { Task { await sync.check() } } label: {
                        Image(systemName: "arrow.clockwise")
                            .frame(width: 24, height: 24)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(sync.isBusy || !sync.isEnabled)
                    .help(L10n.tr("Check iCloud"))
                    .accessibilityLabel(L10n.tr("Check iCloud"))
                    .accessibilityIdentifier("sync.check")
                }
                if let version = sync.cloudData {
                    SnapshotVersionLabel(version: version)
                } else {
                    Text(sync.isEnabled ? L10n.tr("No cloud copy available") : L10n.tr("iCloud data is off"))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                if sync.isEnabled {
                    Button {
                        guard let version = sync.cloudData else { return }
                        setReviewing(true)
                        versionToApply = version
                    } label: {
                        Label(L10n.tr("Apply to This Mac"), systemImage: "arrow.down")
                            .frame(maxWidth: .infinity)
                    }
                    .disabled(!sync.canApply)
                    .buttonStyle(SnapshotSyncActionButtonStyle(prominent: sync.comparison == .receive))
                    .accessibilityIdentifier("sync.apply")
                } else {
                    Button(L10n.tr("Enable iCloud Data")) { setReviewing(true); confirmEnable = true }
                        .disabled(sync.isBusy)
                        .buttonStyle(SnapshotSyncActionButtonStyle())
                }
            }
            dataSection {
                HStack {
                    Text(L10n.tr("Local Data"))
                        .font(.system(size: 12, weight: .semibold))
                    DevelopmentIdentityBadge()
                    Spacer(minLength: 0)
                }
                Text(sync.deviceName)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                    .help(sync.deviceName)
                if let tasks = sync.localCommentCount, let images = sync.localImageCount {
                    Text(L10n.tr("\(tasks) tasks · \(images) images"))
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                } else {
                    Text(L10n.tr("Verifying local data…"))
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Button { setReviewing(true); confirmPublish = true } label: {
                    Label(L10n.tr("Publish to iCloud"), systemImage: "arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .disabled(!sync.canPublish)
                .buttonStyle(SnapshotSyncActionButtonStyle(prominent: sync.comparison == .publish))
                .accessibilityIdentifier("sync.publish")
            }
            if sync.isBusy || sync.issue != nil || sync.publication?.isPending == true
                || sync.cloudTransfer.blocksReplacement || sync.cloudTransfer == .unknown
                || (sync.isEnabled && (sync.lastCheckedAt == nil || sync.localContentHash == nil || sync.comparison == .same)) {
                Text(sync.summary)
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let notice = sync.notice, sync.issue == nil, !sync.isBusy,
               !sync.cloudTransfer.blocksReplacement, sync.publication?.isPending != true {
                Text(notice).font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 6) {
                Button { setReviewing(true); confirmUndo = true } label: {
                    Label(L10n.tr("Undo Last Application"), systemImage: "arrow.uturn.backward")
                }
                .disabled(sync.rollback == nil || sync.isBusy)
                .help(L10n.tr("Undo Last Application") + " — " + rollbackHelp)
                .accessibilityIdentifier("sync.undo")
                if compact {
                    Spacer(minLength: 0)
                    Button {
                        PreferencesWindowController.shared.show(tab: L10n.tr("iCloud Sync"))
                    } label: {
                        Label(L10n.tr("Settings"), systemImage: "gearshape")
                    }
                    .help(L10n.tr("Settings"))
                    .accessibilityLabel(L10n.tr("Settings"))
                }
            }
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .buttonStyle(.plain)
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
            Button(L10n.tr("Publish to iCloud"), role: sync.cloudData == nil ? nil : .destructive) { Task { await sync.publish() } }
        } message: {
            Text(sync.cloudData == nil
                 ? L10n.tr("Upload this Mac’s tasks, images and sessions to create a cloud copy. Local data stays unchanged.")
                 : L10n.tr("Replace the cloud copy with this Mac’s tasks, images and sessions. The previous cloud copy cannot be restored here. Local data stays unchanged."))
        }
        .alert(L10n.tr("Apply cloud data?"), isPresented: Binding(get: { versionToApply != nil }, set: { if !$0 { versionToApply = nil } })) {
            Button(L10n.tr("Cancel"), role: .cancel) { versionToApply = nil }
            Button(L10n.tr("Apply to This Mac"), role: .destructive) {
                if let version = versionToApply { Task { await sync.apply(version) } }
                versionToApply = nil
            }
        } message: {
            Text(L10n.tr("Replace this Mac's comments, images and sessions with the cloud copy? Your current data is saved for one undo."))
        }
        .alert(L10n.tr("Undo last application?"), isPresented: $confirmUndo) {
            Button(L10n.tr("Cancel"), role: .cancel) {}
            Button(L10n.tr("Undo Last Application"), role: .destructive) { Task { await sync.undoLastApply() } }
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
    @ObservedObject private var localization = LocalizationManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(version.deviceName)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
                .help(version.deviceName)
            Text(verbatim: version.createdAt.snapshotInterfaceFormatted())
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .help(L10n.tr("Published \(version.createdAt.interfaceFormatted(date: .abbreviated, time: .standard))"))
            Text(L10n.tr("\(version.commentCount) tasks · \(version.imageCount) images"))
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
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
    var prominent = false
    func makeBody(configuration: Configuration) -> some View {
        SnapshotSyncActionButtonBody(label: configuration.label, isPressed: configuration.isPressed, prominent: prominent)
    }
}

private struct SnapshotSyncActionButtonBody<Label: View>: View {
    let label: Label
    let isPressed: Bool
    let prominent: Bool
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    var body: some View {
        let brand = Color.remarcPrimary(for: colorScheme)
        label
            .font(.system(size: 11, weight: .medium))
            .labelStyle(.titleAndIcon)
            .padding(.horizontal, 10)
            .frame(height: 30)
            .foregroundStyle(isEnabled ? (prominent ? Color.white : (isHovered ? brand : .primary.opacity(0.9))) : .secondary.opacity(0.55))
            .background {
                RoundedRectangle(cornerRadius: 7)
                    .fill(isEnabled && prominent ? Color.remarcButtonBase(for: colorScheme).opacity(isPressed ? 0.75 : (isHovered ? 0.9 : 1))
                          : isEnabled && (isHovered || isPressed)
                          ? brand.opacity(isPressed ? 0.18 : 0.10) : Color.remarcSnapshotButtonSurface(for: colorScheme).opacity(isEnabled ? 1 : 0.45))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(isEnabled ? (isHovered ? brand.opacity(0.45) : Color.remarcSnapshotBorder(for: colorScheme)) : Color.remarcSnapshotBorder(for: colorScheme).opacity(0.45), lineWidth: 0.75)
            }
            .contentShape(RoundedRectangle(cornerRadius: 7))
            .onHover { isHovered = $0 }
            .animation(.easeOut(duration: 0.12), value: isHovered)
            .animation(.easeOut(duration: 0.08), value: isPressed)
    }
}
