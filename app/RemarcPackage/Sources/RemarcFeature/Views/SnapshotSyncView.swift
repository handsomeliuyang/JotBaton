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

    private func directionAction(_ label: String, title: String, symbol: String, explanation: String,
                                 enabled: Bool, identifier: String,
                                 perform: @escaping () -> Void) -> some View {
        SnapshotSyncDirectionButton(label: label, title: title, symbol: symbol,
                                    explanation: enabled ? explanation : sync.summary,
                                    enabled: enabled, prominent: enabled && sync.comparison != .choose,
                                    identifier: identifier, perform: perform)
    }

    private var copyChoices: some View {
        VStack(spacing: 8) {
            directionAction(L10n.tr("Back Up"),
                            title: L10n.tr(sync.comparison == .choose ? "Keep Using This Mac’s Data…" : "Back Up to iCloud…"), symbol: "arrow.right",
                            explanation: L10n.tr(sync.cloudData == nil
                                ? "No cloud copy yet. Publish this Mac’s data to create one."
                                : "Back up this Mac to iCloud, replacing the existing cloud backup."),
                            enabled: sync.canPublish, identifier: "sync.publish", perform: reviewPublish)
            comparisonStatus
            directionAction(L10n.tr("Restore"), title: L10n.tr("Use the Cloud Backup…"), symbol: "arrow.left",
                            explanation: L10n.tr("Restore the cloud backup here, replacing this Mac’s data."),
                            enabled: sync.canApply, identifier: "sync.apply", perform: reviewApply)
        }
        .fixedSize()
        .zIndex(1)
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

    private var comparisonStatus: some View {
        HStack(spacing: 4) {
            if sync.isBusy || sync.cloudTransfer.isActive || sync.publication?.isPending == true {
                ProgressView().controlSize(.mini)
            } else if sync.isStatusConfirmed && sync.comparison == .same {
                Image(systemName: "checkmark").font(.system(size: 9, weight: .semibold))
            } else if sync.issue != nil || sync.cloudTransfer == .failed {
                Image(systemName: "exclamationmark.circle").font(.system(size: 10))
            }
            Text(statusTitle)
                .font(.system(size: 10, weight: .medium))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(statusTint)
        .frame(width: 100)
        .frame(minHeight: 20)
        .help(sync.isStatusConfirmed ? sync.guidance.explanation : sync.summary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(statusTitle)
        .accessibilityHint(sync.isStatusConfirmed ? sync.guidance.explanation : sync.summary)
        .accessibilityIdentifier("sync.status")
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

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "icloud")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Color.remarcPrimary(for: colorScheme))
                .frame(width: 32, height: 32)
                .background(Circle().fill(Color.remarcPrimary(for: colorScheme).opacity(0.13)))
            Text(L10n.tr("iCloud Sync"))
                .font(.system(size: 13, weight: .semibold))
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
        return HStack(alignment: .center, spacing: 8) {
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
                        .help(L10n.tr("Updated \(time.interfaceFormatted(date: .abbreviated, time: .standard))"))
                }
                if let tasks = sync.localCommentCount, let images = sync.localImageCount {
                    Text(L10n.tr("\(tasks) tasks · \(images) images"))
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                } else {
                    Text(L10n.tr("Verifying local data…")).font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
            copyChoices
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

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            issueBanner
            comparisonCards
                .zIndex(1)
            if !sync.isEnabled {
                action(L10n.tr("Enable iCloud Data"), symbol: "icloud", enabled: !sync.isBusy, identifier: "sync.enable") {
                    setReviewing(true)
                    confirmEnable = true
                }
            } else if !sync.isStatusConfirmed && !sync.isBusy && sync.issue == nil && sync.publication?.isPending != true && !sync.cloudTransfer.isActive {
                action(L10n.tr("Check Again"), symbol: "arrow.clockwise", enabled: true, identifier: "sync.retry") {
                    Task { await sync.check() }
                }
            }
            if let notice = sync.notice, sync.issue == nil, (!sync.isBusy || sync.isChecking),
               !sync.cloudTransfer.blocksReplacement, sync.publication?.isPending != true,
               notice != L10n.tr("Cloud data applied. You can undo this application once.") {
                Text(notice).font(.system(size: 10)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 12) {
                if sync.rollback != nil {
                    Button {
                        setReviewing(true)
                        confirmUndo = true
                    } label: {
                        Label(L10n.tr("Undo Last Restore"), systemImage: "arrow.uturn.backward")
                    }
                    .disabled(sync.isBusy)
                    .help(rollbackHelp)
                    .accessibilityIdentifier("sync.undo")
                }
                if compact && sync.isStatusConfirmed && (sync.guidance == .setup || sync.guidance == .conflict) {
                    Button(L10n.tr("Decide Later"), action: onDismiss)
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
        .help(L10n.tr("iCloud · \(sync.isStatusConfirmed ? sync.guidance.explanation : sync.summary)"))
        .accessibilityLabel(L10n.tr("iCloud · \(sync.shortStatus)"))
        .accessibilityIdentifier("sync.toolbar")
        .onRemarcChange(of: panel.isVisible) { visible in
            if !visible && !panel.isDetached { showing = false }
        }

    }
}

/// The enabled wrapper receives hover events even when its button is disabled.
private struct SnapshotSyncDirectionButton: View {
    let label: String
    let title: String
    let symbol: String
    let explanation: String
    let enabled: Bool
    let prominent: Bool
    let identifier: String
    let perform: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    @State private var showsHelp = false

    var body: some View {
        ZStack {
            Button(action: perform) {
                HStack(spacing: 6) {
                    if symbol == "arrow.left" { Image(systemName: symbol) }
                    Text(label).lineLimit(1)
                    if symbol == "arrow.right" { Image(systemName: symbol) }
                }
                .frame(width: 80)
            }
            .disabled(!enabled)
            .buttonStyle(SnapshotSyncActionButtonStyle(prominent: prominent))
            .accessibilityLabel(title)
            .accessibilityHint(explanation)
            .accessibilityIdentifier(identifier)
        }
        .contentShape(Rectangle())
        .onHover { showsHelp = $0 }
        .overlay(alignment: .bottom) {
            if showsHelp {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.system(size: 11, weight: .semibold))
                    Text(explanation).font(.system(size: 10)).foregroundStyle(.secondary)
                }
                .frame(width: 220, alignment: .leading)
                .padding(10)
                .background(Color.remarcSnapshotSurface(for: colorScheme), in: RoundedRectangle(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.remarcSnapshotBorder(for: colorScheme), lineWidth: 0.75)
                }
                .shadow(color: .black.opacity(0.15), radius: 5, y: 2)
                .fixedSize(horizontal: false, vertical: true)
                // The control is 30pt tall; keep the help 6pt above it.
                .offset(y: -36)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
        }
        .zIndex(showsHelp ? 1 : 0)
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
