import CoreLocalization
import CoreTheme
import CoreUI
import FeatureComments
import FeatureSettings
import AppKit
import KeyboardShortcuts
import SwiftUI
import UniformTypeIdentifiers

extension PreferencesView {
    func textButton(
        _ title: String,
        color: Color? = nil,
        restOpacity: Double = 0.8,
        action: @escaping () -> Void
    ) -> some View {
        TextButton(title: title, color: color ?? Color.remarcPrimary(for: colorScheme), restOpacity: restOpacity, action: action)
    }

    // MARK: - Settings Design System
    //
    // Labels are left-aligned, controls are right-aligned, using HStack { label; Spacer; control }.
    // Section headers use .headline-weight at 13pt, descriptions at 11pt secondary.
    // Toggles use .switch style (native macOS toggle, not checkbox).
    // Spacing: 20pt between sections, 10pt between items, 4pt header-to-description.

    static let sectionSpacing: CGFloat = 20
    static let itemSpacing: CGFloat = 10
    static let headerDescriptionSpacing: CGFloat = 4
    static let pickerWidth: CGFloat = SettingsMetrics.controlColumnWidth

    var appShortcutsResetButton: some View {
        textButton(L10n.tr("Reset"), restOpacity: 0.6) {
            KeyboardShortcuts.reset(.commentOnSelection, .quickNote, .screenshotComment, .screenshotCommentWake, .pasteAllComments, .openRemarc)
        }
    }

    /// Reset button for extension shortcuts, used in both Shortcuts and Chrome Extension tabs.
    var extensionShortcutResetButton: some View {
        textButton(L10n.tr("Reset"), restOpacity: 0.6) {
            settings.extensionGrabElementShortcut = .defaultGrabElement
            settings.extensionRegionSelectShortcut = .defaultRegionSelect
        }
    }

    /// Section header with optional description subtitle and optional trailing view aligned to the title.
    func sectionHeader(_ title: String, leadingIcon: String? = nil, description: String? = nil, badge: String? = nil, badgeTooltip: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: Self.headerDescriptionSpacing) {
            HStack(spacing: 6) {
                if let leadingIcon {
                    Image(leadingIcon)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 14, height: 14)
                        .accessibilityHidden(true)
                }
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                if let badge {
                    BadgeView(text: badge, tooltip: badgeTooltip, colorScheme: colorScheme)
                }
            }
            if let description {
                Text(description)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.trailing, SettingsMetrics.descriptionTrailingInset)
            }
        }
    }

    func sectionHeader<Trailing: View>(_ title: String, description: String? = nil, badge: String? = nil, badgeTooltip: String? = nil, @ViewBuilder trailing: () -> Trailing) -> some View {
        VStack(alignment: .leading, spacing: Self.headerDescriptionSpacing) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                if let badge {
                    BadgeView(text: badge, tooltip: badgeTooltip, colorScheme: colorScheme)
                }
                Spacer()
                trailing()
            }
            if let description {
                Text(description)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.trailing, SettingsMetrics.descriptionTrailingInset)
            }
        }
    }

    /// Inline hint with icon and descriptive text (info, warning, or muted).
    func settingsHint(_ text: String, icon: String = "info.circle.fill", tint: Color) -> some View {
        HStack(alignment: .top, spacing: 4) {
            Image(systemName: icon)
                .foregroundStyle(tint)
                .font(.system(size: 11))
            Text(text)
                .settingDescriptionStyle(opacity: 0.6)
        }
    }

    /// Secondary explanation shown under a settings row.
    func settingDescription(_ text: String) -> some View {
        Text(text).settingDescriptionStyle()
    }

    /// A settings row paired with its explanation.
    ///
    /// The note hugs its own row and the pair is padded away from the next one.
    /// With a uniform gap the note sits nearly as close to the row below it,
    /// so it reads as introducing the wrong control.
    func describedRow<Content: View>(
        _ description: String,
        @ViewBuilder row: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: SettingsMetrics.descriptionSpacing) {
            row()
            settingDescription(description)
        }
        .padding(.bottom, SettingsMetrics.describedRowBottomPadding)
    }

    /// A settings row: left-aligned label, right-aligned control, full-width.

    func settingsRow<Content: View, Accessory: View>(
        _ label: String,
        highlight: ExportHighlight? = nil,
        @ViewBuilder labelAccessory: () -> Accessory = { EmptyView() },
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(spacing: 8) {
            HStack(spacing: 4) {
                Text(label)
                    .font(.system(size: 13))
                    .foregroundStyle(.primary)
                labelAccessory()
            }
            Spacer(minLength: 4)
            content()
        }
        .onHover { hovering in
            if let highlight {
                hoveredHighlight = hovering ? highlight : nil
            }
        }
    }

    /// A picker row using custom RemarcDropdown for uniform width and proper hover states.
    func pickerRow<T: Hashable & CaseIterable & RawRepresentable>(
        _ label: String,
        selection: Binding<T>,
        highlight: ExportHighlight? = nil,
        width: CGFloat = pickerWidth,
        labelFor: @escaping (T) -> String
    ) -> some View where T.AllCases: RandomAccessCollection {
        settingsRow(label, highlight: highlight) {
            RemarcDropdown(
                selection: selection,
                options: Array(T.allCases),
                labelFor: labelFor,
                width: width
            )
        }
    }

    /// A toggle row using the settingsRow pattern with native switch style.
    func toggleRow(
        _ label: String,
        isOn: Binding<Bool>,
        highlight: ExportHighlight? = nil,
        disabled: Bool = false
    ) -> some View {
        settingsRow(label, highlight: highlight) {
            Toggle(label, isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .disabled(disabled)
        }
        .opacity(disabled ? 0.5 : 1.0)
    }

    // MARK: - Export Tab

}
