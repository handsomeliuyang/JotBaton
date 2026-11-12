import CoreLocalization
import CorePlatform
import CoreUI
import FeatureSettings
import AppKit
import KeyboardShortcuts
import SwiftUI
import UniformTypeIdentifiers

/// Shared metrics for the Settings panes.
enum SettingsMetrics {
    /// Width of the control column: the pickers, and the space the toggles sit in.
    static let controlColumnWidth: CGFloat = 180

    /// Keeps a row's explanation clear of the control column on the right.
    ///
    /// Without it, notes wrap to the full pane width and end on the same right
    /// edge as the toggles and pickers, so a group reads as one dense slab
    /// instead of a row with a note under it. Stopping where the controls begin
    /// gives the pane a single text measure to read down.
    static let descriptionTrailingInset: CGFloat = controlColumnWidth + 16

    /// Gap between a row and its own explanation.
    static let descriptionSpacing: CGFloat = 5

    /// Extra gap after an explained row, so its note stays visually bound to the
    /// row above rather than the unrelated control below.
    static let describedRowBottomPadding: CGFloat = 4
}

/// Indent plus a leading hairline for a setting that only appears because of
/// the row above it, so the indent gutter reads as nesting rather than an
/// unexplained gap beside the row.
struct NestedSettingModifier: ViewModifier {
    private static let indent: CGFloat = 20

    /// Thin and nearly transparent on purpose: the rule gives the indent an
    /// edge to hang off without competing with the row it belongs to.
    private static let ruleWidth: CGFloat = 1
    private static let ruleOpacity: Double = 0.1

    func body(content: Content) -> some View {
        content
            .padding(.leading, Self.indent)
            .overlay(alignment: .leading) {
                RoundedRectangle(cornerRadius: Self.ruleWidth / 2)
                    .fill(.primary.opacity(Self.ruleOpacity))
                    .frame(width: Self.ruleWidth)
            }
    }
}

extension View {
    /// Styling for the secondary explanation under a settings row.
    func settingDescriptionStyle(opacity: Double = 0.35) -> some View {
        self
            .font(.system(size: 11))
            .foregroundStyle(.primary.opacity(opacity))
            .fixedSize(horizontal: false, vertical: true)
            .padding(.trailing, SettingsMetrics.descriptionTrailingInset)
    }

    /// Marks a settings block as a child of the row above it.
    func nestedSetting() -> some View {
        modifier(NestedSettingModifier())
    }
}

@MainActor
public final class PreferencesWindowController: NSObject, NSWindowDelegate {
    public static let shared = PreferencesWindowController()

    private var window: NSWindow?
    private var resizeObserver: Any?

    /// Notification posted when a specific prefs tab should be selected.
    static let selectTabNotification = Notification.Name("PreferencesSelectTab")

    /// Notification posted when the window should resize for a section.
    static let resizeNotification = Notification.Name("PreferencesResize")

    /// UserDefaults key for persisting the selected settings section.
    static let selectedSectionKey = "selectedSettingsSection"

    /// Window dimensions per section type.
    static let exportSize = NSSize(width: 1100, height: 580)
    /// Wide enough that most row descriptions fit on a single line once the
    /// trailing inset keeps them clear of the control column.
    static let defaultSize = NSSize(width: 940, height: 730)

    public func show() {
        showWithTab("General")
    }

    public func show(tab: String) {
        showWithTab(tab)
    }

    private func showWithTab(_ tab: String) {
        // Dismiss the menu bar popover so it doesn't cover the settings window
        MenuBarPopoverController.shared.dismiss()

        if window == nil {
            // Persist the target tab before the view initializes so its @State
            // init reads it. Otherwise the view starts on the last-persisted
            // tab and the notification below can race the onReceive setup.
            UserDefaults.standard.set(tab, forKey: Self.selectedSectionKey)
            createWindow()
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        ActivationPolicyManager.shared.register(self)

        // Post on the next runloop tick so SwiftUI's onReceive subscription is
        // active by the time the notification fires (covers the case where the
        // window already existed and a fresh @State init no longer runs).
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: Self.selectTabNotification, object: tab)
        }
    }

    private func createWindow() {
        // Determine initial size from persisted section
        let isExport = UserDefaults.standard.string(forKey: Self.selectedSectionKey) == "Export"
        let initialSize = isExport ? Self.exportSize : Self.defaultSize

        let prefsView = PreferencesView()
        let hostingView = NSHostingView(rootView: prefsView)
        hostingView.sizingOptions = []  // Prevent intrinsic content size from stretching the window

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: initialSize.width, height: initialSize.height),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        window.setLocalizedTitle("\(AppIdentity.current.displayName) Settings")
        window.isReleasedWhenClosed = false
        window.center()
        self.window = window
        window.delegate = self

        // Listen for resize requests
        resizeObserver = NotificationCenter.default.addObserver(
            forName: Self.resizeNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let isExport = notification.object as? Bool else { return }
            let targetSize = isExport ? Self.exportSize : Self.defaultSize
            self?.resizeWindow(to: targetSize)
        }
    }

    private func resizeWindow(to targetSize: NSSize) {
        guard let window else { return }
        let currentFrame = window.frame

        // Don't animate if already at the right size
        guard abs(currentFrame.width - targetSize.width) > 1
           || abs(currentFrame.height - targetSize.height) > 1 else { return }

        // Pin top edge, center width change horizontally
        let deltaWidth = targetSize.width - currentFrame.width
        let deltaHeight = targetSize.height - currentFrame.height
        let newFrame = NSRect(
            x: currentFrame.origin.x - deltaWidth / 2,
            y: currentFrame.origin.y - deltaHeight,  // pin top edge (macOS y is bottom-up)
            width: targetSize.width,
            height: targetSize.height
        )

        let shouldAnimate = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        window.setFrame(newFrame, display: true, animate: shouldAnimate)
    }

    public var isVisible: Bool {
        window?.isVisible == true
    }

    public var isMiniaturized: Bool {
        window?.isMiniaturized == true
    }

    public func bringBack() {
        guard let window else { return }
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        ActivationPolicyManager.shared.register(self)
    }

    public func windowWillClose(_ notification: Notification) {
        ActivationPolicyManager.shared.unregister(self)
    }
}

// MARK: - Preferences View
