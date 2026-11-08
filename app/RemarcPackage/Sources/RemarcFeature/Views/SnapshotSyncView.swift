import AppKit
import SwiftUI

struct SnapshotSyncView: View {
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
                    Label("iCloud Sync", systemImage: "icloud").font(.system(size: 19, weight: .semibold))
                    Text("Publish and apply directly from the task panel. This page keeps your setup, history, and recovery backups.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                GroupBox {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack {
                            Text("This Mac").fontWeight(.medium)
                            Spacer()
                            TextField("e.g. Office Mac", text: $sync.deviceName)
                                .textFieldStyle(.roundedBorder).frame(maxWidth: 260)
                                .accessibilityIdentifier("sync.deviceName")
                        }
                        Toggle("iCloud snapshots", isOn: Binding(
                            get: { sync.isEnabled },
                            set: { if $0 { confirmEnable = true } else { sync.disconnect() } }
                        )).toggleStyle(.switch).accessibilityIdentifier("sync.enable")
                        HStack {
                            Text("Storage location").fontWeight(.medium)
                            Spacer()
                            Text("iCloud Drive/Remarc").foregroundStyle(.secondary)
                        }
                        HStack {
                            Text("Directory access").fontWeight(.medium)
                            Spacer()
                            Text(!sync.isEnabled ? "Not enabled" : sync.folder != nil ? "Accessible" : "Not verified")
                                .foregroundStyle(.secondary)
                                .accessibilityIdentifier("sync.connection")
                        }
                        Text("Directory access does not confirm a cloud upload. Upload status is shown separately below.")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                        if let folder = sync.folder {
                            Button("Show in Finder") { NSWorkspace.shared.open(folder) }.font(.system(size: 11))
                        }
                    }.padding(10)
                }.disabled(sync.isBusy)

                GroupBox {
                    SnapshotSyncControls(compact: false).padding(10)
                }

                if sync.isEnabled && sync.folder != nil {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("iCloud versions discovered on this Mac").font(.system(size: 14, weight: .semibold))
                        Text("A version appearing here is not proof that its archive has finished uploading. Applying downloads and verifies the complete archive.")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                        if sync.versions.isEmpty {
                            Text("No versions discovered yet. Publish from your first Mac, then check on your other Mac.")
                                .font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                        ForEach(sync.versions) { version in
                            HStack(alignment: .top) {
                                VStack(alignment: .leading, spacing: 4) {
                                    SnapshotVersionLabel(version: version)
                                    Text("\(version.commentCount) tasks · \(version.imageCount) images")
                                        .font(.system(size: 11)).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if sync.currentVersion?.id == version.id && !sync.hasLocalChanges {
                                    Label("Current", systemImage: "checkmark.circle")
                                        .font(.system(size: 11)).foregroundStyle(.secondary)
                                } else {
                                    Button("Use This Version") { applyingBackup = false; versionToApply = version }
                                        .accessibilityIdentifier("sync.apply.\(version.shortID)")
                                }
                            }.padding(12)
                                .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
                        }
                    }.disabled(sync.isBusy)
                }
                if !sync.backups.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Local recovery backups").font(.system(size: 14, weight: .semibold))
                        Text("A complete local backup is saved before every replacement. Restoring also backs up the current data.")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                        ForEach(sync.backups) { version in
                            HStack {
                                SnapshotVersionLabel(version: version)
                                Spacer()
                                Button("Restore…") { applyingBackup = true; versionToApply = version }
                            }
                        }
                        Button("Show Backups in Finder") {
                            NSWorkspace.shared.open(remarcAppSupportURL.appendingPathComponent("snapshot-backups"))
                        }.font(.system(size: 11))
                    }.disabled(sync.isBusy)
                }
            }.padding(28)
        }
        .task { await sync.checkIfNeeded() }
        .onRemarcChange(of: versionToApply != nil || confirmEnable) { active in sync.holdAutomaticChecks(active, token: reviewToken) }
        .onDisappear { sync.holdAutomaticChecks(false, token: reviewToken) }
        .alert("Replace local tasks?", isPresented: Binding(get: { versionToApply != nil }, set: { if !$0 { versionToApply = nil } })) {
            Button("Cancel", role: .cancel) { versionToApply = nil }
            Button("Back Up and Apply", role: .destructive) {
                if let version = versionToApply {
                    let backup = applyingBackup
                    Task { await sync.apply(version, isBackup: backup) }
                }
                versionToApply = nil
            }.disabled(sync.isBusy)
        } message: {
            if let version = versionToApply { Text(SnapshotVersionLabel.replacementMessage(version)) }
        }
        .alert("Enable iCloud snapshots?", isPresented: $confirmEnable) {
            Button("Cancel", role: .cancel) {}
            Button("Enable iCloud Snapshots") { Task { await sync.enable() } }
        } message: { Text("Remarc will create or reuse iCloud Drive/Remarc. Publishing and applying stay manual.") }
    }
}

