import CoreLocalization
import CorePlatform
import CoreTheme
import CoreUI
import SwiftUI
import AppKit

/// Use the button's native pressed state; a zero-distance drag recognizer on
/// every button competes with its click, especially on the first panel click.
private struct AnnotationButtonPressStyle: ButtonStyle {
    package var pressedScale: CGFloat = 0.94

    package func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? pressedScale : 1)
            .brightness(configuration.isPressed ? -0.04 : 0)
            .animation(.easeInOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// One toolbar control. Cloned from the preview header's button recipe
/// (`ScreenshotPreviewController`) and extended with the pressed and selected
/// states that recipe lacks.
package struct AnnotationToolButton: View {
    @ObservedObject private var localization = LocalizationManager.shared
    package let systemImage: String
    package let label: String
    package let shortcut: String?
    package var isSelected: Bool = false
    package var isEnabled: Bool = true
    /// Draws the small chevron that marks a control which opens a group.
    package var hasGroup: Bool = false
    package let action: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovered = false

    package var body: some View {
        Button(action: action) {
            HStack(spacing: 1.5) {
                Image(systemName: systemImage)
                    .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(foreground)
                if hasGroup {
                    // Laid out BESIDE the icon inside a wider frame. An earlier form
                    // offset it out of a 24x24 frame, so it drew over the next
                    // control in the row.
                    Image(systemName: "chevron.down")
                        .font(.system(size: 6.5, weight: .bold))
                        .foregroundStyle(foreground.opacity(0.75))
                }
            }
            // 24pt tall plus the row's vertical padding clears the hit target.
            .frame(width: hasGroup ? 32 : 24, height: 24)
            .background(RoundedRectangle(cornerRadius: 5).fill(background))
            .contentShape(Rectangle())
        }
        .buttonStyle(AnnotationButtonPressStyle())
        .disabled(!isEnabled)
        .help(shortcut.map { "\(label) (\($0))" } ?? label)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .onHover { isHovered = $0 && isEnabled }
        .animation(.easeInOut(duration: 0.12), value: isHovered)
        .animation(.easeInOut(duration: 0.12), value: isSelected)
    }

    private var foreground: Color {
        guard isEnabled else { return .primary.opacity(0.2) }
        if isSelected || isHovered { return Color.remarcPrimary(for: colorScheme) }
        return .primary.opacity(0.55)
    }

    private var background: Color {
        guard isEnabled else { return .clear }
        if isSelected { return Color.remarcPrimary(for: colorScheme).opacity(0.14) }
        if isHovered { return Color.primary.opacity(0.07) }
        return .clear
    }
}

/// The filled confirm: flatten the marks and leave.
///
/// Deliberately the only filled control wherever it appears, so weight alone
/// marks it as the way out. Internal rather than private because the preview
/// panel's header hosts it too.
package struct AnnotationApplyButton: View {
    package init(action: @escaping () -> Void, isEnabled: Bool = true) { self.action = action; self.isEnabled = isEnabled }
    @ObservedObject private var localization = LocalizationManager.shared
    package let action: () -> Void
    /// False while a commit is already in flight, so a second press cannot
    /// start a parallel write to the same file.
    package var isEnabled: Bool = true

    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovered = false

    package var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Image(systemName: "checkmark")
                    .font(.system(size: 10.5, weight: .bold))
                Text(L10n.tr("Apply"))
                    .font(.system(size: 11.5, weight: .semibold))
            }
            .foregroundStyle(foreground)
            .padding(.horizontal, 9)
            .frame(height: 24)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color.remarcSuccess(for: colorScheme))
                    .brightness(isHovered ? 0.05 : 0)
            )
            .opacity(isEnabled ? 1 : 0.5)
            .contentShape(Rectangle())
        }
        .buttonStyle(AnnotationButtonPressStyle(pressedScale: 0.97))
        .disabled(!isEnabled)
        .help(isEnabled ? L10n.tr("Apply annotations to the saved image") : L10n.tr("Applying..."))
        .accessibilityLabel(L10n.tr("Apply annotations"))
        .onHover { isHovered = $0 && isEnabled }
        .animation(.easeInOut(duration: 0.12), value: isHovered)
    }

    /// The success token is a deep green in light mode but a bright mint in
    /// dark, so one fixed foreground fails contrast in one of them: white on
    /// the mint measures about 1.9:1.
    private var foreground: Color {
        colorScheme == .dark ? Color.black.opacity(0.82) : .white
    }
}

private struct InkSwatch: View {
    @ObservedObject private var localization = LocalizationManager.shared
    package let ink: AnnotationInk
    package let isSelected: Bool
    package var showsChevron = false
    package let action: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovered = false

