import CoreLocalization
import CoreTheme
import CoreUI
import FeatureIntegrations
import FeatureSettings
import AppKit
import KeyboardShortcuts
import SwiftUI
import UniformTypeIdentifiers

extension PreferencesView {
    enum IntegrationRowStatus {
        case installed(String)
        case warning(String)
        case absent(String)
        case inactive(String)
        case pending(String)
    }

    var mcpIntegrationsSection: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Self.sectionSpacing) {
                instantDeliverySection
                Divider()
                claudeCodeIntegrationSection
                Divider()
                codexIntegrationSection
                Divider()
                harnessIntegrationSection(.cursor)
                Divider()
                claudeDesktopSection
                Divider()
                otherMCPClientsSection
            }
            .padding(20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            mcpManager.checkDependencies()
            Task { await harnessManager.installAll() }
        }
        .task {
            await integrations.refreshPluginState()
            integrations.codexPluginState = await integrations.codexDetector.read()
            integrations.codexPluginChecked = true
            await resolveManualPaths()
        }
    }

    // MARK: - Webhooks Tab

    var webhooksSection: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Self.itemSpacing) {
                sectionHeader(
                    L10n.tr("Webhooks"),
                    description: L10n.tr("Send comment events to any service as HTTP POST requests.")
                ) {
                    addWebhookButton
                }

                CalloutView(.info, L10n.tr("Works with Zapier, Make, n8n, IFTTT, Slack incoming webhooks, or any endpoint that accepts JSON."))

                if settings.webhooks.isEmpty {
                    Text(L10n.tr("No webhooks yet. Add one to send comment events - created, resolved, deleted - to any URL, or send individual cards manually from their paperplane action."))
                        .font(.system(size: 12))
                        .foregroundStyle(.primary.opacity(0.5))
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 4)
                } else {
                    VStack(spacing: 8) {
                        ForEach(settings.webhooks) { webhook in
                            webhookRow(webhook)
                        }
                    }
                    .padding(.top, 4)
                }
            }
            .padding(24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .sheet(item: $webhookEditorState) { state in
            WebhookEditorSheet(state: state) { saved in
                if let index = settings.webhooks.firstIndex(where: { $0.id == saved.id }) {
                    settings.webhooks[index] = saved
                } else {
                    settings.webhooks.append(saved)
                }
            }
        }
        .confirmationDialog(
            L10n.tr("Delete webhook \"\(webhookPendingDelete?.name ?? "")\"?"),
            isPresented: Binding(
                get: { webhookPendingDelete != nil },
                set: { if !$0 { webhookPendingDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(L10n.tr("Delete"), role: .destructive) {
                if let pending = webhookPendingDelete {
                    settings.webhooks.removeAll { $0.id == pending.id }
                }
                webhookPendingDelete = nil
            }
            Button(L10n.tr("Cancel"), role: .cancel) {
                webhookPendingDelete = nil
            }
        }
    }

    var addWebhookButton: some View {
        textButton(L10n.tr("Add Webhook")) {
            webhookEditorState = WebhookEditorState(webhook: Webhook(), isNew: true)
        }
        .help(L10n.tr("Add a new webhook endpoint"))
    }

    func webhookRow(_ webhook: Webhook) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(webhook.name)
                        .font(.system(size: 13, weight: .medium))
                    webhookStatusIcon(webhook)
                }
                Text(webhook.url)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.primary.opacity(0.45))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            if testingWebhookIDs.contains(webhook.id) {
                ProgressView()
                    .controlSize(.small)
                    .help(L10n.tr("Sending test event"))
            } else {
                CardActionButton(icon: "paperplane", tooltip: L10n.tr("Send test event"), tint: Color.remarcPrimary(for: colorScheme)) {
                    sendTestWebhook(webhook)
                }
            }
            CardActionButton(icon: "pencil", tooltip: L10n.tr("Edit"), tint: Color.remarcPrimary(for: colorScheme)) {
                webhookEditorState = WebhookEditorState(webhook: webhook, isNew: false)
            }
            CardActionButton(icon: "trash", tooltip: L10n.tr("Delete"), tint: Color.remarcError(for: colorScheme)) {
                webhookPendingDelete = webhook
            }
            Toggle(L10n.tr("Enable \(webhook.name)"), isOn: webhookEnabledBinding(webhook))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .help(webhook.isEnabled ? L10n.tr("Disable this webhook") : L10n.tr("Enable this webhook"))
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.primary.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(.primary.opacity(0.08), lineWidth: 0.5)
        )
        .opacity(webhook.isEnabled ? 1 : 0.55)
    }

    @ViewBuilder
    func webhookStatusIcon(_ webhook: Webhook) -> some View {
        switch webhookService.lastDeliveries[webhook.id] {
        case .success(let date):
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 10))
                .foregroundStyle(Color.remarcSuccess(for: colorScheme))
                .help(L10n.tr("Delivered at \(date.interfaceFormatted(date: .omitted, time: .shortened))"))
        case .failure(let date, let message):
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10))
                .foregroundStyle(Color.remarcWarning(for: colorScheme))
                .help(L10n.tr("Failed at \(date.interfaceFormatted(date: .omitted, time: .shortened)): \(L10n.lookup(message))"))
        case nil:
            EmptyView()
        }
    }

    func webhookEnabledBinding(_ webhook: Webhook) -> Binding<Bool> {
        Binding(
            get: { settings.webhooks.first(where: { $0.id == webhook.id })?.isEnabled ?? false },
            set: { newValue in
                if let index = settings.webhooks.firstIndex(where: { $0.id == webhook.id }) {
                    settings.webhooks[index].isEnabled = newValue
                }
            }
        )
    }

    // Feedback comes from the row's status icon - the toast overlay lives in the
    // menu bar popover, which is closed whenever Settings is open.
    func sendTestWebhook(_ webhook: Webhook) {
        testingWebhookIDs.insert(webhook.id)
        Task { @MainActor in
            await webhookService.sendTest(webhook)
            testingWebhookIDs.remove(webhook.id)
        }
    }

    var claudeCodeIntegrationSection: some View {
        VStack(alignment: .leading, spacing: Self.itemSpacing) {
            sectionHeader(
                L10n.tr("Claude Code"),
                description: L10n.tr("Remarc integrates through Claude Code plugins from the \(PluginInstaller.marketplaceSlug) marketplace.")
            )

            pluginRow(
                plugin: "remarc",
                title: "remarc",
                subtitle: L10n.tr("Required. MCP server and skill for managing comments."),
                installed: integrations.pluginState.remarcInstalled,
                enabled: integrations.pluginState.remarcEnabled,
                healthy: integrations.pluginState.remarcInstalled,
                needsAction: !integrations.pluginState.remarcInstalled,
                actionTitle: L10n.tr("Install"),
                installAllowed: true,
                checked: integrations.pluginStateChecked,
                installing: integrations.installingPlugins.contains("remarc"),
                manualCommands: PluginInstaller.manualCommands(plugin: "remarc"),
                installAction: { integrations.installPlugin("remarc") }
            )

            claudeCodeUpdateRow

            Divider()
                .padding(.vertical, 4)

            pluginRow(
                plugin: "remarc-hooks",
                title: "remarc-hooks",
                subtitle: L10n.tr("Optional, experimental. Auto-links Claude Code sessions to Remarc and injects open comments at session start."),
                installed: integrations.pluginState.remarcHooksInstalled,
                enabled: integrations.pluginState.remarcHooksEnabled,
                healthy: integrations.pluginState.remarcHooksInstalled,
                needsAction: !integrations.pluginState.remarcHooksInstalled,
                actionTitle: L10n.tr("Install"),
                installAllowed: integrations.pluginState.remarcInstalled,
                checked: integrations.pluginStateChecked,
                installing: integrations.installingPlugins.contains("remarc-hooks"),
                manualCommands: PluginInstaller.manualCommands(plugin: "remarc-hooks"),
                installAction: { integrations.installPlugin("remarc-hooks") }
            )

            if integrations.pluginState.remarcHooksInstalled {
                hooksSettingsRows
            }
        }
    }

    /// The remarc plugin's update affordance: one callout holding the exact
    /// update command (always copyable - Claude Code owns its own update
    /// lifecycle, so the app never runs it) and a pointer to auto-update. It
    /// reads as a warning when the installed plugin is older than the version
    /// this app vendored, otherwise a neutral note.
    @ViewBuilder
    var claudeCodeUpdateRow: some View {
        if integrations.pluginStateChecked && integrations.pluginState.remarcInstalled {
            let updateCommand = PluginInstaller.updateCommand(plugin: "remarc")
            let installed = integrations.pluginState.remarcVersion
            let behind = PluginInstaller.updateAvailable(
                installedVersion: installed,
                bundledVersion: BundledPluginVersion.remarc
            )
            let heading: String = {
                if behind, let installed {
                    return L10n.tr("Update available (\(installed) → \(BundledPluginVersion.remarc))")
                }
                if let installed, PluginInstaller.isNumericVersion(installed) {
                    return L10n.tr("Up to date (\(installed))")
                }
                return L10n.tr("Update remarc")
            }()
            CalloutView(behind ? .warning : .info, heading) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .center, spacing: 8) {
                        Text(updateCommand)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.primary.opacity(0.7))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        CardActionButton(
                            icon: integrations.copiedPluginCommands == "remarc-update" ? "checkmark" : "doc.on.doc",
                            tooltip: L10n.tr("Copy update command"),
                            tint: Color.remarcPrimary(for: colorScheme)
                        ) {
                            integrations.copyCommands(updateCommand, key: "remarc-update")
                        }
                    }
                    Text(L10n.tr("Updates aren't automatic for this marketplace. Turn them on once: run /plugin, open Marketplaces, select remarc, then Enable auto-update."))
                        .font(.system(size: 11))
                        .foregroundStyle(.primary.opacity(0.45))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 2)
            }
        }
    }

    var instantDeliverySection: some View {
        VStack(alignment: .leading, spacing: Self.itemSpacing) {
            sectionHeader(
                L10n.tr("Instant delivery"),
                description: L10n.tr("Let a live, paired agent receive a newly saved comment without waiting for the next prompt.")
            )

            toggleRow(
                L10n.tr("Allow comments to wake paired agent sessions"),
                isOn: $settings.wakeOnCommentEnabled
            )

            settingsHint(
                L10n.tr("Send Instantly appears only when the selected Remarc session has a live pairing."),
                tint: .primary.opacity(0.35)
            )

            if settings.wakeOnCommentEnabled && !settings.wakeHooksAvailable {
                settingsHint(
                    L10n.tr("No live pairing is currently reachable. Pair from a supported agent session, then return to Remarc."),
                    tint: .primary.opacity(0.35)
                )
            }

            Link(
                L10n.tr("Set up OMP instant delivery"),
                destination: URL(string: "https://github.com/metedata/remarc-agent-plugins/blob/main/docs/integrations/omp.md")!
            )
            .font(.system(size: 11))
        }
    }

    var codexIntegrationSection: some View {
        VStack(alignment: .leading, spacing: Self.itemSpacing) {
            sectionHeader(
                L10n.tr("Codex"),
                description: L10n.tr("Remarc integrates through a Codex plugin from the \(CodexPluginInstaller.marketplaceSlug) marketplace.")
            )

            pluginRow(
                plugin: "codex-remarc",
                title: "remarc",
                subtitle: L10n.tr("MCP server and skill for managing comments from Codex."),
                installed: integrations.codexPluginState.remarcInstalled,
                enabled: integrations.codexPluginState.remarcEnabled,
                healthy: codexHealthy,
                needsAction: !codexHealthy,
                actionTitle: integrations.codexPluginState.remarcInstalled ? L10n.tr("Repair") : L10n.tr("Install"),
                installAllowed: true,
                checked: integrations.codexPluginChecked,
                installing: integrations.codexInstalling,
                manualCommands: CodexPluginInstaller.manualCommands(),
                installAction: { integrations.installCodexPlugin() }
            )

            if let error = integrations.codexInstallError {
                settingsHint(error, icon: "exclamationmark.triangle.fill", tint: Color.remarcWarning(for: colorScheme))
            }
        }
    }

    var codexHealthy: Bool {
        integrations.codexPluginState.remarcInstalled
            && integrations.codexPluginState.remarcEnabled
            && (integrations.codexPluginState.remarcVersion.map(CodexPluginInstaller.isNumericVersion) ?? false)
    }



    func pluginRowStatus(checked: Bool, installed: Bool, enabled: Bool, healthy: Bool) -> IntegrationRowStatus {
        if !checked { return .pending(L10n.tr("Checking")) }
        if installed && enabled && healthy { return .installed(L10n.tr("Installed")) }
        if installed && enabled { return .warning(L10n.tr("Needs repair")) }
        if installed { return .warning(L10n.tr("Installed (disabled)")) }
        return .inactive(L10n.tr("Not installed"))
    }

    /// One row per plugin: name + status, description, and - while
    /// `needsAction` - the exact commands the action button runs, a copy
    /// fallback, and the button itself. `installAllowed` hides the button
    /// for remarc-hooks until the required remarc plugin is present.
    @ViewBuilder
    func pluginRow(
        plugin: String,
        title: String,
        subtitle: String,
        installed: Bool,
        enabled: Bool,
        healthy: Bool,
        needsAction: Bool,
        actionTitle: String,
        installAllowed: Bool,
        checked: Bool,
        installing: Bool,
        manualCommands: String,
        installAction: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(title)
                        .font(.system(size: 13, weight: .medium))
                    integrationStatusLabel(pluginRowStatus(checked: checked, installed: installed, enabled: enabled, healthy: healthy))
                }
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.primary.opacity(0.45))
                    .fixedSize(horizontal: false, vertical: true)
                if checked && needsAction && !manualCommands.isEmpty {
                    Text(manualCommands)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.primary.opacity(0.55))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 2)
                }
                if let error = integrations.pluginErrors[plugin] {
                    settingsHint(error, icon: "exclamationmark.triangle.fill", tint: Color.remarcWarning(for: colorScheme))
                }
            }

            Spacer(minLength: 8)

            if installing {
                ProgressView()
                    .controlSize(.small)
                    .help(L10n.tr("Installing - the first run clones the marketplace and can take a minute"))
            } else if checked && needsAction {
                if !manualCommands.isEmpty {
                    CardActionButton(
                        icon: integrations.copiedPluginCommands == plugin ? "checkmark" : "doc.on.doc",
                        tooltip: L10n.tr("Copy \(actionTitle.lowercased()) commands"),
                        tint: Color.remarcPrimary(for: colorScheme)
                    ) {
                        integrations.copyCommands(manualCommands, key: plugin)
                    }
                }
                if installAllowed {
                    textButton(actionTitle) {
                        installAction()
                    }
                    .help(L10n.tr("Runs the commands shown via the CLI"))
                }
            }
        }
    }

    /// One hint for the whole session-lifecycle group: how sessions start (only
    /// worth saying when auto-create is off) and what an agent quitting does.
    var sessionLifecycleHint: String {
        let ending = L10n.tr("Quitting an agent only unlinks its session - the session and its comments stay.")
        guard !settings.claudeCodeAutoCreateSession else { return ending }
        return L10n.tr("Create sessions manually with the remarc_create_session MCP tool. ") + ending
    }

    var hooksSettingsRows: some View {
        VStack(alignment: .leading, spacing: Self.itemSpacing) {
            toggleRow(L10n.tr("Auto-create session for new conversations"), isOn: $settings.claudeCodeAutoCreateSession)

            settingsHint(sessionLifecycleHint, tint: .primary.opacity(0.35))

            settingsRow(L10n.tr("When a conversation is cleared")) {
                Picker("", selection: $settings.claudeCodeSessionEndBehavior) {
                    ForEach(ClaudeCodeSessionEndBehavior.allCases, id: \.self) { behavior in
                        Text(behavior.label).tag(behavior)
                    }
                }
                .labelsHidden()
                .frame(width: 200)
            }
        }
    }







    func harnessIntegrationSection(_ harness: SkillInstaller.Harness) -> some View {
        VStack(alignment: .leading, spacing: Self.itemSpacing) {
            sectionHeader(
                harness.rawValue,
                description: harnessDescription(harness)
            )

            harnessToggleRow(for: harness)

            harnessStatusRow(
                label: L10n.tr("Skill"),
                state: skillStatus(for: harness)
            )
            harnessStatusRow(
                label: L10n.tr("MCP server"),
                state: mcpStatus(for: harness)
            )
        }
    }

    func harnessDescription(_ harness: SkillInstaller.Harness) -> String {
        switch harness {
        case .claudeCode:
            return L10n.tr("Installs the Remarc skill and registers the shared MCP server with Claude Code.")
        case .codex:
            return L10n.tr("Installs the Remarc skill and registers the shared MCP server with Codex.")
        case .cursor:
            return L10n.tr("Installs the Remarc skill and registers the shared MCP server with Cursor.")
        }
    }

    func skillStatus(for harness: SkillInstaller.Harness) -> IntegrationRowStatus {
        guard let status = harnessManager.statuses[harness]?.skill else {
            return harnessManager.isWorking ? .pending(L10n.tr("Checking")) : .pending(L10n.tr("Not checked yet"))
        }

        switch status {
        case .installed, .updated, .unchanged:
            return .installed(L10n.tr("Installed"))
        case .notInstalled:
            return .inactive(L10n.tr("Off"))
        case .skippedHarnessAbsent:
            return .absent(L10n.tr("Not detected"))
        case .failed(let message):
            return .warning(L10n.tr("Could not install: \(message)"))
        }
    }

    func mcpStatus(for harness: SkillInstaller.Harness) -> IntegrationRowStatus {
        if harness == .claudeCode {
            if mcpManager.isEnabled {
                return .installed(L10n.tr("Installed"))
            }
            if mcpManager.nodeStatus == .unchecked || mcpManager.claudeStatus == .unchecked {
                return harnessManager.isWorking ? .pending(L10n.tr("Checking")) : .pending(L10n.tr("Not checked yet"))
            }
            if mcpManager.nodeStatus == .notFound {
                return .warning(L10n.tr("Node.js not found"))
            }
            if mcpManager.claudeStatus == .notFound {
                return .warning(L10n.tr("Claude Code not found"))
            }
            if let status = harnessManager.statuses[.claudeCode], status.mcp == .notInstalled {
                return .inactive(L10n.tr("Off"))
            }
            return .warning(L10n.tr("Not registered"))
        }

        guard let status = harnessManager.statuses[harness]?.mcp else {
            return harnessManager.isWorking ? .pending(L10n.tr("Checking")) : .pending(L10n.tr("Not checked yet"))
        }

        switch status {
        case .installed:
            return .installed(L10n.tr("Installed"))
        case .notInstalled:
            return .inactive(L10n.tr("Off"))
        case .skippedHarnessAbsent:
            return .absent(L10n.tr("Not detected"))
        case .skippedNoNode:
            return .warning(L10n.tr("Node.js not found"))
        case .failed(let message):
            return .warning(message)
        }
    }

    func harnessToggleRow(for harness: SkillInstaller.Harness) -> some View {
        let isUpdating = integrations.pendingHarnesses.contains(harness)
            || harnessManager.workingHarnesses.contains(harness)
            || harnessManager.isWorking
        let isUnavailable = isHarnessUnavailable(harness)

        return settingsRow(L10n.tr("Enable integration")) {
            Toggle(L10n.tr("Enable \(harness.rawValue) integration"), isOn: Binding(
                get: { isHarnessEnabled(harness) },
                set: { enabled in
                    integrations.beginSetHarness(harness, enabled: enabled)
                }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
            .disabled(isUnavailable)
            .allowsHitTesting(!isUpdating && !isUnavailable)
            .help("\(isHarnessEnabled(harness) ? L10n.tr("Disable") : L10n.tr("Enable")) \(harness.rawValue)")
        }
    }

    func isHarnessUnavailable(_ harness: SkillInstaller.Harness) -> Bool {
        guard let status = harnessManager.statuses[harness] else { return false }
        return status.skill == .skippedHarnessAbsent
            && status.mcp == .skippedHarnessAbsent
    }

    func isHarnessEnabled(_ harness: SkillInstaller.Harness) -> Bool {
        guard let status = harnessManager.statuses[harness] else {
            return harness == .claudeCode && mcpManager.isEnabled
        }
        return skillIsInstalled(status.skill)
            || status.mcp.isInstalled
    }

    func skillIsInstalled(_ result: SkillInstaller.Result) -> Bool {
        switch result {
        case .installed, .updated, .unchanged:
            return true
        case .notInstalled, .skippedHarnessAbsent, .failed:
            return false
        }
    }





    func harnessStatusRow(
        label: String,
        state: IntegrationRowStatus
    ) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 13))
            Spacer(minLength: 8)
            integrationStatusLabel(state)
        }
    }

    func integrationStatusLabel(_ state: IntegrationRowStatus) -> some View {
        let icon: String
        let tint: Color
        let text: String

        switch state {
        case .installed(let message):
            icon = "checkmark.circle.fill"
            tint = Color.remarcSuccess(for: colorScheme)
            text = message
        case .warning(let message):
            icon = "exclamationmark.triangle.fill"
            tint = Color.remarcWarning(for: colorScheme)
            text = message
        case .absent(let message):
            icon = "slash.circle.fill"
            tint = .secondary
            text = message
        case .inactive(let message):
            icon = "circle"
            tint = .secondary
            text = message
        case .pending(let message):
            icon = "clock.fill"
            tint = Color.remarcInfo(for: colorScheme)
            text = message
        }

        return HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundStyle(tint)
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(.primary.opacity(0.6))
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    var claudeDesktopSection: some View {
        let hasNode = mcpManager.resolvedNodePath != nil
        let hasMCPPath = mcpManager.resolvedMCPPath != nil

        return VStack(alignment: .leading, spacing: Self.itemSpacing) {
            sectionHeader(
                L10n.tr("Claude Desktop"),
                description: L10n.tr("You can also use Remarc with the Claude Desktop app. Add this snippet to your config file (Claude > Settings > Developer > Edit Config), then restart Claude Desktop.")
            )

            if hasNode && hasMCPPath {
                claudeDesktopSnippet

                CalloutView(.info, L10n.tr("Tip: After connecting, go to Customize > Connectors > Remarc and set permissions to \"Always allow\" to avoid constant approval prompts."))
            } else {
                CalloutView(.warning, L10n.tr("Node.js is required for Claude Desktop integration. Install it from nodejs.org, then relaunch Remarc."))
            }
        }
    }

    var claudeDesktopSnippet: some View {
        let snippet = CursorMCPInstaller.snippet(
            nodePath: mcpManager.resolvedNodePath,
            mcpPath: mcpManager.resolvedMCPPath
        )

        return manualMCPSnippet(
            label: L10n.tr("Claude Desktop config"),
            body: snippet,
            copied: $claudeDesktopCopied
        )
    }

    var otherMCPClientsSection: some View {
        let jsonSnippet = CursorMCPInstaller.snippet(nodePath: manualNodePath, mcpPath: manualMCPPath)
        let skillContent = SkillInstaller.bundledSkillContent() ?? L10n.tr("Bundled SKILL.md resource not found.")

        return VStack(alignment: .leading, spacing: Self.itemSpacing) {
            sectionHeader(
                L10n.tr("Other MCP clients"),
                description: L10n.tr("Use these snippets to install Remarc in any other MCP-compatible agent harness, including OpenCode, Continue, Windsurf, or any client that takes JSON config.")
            )

            if isResolvingManualPaths || (manualNodePath == nil && !manualNodeResolutionFailed) {
                settingsHint(L10n.tr("Resolving Node.js..."), tint: Color.remarcInfo(for: colorScheme))
            } else if manualNodeResolutionFailed {
                HStack(spacing: 8) {
                    settingsHint(L10n.tr("Node.js not found on PATH. Install Node 18+ from nodejs.org, then click Retry."), icon: "exclamationmark.triangle.fill", tint: Color.remarcWarning(for: colorScheme))
                    Link(L10n.tr("Help"), destination: URL(string: "https://nodejs.org/")!)
                    Button(L10n.tr("Retry")) {
                        Task { await resolveManualPaths() }
                    }
                    .font(.system(size: 11))
                }
            } else if manualMCPPathMissing {
                settingsHint(L10n.tr("Remarc MCP server bundle not found. Rebuild and relaunch Remarc."), icon: "exclamationmark.triangle.fill", tint: Color.remarcWarning(for: colorScheme))
            }

            Text(L10n.tr("For UI-only clients, paste the JSON snippet into your client's MCP server settings."))
                .font(.system(size: 11))
                .foregroundStyle(.primary.opacity(0.7))
                .fixedSize(horizontal: false, vertical: true)

            manualMCPSnippet(
                label: L10n.tr("MCP server config (JSON)"),
                body: jsonSnippet,
                copied: $manualJSONCopied,
                isCopyDisabled: manualSnippetCopyDisabled
            )

            manualMCPSnippet(
                label: L10n.tr("Skill content (SKILL.md)"),
                body: skillContent,
                copied: $manualSkillCopied
            )
        }
    }

    var manualSnippetCopyDisabled: Bool {
        isResolvingManualPaths || (manualNodePath == nil && !manualNodeResolutionFailed)
    }

    func resolveManualPaths() async {
        isResolvingManualPaths = true
        defer { isResolvingManualPaths = false }

        let node = await BundledMCP.nodePath()
        let mcpPath = BundledMCP.mcpServerPath

        manualNodePath = node
        manualMCPPath = mcpPath
        manualNodeResolutionFailed = node == nil
        manualMCPPathMissing = mcpPath == nil
    }

    func manualMCPSnippet(
        label: String,
        body: String,
        copied: Binding<Bool>,
        isCopyDisabled: Bool = false
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.primary.opacity(0.7))
            Text(body)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.primary.opacity(0.7))
                .textSelection(.enabled)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(.primary.opacity(0.04))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(.primary.opacity(0.1), lineWidth: 0.5)
                )
                .overlay(alignment: .topTrailing) {
                    Button {
                        copy(body, copied: copied)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: copied.wrappedValue ? "checkmark" : "doc.on.doc")
                                .font(.system(size: 10))
                            Text(copyButtonTitle(copied: copied.wrappedValue, disabled: isCopyDisabled))
                                .font(.system(size: 11))
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(copied.wrappedValue ? Color.remarcSuccess(for: colorScheme) : .secondary)
                    .disabled(isCopyDisabled)
                    .padding(4)
                }
        }
    }

    func copyButtonTitle(copied: Bool, disabled: Bool) -> String {
        if copied { return L10n.tr("Copied") }
        return disabled ? L10n.tr("Resolving Node.js...") : L10n.tr("Copy")
    }

    func copy(_ text: String, copied: Binding<Bool>) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        copied.wrappedValue = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            copied.wrappedValue = false
        }
    }


}
