import CoreLocalization
import Foundation

public enum CommentStatus: String, Codable, Sendable, CaseIterable {
    case open
    // Retain the legacy wire value so existing comments, sync and filters remain readable.
    case reusable = "handedOff"
    case inProgress
    case deferred
    case resolved

    /// Reusable context joins every handoff while keeping its status and timestamps.
    public var canStartDevelopment: Bool {
        self == .open || self == .reusable || self == .inProgress
    }

    /// Export wording is independent of the interface language.
    public var exportLabel: String {
        switch self {
        case .open: return "Open"
        case .reusable: return "Reusable"
        case .inProgress: return "In Progress"
        case .deferred: return "On Hold"
        case .resolved: return "Resolved"
        }
    }

    public var label: String { localizedLabel(language: L10n.language) }

    package func localizedLabel(language: AppLanguage) -> String {
        switch self {
        case .open: return L10n.tr("Open", language: language)
        case .reusable: return L10n.tr("Reusable", language: language)
        case .inProgress: return L10n.tr("In Progress", language: language)
        case .deferred: return L10n.tr("On Hold", language: language)
        case .resolved: return L10n.tr("Resolved", language: language)
        }
    }

    /// Shape cue so statuses stay distinguishable without relying on color alone.
    public var iconName: String {
        switch self {
        case .open: return "circle"
        case .reusable: return "arrow.triangle.2.circlepath"
        case .inProgress: return "circle.lefthalf.filled"
        case .deferred: return "pause.circle"
        case .resolved: return "checkmark.circle.fill"
        }
    }

}