    package var body: some View {
        Button(action: action) {
            HStack(spacing: 1.5) {
                Circle()
                    .fill(Color(.sRGB, red: ink.red, green: ink.green, blue: ink.blue,
                                opacity: ink.alpha))
                    .frame(width: 14, height: 14)
                    .overlay(
                        Circle().strokeBorder(
                            Color.remarcPrimary(for: colorScheme),
                            lineWidth: isSelected ? 2 : (isHovered ? 1.5 : 0))
                        .padding(-2.5)
                    )
                if showsChevron {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 6.5, weight: .bold))
                        .foregroundStyle(.primary.opacity(0.55))
                }
            }
            .frame(width: showsChevron ? 32 : 24, height: 24)
            .contentShape(Rectangle())
        }
        .buttonStyle(AnnotationButtonPressStyle(pressedScale: 0.88))
        .help(showsChevron ? L10n.tr("Color") : L10n.tr("Use this color"))
        .accessibilityLabel(L10n.tr("Annotation color"))
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .onHover { isHovered = $0 }
        .animation(.easeInOut(duration: 0.12), value: isSelected)
        .animation(.easeInOut(duration: 0.12), value: isHovered)
    }
}

/// The annotation toolbar.
///
/// Deliberately compact. Eleven tools, six colors, and three stroke presets all
/// laid out at once made a bar roughly 620pt wide, which is wider than most
/// selections and dominated the screen. Related controls collapse into a single
/// button that swaps the row in place when opened - the same pattern the discard
/// bar already uses, rather than a menu, because an `NSMenu` from a nonactivating
/// panel at `.screenSaver + 2` is not a thing this codebase has ever relied on.
///
/// `ToastOverlay` is mounted locally: the shared one lives only in the menu-bar
/// popover, which is dismissed before capture starts, so an error shown through
/// the global manager during annotation would render nowhere.
package struct AnnotationToolbarView: View {
    package init(session: AnnotationSession, zoomState: ZoomState?, showsDiscardControls: Bool,
                 onZoomStep: @escaping (Int) -> Void = { _ in }, onUndo: @escaping () -> Void = {},
                 onRedo: @escaping () -> Void = {}, onDone: @escaping () -> Void = {}, onApply: (() -> Void)? = nil,
                 onRequestDiscard: @escaping () -> Void = {}, onConfirmDiscard: @escaping () -> Void = {},
                 onCancelDiscard: @escaping () -> Void = {}) {
        self.session = session; self.zoomState = zoomState; self.showsDiscardControls = showsDiscardControls
        self.onZoomStep = onZoomStep; self.onUndo = onUndo; self.onRedo = onRedo; self.onDone = onDone
        self.onApply = onApply; self.onRequestDiscard = onRequestDiscard
        self.onConfirmDiscard = onConfirmDiscard; self.onCancelDiscard = onCancelDiscard
    }
    @ObservedObject private var localization = LocalizationManager.shared
    @ObservedObject private var toastManager = ToastManager.shared
    @ObservedObject var session: AnnotationSession

    /// nil hides the stepper entirely: it appears only when magnification can
    /// actually do something.
    package let zoomState: ZoomState?
    package let showsDiscardControls: Bool

    package var onZoomStep: (Int) -> Void = { _ in }
    package var onUndo: () -> Void = {}
    package var onRedo: () -> Void = {}
    package var onDone: () -> Void = {}

    /// Flatten the marks into the stored image and leave.
    ///
    /// Non-nil only where flattening means something: the saved-comment preview
    /// panel. The capture path carries its marks forward into the comment being
    /// composed and has no Apply step, so it keeps the plain Done control.
    package var onApply: (() -> Void)?
    package var onRequestDiscard: () -> Void = {}
    package var onConfirmDiscard: () -> Void = {}
    package var onCancelDiscard: () -> Void = {}

    package struct ZoomState: Equatable {
        package init(effectiveZoom: Int, maxZoom: Int) { self.effectiveZoom = effectiveZoom; self.maxZoom = maxZoom }
        /// **Always the achieved zoom, never the requested one.** A requested 2x
        /// that displayed the selection unchanged while reporting 2x would break
        /// every fitted-rect assumption downstream.
        var effectiveZoom: Int
        var maxZoom: Int
    }

    /// Which group, if any, has taken over the row.
    private enum Expansion { case none, arrows, shapes, redact, colors, strokes }
    @State private var expansion: Expansion = .none

    @Environment(\.colorScheme) private var colorScheme

    /// Collapsed into one control each: three shapes, two redactions.
    private static let shapeTools: [(AnnotationTool, String, String, String)] = [
        (.rect, "rectangle", "Rectangle", "R"),
        (.oval, "oval", "Oval", "O"),
        (.line, "line.diagonal", "Line", "L")
    ]
    private static let redactTools: [(AnnotationTool, String, String, String)] = [
        (.blur, "drop.fill", "Blur", "B"),
        (.pixelate, "square.grid.3x3.fill", "Pixelate", "X")
    ]

    package var body: some View {
        HStack(spacing: AppIdentity.current.isDevelopment ? 6 : 0) {
            DevelopmentIdentityBadge()
            Group {
                if showsDiscardControls {
                    discardBar
                } else {
                    HStack(spacing: 2) {
                        switch expansion {
                        case .none: mainBar
                        case .arrows: arrowBar
                        case .shapes: groupBar(Self.shapeTools, title: L10n.tr("Shape"))
                        case .redact: groupBar(Self.redactTools, title: L10n.tr("Redact"))
                        case .colors: colorBar
                        case .strokes: strokeBar
                        }
                        divider
                        historyControls
                        if expansion == .none {
                            resolutionControls
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .overlay(alignment: .top) {
            if let toast = toastManager.currentToast {
                ToastOverlay(toast: toast)
                    .offset(y: -34)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.14), value: expansion)
        .animation(.easeInOut(duration: 0.14), value: showsDiscardControls)
    }

    // MARK: - Main row

    private var mainBar: some View {
        HStack(spacing: 2) {
            Group {
                AnnotationToolButton(systemImage: "cursorarrow", label: L10n.tr("Select"), shortcut: "V",
                                     isSelected: session.tool == .select) { session.tool = .select }
                AnnotationToolButton(systemImage: session.arrowStyle.systemImage,
                                     label: session.arrowStyle.label, shortcut: "A",
                                     isSelected: session.tool == .arrow,
                                     hasGroup: true) {
                    session.tool = .arrow
                    expansion = .arrows
                }

                AnnotationToolButton(systemImage: shapeIcon, label: L10n.tr("Shape"),
                                     shortcut: "R / O / L",
                                     isSelected: Self.shapeTools.contains { $0.0 == session.tool },
                                     hasGroup: true) { expansion = .shapes }

                AnnotationToolButton(systemImage: "scribble", label: L10n.tr("Pen"), shortcut: "P",
                                     isSelected: session.tool == .freehand) { session.tool = .freehand }
                AnnotationToolButton(systemImage: "highlighter", label: L10n.tr("Highlighter"), shortcut: "H",
                                     isSelected: session.tool == .highlighter) { session.tool = .highlighter }
                AnnotationToolButton(systemImage: "textformat", label: L10n.tr("Text"), shortcut: "T",
                                     isSelected: session.tool == .text) { session.tool = .text }
                AnnotationToolButton(systemImage: "number.circle", label: L10n.tr("Counter"), shortcut: "C",
                                     isSelected: session.tool == .counter) { session.tool = .counter }

                AnnotationToolButton(systemImage: redactIcon, label: L10n.tr("Redact"), shortcut: L10n.tr("B / X"),
                                     isSelected: Self.redactTools.contains { $0.0 == session.tool },
                                     hasGroup: true) { expansion = .redact }
            }

            divider

            InkSwatch(ink: session.ink, isSelected: false, showsChevron: true) {
                expansion = .colors
            }
            AnnotationToolButton(systemImage: strokeIcon(session.stroke),
                                 label: L10n.tr("\(session.stroke.label) stroke"), shortcut: nil,
                                 hasGroup: true) { expansion = .strokes }
        }
    }

    // History stays available while a tool, color, or stroke group is open.
    // The hosting panels route the shortcuts after a toolbar click takes focus.
    private var historyControls: some View {
        HStack(spacing: 2) {
            AnnotationToolButton(systemImage: "arrow.uturn.backward", label: L10n.tr("Undo"),
                                 shortcut: "⌘Z", isEnabled: session.canUndo && !session.isFrozen,
                                 action: onUndo)
            AnnotationToolButton(systemImage: "arrow.uturn.forward", label: L10n.tr("Redo"),
                                 shortcut: "⇧⌘Z", isEnabled: session.canRedo && !session.isFrozen,
                                 action: onRedo)
        }
    }

    @ViewBuilder
    private var resolutionControls: some View {
        if let zoomState, zoomState.maxZoom > 1 {
            divider
            zoomStepper(zoomState)
        }

        // The saved-image preview has its own Apply and Discard header.
        if onApply == nil {
            divider
            AnnotationToolButton(systemImage: "trash", label: L10n.tr("Discard annotations"),
                                 shortcut: nil, isEnabled: session.isDirty,
                                 action: onRequestDiscard)
            AnnotationToolButton(systemImage: "checkmark", label: L10n.tr("Done annotating"),
                                 shortcut: "Esc", action: onDone)
        }
    }

    // MARK: - Expanded rows

    private func groupBar(_ tools: [(AnnotationTool, String, String, String)],
                          title: String) -> some View {
        HStack(spacing: 2) {
            backButton
            Text(title)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.primary.opacity(0.6))
                .padding(.trailing, 2)
            ForEach(tools, id: \.0) { tool, image, label, key in
                AnnotationToolButton(systemImage: image, label: L10n.lookup(label), shortcut: key,
                                     isSelected: session.tool == tool) {
                    session.tool = tool
                    expansion = .none
                }
            }
        }
    }

    private var arrowBar: some View {
        HStack(spacing: 2) {
            backButton
            Text(L10n.tr("Arrow"))
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.primary.opacity(0.6))
                .padding(.trailing, 2)
            ForEach(AnnotationArrowStyle.allCases, id: \.self) { style in
                AnnotationToolButton(systemImage: style.systemImage, label: style.label,
                                     shortcut: nil,
                                     isSelected: session.arrowStyle == style) {
                    session.arrowStyle = style
                    session.tool = .arrow
                    expansion = .none
                }
            }
        }
    }

    private var colorBar: some View {
        HStack(spacing: 2) {
            backButton
            ForEach(Array(AnnotationInk.presets.enumerated()), id: \.offset) { _, ink in
                InkSwatch(ink: ink, isSelected: session.ink == ink) {
                    session.ink = ink
                    session.restyleSelected(ink: ink)
                    expansion = .none
                }
            }
        }
    }

    private var strokeBar: some View {
        HStack(spacing: 2) {
            backButton
            ForEach(AnnotationStroke.allCases, id: \.self) { preset in
                AnnotationToolButton(systemImage: strokeIcon(preset),
                                     label: L10n.tr("\(preset.label) stroke"), shortcut: nil,
                                     isSelected: session.stroke == preset) {
                    session.stroke = preset
                    session.restyleSelected(stroke: preset)
                    expansion = .none
                }
            }
        }
    }

    private var backButton: some View {
        AnnotationToolButton(systemImage: "chevron.left", label: L10n.tr("Back"), shortcut: nil) {
            expansion = .none
        }
    }

    /// Inline discard, built from two controls rather than a modal: a sheet over a
    /// `.screenSaver` overlay is not reliably keyable.
    private var discardBar: some View {
        HStack(spacing: 8) {
            Text(L10n.tr("Discard all annotations?"))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.primary.opacity(0.75))
            Spacer(minLength: 8)
            AnnotationToolButton(systemImage: "xmark", label: L10n.tr("Keep annotating"),
                                 shortcut: "Esc", action: onCancelDiscard)
            AnnotationToolButton(systemImage: "trash.fill", label: L10n.tr("Discard"),
                                 shortcut: nil, action: onConfirmDiscard)
        }
        .frame(minWidth: 240)
    }

    private func zoomStepper(_ state: ZoomState) -> some View {
        HStack(spacing: 1) {
            AnnotationToolButton(systemImage: "minus", label: L10n.tr("Zoom out"), shortcut: L10n.tr("Cmd -"),
                                 isEnabled: state.effectiveZoom > 1) { onZoomStep(-1) }
            Text(L10n.tr("\(state.effectiveZoom)x"))
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundStyle(.primary.opacity(0.7))
                .frame(minWidth: 20)
                .accessibilityLabel(L10n.tr("Zoom \(state.effectiveZoom) times"))
            AnnotationToolButton(systemImage: "plus", label: L10n.tr("Zoom in"), shortcut: L10n.tr("Cmd +"),
                                 isEnabled: state.effectiveZoom < state.maxZoom) { onZoomStep(1) }
        }
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.12))
            .frame(width: 1, height: 16)
            .padding(.horizontal, 2)
    }

    /// The collapsed control shows whichever member of its group is active, so the
    /// current tool is still readable without opening it.
    private var shapeIcon: String {
        Self.shapeTools.first { $0.0 == session.tool }?.1 ?? "rectangle"
    }

    private var redactIcon: String {
        Self.redactTools.first { $0.0 == session.tool }?.1 ?? "drop.fill"
    }

    private func strokeIcon(_ preset: AnnotationStroke) -> String {
        switch preset {
        case .thin: return "line.horizontal.3.decrease"
        case .medium: return "equal"
        case .thick: return "minus"
        }
    }
}
