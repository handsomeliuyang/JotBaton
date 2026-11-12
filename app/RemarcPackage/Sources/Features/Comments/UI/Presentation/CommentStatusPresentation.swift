import CoreTheme
import FeatureComments
import SwiftUI

extension CommentStatus {
    public static func color(for status: CommentStatus, colorScheme: ColorScheme) -> Color {
        switch status {
        case .open:       return Color.remarcPrimary(for: colorScheme)
        case .handedOff:  return Color.remarcInfo(for: colorScheme)
        case .inProgress: return Color.remarcWarning(for: colorScheme)
        case .resolved:   return Color.remarcResolved(for: colorScheme)
        }
    }
}
