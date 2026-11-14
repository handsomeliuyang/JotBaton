import CoreLocalization
import CorePlatform
import CoreTheme
import CoreUI
import FeatureComments
import FeatureCloudSync
import FeatureUpdates
import SwiftUI
import AppKit

struct CloudSyncView: View {
    @ObservedObject private var localization = LocalizationManager.shared
    @ObservedObject private var sync = AppServices.shared.cloudSync
    @State private var confirmEnable = false
    @State private var confirmUndo = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text(L10n.tr("iCloud Sync")).font(.title2.bold())
                Text(L10n.tr("Tasks, images and sessions sync automatically between your Macs through \(AppIdentity.current.cloudDisplayPath). Each Mac keeps working offline, and changes merge task by task."))
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Toggle(L10n.tr("Sync automatically"), isOn: Binding(
                    get: { sync.isEnabled },
                    set: { if $0 { confirmEnable = true } else { sync.disable() } }
                ))
                .toggleStyle(.switch)
                .accessibilityIdentifier("sync.enabled")
                HStack {
                    Text(L10n.tr("This Mac"))
                    TextField(L10n.tr("Device name"), text: $sync.deviceName)
                        .textFieldStyle(.roundedBorder)
                }
                if sync.isEnabled {
                    CloudSyncControls(compact: false)
                    if !sync.devices.isEmpty { deviceList }
                }
                HStack {
                    Button(L10n.tr("Show iCloud Folder")) {
                        if let folder = sync.folder { NSWorkspace.shared.open(folder) }
                    }.disabled(sync.folder == nil)
                    if sync.canUndoLastSync {
                        Button(L10n.tr("Undo Last Sync…")) { confirmUndo = true }
                            .disabled(sync.isSyncing)
                            .accessibilityIdentifier("sync.undo")
                    }
                }.font(.system(size: 12))
            }.padding(28)
        }
        .syncEnableConfirmation(isPresented: $confirmEnable)
        .alert(L10n.tr("Undo the last sync?"), isPresented: $confirmUndo) {
            Button(L10n.tr("Cancel"), role: .cancel) {}
            Button(L10n.tr("Undo Last Sync"), role: .destructive) {
                Task {
                    if await sync.undoLastSync() { ToastManager.shared.show(L10n.tr("Last sync undone")) }
                }
            }
        } message: {
            Text(L10n.tr("Tasks on this Mac return to how they were before the last sync changed them, and that version then syncs to your other Macs. Tasks added on other Macs are kept."))
        }
    }

    private var deviceList: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L10n.tr("Other Macs")).font(.system(size: 12, weight: .semibold))
            ForEach(sync.devices) { device in
                HStack(spacing: 6) {
                    Image(systemName: "desktopcomputer").foregroundStyle(.secondary)
                    Text(device.name).lineLimit(1)
                    Spacer(minLength: 8)
                    Text(deviceStatus(device)).foregroundStyle(.secondary).lineLimit(1)
                }
                .font(.system(size: 11))
            }
        }
    }

    private func deviceStatus(_ device: SyncDeviceSummary) -> String {
        if device.needsNewerApp { return L10n.tr("Uses a newer JotBaton") }
        if device.isWaiting { return L10n.tr("Downloading from iCloud…") }
        guard let time = device.updatedAt else { return "" }
        return L10n.tr("Updated \(time.syncInterfaceFormatted())")
    }
}

private extension View {
    func syncEnableConfirmation(isPresented: Binding<Bool>) -> some View {
        alert(L10n.tr("Turn on iCloud sync?"), isPresented: isPresented) {
            Button(L10n.tr("Cancel"), role: .cancel) {}
            Button(L10n.tr("Turn On")) { AppServices.shared.cloudSync.enable() }
        } message: {
            Text(L10n.tr("This Mac's tasks, images and sessions are merged with your other Macs through \(AppIdentity.current.cloudDisplayPath). Nothing is replaced: edits from every Mac are kept, and the newer one wins when the same field changed on two Macs."))
        }
    }
}

/// Status, problems and conflicts. Shared by the settings pane and the
/// toolbar popover.
struct CloudSyncControls: View {
    var compact = false
    var onReviewChanged: (Bool) -> Void = { _ in }
    var onDismiss: () -> Void = {}
    @ObservedObject private var localization = LocalizationManager.shared
    @ObservedObject private var sync = AppServices.shared.cloudSync
    @Environment(\.colorScheme) private var colorScheme
    @State private var confirmEnable = false

