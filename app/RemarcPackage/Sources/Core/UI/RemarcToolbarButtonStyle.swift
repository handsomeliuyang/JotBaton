import CoreTheme
import SwiftUI

/// Compact toolbar actions share one surface and interaction hierarchy.
package struct RemarcToolbarButtonStyle: ButtonStyle {
    package init(prominent: Bool = false, isActive: Bool = false,
                 isWorking: Bool = false, attentionTint: Color? = nil,
                 tint: Color? = nil) {
        self.prominent = prominent
        self.isActive = isActive
        self.isWorking = isWorking
        self.attentionTint = attentionTint
        self.tint = tint
    }

    private let prominent: Bool
    private let isActive: Bool
    private let isWorking: Bool
    private let attentionTint: Color?
    private let tint: Color?

    package func makeBody(configuration: Configuration) -> some View {
        ToolbarButtonBody(
            label: configuration.label,
            prominent: prominent,
            isActive: isActive,
            isWorking: isWorking,
            attentionTint: attentionTint,
            tint: tint,
            isPressed: configuration.isPressed
        )
    }
}

private struct ToolbarButtonBody<Label: View>: View {
    let label: Label
    let prominent: Bool
    let isActive: Bool
    let isWorking: Bool
    let attentionTint: Color?
    let tint: Color?
    let isPressed: Bool

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    private var highlighted: Bool {
        isEnabled && (isHovered || isActive || isPressed)
    }

    private var foreground: Color {
        if !isEnabled && !isWorking {
            return Color.remarcIconRest(for: colorScheme).opacity(0.45)
        }
        if prominent { return .white }
        if let tint { return tint }
        return attentionTint ?? (highlighted
            ? Color.remarcPrimary(for: colorScheme)
            : Color.remarcIconRest(for: colorScheme))
    }

    private var fill: Color {
        if !isEnabled && !isWorking {
            return Color.remarcToolbarButtonSurface(for: colorScheme).opacity(0.45)
        }
        if prominent { return Color.remarcButtonBase(for: colorScheme) }
        if let tint {
            let opacity: Double
            if isEnabled && isPressed {
                opacity = 0.24
            } else if highlighted {
                opacity = 0.18
            } else {
                opacity = 0.12
            }
            return tint.opacity(opacity)
        }
        return Color.remarcToolbarButtonSurface(
            for: colorScheme, highlighted: highlighted, pressed: isEnabled && isPressed
        )
    }

    var body: some View {
        label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(foreground)
            .tint(foreground)
            .frame(minWidth: 30, minHeight: 28, maxHeight: 28)
            .background {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(fill)
                    .overlay {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(isPressed ? Color.black : Color.white)
                            .opacity(prominent && highlighted ? (isPressed ? 0.12 : 0.06) : 0)
                    }
            }
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .onHover { isHovered = $0 }
            .animation(.easeInOut(duration: 0.15), value: highlighted)
            .animation(.easeOut(duration: 0.08), value: isPressed)
    }
}