struct SnapshotVersionLabel: View {
    let version: SnapshotVersion
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(version.deviceName).font(.system(size: 12, weight: .medium))
            Text(version.contentModifiedAt.map { "Content: \($0.formatted(date: .abbreviated, time: .standard))" } ?? "Content time not recorded")
            Text("Saved: \(version.createdAt.formatted(date: .abbreviated, time: .standard))")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }
    static func replacementMessage(_ version: SnapshotVersion) -> String {
        "Use the data from \(version.deviceName)? Content time: \(version.contentModifiedAt.map { $0.formatted(date: .abbreviated, time: .standard) } ?? "not recorded"). This replaces all local tasks, including additions and deletions. Your current data will be backed up first."
    }
}

/// Both surfaces render this same state and invoke the same operations.
/// Publishing/checking/recovery never navigates to Settings implicitly.
struct SnapshotSyncControls: View {
    let compact: Bool
    @ObservedObject private var sync = SnapshotSyncManager.shared
    @Environment(\.colorScheme) private var colorScheme
    @State private var choosing = false
    @State private var versionToApply: SnapshotVersion?
    @State private var confirmPublish = false
    @State private var confirmEnable = false
    @State private var detailsExpanded = false
    @State private var reviewToken = UUID()

    private var tone: Color {
        switch sync.presentation.tone {
        case .success: return Color.remarcSuccess(for: colorScheme)
        case .warning: return Color.remarcWarning(for: colorScheme)
        case .error: return Color.remarcError(for: colorScheme)
        case .neutral: return Color.remarcPrimary(for: colorScheme)
        }
    }
    private var primaryTitle: String {
        switch sync.presentation.action {
        case .enable: return "Enable"
        case .publish: return "Publish This Mac"
        case .retry: return "Retry"
        case .authorize: return "Authorize"
        case .check: return "Check"
        case .apply: return "Apply to This Mac"
        case .choose: return "Choose"
        }
    }

    private var canChooseData: Bool {
        sync.isEnabled && sync.folder != nil && !sync.isBusy && sync.publication?.isPending != true
            && !sync.cloudTransfer.blocksReplacement && (sync.issue == nil || sync.presentation.action == .choose)
    }
    private var canApplyCloud: Bool {
        canChooseData && !sync.cloudHeads.isEmpty && (sync.comparison == .receive || sync.comparison == .choose)
    }
    private var canPublishLocal: Bool {
        canChooseData && (sync.comparison == .publish || sync.comparison == .choose || sync.presentation.action == .choose)
    }
    private var cloudStatus: String {
        if !sync.isEnabled { return "Enable sync to check iCloud data." }
        if sync.folder == nil { return "Check iCloud access first." }
        if sync.publication?.isPending == true { return "Showing the last confirmed cloud data." }
        if sync.cloudTransfer.blocksReplacement { return "Check the transfer status before applying cloud data." }
        if sync.cloudHeads.isEmpty { return "Nothing published yet." }
        switch sync.comparison {
        case .same: return "Matches this Mac."
        case .publish: return "Already applied on this Mac."
        case .receive: return "Cloud changes are ready to apply."
        case .choose: return "Different data · choose which copy to keep."
        }
    }
    private var localStatus: String {
        if !sync.isEnabled { return "Stored on this Mac." }
        if sync.publication?.isPending == true {
            return sync.hasSavedCurrentSnapshot ? "Saved · cloud upload is not confirmed." : "New edits made · finish the pending upload first."
        }
        if sync.folder == nil { return "Check iCloud to compare your data." }
        if sync.cloudTransfer.blocksReplacement { return "Local data is kept while iCloud updates." }
        switch sync.comparison {
        case .same: return "Up to date with iCloud."
        case .publish: return "Unpublished changes · ready to publish."
        case .receive: return "Cloud changes have not been applied here."
        case .choose: return "Local and cloud data differ."
        }
    }
    private var needsRecovery: Bool {
        [.enable, .authorize, .retry].contains(sync.presentation.action)
    }
    private var showOperationStatus: Bool {
        !sync.isEnabled || sync.folder == nil || sync.isBusy || sync.issue != nil || sync.publication?.isPending == true
    }

