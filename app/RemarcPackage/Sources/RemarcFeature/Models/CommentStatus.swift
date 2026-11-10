import Foundation
import SwiftUI

public enum CommentStatus: String, Codable, Sendable, CaseIterable {
    case open
    case handedOff
    case inProgress
    case resolved

    /// Stable export wording is independent of the interface language.
    public var exportLabel: String {
        switch self {
        case .open: return "Open"
        case .handedOff: return "Handed Off"
        case .inProgress: return "正在开发中"
        case .resolved: return "Resolved"
        }
    }

    public var label: String { localizedLabel(language: L10n.language) }

    func localizedLabel(language: AppLanguage) -> String {
        switch self {
        case .open: return L10n.tr("Open", language: language)
        case .handedOff: return L10n.tr("Handed Off", language: language)
        case .inProgress: return L10n.tr("In Progress", language: language)
        case .resolved: return L10n.tr("Resolved", language: language)
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
