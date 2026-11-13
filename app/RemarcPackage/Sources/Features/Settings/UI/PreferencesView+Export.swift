import CoreLocalization
import CoreTheme
import FeatureComments
import FeatureSettings
import AppKit
import KeyboardShortcuts
import SwiftUI
import UniformTypeIdentifiers

extension PreferencesView {
    func clipboardPrefixRow(
        _ label: String,
        keyPath: WritableKeyPath<ClipboardLayout, String>,
        highlight: ExportHighlight
    ) -> some View {
        settingsRow(label, highlight: highlight) {
            TextField("", text: Binding(
                get: { settings.clipboardLayout[keyPath: keyPath] },
                set: { settings.clipboardLayout[keyPath: keyPath] = $0 }
            ))
            .textFieldStyle(.roundedBorder)
            .frame(width: Self.pickerWidth)
            .accessibilityLabel(Text(label))
        }
    }

    var clipboardCompositionControls: some View {
        VStack(alignment: .leading, spacing: Self.itemSpacing) {
            clipboardPrefixRow(L10n.tr("Reference prefix"), keyPath: \.referencePrefix, highlight: .reference)
            clipboardPrefixRow(L10n.tr("Screenshot prefix"), keyPath: \.screenshotPrefix, highlight: .screenshotPrefix)
            clipboardPrefixRow(L10n.tr("Attachment prefix"), keyPath: \.attachmentPrefix, highlight: .attachmentPrefix)
            clipboardPrefixRow(L10n.tr("Comment prefix"), keyPath: \.commentPrefix, highlight: .commentPrefix)
            settingDescription(L10n.tr("Leave a prefix empty to omit its label."))
            pickerRow(L10n.tr("Field spacing"), selection: $settings.clipboardLayout.fieldSpacing, highlight: .layout) { $0.label }
            Text(L10n.tr("Field order"))
                .font(.system(size: 13))
            ForEach(settings.clipboardLayout.orderedFields, id: \.self) { field in
                settingsRow(field.label, highlight: .layout) {
                    HStack(spacing: 8) {
                        Button {
                            settings.clipboardLayout.move(field, by: -1)
                        } label: {
                            Image(systemName: "chevron.up")
                        }
                        .disabled(settings.clipboardLayout.orderedFields.first == field)
                        .help(L10n.tr("Move up"))
                        .accessibilityLabel(Text(L10n.tr("Move \(field.label) up")))
                        Button {
                            settings.clipboardLayout.move(field, by: 1)
                        } label: {
                            Image(systemName: "chevron.down")
                        }
                        .disabled(settings.clipboardLayout.orderedFields.last == field)
                        .help(L10n.tr("Move down"))
                        .accessibilityLabel(Text(L10n.tr("Move \(field.label) down")))
                    }
                    .controlSize(.small)
                }
            }
        }
    }