    private var cloudRecovery: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let issue = sync.issue, sync.isEnabled {
                Text(issue.recovery).font(.system(size: compact ? 10 : 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    if issue.needsAuthorization && sync.presentation.action != .authorize {
                        Button("Authorize Access…") { Task { await sync.authorizeAccess() } }
                    }
                    if issue.needsICloudSettings {
                        Button(issue.kind == .quota ? "Manage iCloud Storage…" : "Open iCloud Settings…") { sync.openICloudSettings() }
                    }
                }.font(.system(size: compact ? 10 : 12)).disabled(sync.isBusy)
                DisclosureGroup("Diagnostic Details", isExpanded: $detailsExpanded) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(issue.diagnostic).font(.system(size: compact ? 9 : 11, design: .monospaced))
                            .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        Button("Copy Details") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(issue.diagnostic, forType: .string)
                        }
                    }
                }.font(.system(size: compact ? 10 : 11))
            }
            if let message = sync.uploadMessage, sync.publication?.isPending == true {
                Text(message).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            if let notice = sync.notice { Text(notice).font(.system(size: compact ? 10 : 12)).foregroundStyle(.secondary) }
        }
    }
    private var cloudChoices: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()
            Text("Choose the complete state to keep").font(.system(size: 11, weight: .semibold))
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(sync.cloudHeads) { version in
                        HStack(alignment: .top) {
                            SnapshotVersionLabel(version: version)
                            Spacer(minLength: 4)
                            Button("Use") { versionToApply = version }
                                .disabled(sync.isBusy)
                                .accessibilityIdentifier("sync.quickApply.\(version.shortID)")
                        }
                    }
                }
            }.frame(maxHeight: compact ? 130 : 220)
            HStack {
                Button("Use Local Instead…") { confirmPublish = true }.disabled(sync.isBusy)
                Button("Cancel") { choosing = false }
            }.font(.system(size: 11))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("iCloud Data", systemImage: "icloud").font(.system(size: 12, weight: .semibold))
                    Spacer()
                    Menu {
                        Button("Sync Settings and History…") { PreferencesWindowController.shared.show(tab: "iCloud Sync") }
                        if let folder = sync.folder { Button("Show in Finder") { NSWorkspace.shared.open(folder) } }
                        if sync.isEnabled {
                            Button("Authorize iCloud Drive Access…") { Task { await sync.authorizeAccess() } }
                            Button("Open iCloud Settings…") { sync.openICloudSettings() }
                        }
                    } label: { Image(systemName: "ellipsis") }
                    .menuStyle(.borderlessButton).fixedSize()
                    .accessibilityIdentifier("sync.more")
                }
                dataRow("Source", value: !sync.isEnabled ? "Not enabled" : sync.folder == nil ? "Not checked" : sync.cloudSource)
                dataRow("Published", value: sync.cloudData.map { contentTime($0.createdAt) } ?? "—")
                    .help("The time recorded for this publication. iCloud delivery may finish later.")
                dataRow("Transfer", value: sync.cloudTransferTitle)
                    .help("The latest snapshot files' transfer state reported on this Mac. Other Macs may discover changes later.")
                Text(cloudStatus).font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("sync.cloudStatus")
                if showOperationStatus {
                    HStack(alignment: .top, spacing: 7) {
                        if sync.isBusy { ProgressView().controlSize(.mini) }
                        else { Image(systemName: sync.issue != nil ? "exclamationmark.circle" : "info.circle").foregroundStyle(tone) }
                        Text(sync.summary).font(.system(size: 12, weight: .medium))
                            .foregroundStyle(tone).fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("sync.status")
                    }
                }
                HStack {
                    if needsRecovery {
                        Button(primaryTitle, action: primaryAction)
                            .disabled(sync.isBusy)
                            .accessibilityIdentifier("sync.primary")
                    } else {
                        Button(sync.cloudHeads.count > 1 ? "Choose Cloud Data…" : "Apply to This Mac…", action: applyCloud)
                            .disabled(!canApplyCloud)
                            .accessibilityIdentifier("sync.applyCloud")
                    }
                    if sync.isEnabled {
                        Button("Check Updates") { Task { await sync.check() } }
                            .disabled(sync.isBusy)
                            .accessibilityIdentifier("sync.check")
                    }
                    Spacer(minLength: 0)
                }.controlSize(.small)
                if let checked = sync.lastCheckedAt {
                    Text("Last checked: \(contentTime(checked))")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                        .accessibilityIdentifier("sync.lastChecked")
                }
                if sync.issue != nil || sync.publication?.isPending == true || sync.notice != nil { cloudRecovery }
                if choosing { cloudChoices }
            }.padding(12)
                .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))

            VStack(alignment: .leading, spacing: 10) {
                Label("Local Data", systemImage: "internaldrive").font(.system(size: 12, weight: .semibold))
                dataRow("Updated", value: contentTime(sync.localUpdatedAt))
                Text(localStatus).font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("sync.localStatus")
                HStack {
                    Button("Publish to iCloud…", action: publishLocal)
                        .disabled(!canPublishLocal)
                        .accessibilityIdentifier("sync.publish")
                    Spacer(minLength: 0)
                }.controlSize(.small)
            }.padding(12)
                .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
        }
        .alert("Replace local tasks?", isPresented: Binding(get: { versionToApply != nil }, set: { if !$0 { versionToApply = nil } })) {
            Button("Cancel", role: .cancel) { versionToApply = nil }
            Button("Back Up and Apply", role: .destructive) {
                if let version = versionToApply { Task { await sync.apply(version) } }
                versionToApply = nil; choosing = false
            }.disabled(sync.isBusy)
        } message: {
            if let version = versionToApply { Text(SnapshotVersionLabel.replacementMessage(version)) }
        }
        .alert("Publish to iCloud?", isPresented: $confirmPublish) {
            Button("Cancel", role: .cancel) {}
            Button("Publish and Replace") { choosing = false; Task { await sync.publish(allowReplacingRemote: true) } }.disabled(sync.isBusy)
        } message: {
            Text("Replace the current cloud data with all data from \(sync.deviceName), including deletions? Previous copies remain in history.")
        }
        .alert("Enable iCloud snapshots?", isPresented: $confirmEnable) {
            Button("Cancel", role: .cancel) {}
            Button("Enable iCloud Snapshots") { Task { await sync.enable() } }
        } message: { Text("Remarc will create or reuse iCloud Drive/Remarc. Publishing and applying stay manual.") }
        .onRemarcChange(of: choosing || versionToApply != nil || confirmPublish || confirmEnable) { active in
            sync.holdAutomaticChecks(active, token: reviewToken)
        }
        .task { await sync.observeCloud() }
        .onDisappear { sync.holdAutomaticChecks(false, token: reviewToken) }
    }

    private func contentTime(_ date: Date?) -> String {
        date?.formatted(date: .abbreviated, time: .standard) ?? "Not recorded"
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
    private func primaryAction() {
        switch sync.presentation.action {
        case .enable: confirmEnable = true
        case .publish: publishLocal()
        case .retry: Task { await sync.retry() }
        case .authorize: Task { await sync.authorizeAccess() }
        case .check: Task { await sync.check() }
        case .apply: applyCloud()
        case .choose: choosing.toggle()
        }
    }
}

