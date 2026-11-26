import CoreLocalization
import FeatureComments
import AppKit

/// Strips a trailing `.app` suffix returned by `FileManager.displayName(atPath:)`
/// when Finder's "Show all filename extensions" preference is enabled.
func normalizedAppDisplayName(_ rawName: String) -> String {
    if rawName.count > 4, rawName.lowercased().hasSuffix(".app") {
        return String(rawName.dropLast(4))
    }
    return rawName
}

/// Resolves a comment's `appBundleID` to a display name, or `nil` if no app is associated.
/// Results are cached to avoid repeated filesystem lookups per card per render.
@MainActor
func appDisplayName(for comment: Comment) -> String? {
    guard let bundleID = comment.appBundleID else { return nil }
    if let cached = appDisplayNameCache[bundleID] { return cached }
    guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
    let name = normalizedAppDisplayName(FileManager.default.displayName(atPath: url.path))
    appDisplayNameCache[bundleID] = name
    return name
}
@MainActor private var appDisplayNameCache: [String: String] = [:]

// MARK: - Compact Timestamp (display only)

extension Date {
    /// Compact timestamp for `CommentCardView` display. Display only; copy / export /
    /// Storage and export paths keep the full timestamp.
    ///
    /// - Same calendar day as `now`: time of day (`15:45` or `3:45 PM`).
    /// - Previous calendar day relative to `now`: `Yesterday 15:45` / `昨天 15:45`.
    /// - Earlier: the date, formatted with `dateFormat`.
    ///
    /// `now` and `calendar` are injected so tier decisions are deterministic in tests
    /// and a periodic refresh can re-evaluate them as time passes.
    @MainActor
    func remarcCompactTimestamp(
        dateFormat: ExportDateFormat,
        use24Hour: Bool,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> String {
        func formattedTime() -> String {
            let formatter = DateFormatter()
            formatter.calendar = calendar
            formatter.timeZone = calendar.timeZone
            formatter.locale = L10n.locale
            formatter.dateFormat = use24Hour ? "HH:mm" : "h:mm a"
            return formatter.string(from: self)
        }

        if calendar.isDate(self, inSameDayAs: now) {
            return formattedTime()
        }

        let startOfToday = calendar.startOfDay(for: now)
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: startOfToday),
           calendar.isDate(self, inSameDayAs: yesterday) {
            let time = formattedTime()
            return L10n.tr("Yesterday \(time)")
        }

        return ExportManager.shared.formatDate(
            self,
            format: dateFormat,
            locale: L10n.locale,
            calendar: calendar
        )
    }
}