    private var health: SyncHealth { sync.health }

    private var statusTint: Color {
        switch health {
        case .off: return .secondary
        case .ok: return .remarcSuccess(for: colorScheme)
        case .syncing, .waiting: return .remarcPrimary(for: colorScheme)
        case .attention: return .remarcWarning(for: colorScheme)
        }
    }

    private var statusPill: some View {
        HStack(spacing: 4) {
            switch health {
            case .ok: Image(systemName: "checkmark").font(.system(size: 8.5, weight: .bold))
            case .attention: Image(systemName: "exclamationmark").font(.system(size: 8.5, weight: .bold))
            default: Circle().frame(width: 5, height: 5)
            }
            Text(shortStatus)
                .font(.system(size: 10.5, weight: .medium))
                .lineLimit(1)
        }
        .foregroundStyle(statusTint)
        .padding(.horizontal, 7)
        .frame(height: 20)
        .background(Capsule().fill(statusTint.opacity(0.12)))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(health.title)
        .accessibilityIdentifier("sync.status")
    }

    private var shortStatus: String {
        switch health {
        case .off: return L10n.tr("Off")
        case .ok: return L10n.tr("Synced")
        case .syncing: return L10n.tr("Syncing")
        case .waiting: return L10n.tr("Downloading")
        case .attention: return L10n.tr("Needs attention")
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(L10n.tr("iCloud Sync"))
                .font(.system(size: 13, weight: .semibold))
            statusPill
            Spacer(minLength: 4)
            HStack(spacing: 2) {
                Group {
                    if sync.isSyncing {
                        ProgressView().controlSize(.small).scaleEffect(0.75)
                    } else {
                        CloudSyncIconButton(symbol: "arrow.clockwise", help: L10n.tr("Sync Now"),
                                               identifier: "sync.now") { Task { await sync.syncNow() } }
                            .disabled(!sync.isEnabled)
                    }
                }
                .frame(width: 26, height: 26)
                if compact {
                    CloudSyncIconButton(symbol: "folder", help: L10n.tr("Show iCloud Folder"),
                                           identifier: "sync.openFolder") {
                        if let folder = sync.folder {
                            onDismiss()
                            NSWorkspace.shared.open(folder)
                        }
                    }
                    .disabled(sync.folder == nil)
                    CloudSyncIconButton(symbol: "gearshape", help: L10n.tr("iCloud Sync Settings"),
                                           identifier: "sync.settings") {
                        onDismiss()
                        PreferencesWindowController.shared.show(tab: L10n.tr("iCloud Sync"))
                    }
                }
            }
        }
    }