struct SnapshotSyncToolbarButton: View {
    @ObservedObject private var sync = SnapshotSyncManager.shared
    @ObservedObject private var panel = MenuBarPopoverController.shared
    @Environment(\.colorScheme) private var colorScheme
    @State private var showing = false

    private var tint: Color {
        switch sync.presentation.tone {
        case .success: return .remarcSuccess(for: colorScheme)
        case .warning: return .remarcWarning(for: colorScheme)
        case .error: return .remarcError(for: colorScheme)
        case .neutral: return .remarcPrimary(for: colorScheme)
        }
    }
    var body: some View {
        Button { showing.toggle() } label: {
            VStack(spacing: 1) {
                Image(systemName: sync.issue != nil ? "icloud.badge.exclamationmark" : "icloud")
                    .font(.system(size: 12))
                Text(sync.shortStatus).font(.system(size: 8, weight: .medium))
            }.foregroundStyle(tint).frame(width: 38, height: 28).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("iCloud · \(sync.summary)")
        .accessibilityLabel("iCloud · \(sync.shortStatus)")
        .accessibilityIdentifier("sync.toolbar")
        .popover(isPresented: $showing, arrowEdge: .top) {
            ScrollView {
                SnapshotSyncControls(compact: true).padding(16)
            }.frame(width: 340).frame(maxHeight: 510)
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
