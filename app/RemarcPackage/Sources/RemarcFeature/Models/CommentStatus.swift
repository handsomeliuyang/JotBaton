import Foundation
import SwiftUI

public enum CommentStatus: String, Codable, Sendable, CaseIterable {
    case open
    case handedOff
    case inProgress
    case resolved

    public var label: String {
        switch self {
        case .open: return "Open"
        case .handedOff: return "Handed Off"
        case .inProgress: return "正在开发中"
        case .resolved: return "Resolved"
        }
    }

    /// Shape cue so statuses stay distinguishable without relying on color alone.
    public var iconName: String {
        switch self {
        case .open: return "circle"
        case .handedOff: return "arrow.right.circle"
        case .inProgress: return "circle.lefthalf.filled"
        case .resolved: return "checkmark.circle.fill"
        }
    }

    public static func color(for status: CommentStatus, colorScheme: ColorScheme) -> Color {
        switch status {
        case .open:       return Color.remarcPrimary(for: colorScheme)
        case .handedOff:  return Color.remarcInfo(for: colorScheme)
        case .inProgress: return Color.remarcWarning(for: colorScheme)
        case .resolved:   return Color.remarcResolved(for: colorScheme)
        }
    }
}
