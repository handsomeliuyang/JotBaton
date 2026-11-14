import CoreLocalization
import CorePlatform
import CoreUI
import FeatureCapture
import FeatureComments
import FeatureIntegrations
import Foundation
import Combine
import ServiceManagement
import KeyboardShortcuts

@MainActor
public final class SettingsManager: ObservableObject {
    public static let shared = SettingsManager()

    private let defaults = UserDefaults.standard

    /// Subset of keys that must be readable outside @MainActor (e.g. CGEventTap callbacks).
    package nonisolated static let screenshotDirectoryPathKey = remarcScreenshotDirectoryPathKey

    private enum Keys {
        static let isPaused = "isPaused"
        static let outputFormat = "outputFormat"
        static let selectionDetectionMode = "selectionDetectionMode"
        static let includeMetadataInExport = "includeMetadataInExport"
        static let historyRetentionDays = "historyRetentionDays"
        static let legacyImageRetentionDays = "imageRetentionDays"

        static let excludedAppBundleIDs = "excludedAppBundleIDs"
        static let hasCompletedOnboarding = "hasCompletedOnboarding"
        static let hasSeenMenuBarTooltip = "hasSeenMenuBarTooltip"
        static let widgetCorner = "widgetCorner"
        static let normalizeWhitespace = "normalizeWhitespace"
        static let copyScreenshotToClipboard = "copyScreenshotToClipboard"
        static let screenshotDirectoryPath = SettingsManager.screenshotDirectoryPathKey
        static let deleteResolvedComments = "deleteResolvedComments" // legacy migration key
        static let resolvedCommentDeletion = "resolvedCommentDeletion"
        static let autoClearAfterExport = "autoClearAfterExport" // legacy migration key
        static let clearAfterExportBehavior = "clearAfterExportBehavior"
        static let referenceStyle = "referenceStyle"
        static let numberingStyle = "numberingStyle"
        static let dividerStyle = "dividerStyle"
        static let exportDateFormat = "exportDateFormat"
        static let includeSource = "includeSource"
        static let includeDate = "includeDate"
        static let includeStatus = "includeStatus"
        static let includeTime = "includeTime"
        static let commentPrefixStyle = "commentPrefixStyle"
        static let timeFormat = "timeFormat"
        static let metadataDividerStyle = "metadataDividerStyle"
        static let includeRemarkID = "includeRemarkID"
        static let showInDock = "showInDock"
        static let includeType = "includeType"

        static let hasExtensionEverConnected = "hasExtensionEverConnected"
        static let webContextReactEnabled = "webContextReactEnabled"
        static let webContextStylesEnabled = "webContextStylesEnabled"
        static let webContextAccessibilityEnabled = "webContextAccessibilityEnabled"
        static let webContextLayoutEnabled = "webContextLayoutEnabled"
        static let webContextIdentityEnabled = "webContextIdentityEnabled"
        static let webContextHyperframesEnabled = "webContextHyperframesEnabled"

        static let extensionGrabElementShortcut = "extensionGrabElementShortcut"
        static let extensionRegionSelectShortcut = "extensionRegionSelectShortcut"

        static let tooltipPosition = "tooltipPosition"
        static let menuBarIndicatorStyle = "menuBarIndicatorStyle"
        static let retiredHidesMenuBarCountAtZero = "hidesMenuBarCountAtZero"
        static let inactiveSessionCleanupEnabled = "inactiveSessionCleanupEnabled"
        static let inactiveSessionCleanupInterval = "inactiveSessionCleanupInterval"
        static let historyDefaultsVersion = "historyDefaultsVersion"
        static let webhooksConfig = "webhooksConfig"
    }

    /// Apply the agreed History defaults once per installed channel. Later
    /// launches must preserve the user's choices, including disabling cleanup.
    package static func applyHistoryDefaults(to defaults: UserDefaults) {
        // Images now follow history retention. Never replace the user's history choice.
        defaults.removeObject(forKey: Keys.legacyImageRetentionDays)
        guard defaults.integer(forKey: Keys.historyDefaultsVersion) < 1 else { return }
        defaults.set(ResolvedCommentDeletion.immediately.rawValue, forKey: Keys.resolvedCommentDeletion)
        defaults.set(true, forKey: Keys.inactiveSessionCleanupEnabled)
        defaults.set(InactiveSessionCleanupInterval.after30Minutes.rawValue, forKey: Keys.inactiveSessionCleanupInterval)
        defaults.set(1, forKey: Keys.historyDefaultsVersion)
    }

