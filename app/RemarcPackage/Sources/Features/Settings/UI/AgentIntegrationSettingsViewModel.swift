import CoreLocalization
import FeatureIntegrations
import FeatureSettings
import AppKit
import Combine

/// Installation progress and commands for the agent settings pane. SwiftUI
/// binds to state and invokes actions; CLI calls and retries live here.
@MainActor
final class AgentIntegrationSettingsViewModel: ObservableObject {
    private let settings: SettingsManager
    private let harnessManager: HarnessIntegrationManager

    init(settings: SettingsManager, harnessManager: HarnessIntegrationManager) {
        self.settings = settings
        self.harnessManager = harnessManager
    }

    @Published var pluginState: PluginInstallState = .zero
    @Published var pluginStateChecked = false
    @Published var installingPlugins: Set<String> = []
    @Published var pluginErrors: [String: String] = [:]
    @Published var copiedPluginCommands: String?
    let pluginDetector = PluginInstallDetector()
    @Published var codexPluginState: CodexPluginState = .zero
    @Published var codexPluginChecked = false
    @Published var codexInstalling = false
    @Published var codexInstallError: String?
    let codexDetector = CodexPluginDetector()
    @Published var pendingHarnesses: Set<SkillInstaller.Harness> = []

    func installCodexPlugin() {
        guard !codexInstalling else { return }
        codexInstalling = true
        codexInstallError = nil
        Task { @MainActor in
            switch await CodexPluginInstaller.install() {
            case .success:
                break
            case .codexNotFound:
                codexInstallError = L10n.tr("Codex CLI not found. Install Codex first, or run the commands in a terminal.")
            case .failed(let message):
                codexInstallError = message
            }
            codexPluginState = await codexDetector.read()
            codexPluginChecked = true
            codexInstalling = false
        }
    }

    func refreshPluginState() async {
        pluginState = await pluginDetector.read()
        pluginStateChecked = true
        settings.refreshWakeReachability()
    }

    func installPlugin(_ plugin: String) {
        guard !installingPlugins.contains(plugin) else { return }
        installingPlugins.insert(plugin)
        pluginErrors[plugin] = nil
        Task { @MainActor in
            switch await PluginInstaller.install(plugin: plugin) {
            case .success:
                break
            case .claudeNotFound:
                pluginErrors[plugin] = L10n.tr("Claude Code CLI not found. Install Claude Code first, or run the commands in a terminal.")
            case .failed(let message):
                pluginErrors[plugin] = message
            }
            await refreshPluginState()
            installingPlugins.remove(plugin)
        }
    }

    func copyCommands(_ commands: String, key: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(commands, forType: .string)
        copiedPluginCommands = key
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if copiedPluginCommands == key { copiedPluginCommands = nil }
        }
    }

    func beginSetHarness(_ harness: SkillInstaller.Harness, enabled: Bool) {
        guard !pendingHarnesses.contains(harness),
              !harnessManager.workingHarnesses.contains(harness) else {
            return
        }

        pendingHarnesses.insert(harness)
        Task { @MainActor in
            await setHarness(harness, enabled: enabled)
            pendingHarnesses.remove(harness)
        }
    }

    func setHarness(_ harness: SkillInstaller.Harness, enabled: Bool) async {
        if enabled {
            await harnessManager.enable(harness)
        } else {
            await harnessManager.uninstall(harness)
        }
    }
}
