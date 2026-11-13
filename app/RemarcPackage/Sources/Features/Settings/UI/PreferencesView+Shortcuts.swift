import CoreLocalization
import CoreTheme
import FeatureComments
import FeatureSettings
import AppKit
import KeyboardShortcuts
import SwiftUI
import UniformTypeIdentifiers

extension PreferencesView {
    var shortcutsSection: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Self.itemSpacing) {
                sectionHeader(L10n.tr("App Shortcuts"), description: L10n.tr("Global keyboard shortcuts for Remarc actions.")) {
                    appShortcutsResetButton
                }

                settingsRow(L10n.tr("Comment")) {
                    ConflictAwareRecorder(name: .commentOnSelection)
                }
                settingsRow(L10n.tr("Quick Note")) {
                    ConflictAwareRecorder(name: .quickNote)
                }
                settingsRow(L10n.tr("Screenshot")) {
                    ConflictAwareRecorder(name: .screenshotComment)
                }
                if settings.wakeOnCommentEnabled {
                    settingsRow(L10n.tr("Screenshot & Send Instantly")) {
                        ConflictAwareRecorder(name: .screenshotCommentWake)
                    }
                }
                settingsRow(L10n.tr("Paste All")) {
                    ConflictAwareRecorder(name: .pasteAllComments)
                }
                settingsRow(L10n.tr("Open Remarc")) {
                    ConflictAwareRecorder(name: .openRemarc)
                }

                Divider()
                    .padding(.vertical, 4)

                sectionHeader(L10n.tr("Chrome Shortcuts"), description: L10n.tr("Keyboard shortcuts for the Chrome Extension.")) {
                    extensionShortcutResetButton
                }

                HStack(spacing: 6) {
                    Circle()
                        .fill(webSocketService.isClientConnected ? Color.green : Color.primary.opacity(0.25))
                        .frame(width: 6, height: 6)
                    Text(webSocketService.isClientConnected ? L10n.tr("Extension connected") : L10n.tr("Extension not connected"))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                settingsRow(L10n.tr("Grab Element")) {
                    ExtensionShortcutRecorder(shortcut: $settings.extensionGrabElementShortcut)
                }
                settingsRow(L10n.tr("Select Region")) {
                    ExtensionShortcutRecorder(shortcut: $settings.extensionRegionSelectShortcut)
                }

                HStack(spacing: 8) {
                    Image(systemName: "info.circle.fill")
                        .foregroundStyle(Color.remarcPrimary(for: colorScheme))
                        .font(.system(size: 12))
                    Text(L10n.tr("Use ⌃⇧ or ⌥⇧ combinations. ⌘ is not supported in Chrome."))
                        .font(.system(size: 11))
                        .foregroundStyle(.primary.opacity(0.7))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.remarcPrimary(for: colorScheme).opacity(0.08))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color.remarcPrimary(for: colorScheme).opacity(0.25), lineWidth: 1)
                )

            }
            .padding(24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

}