    @Published public var isPaused: Bool {
        didSet { defaults.set(isPaused, forKey: Keys.isPaused) }
    }

    @Published public var outputFormat: OutputFormat {
        didSet { defaults.set(outputFormat.rawValue, forKey: Keys.outputFormat) }
    }

    @Published public var selectionDetectionMode: SelectionDetectionMode {
        didSet { defaults.set(selectionDetectionMode.rawValue, forKey: Keys.selectionDetectionMode) }
    }

    @Published public var tooltipPosition: TooltipPosition {
        didSet { defaults.set(tooltipPosition.rawValue, forKey: Keys.tooltipPosition) }
    }

    @Published public var menuBarIndicatorStyle: MenuBarIndicatorStyle {
        didSet { defaults.set(menuBarIndicatorStyle.rawValue, forKey: Keys.menuBarIndicatorStyle) }
    }

    @Published public var includeMetadataInExport: Bool {
        didSet { defaults.set(includeMetadataInExport, forKey: Keys.includeMetadataInExport) }
    }

    @Published public var historyRetentionDays: Int {
        didSet { defaults.set(historyRetentionDays, forKey: Keys.historyRetentionDays) }
    }

    @Published public var excludedAppBundleIDs: [String] {
        didSet { defaults.set(excludedAppBundleIDs, forKey: Keys.excludedAppBundleIDs) }
    }

    @Published public var hasCompletedOnboarding: Bool {
        didSet { defaults.set(hasCompletedOnboarding, forKey: Keys.hasCompletedOnboarding) }
    }

    @Published public var showInDock: Bool {
        didSet { defaults.set(showInDock, forKey: Keys.showInDock) }
    }

    @Published public var hasSeenMenuBarTooltip: Bool {
        didSet { defaults.set(hasSeenMenuBarTooltip, forKey: Keys.hasSeenMenuBarTooltip) }
    }

    @Published public var normalizeWhitespace: Bool {
        didSet { defaults.set(normalizeWhitespace, forKey: Keys.normalizeWhitespace) }
    }

    @Published public var copyScreenshotToClipboard: Bool {
        didSet { defaults.set(copyScreenshotToClipboard, forKey: Keys.copyScreenshotToClipboard) }
    }

    /// Absolute folder for new screenshots. Empty means Application Support/Remarc/images.
    @Published public private(set) var screenshotDirectoryPath: String

    /// Changes the destination only after the folder has been validated for saving images.
    public func setScreenshotDirectory(_ directory: URL?) throws {
        screenshotDirectoryPath = try ScreenshotStorage.configure(directory: directory, defaults: defaults)
    }

    @Published public var resolvedCommentDeletion: ResolvedCommentDeletion {
        didSet { defaults.set(resolvedCommentDeletion.rawValue, forKey: Keys.resolvedCommentDeletion) }
    }

    @Published public var inactiveSessionCleanupEnabled: Bool {
        didSet { defaults.set(inactiveSessionCleanupEnabled, forKey: Keys.inactiveSessionCleanupEnabled) }
    }

    @Published public var inactiveSessionCleanupInterval: InactiveSessionCleanupInterval {
        didSet { defaults.set(inactiveSessionCleanupInterval.rawValue, forKey: Keys.inactiveSessionCleanupInterval) }
    }

    @Published public var clearAfterExportBehavior: ClearAfterExportBehavior {
        didSet { defaults.set(clearAfterExportBehavior.rawValue, forKey: Keys.clearAfterExportBehavior) }
    }

    @Published public var referenceStyle: ReferenceStyle {
        didSet { defaults.set(referenceStyle.rawValue, forKey: Keys.referenceStyle) }
    }

    @Published public var clipboardLayout: ClipboardLayout {
        didSet { clipboardLayout.save(to: defaults) }
    }

    @Published public var numberingStyle: NumberingStyle {
        didSet { defaults.set(numberingStyle.rawValue, forKey: Keys.numberingStyle) }
    }

    @Published public var dividerStyle: DividerStyle {
        didSet { defaults.set(dividerStyle.rawValue, forKey: Keys.dividerStyle) }
    }

    @Published public var exportDateFormat: ExportDateFormat {
        didSet { defaults.set(exportDateFormat.rawValue, forKey: Keys.exportDateFormat) }
    }

    @Published public var includeSource: Bool {
        didSet { defaults.set(includeSource, forKey: Keys.includeSource) }
    }

    @Published public var includeDate: Bool {
        didSet { defaults.set(includeDate, forKey: Keys.includeDate) }
    }

    @Published public var includeStatus: Bool {
        didSet { defaults.set(includeStatus, forKey: Keys.includeStatus) }
    }

