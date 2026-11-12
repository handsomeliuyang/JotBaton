import CoreLocalization
import FeatureComments
import AppKit

/// Resolves a comment's `appBundleID` to a display name, or `nil` if no app is associated.
/// Results are cached to avoid repeated filesystem lookups per card per render.
@MainActor
func appDisplayName(for comment: Comment) -> String? {
    guard let bundleID = comment.appBundleID else { return nil }
    if let cached = appDisplayNameCache[bundleID] { return cached }
    guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
    let name = FileManager.default.displayName(atPath: url.path)
    appDisplayNameCache[bundleID] = name
    return name
}
@MainActor private var appDisplayNameCache: [String: String] = [:]

// MARK: - Compact Timestamp (display only)

extension Date {
    /// Compact timestamp for `CommentCardView` display. Display only; copy / export /
    /// MCP paths keep the full timestamp.
    ///
    /// - Less than 24h before `now`: time of day (`15:45` or `3:45 PM`).
    /// - 24h or older: the date, formatted with `dateFormat`.
    ///
    /// `now` is injected so the tier decision is deterministic in tests and so a
    /// periodic refresh can re-evaluate it as time passes.
    @MainActor
    func remarcCompactTimestamp(
        dateFormat: ExportDateFormat,
        use24Hour: Bool,
        now: Date = Date()
    ) -> String {
        if now.timeIntervalSince(self) < 24 * 60 * 60 {
            let formatter = DateFormatter()
            formatter.locale = L10n.locale
            formatter.dateFormat = use24Hour ? "HH:mm" : "h:mm a"
            return formatter.string(from: self)
        } else {
            return ExportManager.shared.formatDate(self, format: dateFormat, locale: L10n.locale)
        }
    }
}
