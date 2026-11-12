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

    private var isWorking: Bool {
        sync.isBusy || sync.publication?.isPending == true || sync.cloudTransfer.isActive
    }

    /// Status color shared by the header badge and the comparison arrow.
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

    /// Which way data should flow, drawn between the two copies.
    private var directionSymbol: String {
        guard sync.isStatusConfirmed else { return "arrow.left.arrow.right" }
        switch sync.comparison {
        case .same: return "equal"
        case .publish: return "arrow.right"
        case .receive: return "arrow.left"
        case .choose: return "arrow.left.arrow.right"
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: sync.statusSymbol)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(statusTint)
                .frame(width: 32, height: 32)
                .background(Circle().fill(statusTint.opacity(0.13)))
            VStack(alignment: .leading, spacing: 3) {
                Text(sync.isStatusConfirmed ? sync.guidance.title : sync.shortStatus)
                    .font(.system(size: 13, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                if sync.isStatusConfirmed {
                    Text(sync.guidance.explanation).font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.top, sync.isStatusConfirmed ? 0 : 7)
            Spacer(minLength: 4)
            Group {
                if isWorking {
                    ProgressView().controlSize(.small)
                } else {
                    Button { Task { await sync.check() } } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 11, weight: .medium))
                            .frame(width: 24, height: 24)
                            .background(Circle().fill(Color.remarcNeutralFill(for: colorScheme)))
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.remarcIconRest(for: colorScheme))
                    .disabled(sync.isBusy || !sync.isEnabled)
                    .help(L10n.tr("Check iCloud"))
                    .accessibilityLabel(L10n.tr("Check iCloud"))
                    .accessibilityIdentifier("sync.check")
                }
            }
            .frame(width: 24, height: 24)
            .padding(.top, 4)
        }
    }

    /// One side of the Mac ↔ iCloud comparison; `isSource` marks the newer copy.
    private func copyCard<Content: View>(isSource: Bool, @ViewBuilder content: () -> Content) -> some View {
        let brand = Color.remarcPrimary(for: colorScheme)
        return VStack(alignment: .leading, spacing: 4, content: content)
            .padding(10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background {
                let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
                ZStack {
                    shape.fill(Color.remarcSnapshotSurface(for: colorScheme))
                    if isSource { shape.fill(brand.opacity(0.06)) }
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(isSource ? brand.opacity(0.5) : Color.remarcSnapshotBorder(for: colorScheme),
                                  lineWidth: isSource ? 1 : 0.75)
                    .allowsHitTesting(false)
            }
    }

    private func cardTitle(_ title: String, symbol: String) -> some View {
        Label(title, systemImage: symbol)
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }

    private var comparisonCards: some View {
        let confirmed = sync.isStatusConfirmed
        return HStack(alignment: .center, spacing: 4) {
            copyCard(isSource: confirmed && sync.comparison == .publish) {
                HStack(spacing: 4) {
                    cardTitle(L10n.tr("This Mac"), symbol: "desktopcomputer")
                    Spacer(minLength: 0)
                    DevelopmentIdentityBadge().scaleEffect(0.8, anchor: .trailing)
                }
                Text(sync.deviceName).font(.system(size: 11, weight: .medium)).lineLimit(1).help(sync.deviceName)
                if let time = sync.localUpdatedAt, time != .distantPast {
                    Text(L10n.tr("Updated \(time.snapshotInterfaceFormatted())"))
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
                if let tasks = sync.localCommentCount, let images = sync.localImageCount {
                    Text(L10n.tr("\(tasks) tasks · \(images) images"))
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                } else {
                    Text(L10n.tr("Verifying local data…")).font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
            Image(systemName: directionSymbol)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(confirmed ? statusTint : Color.secondary.opacity(0.5))
                .frame(width: 14)
                .accessibilityHidden(true)
            copyCard(isSource: confirmed && sync.comparison == .receive) {
                cardTitle(L10n.tr("Backup in iCloud"), symbol: "icloud")
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

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            issueBanner
            comparisonCards
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
            .font(.system(size: 10.5)).foregroundStyle(.secondary).buttonStyle(.plain)
            .padding(.top, 10)
            .overlay(alignment: .top) {
                Rectangle().fill(Color.remarcHairline(for: colorScheme)).frame(height: 0.5)
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
