import CoreLocalization
import CorePlatform
import CoreTheme
import AppKit
import SwiftUI

@MainActor
package enum RemarcBrandAssets {
    package static let applicationIcon: NSImage = {
        if let url = Bundle.main.url(forResource: AppIdentity.current.appIconName, withExtension: "icns"),
           let image = NSImage(contentsOf: url) {
            return image
        }
        return NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)
    }()
}

/// One brand mark for floating surfaces, including the selection tooltip.
@MainActor
package struct RemarcBrandMark: View {
    package init(size: CGFloat = 16) { self.size = size }

    @ObservedObject private var localization = LocalizationManager.shared
    package var size: CGFloat = 16

    package var body: some View {
        Group {
            if AppIdentity.current.isDevelopment {
                Image(nsImage: RemarcBrandAssets.applicationIcon)
                    .resizable()
                    .renderingMode(.original)
                    .interpolation(.high)
                    .scaledToFit()
            } else {
                ZStack {
                    Circle().fill(Color.remarcBrandIndigo)
                    RemarcLogoShape(part: .outline)
                        .fill(.white)
                        .overlay {
                            RemarcLogoShape(part: .counter)
                                .fill(.black)
                                .blendMode(.destinationOut)
                        }
                        .compositingGroup()
                        .frame(width: size / 2, height: size / 2)
                }
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel(AppIdentity.current.displayName)
    }
}

/// Makes composers and screenshot controls identifiable even without a title bar.
@MainActor
package struct DevelopmentIdentityBadge: View {
    package init() {}
    @ObservedObject private var localization = LocalizationManager.shared
    @Environment(\.colorScheme) private var colorScheme

    package var body: some View {
        if AppIdentity.current.isDevelopment {
            HStack(spacing: 4) {
                RemarcBrandMark(size: 18)
                Text(L10n.tr("DEV"))
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
            }
            .foregroundStyle(Color.remarcPrimary(for: colorScheme))
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color.remarcPrimary(for: colorScheme).opacity(0.12)))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(L10n.tr("Remarc Dev"))
        }
    }
}