    var exportSection: some View {
        HStack(alignment: .top, spacing: 32) {
            // Left column: controls
            ScrollView {
                VStack(alignment: .leading, spacing: Self.sectionSpacing) {
                    // Clipboard Format section
                    VStack(alignment: .leading, spacing: Self.itemSpacing) {
                        sectionHeader(
                            L10n.tr("Clipboard Format"),
                            description: L10n.tr("Controls how comments are formatted when copied to clipboard.")
                        )

                        pickerRow(L10n.tr("Reference style"), selection: $settings.referenceStyle, highlight: .reference) { $0.label }
                        clipboardCompositionControls
                        pickerRow(L10n.tr("List style"), selection: $settings.numberingStyle, highlight: .numbering) { $0.label }
                        pickerRow(L10n.tr("Comment dividers"), selection: $settings.dividerStyle, highlight: .divider) { $0.label }
                        pickerRow(L10n.tr("Metadata divider"), selection: $settings.metadataDividerStyle, highlight: .metadataDivider) { $0.label }
                    }

                    Divider()

                    // Metadata toggles
                    VStack(alignment: .leading, spacing: Self.itemSpacing) {
                        sectionHeader(
                            L10n.tr("Include in Export"),
                            description: L10n.tr("Choose which metadata to attach to each comment.")
                        )

                        toggleRow(L10n.tr("Type"), isOn: $settings.includeType, highlight: .type)
                        toggleRow(L10n.tr("Source app"), isOn: $settings.includeSource, highlight: .source)
                        toggleRow(L10n.tr("Date"), isOn: $settings.includeDate, highlight: .date)
                        toggleRow(L10n.tr("Include time"), isOn: $settings.includeTime, highlight: .date, disabled: !settings.includeDate)
                        toggleRow(L10n.tr("Status"), isOn: $settings.includeStatus, highlight: .status)
                        toggleRow(L10n.tr("Comment ID"), isOn: $settings.includeRemarkID, highlight: .remarkID)
                    }

                    Divider()

                    // Behavior
                    VStack(alignment: .leading, spacing: Self.itemSpacing) {
                        sectionHeader(
                            L10n.tr("After Export"),
                            description: L10n.tr("What happens after copying or saving comments.")
                        )

                        pickerRow(L10n.tr("After copying"), selection: $settings.clearAfterExportBehavior) { $0.label }
                    }

                    Divider()

                    // File export format
                    VStack(alignment: .leading, spacing: Self.itemSpacing) {
                        sectionHeader(
                            L10n.tr("File Export"),
                            description: L10n.tr("Default format when saving comments to a file.")
                        )

                        pickerRow(L10n.tr("Format"), selection: $settings.outputFormat) { $0.label }
                    }

                    Spacer()
                }
                .frame(maxWidth: .infinity)
            }
            .frame(width: 330)

            // Right column: live preview
            VStack(alignment: .leading, spacing: 8) {
                sectionHeader(
                    L10n.tr("Preview"),
                    description: L10n.tr("Live preview of how your comments will look when copied.")
                )

                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(exportPreviewLines) { line in
                            let lineHasHighlight = hoveredHighlight != nil
                                && line.segments.contains { $0.highlights.contains(hoveredHighlight!) }
                            let isEmpty = line.segments.allSatisfy { $0.text.isEmpty }

                            if isEmpty {
                                let emptyHighlight = hoveredHighlight != nil
                                    && line.segments.contains { $0.highlights.contains(hoveredHighlight!) }
                                Text(" ")
                                    .font(.system(size: 13, design: .monospaced))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 2)
                                    .background(
                                        RoundedRectangle(cornerRadius: 3)
                                            .fill(emptyHighlight ? Color.remarcPrimary(for: colorScheme).opacity(0.08) : .clear)
                                    )
                                    .animation(.easeInOut(duration: 0.15), value: hoveredHighlight)
                            } else {
                                let metadataHighlights: Set<ExportHighlight> = [.source, .date, .dateFormat, .status, .metadataDivider, .remarkID, .type]
                                let isMetadataLine = line.segments.contains { !$0.highlights.isDisjoint(with: metadataHighlights) }
                                line.segments.reduce(Text("")) { result, segment in
                                    let hit = hoveredHighlight != nil && segment.highlights.contains(hoveredHighlight!)
                                    let defaultColor: Color = isMetadataLine ? .primary.opacity(0.6) : .primary
                                    return result + Text(segment.text)
                                        .foregroundColor(hit ? Color.remarcPrimary(for: colorScheme) : defaultColor)
                                }
                                .font(.system(size: 13, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 2)
                                .background(
                                    RoundedRectangle(cornerRadius: 3)
                                        .fill(lineHasHighlight ? Color.remarcPrimary(for: colorScheme).opacity(0.08) : .clear)
                                )
                                .animation(.easeInOut(duration: 0.15), value: hoveredHighlight)
                            }
                        }
                    }
                    .textSelection(.enabled)
                    .padding(12)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(.primary.opacity(0.04))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(.primary.opacity(0.08), lineWidth: 1)
                )
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }


    var exportPreviewLines: [PreviewLine] {
        ExportManager.shared.previewLines(
            referenceStyle: settings.referenceStyle,
            numberingStyle: settings.numberingStyle,
            commentPrefixStyle: settings.commentPrefixStyle,
            dividerStyle: settings.dividerStyle,
            dateFormat: settings.exportDateFormat,
            includeRemarkID: settings.includeRemarkID,
            includeSource: settings.includeSource,
            includeDate: settings.includeDate,
            includeStatus: settings.includeStatus,
            includeType: settings.includeType,
            includeTime: settings.includeTime,
            use24Hour: settings.timeFormat.use24Hour,
            metadataDivider: settings.metadataDividerStyle,
            layout: settings.clipboardLayout
        )
    }

    // MARK: - Extension Tab


}
