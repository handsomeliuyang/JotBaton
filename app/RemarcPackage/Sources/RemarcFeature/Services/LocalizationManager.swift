import AppKit
import Combine
import Foundation

public enum AppLanguage: String, CaseIterable, Sendable, Identifiable {
    case system, english, simplifiedChinese

    public var id: String { rawValue }

    public func resolved(preferredLanguages: [String] = Locale.preferredLanguages) -> AppLanguage {
        guard self == .system else { return self }
        return preferredLanguages.first?.lowercased().hasPrefix("zh") == true ? .simplifiedChinese : .english
    }

    public var label: String {
        switch self {
        case .system: return L10n.tr("Follow System")
        case .english: return "English"
        case .simplifiedChinese: return "简体中文"
        }
    }
}

/// Uses this app's defaults domain, keeping production and development separate.
@MainActor
public final class LocalizationManager: ObservableObject {
    public static let shared = LocalizationManager()
    public nonisolated static let preferenceKey = "interfaceLanguage"

    @Published public var language: AppLanguage {
        didSet {
            defaults.set(language.rawValue, forKey: Self.preferenceKey)
            refreshWindowTitles()
        }
    }

    private let defaults: UserDefaults
    private var localeObserver: AnyCancellable?
    private var windowTitles: [WindowTitle] = []

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        language = AppLanguage(rawValue: defaults.string(forKey: Self.preferenceKey) ?? "") ?? .system
        localeObserver = NotificationCenter.default.publisher(for: NSLocale.currentLocaleDidChangeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.language == .system else { return }
                    self.objectWillChange.send()
                    self.refreshWindowTitles()
                }
            }
    }

    func registerTitle(_ key: L10n.Key, for window: NSWindow) {
        windowTitles.removeAll { $0.window == nil || $0.window === window }
        windowTitles.append(WindowTitle(window: window, key: key))
        window.title = L10n.tr(key)
    }

    private func refreshWindowTitles() {
        windowTitles.removeAll { $0.window == nil }
        for item in windowTitles { item.window?.title = L10n.tr(item.key) }
    }

    private struct WindowTitle {
        weak var window: NSWindow?
        let key: L10n.Key
    }
}

/// UI-only localization. Values remain separate from the lookup key, so user
/// text, names, paths and braces in interpolated values are never translated.
public enum L10n {
    public struct Key: ExpressibleByStringLiteral, ExpressibleByStringInterpolation, Sendable {
        let template: String
        let arguments: [String]

        public init(stringLiteral value: String) {
            template = value
            arguments = []
        }

        public init(stringInterpolation: StringInterpolation) {
            template = stringInterpolation.template
            arguments = stringInterpolation.arguments
        }

        public struct StringInterpolation: StringInterpolationProtocol {
            var template = ""
            var arguments: [String] = []

            public init(literalCapacity: Int, interpolationCount: Int) {
                template.reserveCapacity(literalCapacity)
                arguments.reserveCapacity(interpolationCount)
            }

            public mutating func appendLiteral(_ literal: String) { template += literal }

            public mutating func appendInterpolation<T>(_ value: T) {
                template += "{\(arguments.count)}"
                arguments.append(String(describing: value))
            }
        }
    }

    static let chinese: [String: String] = {
        guard let url = Bundle.module.url(forResource: "Localizations", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let strings = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return strings
    }()

    public static var language: AppLanguage {
        (AppLanguage(rawValue: UserDefaults.standard.string(forKey: LocalizationManager.preferenceKey) ?? "") ?? .system).resolved()
    }

    public static func tr(_ key: Key, language: AppLanguage? = nil) -> String {
        let selected = (language ?? self.language).resolved()
        let template = selected == .simplifiedChinese ? chinese[key.template] ?? key.template : key.template
        return render(template, arguments: key.arguments)
    }

    /// For stable, non-interpolated display keys such as settings section IDs.
    /// Call only for app-owned keys, never for comment or session content.
    public static func lookup(_ key: String, language: AppLanguage? = nil) -> String {
        // Persisted app-owned notices from an earlier language remain readable
        // after switching back. Dynamic user content never calls this method.
        let canonical = chinese[key] == nil ? englishByChinese[key] ?? key : key
        return tr(Key(stringLiteral: canonical), language: language)
    }

    private static let englishByChinese: [String: String] = {
        var result: [String: String] = [:]
        for key in chinese.keys.sorted() where !key.contains("{0}") {
            if let value = chinese[key] { result[value] = key }
        }
        return result
    }()

    public static var locale: Locale {
        Locale(identifier: language == .simplifiedChinese ? "zh_Hans" : "en")
    }

    static func render(_ template: String, arguments: [String]) -> String {
        var result = ""
        var index = template.startIndex
        while index < template.endIndex {
            if template[index] == "{", let end = template[index...].firstIndex(of: "}"),
               let position = Int(template[template.index(after: index)..<end]),
               arguments.indices.contains(position) {
                result += arguments[position]
                index = template.index(after: end)
            } else {
                result.append(template[index])
                index = template.index(after: index)
            }
        }
        return result
    }
}

extension NSWindow {
    func setLocalizedTitle(_ key: L10n.Key) {
        LocalizationManager.shared.registerTitle(key, for: self)
    }
}

extension Date {
    /// Presentation only. Export formatting retains its existing locale rules.
    func interfaceFormatted(date: Date.FormatStyle.DateStyle, time: Date.FormatStyle.TimeStyle) -> String {
        Date.FormatStyle(date: date, time: time).locale(L10n.locale).format(self)
    }
}
