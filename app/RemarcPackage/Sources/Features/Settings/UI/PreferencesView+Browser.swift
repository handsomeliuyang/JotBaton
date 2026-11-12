import CoreLocalization
import CoreTheme
import FeatureIntegrations
import FeatureSettings
import AppKit
import KeyboardShortcuts
import SwiftUI
import UniformTypeIdentifiers

extension PreferencesView {
    var extensionStatusColor: Color {
        if webSocketService.serverError != nil { return .red }
        if !webSocketService.isRunning { return .orange }
        if webSocketService.isClientConnected { return .green }
        return .primary.opacity(0.2)
    }

    var extensionStatusText: String {
        if webSocketService.serverError != nil { return L10n.tr("Port \(IntegrationConstants.webSocketPort) unavailable") }
        if !webSocketService.isRunning { return L10n.tr("Starting server\u{2026}") }
        if webSocketService.isClientConnected { return L10n.tr("Extension connected") }
        if settings.hasExtensionEverConnected { return L10n.tr("Extension not connected") }
        return L10n.tr("Waiting for extension")
    }

    var chromeExtensionSection: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // Connection section
                VStack(alignment: .leading, spacing: Self.itemSpacing) {
                    sectionHeader(L10n.tr("Connection"), description: L10n.tr("Chrome extension connectivity.")) {
                        GetExtensionButton {
                            NSWorkspace.shared.open(IntegrationConstants.chromeExtensionURL)
                        }
                    }

                    // Status row
                    HStack(spacing: 8) {
                        Circle()
                            .fill(extensionStatusColor)
                            .frame(width: 8, height: 8)
                        Text(extensionStatusText)
                            .font(.system(size: 13))
                        Spacer()
                        Text(L10n.tr("Port \(IntegrationConstants.webSocketPort)"))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.primary.opacity(0.35))
                    }

                    // Server error state
                    if webSocketService.serverError != nil {
                        settingsHint(L10n.tr("Another app may be using this port."), icon: "exclamationmark.triangle.fill", tint: Color.remarcWarning(for: colorScheme))
                        Button(L10n.tr("Retry")) {
                            webSocketService.retryServer()
                        }
                        .font(.system(size: 12))
                    }

                    // Reconnection hint
                    if webSocketService.isRunning && !webSocketService.isClientConnected && settings.hasExtensionEverConnected {
                        settingsHint(L10n.tr("Open a Chrome tab to reconnect."), tint: Color.remarcInfo(for: colorScheme))
                    }

                    // First-time onboarding card
                    if !settings.hasExtensionEverConnected {
                        Divider()

                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 6) {
                                Image(systemName: "puzzlepiece.extension")
                                    .font(.system(size: 14))
                                    .foregroundStyle(Color.remarcPrimary(for: colorScheme))
                                Text(L10n.tr("Get more context from web pages"))
                                    .font(.system(size: 13, weight: .medium))
                            }

                            VStack(alignment: .leading, spacing: 4) {
                                onboardingBullet(L10n.tr("React component names and file paths"))
                                onboardingBullet(L10n.tr("Computed styles and accessibility info"))
                                onboardingBullet(L10n.tr("Layout structure and nearby elements"))
                            }

                            Button(L10n.tr("Installation Guide\u{2026}")) {
                                NSWorkspace.shared.open(IntegrationConstants.chromeExtensionURL)
                            }
                            .font(.system(size: 12))
                        }
                    }
                }

                Divider()

                // Extension Shortcuts subsection
                VStack(alignment: .leading, spacing: Self.itemSpacing) {
                    sectionHeader(L10n.tr("Chrome Shortcuts"), description: L10n.tr("Configure keyboard shortcuts for element capture."))

                    settingsRow(L10n.tr("Grab Element")) {
                        ExtensionShortcutRecorder(shortcut: $settings.extensionGrabElementShortcut)
                    }
                    settingsRow(L10n.tr("Select Region")) {
                        ExtensionShortcutRecorder(shortcut: $settings.extensionRegionSelectShortcut)
                    }

                    Text(L10n.tr("Use ⌃⇧ or ⌥⇧ combinations. ⌘ is not supported in Chrome."))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)

                    Button(L10n.tr("Reset to Defaults")) {
                        settings.extensionGrabElementShortcut = .defaultGrabElement
                        settings.extensionRegionSelectShortcut = .defaultRegionSelect
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .buttonStyle(.plain)
                }

                Divider()

                // Captured Metadata section
                VStack(alignment: .leading, spacing: Self.itemSpacing) {
                    sectionHeader(L10n.tr("Captured Metadata"), description: L10n.tr("Choose which web context data is saved with comments."))

                    let disabled = !settings.hasExtensionEverConnected

                    metadataToggle(L10n.tr("React components"), detail: L10n.tr("Component name, file path, hierarchy"),
                                   isOn: $settings.webContextReactEnabled, disabled: disabled)
                    metadataToggle(L10n.tr("Computed styles"), detail: L10n.tr("CSS properties on the element"),
                                   isOn: $settings.webContextStylesEnabled, disabled: disabled)
                    metadataToggle(L10n.tr("Accessibility"), detail: L10n.tr("ARIA roles, labels, tab index"),
                                   isOn: $settings.webContextAccessibilityEnabled, disabled: disabled)
                    metadataToggle(L10n.tr("Layout & structure"), detail: L10n.tr("Bounding box, parent, nearby elements"),
                                   isOn: $settings.webContextLayoutEnabled, disabled: disabled)
                    metadataToggle(L10n.tr("Element identity"), detail: L10n.tr("CSS selector, HTML snippet, page URL"),
                                   isOn: $settings.webContextIdentityEnabled, disabled: disabled)

                    if !settings.hasExtensionEverConnected {
                        settingsHint(L10n.tr("Connect the extension to configure."), tint: .primary.opacity(0.35))
                    }
                }
            }
            .padding(24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { webSocketService.ensureStarted() }
    }

    func metadataToggle(
        _ label: String,
        detail: String,
        isOn: Binding<Bool>,
        disabled: Bool = false
    ) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .font(.system(size: 13))
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.primary.opacity(0.45))
            }
            Spacer(minLength: 4)
            Toggle(label, isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .disabled(disabled)
        }
        .opacity(disabled ? 0.5 : 1.0)
    }

    func onboardingBullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text("\u{2022}")
                .font(.system(size: 11))
                .foregroundStyle(.primary.opacity(0.45))
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(.primary.opacity(0.6))
        }
    }


}
