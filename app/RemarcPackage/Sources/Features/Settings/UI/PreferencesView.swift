import CoreLocalization
import CoreTheme
import CoreUI
import FeatureComments
import FeatureIntegrations
import FeatureSettings
import FeatureUpdates
import FeatureVoice
import AppKit
import KeyboardShortcuts
import SwiftUI
import UniformTypeIdentifiers

struct PreferencesView: View {
    @Environment(\.colorScheme) var colorScheme
    @StateObject var integrations = AgentIntegrationSettingsViewModel(settings: .shared, harnessManager: .shared)
    @ObservedObject var localization = LocalizationManager.shared
    @ObservedObject var settings = SettingsManager.shared
    @ObservedObject var mcpManager = MCPManager.shared
    @ObservedObject var harnessManager = HarnessIntegrationManager.shared

    // Claude Code plugin install state (read-only detection via `claude plugin
    // list --json`; installs go through PluginInstaller's CLI calls).

    // Codex plugin install state (read-only detection via `codex plugin list
    // --json`; installs go through CodexPluginInstaller's CLI calls).
    @State var screenshotFolderError: String?
    @ObservedObject var webSocketService = WebSocketService.shared
    @ObservedObject var updateManager = UpdateManager.shared
    @ObservedObject var modelManager = WhisperKitModelManager.shared
    #if canImport(FluidAudio)
    @ObservedObject var parakeetManager = ParakeetModelManager.shared
    #endif
    @State var selectedSection: SettingsSection = {
        if let raw = UserDefaults.standard.string(forKey: PreferencesWindowController.selectedSectionKey),
           let section = SettingsSection(rawValue: raw) {
            return section
        }
        return .general
    }()
    @State var hoveredHighlight: ExportHighlight?
    @State var excludedApps: [ExcludedAppInfo] = []
    @State var excludedSelection: Set<String> = []
    @State var claudeDesktopCopied = false
    @State var manualJSONCopied = false
    @State var manualSkillCopied = false
    @State var manualNodePath: String?
    @State var manualMCPPath: String?
    @State var isResolvingManualPaths = false
    @State var manualNodeResolutionFailed = false
    @State var manualMCPPathMissing = false
    @State var newVocabHint: String = ""
    @State var showResetDataConfirm = false
    @ObservedObject var webhookService = WebhookService.shared
    @State var webhookEditorState: WebhookEditorState?
    @State var testingWebhookIDs: Set<UUID> = []
    @State var webhookPendingDelete: Webhook?

    enum SettingsSection: String, CaseIterable, Identifiable {
        case general = "General"
        case iCloudSync = "iCloud Sync"
        case shortcuts = "Shortcuts"
        case voice = "Voice"
        case export = "Export"
        case chromeExtension = "Chrome Extension"
        case mcpIntegrations = "MCP Integrations"
        case webhooks = "Webhooks"
        case excludedApps = "Excluded Apps"
        case about = "About"
        case experimental = "Experimental"

        var id: String { rawValue }

        var icon: String {
            switch self {
            case .general: return "gearshape"
            case .iCloudSync: return "icloud"
            case .shortcuts: return "command"
            case .voice: return "waveform"
            case .export: return "square.and.arrow.up"
            case .chromeExtension: return "globe"
            case .mcpIntegrations: return "puzzlepiece.extension"
            case .webhooks: return "bolt"
            case .excludedApps: return "app.dashed"
            case .about: return "info.circle"
            case .experimental: return "flask"
            }
        }
    }

    var visibleSections: [SettingsSection] {
        SettingsSection.allCases.filter { section in
            #if !DEBUG
            if section == .experimental { return false }
            #endif
            if #available(macOS 26, *) { return true }
            return section != .voice
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            // Sidebar
            VStack(spacing: 0) {
            List(selection: $selectedSection) {
                ForEach(visibleSections) { section in
                    if section == .chromeExtension {
                        Label {
                            Text(L10n.lookup(section.rawValue))
                        } icon: {
                            Image("ChromeLogo")
                                .resizable()
                                .renderingMode(.template)
                                .frame(width: 14, height: 14)
                        }
                        .font(.system(size: 13))
                        .tag(section)
                    } else {
                        Label(L10n.lookup(section.rawValue), systemImage: section.icon)
                            .font(.system(size: 13))
                            .tag(section)
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .tint(Color.remarcPrimary(for: colorScheme))
            }
            .frame(width: 220)
            .background(Color.remarcBackgroundGradient(for: colorScheme).opacity(0.3))

            Divider()

            // Detail pane
            Group {
                switch selectedSection {
                case .general: generalSection
                case .iCloudSync: SnapshotSyncView()
                case .shortcuts: shortcutsSection
                case .voice:
                    if #available(macOS 26, *) {
                        voiceSection
                    }
                case .export: exportSection
                case .chromeExtension: chromeExtensionSection
                case .mcpIntegrations: mcpIntegrationsSection
                case .webhooks: webhooksSection
                case .excludedApps: excludedAppsSection
                case .about: aboutSection
                case .experimental:
                    #if DEBUG
                    experimentalSection
                    #else
                    EmptyView()
                    #endif
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.remarcBackgroundGradient(for: colorScheme).opacity(0.3))
        }
        .onReceive(NotificationCenter.default.publisher(for: PreferencesWindowController.selectTabNotification)) { notification in
            if let raw = notification.object as? String,
               let section = SettingsSection(rawValue: raw) {
                selectedSection = section
            }
        }
        .onRemarcChange(of: selectedSection) { newValue in
            UserDefaults.standard.set(newValue.rawValue, forKey: PreferencesWindowController.selectedSectionKey)
            NotificationCenter.default.post(
                name: PreferencesWindowController.resizeNotification,
                object: newValue == .export
            )
        }
    }

}
