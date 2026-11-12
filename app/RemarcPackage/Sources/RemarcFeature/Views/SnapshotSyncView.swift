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
    var onDismiss: () -> Void = {}
    @ObservedObject private var localization = LocalizationManager.shared
    @ObservedObject private var sync = SnapshotSyncManager.shared
    @Environment(\.colorScheme) private var colorScheme
    @State private var choosingCopy = false
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

    private func reviewPublish() {
        guard sync.canPublish else { return }
        setReviewing(true)
        confirmPublish = true
    }

    private func reviewApply() {
        guard sync.canApply, let version = sync.cloudData else { return }
        setReviewing(true)
        versionToApply = version
    }

    private func action(_ title: String, symbol: String, explanation: String? = nil,
                        prominent: Bool = false, enabled: Bool, identifier: String,
                        perform: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Button(action: perform) {
                Label(title, systemImage: symbol).frame(maxWidth: .infinity)
            }
            .disabled(!enabled)
            .buttonStyle(SnapshotSyncActionButtonStyle(prominent: prominent))
            .accessibilityIdentifier(identifier)
            if let explanation {
                Text(explanation).font(.system(size: 10)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder private var copyChoices: some View {
        action(L10n.tr("Keep Using This Mac’s Data…"), symbol: "arrow.up",
               explanation: L10n.tr("Back up this Mac to iCloud, replacing the existing cloud backup."),
               enabled: sync.canPublish, identifier: "sync.publish", perform: reviewPublish)
        action(L10n.tr("Use the Cloud Backup…"), symbol: "arrow.down",
               explanation: L10n.tr("Restore the cloud backup here, replacing this Mac’s data."),
               enabled: sync.canApply, identifier: "sync.apply", perform: reviewApply)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top) {
                    Text(sync.isStatusConfirmed ? sync.guidance.title : sync.shortStatus)
                        .font(.system(size: 13, weight: .semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    if sync.isBusy || sync.publication?.isPending == true || sync.cloudTransfer.isActive {
                        ProgressView().controlSize(.small)
                    }
                    Button { Task { await sync.check() } } label: {
                        Image(systemName: "arrow.clockwise").frame(width: 24, height: 24).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).disabled(sync.isBusy || !sync.isEnabled)
                    .help(L10n.tr("Check iCloud"))
                    .accessibilityLabel(L10n.tr("Check iCloud"))
                    .accessibilityIdentifier("sync.check")
                }
                if sync.isStatusConfirmed {
                    Text(sync.guidance.explanation).font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            dataSection {
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Label(L10n.tr("This Mac"), systemImage: "desktopcomputer")
                            .font(.system(size: 11, weight: .semibold))
                        DevelopmentIdentityBadge()
                        Spacer(minLength: 0)
                    }
                    Text(sync.deviceName).font(.system(size: 11)).lineLimit(1).help(sync.deviceName)
                    if let tasks = sync.localCommentCount, let images = sync.localImageCount {
                        Text(L10n.tr("\(tasks) tasks · \(images) images"))
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                    } else {
                        Text(L10n.tr("Verifying local data…")).font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    if let time = sync.localUpdatedAt, time != .distantPast {
                        Text(L10n.tr("Updated \(time.snapshotInterfaceFormatted())"))
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
                Divider().padding(.vertical, 3)
                VStack(alignment: .leading, spacing: 5) {
                    Label(L10n.tr("Backup in iCloud"), systemImage: "icloud")
                        .font(.system(size: 11, weight: .semibold))
                    if let version = sync.cloudData {
                        SnapshotVersionLabel(version: version)
                    } else {
                        Text(L10n.tr("No cloud copy available")).font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
            }
            if sync.isStatusConfirmed {
                switch sync.guidance {
                case .setup:
                    copyChoices
                case .conflict:
                    if choosingCopy {
                        copyChoices
                    } else {
                        action(L10n.tr("Choose Which Data to Use…"), symbol: "arrow.left.arrow.right",
                               enabled: true, identifier: "sync.choose") { choosingCopy = true }
                    }
                case .backup:
                    action(L10n.tr("Back Up to iCloud…"), symbol: "arrow.up", prominent: true,
                           enabled: sync.canPublish, identifier: "sync.publish", perform: reviewPublish)
                case .restore:
                    action(L10n.tr("Restore Cloud Update…"), symbol: "arrow.down", prominent: true,
                           enabled: sync.canApply, identifier: "sync.apply", perform: reviewApply)
                case .current:
                    EmptyView()
                }
            } else if !sync.isEnabled {
                action(L10n.tr("Enable iCloud Data"), symbol: "icloud", enabled: !sync.isBusy, identifier: "sync.enable") {
                    setReviewing(true)
                    confirmEnable = true
                }
            } else if !sync.isBusy && sync.issue == nil && sync.publication?.isPending != true && !sync.cloudTransfer.isActive {
                action(L10n.tr("Check Again"), symbol: "arrow.clockwise", enabled: true, identifier: "sync.retry") {
                    Task { await sync.check() }
                }
            }
            if let notice = sync.notice, sync.issue == nil, (!sync.isBusy || sync.isChecking),
               !sync.cloudTransfer.blocksReplacement, sync.publication?.isPending != true {
                Text(notice).font(.system(size: 10)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if compact && sync.isStatusConfirmed && (sync.guidance == .setup || sync.guidance == .conflict) {
                    Button(L10n.tr("Decide Later"), action: onDismiss)
                } else {
                    Menu(L10n.tr("Other Actions")) {
                        Button(L10n.tr("Undo Last Application")) { setReviewing(true); confirmUndo = true }
                            .disabled(sync.rollback == nil || sync.isBusy)
                            .help(rollbackHelp)
                        if sync.isStatusConfirmed && sync.guidance == .backup && sync.cloudData != nil {
                            Button(L10n.tr("Use the Cloud Backup…"), action: reviewApply)
                        }
                        if sync.isStatusConfirmed && sync.guidance == .restore {
                            Button(L10n.tr("Keep Using This Mac’s Data…"), action: reviewPublish)
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
                Spacer()
                if compact {
                    Button {
                        PreferencesWindowController.shared.show(tab: L10n.tr("iCloud Sync"))
                    } label: { Label(L10n.tr("Settings"), systemImage: "gearshape") }
                }
            }
            .font(.system(size: 10)).foregroundStyle(.secondary).buttonStyle(.plain)
            if let issue = sync.issue {
                HStack {
                    if !issue.needsAuthorization {
                        Button(L10n.tr("Retry")) { Task { await sync.check() } }
                            .accessibilityIdentifier("sync.retry")
                    }
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
        .alert(sync.cloudData == nil ? L10n.tr("Create an iCloud backup?") : L10n.tr("Replace the iCloud backup?"), isPresented: $confirmPublish) {
            Button(L10n.tr("Cancel"), role: .cancel) {}
            Button(L10n.tr("Back Up to iCloud"), role: sync.cloudData == nil ? nil : .destructive) { Task { await sync.publish() } }
        } message: {
            Text(sync.cloudData == nil
                 ? L10n.tr("This Mac → iCloud. Create a backup of this Mac’s tasks, images and sessions. This Mac’s data stays unchanged.")
                 : L10n.tr("This Mac → iCloud. Replace the existing cloud backup with this Mac’s tasks, images and sessions. The previous cloud backup cannot be restored here. This Mac’s data stays unchanged."))
        }
        .alert(L10n.tr("Restore the cloud backup to this Mac?"), isPresented: Binding(get: { versionToApply != nil }, set: { if !$0 { versionToApply = nil } })) {
            Button(L10n.tr("Cancel"), role: .cancel) { versionToApply = nil }
            Button(L10n.tr("Restore to This Mac"), role: .destructive) {
                if let version = versionToApply { Task { await sync.apply(version) } }
                versionToApply = nil
            }
        } message: {
            Text(L10n.tr("iCloud → This Mac. Replace this Mac’s tasks, images and sessions with the selected cloud backup. You can undo this restore once. The cloud backup stays unchanged."))
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
        .onDisappear { setReviewing(false) }
    }
}

struct SnapshotVersionLabel: View {
    let version: SnapshotVersion
    @ObservedObject private var localization = LocalizationManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(L10n.tr("From \(version.deviceName)"))
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
                .help(version.deviceName)
            Text(L10n.tr("Backed up \(version.createdAt.snapshotInterfaceFormatted())"))
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
        if sync.issue != nil || sync.cloudTransfer == .failed { return .remarcWarning(for: colorScheme) }
        if sync.isStatusConfirmed && sync.comparison == .same { return .remarcSuccess(for: colorScheme) }
        return .remarcPrimary(for: colorScheme)
    }
    var body: some View {
        Button { showing.toggle() } label: {
            Group {
                if sync.isBusy || sync.publication?.isPending == true || sync.cloudTransfer.isActive { ProgressView().controlSize(.mini) }
                else { Image(systemName: sync.statusSymbol).font(.system(size: 12)) }
            }
            .foregroundStyle(tint).frame(width: 26, height: 26).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(SnapshotSyncPopoverAnchor(isPresented: $showing, colorScheme: colorScheme))
        .help(L10n.tr("iCloud · \(sync.isStatusConfirmed ? sync.guidance.explanation : sync.summary)"))
        .accessibilityLabel(L10n.tr("iCloud · \(sync.shortStatus)"))
        .accessibilityIdentifier("sync.toolbar")
        .onRemarcChange(of: panel.isVisible) { visible in
            if !visible && !panel.isDetached { showing = false }
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
