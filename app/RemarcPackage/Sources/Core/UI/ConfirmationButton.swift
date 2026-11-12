import CoreLocalization
import CoreTheme
import SwiftUI

package struct ConfirmationButton: View {
    package init(label: String, role: Role, action: @escaping () -> Void) {
        self.label = label; self.role = role; self.action = action
    }

    @ObservedObject private var localization = LocalizationManager.shared
    package enum Role {
        case cancel
        case destructive
        case confirm
    }

    package let label: String
    package let role: Role
    package let action: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovered = false

    package var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(foregroundColor)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(background, in: RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(borderColor, lineWidth: role == .cancel ? 1 : 0)

                )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(.easeInOut(duration: 0.15), value: isHovered)
    }

    private var foregroundColor: Color {
        switch role {
        case .cancel:
            .primary
        case .destructive, .confirm:
            .white
        }
    }

    private var background: some ShapeStyle {
        switch role {
        case .cancel:
            AnyShapeStyle(isHovered ? Color.primary.opacity(0.1) : Color.clear)
        case .destructive:
            AnyShapeStyle(
                Color.remarcError(for: colorScheme)
                    .opacity(isHovered ? 0.85 : 1.0)
            )
        case .confirm:
            AnyShapeStyle(
                Color.remarcConfirmationFill
                    .opacity(isHovered ? 0.85 : 1.0)
            )
        }
    }

    private var borderColor: Color {
        switch role {
        case .cancel:
            .primary.opacity(isHovered ? 0.25 : 0.15)
        case .destructive, .confirm:
            .clear
        }
    }
}
