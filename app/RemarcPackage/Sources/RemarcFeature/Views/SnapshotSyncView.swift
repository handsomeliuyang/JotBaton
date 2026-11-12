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

    /// The undo stays one click away right after a restore, then gets out of the way.
    /// Preferences keeps a lasting entry for as long as the undo copy exists.
    private func restore(_ version: SnapshotVersion) {
        Task {
            guard await sync.apply(version) else { return }
            onDismiss()
            ToastManager.shared.show(L10n.tr("Restored from iCloud"), undo: {
                Task {
                    if await SnapshotSyncManager.shared.undoLastApply() {
                        ToastManager.shared.show(L10n.tr("Restore undone"))
                    }
                }
            }, duration: 8)
        }
    }

    private var isWorking: Bool {
        sync.isBusy || sync.publication?.isPending == true || sync.cloudTransfer.isActive
    }

    private var statusTitle: String {
        if !sync.isEnabled { return L10n.tr("Off") }
        if sync.isChecking { return L10n.tr("Checking") }
        if sync.isBusy { return L10n.tr("Working…") }
        if sync.issue != nil || sync.cloudTransfer == .failed { return L10n.tr("Sync needs attention") }
        if sync.publication?.isPending == true { return L10n.tr("Awaiting upload") }
        if sync.cloudTransfer.blocksReplacement { return sync.cloudTransfer.title }
        guard sync.isStatusConfirmed else { return L10n.tr("Not confirmed") }
        switch sync.comparison {
        case .same: return L10n.tr("Up to date")
        case .publish: return L10n.tr("Local update")
        case .receive: return L10n.tr("Cloud update")
        case .choose: return L10n.tr("Choose data")
        }
    }

    /// Color for the status between the two copies.
    private var statusTint: Color {
        if !sync.isEnabled { return .secondary }
        if sync.issue != nil || sync.cloudTransfer == .failed { return .remarcWarning(for: colorScheme) }
        guard sync.isStatusConfirmed else { return .remarcPrimary(for: colorScheme) }
        switch sync.comparison {
        case .same: return .remarcSuccess(for: colorScheme)
        case .publish, .receive: return .remarcPrimary(for: colorScheme)
        case .choose: return .remarcWarning(for: colorScheme)
        }
    }

    private var statusPill: some View {
        HStack(spacing: 4) {
            if sync.isStatusConfirmed && sync.comparison == .same {
                Image(systemName: "checkmark").font(.system(size: 8.5, weight: .bold))
            } else if sync.issue != nil || sync.cloudTransfer == .failed {
                Image(systemName: "exclamationmark").font(.system(size: 8.5, weight: .bold))
            } else {
                Circle().frame(width: 5, height: 5)
            }
            Text(statusTitle)
                .font(.system(size: 10.5, weight: .medium))
                .lineLimit(1)
        }
        .foregroundStyle(statusTint)
        .padding(.horizontal, 7)
        .frame(height: 20)
        .background(Capsule().fill(statusTint.opacity(0.12)))
        .help(sync.isStatusConfirmed ? sync.guidance.explanation : sync.summary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(statusTitle)
        .accessibilityHint(sync.isStatusConfirmed ? sync.guidance.explanation : sync.summary)
        .accessibilityIdentifier("sync.status")
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(L10n.tr("iCloud Sync"))
                .font(.system(size: 13, weight: .semibold))
            statusPill
            Spacer(minLength: 4)
            HStack(spacing: 2) {
                Group {
                    if isWorking {
                        ProgressView().controlSize(.small).scaleEffect(0.75)
                    } else {
                        SnapshotSyncIconButton(symbol: "arrow.clockwise", help: L10n.tr("Check iCloud"),
                                               identifier: "sync.check") { Task { await sync.check() } }
                            .disabled(sync.isBusy || !sync.isEnabled)
                    }
                }
                .frame(width: 26, height: 26)
                if compact {
                    SnapshotSyncIconButton(symbol: "gearshape", help: L10n.tr("iCloud Sync Settings"),
                                           identifier: "sync.settings") {
                        PreferencesWindowController.shared.show(tab: L10n.tr("iCloud Sync"))
                    }
                }
            }
        }
    }

    /// One side of the Mac ↔ iCloud comparison; `isSource` marks the newer copy.
    private func copyCard<Content: View>(isSource: Bool, @ViewBuilder content: () -> Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
        return VStack(alignment: .leading, spacing: 4, content: content)
            .padding(10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background {
                ZStack {
                    shape.fill(Color.remarcCardSurface(for: colorScheme))
                    if isSource { shape.fill(Color.remarcPrimary(for: colorScheme).opacity(0.06)) }
                }
            }
            .overlay {
                shape.strokeBorder(Color.remarcHairline(for: colorScheme), lineWidth: 0.75)
                    .allowsHitTesting(false)
            }
    }

    private func cardTitle(_ title: String, symbol: String, isNewer: Bool) -> some View {
        HStack(spacing: 4) {
            Label(title, systemImage: symbol)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
            if isNewer {
                Text(L10n.tr("Newer"))
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(Color.remarcPrimary(for: colorScheme))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1.5)
                    .background(Capsule().fill(Color.remarcPrimary(for: colorScheme).opacity(0.12)))
                    .fixedSize()
            }
        }
    }

    /// Points from the copy that would be written to the copy it would replace.
    private var directionIndicator: some View {
        let confirmed = sync.isStatusConfirmed
        let symbol = !confirmed ? "arrow.left.arrow.right"
            : sync.comparison == .publish ? "arrow.right"
            : sync.comparison == .receive ? "arrow.left"
            : sync.comparison == .same ? "equal" : "arrow.left.arrow.right"
        let directed = confirmed && (sync.comparison == .publish || sync.comparison == .receive)
        return Image(systemName: symbol)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(directed ? AnyShapeStyle(Color.remarcPrimary(for: colorScheme))
                                      : AnyShapeStyle(HierarchicalShapeStyle.tertiary))
            .frame(width: 16)
            .accessibilityHidden(true)
    }

    private var comparisonCards: some View {
        let confirmed = sync.isStatusConfirmed
        let localNewer = confirmed && sync.comparison == .publish
        let cloudNewer = confirmed && sync.comparison == .receive
        return HStack(alignment: .center, spacing: 6) {
            copyCard(isSource: localNewer) {
                HStack(spacing: 4) {
                    cardTitle(L10n.tr("This Mac"), symbol: "desktopcomputer", isNewer: localNewer)
                    DevelopmentIdentityBadge().scaleEffect(0.8, anchor: .trailing)
                }
                Text(sync.deviceName).font(.system(size: 11, weight: .medium)).lineLimit(1).help(sync.deviceName)
                if let time = sync.localUpdatedAt, time != .distantPast {
                    Text(L10n.tr("Updated \(time.snapshotInterfaceFormatted())"))
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                        .help(L10n.tr("Updated \(time.interfaceFormatted(date: .abbreviated, time: .standard))"))
                }
                if let tasks = sync.localCommentCount, let images = sync.localImageCount {
                    Text(L10n.tr("\(tasks) tasks · \(images) images"))
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                } else {
                    Text(L10n.tr("Verifying local data…")).font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
            directionIndicator
            copyCard(isSource: cloudNewer) {
                cardTitle(L10n.tr("Backup in iCloud"), symbol: "icloud", isNewer: cloudNewer)
                if let version = sync.cloudData {
                    SnapshotVersionLabel(version: version)
                } else {
                    Text(L10n.tr("No cloud copy available")).font(.system(size: 10)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private var issueBanner: some View {
        if let issue = sync.issue {
            let warning = Color.remarcWarning(for: colorScheme)
            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.lookup(issue.message))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
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
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                Button(L10n.tr("Copy diagnostic details")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(issue.diagnostic, forType: .string)
                }
                .buttonStyle(.plain)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            }
            .disabled(sync.isBusy)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(warning.opacity(0.10), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(warning.opacity(0.35), lineWidth: 0.75)
                    .allowsHitTesting(false)
            }
        }
    }

    private var needsCheck: Bool {
        sync.isEnabled && !sync.isStatusConfirmed && !sync.isBusy && sync.issue == nil
            && sync.publication?.isPending != true && !sync.cloudTransfer.isActive
    }

    private var noticeText: String? {
        guard let notice = sync.notice, sync.issue == nil, !sync.isBusy || sync.isChecking,
              !sync.cloudTransfer.blocksReplacement, sync.publication?.isPending != true,
              notice != L10n.tr("Cloud data applied. You can undo this application once.") else { return nil }
        return notice
    }

    /// Always-visible consequence of the buttons above, or why they are unavailable.
    private var actionExplanation: String? {
        if let noticeText { return noticeText }
        guard sync.isEnabled, sync.issue == nil else { return nil }
        guard sync.isStatusConfirmed else { return sync.summary }
        switch sync.comparison {
        case .publish:
            return L10n.tr(sync.cloudData == nil
                ? "No cloud copy yet. Publish this Mac’s data to create one."
                : "Back up this Mac to iCloud, replacing the existing cloud backup.")
        case .receive: return L10n.tr("Restore the cloud backup here, replacing this Mac’s data.")
        case .same, .choose: return sync.guidance.explanation
        }
    }

    @ViewBuilder private var actionRow: some View {
        let choosing = sync.isStatusConfirmed && sync.comparison == .choose
        HStack(spacing: 8) {
            if compact && sync.isStatusConfirmed && (sync.guidance == .setup || sync.guidance == .conflict) {
                Button(L10n.tr("Decide Later"), action: onDismiss)
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if !sync.isEnabled {
                actionButton(L10n.tr("Enable iCloud Data…"), prominent: true, enabled: !sync.isBusy,
                             help: nil, identifier: "sync.enable") {
                    setReviewing(true)
                    confirmEnable = true
                }
            } else if needsCheck {
                actionButton(L10n.tr("Check Again"), prominent: true, enabled: true,
                             help: nil, identifier: "sync.retry") { Task { await sync.check() } }
            } else {
                if sync.cloudData != nil {
                    actionButton(L10n.tr(choosing ? "Use the Cloud Backup…" : "Restore from iCloud…"),
                                 prominent: sync.canApply && !choosing, enabled: sync.canApply,
                                 help: sync.canApply ? L10n.tr("Restore the cloud backup here, replacing this Mac’s data.") : sync.summary,
                                 identifier: "sync.apply", perform: reviewApply)
                }
                actionButton(L10n.tr(choosing ? "Keep Using This Mac’s Data…" : "Back Up to iCloud…"),
                             prominent: sync.canPublish && !choosing, enabled: sync.canPublish,
                             help: sync.canPublish ? L10n.tr("Back up this Mac to iCloud, replacing the existing cloud backup.") : sync.summary,
                             identifier: "sync.publish", perform: reviewPublish)
            }
        }
    }

    /// The `.help` sits on an enabled wrapper so disabled buttons still explain why.
    private func actionButton(_ title: String, prominent: Bool, enabled: Bool, help: String?,
                              identifier: String, perform: @escaping () -> Void) -> some View {
        Button(action: perform) { Text(title).lineLimit(1) }
            .disabled(!enabled)
            .buttonStyle(SnapshotSyncActionButtonStyle(prominent: prominent))
            .accessibilityIdentifier(identifier)
            .accessibilityHint(help ?? "")
            .fixedSize()
            .contentShape(Rectangle())
            .help(help ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            issueBanner
            comparisonCards
            VStack(alignment: .leading, spacing: 8) {
                actionRow
                if let actionExplanation {
                    Text(actionExplanation)
                        .font(.system(size: 10.5)).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .multilineTextAlignment(.trailing)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("sync.explanation")
                }
            }
            if !compact && sync.rollback != nil {
                Button {
                    setReviewing(true)
                    confirmUndo = true
                } label: {
                    Label(L10n.tr("Undo Last Restore"), systemImage: "arrow.uturn.backward")
                }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .disabled(sync.isBusy)
                .help(rollbackHelp)
                .accessibilityIdentifier("sync.undo")
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
                if let version = versionToApply { restore(version) }
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
            if let time = version.contentModifiedAt {
                Text(L10n.tr("Updated \(time.snapshotInterfaceFormatted())"))
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    .help(L10n.tr("Updated \(time.interfaceFormatted(date: .abbreviated, time: .standard))"))
            } else {
                Text(L10n.tr("Backed up \(version.createdAt.snapshotInterfaceFormatted())"))
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    .help(L10n.tr("Published \(version.createdAt.interfaceFormatted(date: .abbreviated, time: .standard))"))
            }
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

    @State private var isHovered = false

    private var hasIssue: Bool { sync.issue != nil || sync.cloudTransfer == .failed }

    /// Quiet like the other footer icons; only something worth acting on gets a dot.
    private var needsAttention: Bool {
        hasIssue || (sync.isStatusConfirmed && sync.comparison != .same)
    }

    private var tint: Color {
        if hasIssue { return .remarcWarning(for: colorScheme) }
        if isHovered || showing { return .remarcPrimary(for: colorScheme) }
        return .remarcIconRest(for: colorScheme)
    }

    var body: some View {
        Button { showing.toggle() } label: {
            Group {
                if sync.isBusy || sync.publication?.isPending == true || sync.cloudTransfer.isActive { ProgressView().controlSize(.mini) }
                else { Image(systemName: sync.isEnabled ? "icloud" : "icloud.slash").font(.system(size: 13)) }
            }
            .foregroundStyle(tint)
            .frame(width: 26, height: 26)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(isHovered || showing ? Color.remarcNeutralFill(for: colorScheme) : .clear)
            )
            .overlay(alignment: .topTrailing) {
                if needsAttention {
                    Circle()
                        .fill(Color.remarcWarning(for: colorScheme))
                        .frame(width: 6, height: 6)
                        .offset(x: -3, y: 4)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(.easeInOut(duration: 0.15), value: isHovered)
        .background(SnapshotSyncPopoverAnchor(isPresented: $showing, colorScheme: colorScheme))
        .help(L10n.tr("iCloud · \(sync.shortStatus)"))
        .accessibilityLabel(L10n.tr("iCloud · \(sync.shortStatus)"))
        .accessibilityIdentifier("sync.toolbar")
        .onRemarcChange(of: panel.isVisible) { visible in
            if !visible && !panel.isDetached { showing = false }
        }

    }
}

/// Borderless header icon; the fill only appears on hover so the header stays quiet.
private struct SnapshotSyncIconButton: View {
    let symbol: String
    let help: String
    let identifier: String
    let perform: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    var body: some View {
        Button(action: perform) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 26, height: 26)
                .background {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isHovered && isEnabled ? Color.remarcNeutralFill(for: colorScheme) : .clear)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isHovered && isEnabled ? Color.remarcPrimary(for: colorScheme) : Color.remarcIconRest(for: colorScheme))
        .opacity(isEnabled ? 1 : 0.45)
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovered)
        .help(help)
        .accessibilityLabel(help)
        .accessibilityIdentifier(identifier)
    }
}

/// Shared styling for action rows and the directional buttons between copies.
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
            .font(.system(size: 11.5, weight: .medium))
            .labelStyle(.titleAndIcon)
            .padding(.horizontal, 12)
            .frame(height: 28)
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