    private var detail: String {
        switch health {
        case .off: return L10n.tr("Sync keeps tasks, images and sessions the same on all your Macs.")
        case .waiting(let count): return L10n.tr("iCloud is downloading \(count) files. Your tasks keep working meanwhile.")
        case .syncing, .ok, .attention:
            guard let time = sync.lastSuccessAt else { return L10n.tr("Not synced yet.") }
            return L10n.tr("Last synced \(time.syncInterfaceFormatted())")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if case .attention = health {
                CloudSyncAttentionView(onDismiss: onDismiss)
            }
            Text(detail)
                .font(.system(size: 10.5)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("sync.explanation")
            if !sync.conflicts.isEmpty {
                SyncConflictList(conflicts: compact ? Array(sync.conflicts.suffix(3)) : sync.conflicts)
            }
            if !sync.isEnabled {
                HStack {
                    Spacer(minLength: 0)
                    Button(L10n.tr("Turn On iCloud Sync…")) { confirmEnable = true }
                        .buttonStyle(CloudSyncActionButtonStyle(prominent: true))
                        .accessibilityIdentifier("sync.enable")
                }
            }
        }
        .syncEnableConfirmation(isPresented: $confirmEnable)
        .onRemarcChange(of: confirmEnable) { active in onReviewChanged(active) }
        .onDisappear { onReviewChanged(false) }
    }
}

/// The problem and the one or two actions that fix it.
struct CloudSyncAttentionView: View {
    var showsExplanation = true
    var onDismiss: () -> Void = {}
    @ObservedObject private var sync = AppServices.shared.cloudSync
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let warning = Color.remarcWarning(for: colorScheme)
        let health = sync.health
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "exclamationmark.icloud.fill").foregroundStyle(warning)
                Text(health.title).font(.system(size: 11.5, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if showsExplanation, let explanation = health.explanation {
                Text(explanation)
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 6) { actions(for: health) }
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(warning.opacity(0.10), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(warning.opacity(0.35), lineWidth: 0.75)
                .allowsHitTesting(false)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("sync.attention")
    }

    @ViewBuilder private func actions(for health: SyncHealth) -> some View {
        if case .attention(let attention) = health {
            switch attention {
            case .issue(let issue):
                if issue.needsAuthorization {
                    Button(L10n.tr("Allow Access")) { Task { await sync.authorizeAccess() } }
                } else {
                    Button(L10n.tr("Retry")) { Task { await sync.syncNow() } }
                        .accessibilityIdentifier("sync.retry")
                }
                if issue.needsICloudSettings {
                    Button(L10n.tr("iCloud Settings")) { sync.openICloudSettings() }
                }
                Button(L10n.tr("Copy diagnostic details")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(issue.diagnostic, forType: .string)
                }
            case .newerFormat:
                Button(L10n.tr("Check for Updates")) { UpdateManager.shared.checkForUpdates() }
            case .stuckDownload:
                Button(L10n.tr("Retry")) { Task { await sync.syncNow() } }
                if let folder = sync.folder {
                    Button(L10n.tr("Show iCloud Folder")) { NSWorkspace.shared.open(folder) }
                }
            case .unsynced:
                Button(L10n.tr("Retry")) { Task { await sync.syncNow() } }
                Button(L10n.tr("iCloud Settings")) { sync.openICloudSettings() }
            case .conflicts:
                Button(L10n.tr("Review")) {
                    onDismiss()
                    PreferencesWindowController.shared.show(tab: L10n.tr("iCloud Sync"))
                }
            }
        }
    }
}

/// Persistent banner at the top of the task list. Edits happen here, so this is
/// where a problem that risks conflicting edits must be impossible to miss.
/// It never blocks editing.
struct CloudSyncBanner: View {
    @ObservedObject private var sync = AppServices.shared.cloudSync

    var body: some View {
        if sync.health.needsAttention {
            CloudSyncAttentionView(showsExplanation: true)
                .padding(.horizontal, 10)
                .padding(.top, 8)
                .transition(.opacity)
        }
    }
}

/// Each entry shows the version that was not kept, with a way to switch to it.
struct SyncConflictList: View {
    let conflicts: [SyncConflict]
    @ObservedObject private var sync = AppServices.shared.cloudSync

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(conflicts) { conflict in
                SyncConflictRow(conflict: conflict, title: sync.comment(for: conflict).map(Self.title) ?? "")
            }
        }
    }

    static func title(_ comment: Comment) -> String {
        let text = comment.customTitle ?? comment.meaningfulCommentText ?? comment.type.displayName
        return text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
    }
}

struct SyncConflictRow: View {
    let conflict: SyncConflict
    let title: String
    @ObservedObject private var sync = AppServices.shared.cloudSync
    @Environment(\.colorScheme) private var colorScheme

    private var fieldName: String {
        switch conflict.field {
        case .text: return L10n.tr("Comment")
        case .title: return L10n.tr("Title")
        case .status: return L10n.tr("Status")
        case .session: return L10n.tr("Session")
        }
    }