    @Published public var includeTime: Bool {
        didSet { defaults.set(includeTime, forKey: Keys.includeTime) }
    }

    @Published public var commentPrefixStyle: CommentPrefixStyle {
        didSet { defaults.set(commentPrefixStyle.rawValue, forKey: Keys.commentPrefixStyle) }
    }

    @Published public var timeFormat: TimeFormat {
        didSet { defaults.set(timeFormat.rawValue, forKey: Keys.timeFormat) }
    }

    @Published public var metadataDividerStyle: MetadataDividerStyle {
        didSet { defaults.set(metadataDividerStyle.rawValue, forKey: Keys.metadataDividerStyle) }
    }

    @Published public var includeRemarkID: Bool {
        didSet { defaults.set(includeRemarkID, forKey: Keys.includeRemarkID) }
    }

    @Published public var includeType: Bool {
        didSet { defaults.set(includeType, forKey: Keys.includeType) }
    }

    @Published public var widgetCorner: WidgetCorner {
        didSet { defaults.set(widgetCorner.rawValue, forKey: Keys.widgetCorner) }
    }

    @Published public var hasExtensionEverConnected: Bool {
        didSet { defaults.set(hasExtensionEverConnected, forKey: Keys.hasExtensionEverConnected) }
    }

    @Published public var webContextReactEnabled: Bool {
        didSet { defaults.set(webContextReactEnabled, forKey: Keys.webContextReactEnabled) }
    }

    @Published public var webContextStylesEnabled: Bool {
        didSet { defaults.set(webContextStylesEnabled, forKey: Keys.webContextStylesEnabled) }
    }

    @Published public var webContextAccessibilityEnabled: Bool {
        didSet { defaults.set(webContextAccessibilityEnabled, forKey: Keys.webContextAccessibilityEnabled) }
    }

    @Published public var webContextLayoutEnabled: Bool {
        didSet { defaults.set(webContextLayoutEnabled, forKey: Keys.webContextLayoutEnabled) }
    }

    @Published public var webContextIdentityEnabled: Bool {
        didSet { defaults.set(webContextIdentityEnabled, forKey: Keys.webContextIdentityEnabled) }
    }

    /// HyperFrames composition context attached to web-element/region/quickNote comments.
    /// Debug-only experimental feature. Defaults to `false` in release builds; the
    /// toggle is surfaced in Preferences → Experimental → HyperFrames Context (which is
    /// itself `#if DEBUG`-gated). When false, `WebContext.filtered()` nulls out
    /// `hyperframesContext` on save, so the field is dropped from persistence.
    @Published public var webContextHyperframesEnabled: Bool {
        didSet { defaults.set(webContextHyperframesEnabled, forKey: Keys.webContextHyperframesEnabled) }
    }

    @Published public var extensionGrabElementShortcut: ExtensionShortcut {
        didSet {
            if let data = try? JSONEncoder().encode(extensionGrabElementShortcut) {
                defaults.set(data, forKey: Keys.extensionGrabElementShortcut)
            }
        }
    }
    @Published public var extensionRegionSelectShortcut: ExtensionShortcut {
        didSet {
            if let data = try? JSONEncoder().encode(extensionRegionSelectShortcut) {
                defaults.set(data, forKey: Keys.extensionRegionSelectShortcut)
            }
        }
    }

    @Published public var webhooks: [Webhook] {
        didSet {
            if let data = try? JSONEncoder().encode(webhooks) {
                defaults.set(data, forKey: Keys.webhooksConfig)
            }
        }
    }

