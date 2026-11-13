import CoreLocalization
import CoreTheme
import SwiftUI

// MARK: - Creation Header Button (prominent circular buttons in the header)

struct CreationHeaderButton: View {
    @ObservedObject private var localization = LocalizationManager.shared
    let icon: String
    let brandColor: Color
    let colorScheme: ColorScheme
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(isHovered ? brandColor : Color.remarcIconRest(for: colorScheme))
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isHovered ? Color.remarcNeutralFill(for: colorScheme) : Color.clear)
                )
                .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
        }
        .animation(.easeInOut(duration: 0.15), value: isHovered)
    }
}
