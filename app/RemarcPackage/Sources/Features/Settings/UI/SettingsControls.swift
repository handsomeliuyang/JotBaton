import CoreLocalization
import CoreTheme
import FeatureIntegrations
import FeatureSettings
import AppKit
import KeyboardShortcuts
import SwiftUI
import UniformTypeIdentifiers

struct GetExtensionButton: View {
    @ObservedObject private var localization = LocalizationManager.shared
    var title: String = L10n.tr("Get Extension")
    var help: String = L10n.tr("Get Chrome extension")
    var action: () -> Void
    @State private var isHovered = false
    @State private var isPressed = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: "square.and.arrow.down")
                    .font(.system(size: 10.5, weight: .medium))

                Text(title)
                    .font(.system(size: 10, weight: .medium))
                    .lineLimit(1)
                    .fixedSize()
            }
            .foregroundStyle(.primary.opacity(isPressed ? 0.85 : (isHovered ? 0.7 : 0.55)))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                Capsule()
                    .fill(Color.primary.opacity(isPressed ? 0.16 : (isHovered ? 0.1 : 0.06)))
            )
            .overlay(
                Capsule()
                    .strokeBorder(Color.primary.opacity(isPressed ? 0.22 : (isHovered ? 0.16 : 0.1)), lineWidth: 0.5)
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { hovering in isHovered = hovering }
        .animation(.easeInOut(duration: 0.15), value: isHovered)
        .animation(.easeInOut(duration: 0.15), value: isPressed)
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in isPressed = true }
                .onEnded { _ in isPressed = false }
        )
    }
}

struct VoiceSettingsGearButton: View {
    @ObservedObject private var localization = LocalizationManager.shared
    var action: () -> Void
    @State private var isHovered = false

    private let collapsedWidth: CGFloat = 15
    private let expandedWidth: CGFloat = 96

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Image(systemName: "gearshape")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.primary.opacity(isHovered ? 0.55 : 0.25))

                Text(L10n.tr("More settings"))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.primary.opacity(0.55))
                    .lineLimit(1)
                    .fixedSize()
            }
            .padding(.horizontal, isHovered ? 6 : 3)
            .padding(.vertical, 2)
            .frame(width: isHovered ? expandedWidth : collapsedWidth, alignment: .leading)
            .background(
                Capsule()
                    .fill(Color.primary.opacity(isHovered ? 0.06 : 0))
            )
            .overlay(
                Capsule()
                    .strokeBorder(Color.primary.opacity(isHovered ? 0.12 : 0), lineWidth: 0.5)
            )
            .clipShape(Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(L10n.tr("Open Voice settings"))
        .onHover { hovering in
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                isHovered = hovering
            }
        }
    }
}

/// Shortcut recorder styled to match KeyboardShortcuts.Recorder (NSSearchField-based).
struct ExtensionShortcutRecorder: View {
    @ObservedObject private var localization = LocalizationManager.shared
    @Binding var shortcut: ExtensionShortcut

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            ExtensionShortcutRecorderField(shortcut: $shortcut, conflictWarning: $conflictWarning)
                .frame(width: 130, height: 22)

            if let conflictWarning {
                Text(conflictWarning)
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
            }
        }
    }

    @State private var conflictWarning: String?
}

/// NSViewRepresentable wrapping an NSSearchField to match the native KeyboardShortcuts.Recorder appearance.
/// Uses local event monitors for both click and key detection since NSSearchField with isEditable=false
/// swallows mouse events and prevents normal target/action interaction.
struct ExtensionShortcutRecorderField: NSViewRepresentable {
    @Binding var shortcut: ExtensionShortcut
    @Binding var conflictWarning: String?

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.centersPlaceholder = true
        field.alignment = .center
        field.font = .systemFont(ofSize: NSFont.systemFontSize)
        field.placeholderString = L10n.tr("Record Shortcut")
        field.stringValue = shortcut.displayString
        field.isEditable = false
        (field.cell as? NSSearchFieldCell)?.searchButtonCell = nil
        context.coordinator.field = field
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        if context.coordinator.isRecording {
            field.stringValue = ""
        } else {
            field.stringValue = shortcut.displayString
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(shortcut: $shortcut, conflictWarning: $conflictWarning)
    }