    /// Launch at Login — reads/writes directly via SMAppService
    public var launchAtLogin: Bool {
        get {
            SMAppService.mainApp.status == .enabled
        }
        set {
            do {
                if newValue {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                debugLog("Failed to \(newValue ? "enable" : "disable") launch at login: \(error)")
            }
        }
    }

    private init() {
        Self.applyHistoryDefaults(to: defaults)
        self.isPaused = defaults.bool(forKey: Keys.isPaused)

        if let savedFormat = defaults.string(forKey: Keys.outputFormat),
           let format = OutputFormat(rawValue: savedFormat) {
            self.outputFormat = format
        } else {
            self.outputFormat = .markdown
        }

        if let savedMode = defaults.string(forKey: Keys.selectionDetectionMode),
           let mode = SelectionDetectionMode(rawValue: savedMode) {
            self.selectionDetectionMode = mode
        } else {
            self.selectionDetectionMode = .auto
        }

        if let savedPos = defaults.string(forKey: Keys.tooltipPosition),
           let pos = TooltipPosition(rawValue: savedPos) {
            self.tooltipPosition = pos
        } else {
            self.tooltipPosition = .above
        }

        if let savedIndicator = defaults.string(forKey: Keys.menuBarIndicatorStyle),
           let indicator = MenuBarIndicatorStyle(rawValue: savedIndicator) {
            self.menuBarIndicatorStyle = indicator
        } else {
            self.menuBarIndicatorStyle = .count
        }
        // The indicator now always hides at zero.
        defaults.removeObject(forKey: Keys.retiredHidesMenuBarCountAtZero)

        if defaults.object(forKey: Keys.includeMetadataInExport) != nil {
            self.includeMetadataInExport = defaults.bool(forKey: Keys.includeMetadataInExport)
        } else {
            self.includeMetadataInExport = true
        }

        let savedRetention = defaults.integer(forKey: Keys.historyRetentionDays)
        self.historyRetentionDays = savedRetention > 0 ? savedRetention : CommentConstants.defaultHistoryRetentionDays

        if defaults.object(forKey: Keys.normalizeWhitespace) != nil {
            self.normalizeWhitespace = defaults.bool(forKey: Keys.normalizeWhitespace)
        } else {
            self.normalizeWhitespace = true
        }
        self.copyScreenshotToClipboard = defaults.bool(forKey: Keys.copyScreenshotToClipboard)
        self.screenshotDirectoryPath = defaults.string(forKey: Keys.screenshotDirectoryPath) ?? ""

        // Migration: old Bool deleteResolvedComments → new enum resolvedCommentDeletion
        if let saved = defaults.string(forKey: Keys.resolvedCommentDeletion),
           let value = ResolvedCommentDeletion(rawValue: saved) {
            self.resolvedCommentDeletion = value
        } else if defaults.object(forKey: Keys.deleteResolvedComments) != nil {
            // Migrate: old true → .immediately, old false → .never
            self.resolvedCommentDeletion = defaults.bool(forKey: Keys.deleteResolvedComments) ? .immediately : .never
        } else {
            self.resolvedCommentDeletion = .immediately
        }

        // Migration: old Bool autoClearAfterExport → new enum clearAfterExportBehavior
        if let saved = defaults.string(forKey: Keys.clearAfterExportBehavior),
           let value = ClearAfterExportBehavior(rawValue: saved) {
            self.clearAfterExportBehavior = value
        } else if defaults.object(forKey: Keys.autoClearAfterExport) != nil {
            // Migrate: old true → .delete, old false → .ask
            self.clearAfterExportBehavior = defaults.bool(forKey: Keys.autoClearAfterExport) ? .delete : .ask
        } else {
            self.clearAfterExportBehavior = .ask
        }

        self.inactiveSessionCleanupEnabled = defaults.object(forKey: Keys.inactiveSessionCleanupEnabled) == nil
            ? true : defaults.bool(forKey: Keys.inactiveSessionCleanupEnabled)
        if let saved = defaults.string(forKey: Keys.inactiveSessionCleanupInterval),
           let value = InactiveSessionCleanupInterval(rawValue: saved) {
            self.inactiveSessionCleanupInterval = value
        } else {
            self.inactiveSessionCleanupInterval = .after30Minutes
        }

        self.clipboardLayout = ClipboardLayout.load(from: defaults)

        if let saved = defaults.string(forKey: Keys.referenceStyle),
           let style = ReferenceStyle(rawValue: saved) {
            self.referenceStyle = style
        } else {
            self.referenceStyle = .plain
        }

        if let saved = defaults.string(forKey: Keys.numberingStyle),
           let style = NumberingStyle(rawValue: saved) {
            self.numberingStyle = style
        } else {
            self.numberingStyle = .numbered
        }

        if let saved = defaults.string(forKey: Keys.dividerStyle),
           let style = DividerStyle(rawValue: saved) {
            self.dividerStyle = style
        } else {
            self.dividerStyle = .blankLine
        }

        if let saved = defaults.string(forKey: Keys.exportDateFormat),
           let fmt = ExportDateFormat(rawValue: saved) {
            self.exportDateFormat = fmt
        } else {
            self.exportDateFormat = .short
        }

        // Migration: if old includeMetadataInExport was explicitly set, use it for includeSource/includeDate
        let metadataDefault = defaults.object(forKey: Keys.includeMetadataInExport) != nil
            ? defaults.bool(forKey: Keys.includeMetadataInExport)
            : true

        if defaults.object(forKey: Keys.includeSource) != nil {
            self.includeSource = defaults.bool(forKey: Keys.includeSource)
        } else {
            self.includeSource = metadataDefault
        }

        if defaults.object(forKey: Keys.includeDate) != nil {
            self.includeDate = defaults.bool(forKey: Keys.includeDate)
        } else {
            self.includeDate = metadataDefault
        }

        if defaults.object(forKey: Keys.includeStatus) != nil {
            self.includeStatus = defaults.bool(forKey: Keys.includeStatus)
        } else {
            self.includeStatus = false
        }

        self.includeTime = defaults.bool(forKey: Keys.includeTime)

        if let saved = defaults.string(forKey: Keys.commentPrefixStyle),
           let style = CommentPrefixStyle(rawValue: saved) {
            self.commentPrefixStyle = style
        } else {
            self.commentPrefixStyle = .comment
        }

        if let saved = defaults.string(forKey: Keys.timeFormat),
           let fmt = TimeFormat(rawValue: saved) {
            self.timeFormat = fmt
        } else {
            self.timeFormat = .twelve
        }

        if let saved = defaults.string(forKey: Keys.metadataDividerStyle),
           let style = MetadataDividerStyle(rawValue: saved) {
            self.metadataDividerStyle = style
        } else {
            self.metadataDividerStyle = .pipe
        }

        self.excludedAppBundleIDs = defaults.stringArray(forKey: Keys.excludedAppBundleIDs) ?? []
        self.hasCompletedOnboarding = defaults.bool(forKey: Keys.hasCompletedOnboarding)
        self.showInDock = defaults.bool(forKey: Keys.showInDock)
        self.hasSeenMenuBarTooltip = defaults.bool(forKey: Keys.hasSeenMenuBarTooltip)
        if defaults.object(forKey: Keys.includeRemarkID) != nil {
            self.includeRemarkID = defaults.bool(forKey: Keys.includeRemarkID)
        } else {
            self.includeRemarkID = true
        }


        if defaults.object(forKey: Keys.includeType) != nil {
            self.includeType = defaults.bool(forKey: Keys.includeType)
        } else {
            self.includeType = true
        }

        if let savedCorner = defaults.string(forKey: Keys.widgetCorner),
           let corner = WidgetCorner(rawValue: savedCorner) {
            self.widgetCorner = corner
        } else {
            self.widgetCorner = .bottomRight
        }

        self.hasExtensionEverConnected = defaults.bool(forKey: Keys.hasExtensionEverConnected)

        self.webContextReactEnabled = defaults.object(forKey: Keys.webContextReactEnabled) == nil
            ? true : defaults.bool(forKey: Keys.webContextReactEnabled)
        self.webContextStylesEnabled = defaults.object(forKey: Keys.webContextStylesEnabled) == nil
            ? true : defaults.bool(forKey: Keys.webContextStylesEnabled)
        self.webContextAccessibilityEnabled = defaults.object(forKey: Keys.webContextAccessibilityEnabled) == nil
            ? true : defaults.bool(forKey: Keys.webContextAccessibilityEnabled)
        self.webContextLayoutEnabled = defaults.object(forKey: Keys.webContextLayoutEnabled) == nil
            ? true : defaults.bool(forKey: Keys.webContextLayoutEnabled)
        self.webContextIdentityEnabled = defaults.object(forKey: Keys.webContextIdentityEnabled) == nil
            ? true : defaults.bool(forKey: Keys.webContextIdentityEnabled)
        // Debug-only / experimental — defaults FALSE so release builds never persist HF context.
        self.webContextHyperframesEnabled = defaults.object(forKey: Keys.webContextHyperframesEnabled) == nil
            ? false : defaults.bool(forKey: Keys.webContextHyperframesEnabled)

        if let data = defaults.data(forKey: Keys.extensionGrabElementShortcut),
           let shortcut = try? JSONDecoder().decode(ExtensionShortcut.self, from: data) {
            self.extensionGrabElementShortcut = shortcut
        } else {
            self.extensionGrabElementShortcut = .defaultGrabElement
        }
        if let data = defaults.data(forKey: Keys.extensionRegionSelectShortcut),
           let shortcut = try? JSONDecoder().decode(ExtensionShortcut.self, from: data) {
            self.extensionRegionSelectShortcut = shortcut
        } else {
            self.extensionRegionSelectShortcut = .defaultRegionSelect
        }

        if let data = defaults.data(forKey: Keys.webhooksConfig),
           let decoded = try? JSONDecoder().decode([Webhook].self, from: data) {
            self.webhooks = decoded
        } else {
            self.webhooks = []
        }

    }

}