    private var otherValue: String {
        let other = conflict.alternative
        switch conflict.field {
        case .text: return other.meaningfulCommentText ?? L10n.tr("(empty)")
        case .title: return other.customTitle ?? L10n.tr("(empty)")
        case .status: return other.status.label
        case .session:
            return AppServices.shared.comments.appState.sessions.first { $0.id == other.sessionID }?.name ?? L10n.tr("Another session")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L10n.tr("\(fieldName) of \"\(title)\""))
                .font(.system(size: 11, weight: .medium)).lineLimit(1)
            Text(conflict.localWon
                 ? L10n.tr("Kept this Mac's version. \(conflict.deviceName) had: \(otherValue)")
                 : L10n.tr("Kept the version from \(conflict.deviceName). This Mac had: \(otherValue)"))
                .font(.system(size: 10.5)).foregroundStyle(.secondary)
                .lineLimit(3)
            HStack(spacing: 6) {
                Button(L10n.tr("Keep")) { sync.keepCurrent(conflict) }
                Button(conflict.localWon ? L10n.tr("Use Other Mac's Version") : L10n.tr("Use This Mac's Version")) {
                    Task { await sync.useAlternative(conflict) }
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.remarcCardSurface(for: colorScheme), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("sync.conflict")
    }
}

/// Marks a task whose field was edited on two Macs; opens the choice in place.
struct SyncConflictBadge: View {
    let commentID: UUID
    @ObservedObject private var sync = AppServices.shared.cloudSync
    @Environment(\.colorScheme) private var colorScheme
    @State private var showing = false

    var body: some View {
        let conflicts = sync.conflicts.filter { $0.commentID == commentID }
        if !conflicts.isEmpty {
            Button { showing.toggle() } label: {
                Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.remarcWarning(for: colorScheme))
                    .background(Circle().fill(Color.remarcCardSurface(for: colorScheme)))
            }
            .buttonStyle(.plain)
            .help(L10n.tr("Edited on two Macs"))
            .accessibilityLabel(L10n.tr("Edited on two Macs"))
            .popover(isPresented: $showing, arrowEdge: .trailing) {
                SyncConflictList(conflicts: conflicts)
                    .frame(width: 280)
                    .padding(12)
            }
        }
    }
}

struct CloudSyncToolbarButton: View {
    @ObservedObject private var localization = LocalizationManager.shared
    @ObservedObject private var sync = AppServices.shared.cloudSync
    @ObservedObject private var panel = MenuBarPopoverController.shared
    @Environment(\.colorScheme) private var colorScheme
    @State private var showing = false
    @State private var isHovered = false

    private var tint: Color {
        if sync.health.needsAttention { return .remarcWarning(for: colorScheme) }
        if isHovered || showing { return .remarcPrimary(for: colorScheme) }
        return .remarcIconRest(for: colorScheme)
    }

    var body: some View {
        Button { showing.toggle() } label: {
            Group {
                if sync.isSyncing { ProgressView().controlSize(.mini) }
                else { Image(systemName: sync.isEnabled ? "icloud" : "icloud.slash").font(.system(size: 13)) }
            }
            .foregroundStyle(tint)
            .frame(width: 26, height: 26)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(isHovered || showing ? Color.remarcNeutralFill(for: colorScheme) : .clear)
            )
            .overlay(alignment: .topTrailing) {
                if sync.health.needsAttention {
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
        .background(CloudSyncPopoverAnchor(isPresented: $showing, colorScheme: colorScheme))
        .help(L10n.tr("iCloud · \(sync.health.title)"))
        .accessibilityLabel(L10n.tr("iCloud · \(sync.health.title)"))
        .accessibilityIdentifier("sync.toolbar")
        .onRemarcChange(of: panel.isVisible) { visible in
            if !visible && !panel.isDetached { showing = false }
        }
    }
}

/// Borderless header icon; the fill only appears on hover so the header stays quiet.
private struct CloudSyncIconButton: View {
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

private struct CloudSyncActionButtonStyle: ButtonStyle {
    var prominent = false
    func makeBody(configuration: Configuration) -> some View {
        CloudSyncActionButtonBody(label: configuration.label, isPressed: configuration.isPressed, prominent: prominent)
    }
}

private struct CloudSyncActionButtonBody<Label: View>: View {
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
                          ? brand.opacity(isPressed ? 0.18 : 0.10) : Color.remarcSyncButtonSurface(for: colorScheme).opacity(isEnabled ? 1 : 0.45))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(isEnabled ? (isHovered ? brand.opacity(0.45) : Color.remarcSyncBorder(for: colorScheme)) : Color.remarcSyncBorder(for: colorScheme).opacity(0.45), lineWidth: 0.75)
            }
            .contentShape(RoundedRectangle(cornerRadius: 7))
            .onHover { isHovered = $0 }
            .animation(.easeOut(duration: 0.12), value: isHovered)
            .animation(.easeOut(duration: 0.08), value: isPressed)
    }
}