    @MainActor
    final class Coordinator: NSObject {
        @Binding var shortcut: ExtensionShortcut
        @Binding var conflictWarning: String?
        var isRecording = false
        nonisolated(unsafe) var keyMonitor: Any?
        nonisolated(unsafe) var clickMonitor: Any?
        weak var field: NSSearchField?

        init(shortcut: Binding<ExtensionShortcut>, conflictWarning: Binding<String?>) {
            _shortcut = shortcut
            _conflictWarning = conflictWarning
            super.init()
            installClickMonitor()
        }

        deinit {
            let km = keyMonitor
            let cm = clickMonitor
            DispatchQueue.main.async {
                if let km { NSEvent.removeMonitor(km) }
                if let cm { NSEvent.removeMonitor(cm) }
            }
        }

        private func installClickMonitor() {
            clickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
                guard let self, let field = self.field else { return event }
                guard let fieldWindow = field.window, fieldWindow == event.window else {
                    if self.isRecording { self.stopRecording() }
                    return event
                }
                let point = field.convert(event.locationInWindow, from: nil)
                guard field.bounds.contains(point) else {
                    if self.isRecording { self.stopRecording() }
                    return event
                }
                // Toggle recording
                if self.isRecording {
                    self.stopRecording()
                } else {
                    self.startRecording()
                }
                return nil
            }
        }

        private func startRecording() {
            isRecording = true
            conflictWarning = nil
            field?.stringValue = ""
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self else { return event }
                if event.keyCode == 53 { // Escape — cancel
                    self.stopRecording()
                    return nil
                }
                if let newShortcut = ExtensionShortcut.from(event: event), newShortcut.isValid {
                    if newShortcut.modifiers.contains("Meta") {
                        // Chrome intercepts ⌘ shortcuts — reject and keep recording
                        self.conflictWarning = L10n.tr("⌘ shortcuts won't work in Chrome")
                    } else {
                        self.shortcut = newShortcut
                        self.conflictWarning = self.checkConflict(newShortcut)
                        self.stopRecording()
                    }
                }
                return nil
            }
        }

        private func stopRecording() {
            isRecording = false
            if let keyMonitor {
                NSEvent.removeMonitor(keyMonitor)
            }
            keyMonitor = nil
            field?.stringValue = shortcut.displayString
        }

        private func checkConflict(_ candidate: ExtensionShortcut) -> String? {
            let appShortcuts: [KeyboardShortcuts.Name] = [
                .commentOnSelection, .screenshotComment, .pasteAllComments, .voiceInput, .pasteLastTranscription, .openRemarc, .startCritMode
            ]
            guard let candidateKeyCode = candidate.carbonKeyCode else { return nil }
            for name in appShortcuts {
                guard let existing = KeyboardShortcuts.getShortcut(for: name) else { continue }
                var mods: [String] = []
                if existing.modifiers.contains(.command) { mods.append("Meta") }
                if existing.modifiers.contains(.control) { mods.append("Control") }
                if existing.modifiers.contains(.option)  { mods.append("Alt") }
                if existing.modifiers.contains(.shift)   { mods.append("Shift") }
                if existing.key?.rawValue == candidateKeyCode,
                   Set(mods) == Set(candidate.modifiers) {
                    return L10n.tr("Conflicts with \(name.rawValue)")
                }
            }
            return nil
        }
    }
}

struct ExcludedAppInfo: Identifiable {
    let bundleID: String
    let name: String
    let icon: NSImage?
    var id: String { bundleID }
}

// MARK: - Text Button with Hover State

struct TextButton: View {
    @ObservedObject private var localization = LocalizationManager.shared
    let title: String
    let color: Color
    var restOpacity: Double = 0.8
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(color)
                .opacity(isHovered ? 1.0 : restOpacity)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
    }
}

// MARK: - Badge View (with optional hover tooltip)

struct BadgeView: View {
    @ObservedObject private var localization = LocalizationManager.shared
    let text: String
    let tooltip: String?
    let colorScheme: ColorScheme

    @State private var showTooltip = false

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.remarcPrimary(for: colorScheme).opacity(0.7))
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .onHover { hovering in
                if tooltip != nil { showTooltip = hovering }
            }
            .popover(isPresented: $showTooltip, arrowEdge: .bottom) {
                if let tooltip {
                    Text(tooltip)
                        .font(.system(size: 11))
                        .foregroundStyle(.primary.opacity(0.8))
                        .padding(10)
                        .frame(width: 240)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
    }
}
