import CoreLocalization
import CoreTheme
import CoreUI
import FeatureSettings
import AppKit
import KeyboardShortcuts
import SwiftUI
import UniformTypeIdentifiers

extension PreferencesView {
    var generalSection: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // App section
                VStack(alignment: .leading, spacing: Self.itemSpacing) {
                    sectionHeader(L10n.tr("App"), description: L10n.tr("Startup and detection behavior."))

                    pickerRow(L10n.tr("Language"), selection: $localization.language) { $0.label }
                        .accessibilityIdentifier("remarc.settings.language")

                    toggleRow(L10n.tr("Launch at Login"), isOn: Binding(
                        get: { settings.launchAtLogin },
                        set: { settings.launchAtLogin = $0 }
                    ))
                    describedRow(L10n.tr("When enabled, Remarc always shows in the Dock. Otherwise, it only appears while Settings or Permissions are open.")) {
                        toggleRow(L10n.tr("Show in Dock"), isOn: $settings.showInDock)
                    }
                    describedRow(L10n.tr("Dot shows only whether you have unresolved comments. Dot and Off keep the icon at a fixed width, which helps in crowded menu bars.")) {
                        pickerRow(L10n.tr("Menu bar indicator"), selection: $settings.menuBarIndicatorStyle) { $0.label }
                    }
                    if settings.menuBarIndicatorStyle == .count {
                        describedRow(L10n.tr("Hides the badge when you have no unresolved comments, instead of showing a 0.")) {
                            toggleRow(L10n.tr("Hide the count at 0"), isOn: $settings.hidesMenuBarCountAtZero)
                        }
                        .nestedSetting()
                    }
                    describedRow(L10n.tr("Auto-detect shows the Remarc popup as soon as you select text. Hotkey only hides the popup and waits for your shortcut.")) {
                        pickerRow(L10n.tr("Detection mode"), selection: $settings.selectionDetectionMode) { $0.label }
                    }
                    if PopClipInstaller.isInstalled() {
                        CalloutView(.info, L10n.tr("Using PopClip? Choose Hotkey Only\nto prevent duplicate selection popups."), contentPlacement: .trailing) {
                            GetExtensionButton(
                                title: L10n.tr("Install PopClip Extension"),
                                help: L10n.tr("Install the Remarc PopClip extension")
                            ) {
                                PopClipInstaller.shared.install()
                            }
                        }
                    }
                    pickerRow(L10n.tr("Tooltip position"), selection: $settings.tooltipPosition) { $0.label }
                    pickerRow(L10n.tr("Date format"), selection: $settings.exportDateFormat) { $0.label }
                    pickerRow(L10n.tr("Time format"), selection: $settings.timeFormat) { $0.label }
                }

                Divider()

                // Clipboard section
                VStack(alignment: .leading, spacing: Self.itemSpacing) {
                    sectionHeader(L10n.tr("Clipboard"), description: L10n.tr("How copied content is processed."))

                    toggleRow(L10n.tr("Clean up whitespace"), isOn: $settings.normalizeWhitespace)
                    toggleRow(L10n.tr("Copy image when saving a screenshot comment"), isOn: $settings.copyScreenshotToClipboard)
                }

                Divider()

                VStack(alignment: .leading, spacing: Self.itemSpacing) {
                    sectionHeader(L10n.tr("Screenshots"), description: L10n.tr("Where captured images are stored."))

                    VStack(alignment: .leading, spacing: SettingsMetrics.descriptionSpacing) {
                        settingsRow(L10n.tr("Storage folder")) {
                            HStack(spacing: 8) {
                                textButton(L10n.tr("Choose\u{2026}"), action: chooseScreenshotFolder)
                                    .accessibilityLabel(L10n.tr("Choose screenshot storage folder"))
                                if !settings.screenshotDirectoryPath.isEmpty {
                                    textButton(L10n.tr("Use Default"), restOpacity: 0.6, action: useDefaultScreenshotFolder)
                                        .accessibilityLabel(L10n.tr("Use default screenshot storage folder"))
                                }
                            }
                        }
                        Text(screenshotFolderDescription)
                            .settingDescriptionStyle()
                            .lineLimit(2)
                            .truncationMode(.middle)
                            .help(screenshotFolderURL.path)
                        Text(L10n.tr("Existing images stay in their original folders. Your coding agent needs access to this folder."))
                            .settingDescriptionStyle()
                        if let error = screenshotFolderError {
                            settingsHint(error, icon: "exclamationmark.triangle.fill", tint: Color.remarcError(for: colorScheme))
                        }
                    }
                }

                Divider()

                // Retention section
                VStack(alignment: .leading, spacing: Self.itemSpacing) {
                    sectionHeader(L10n.tr("Retention"), description: L10n.tr("Comments moved to History, along with their images and attachments, are removed when the retention period ends."))

                    settingsRow(L10n.tr("History retention")) {
                        RemarcDropdown(
                            selection: $settings.historyRetentionDays,
                            options: [1, 7, 30],
                            labelFor: { days in
                                switch days {
                                case 1: return L10n.tr("1 day")
                                case 7: return L10n.tr("1 week")
                                case 30: return L10n.tr("1 month")
                                default: return L10n.tr("\(days) days")
                                }
                            },
                            width: Self.pickerWidth
                        )
                    }
                    VStack(alignment: .leading, spacing: SettingsMetrics.descriptionSpacing) {
                        pickerRow(L10n.tr("Move completed comments to History"), selection: $settings.resolvedCommentDeletion) { $0.label }
                        Text(L10n.tr("Completed comments leave the current list and can be viewed or restored in History until the history retention period expires."))
                            .settingDescriptionStyle()
                    }

                    VStack(alignment: .leading, spacing: SettingsMetrics.descriptionSpacing) {
                        toggleRow(L10n.tr("Move empty sessions to History automatically"), isOn: $settings.inactiveSessionCleanupEnabled)
                        Text(L10n.tr("Empty sessions move to History after the selected duration. Retained tasks, including completed tasks, prevent cleanup. The Inbox and pinned sessions are always kept."))
                            .settingDescriptionStyle()
                    }

                    if settings.inactiveSessionCleanupEnabled {
                        VStack(alignment: .leading, spacing: Self.itemSpacing) {
                            pickerRow(L10n.tr("Empty for"), selection: $settings.inactiveSessionCleanupInterval) { $0.label }
                        }
                        .nestedSetting()
                    }
                }

            }
            .padding(24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }


}
