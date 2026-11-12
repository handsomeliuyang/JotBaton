import CoreLocalization
import SwiftUI

public struct RemarcSettingsScene: Scene {
    public init() {}
    @ObservedObject private var localization = LocalizationManager.shared

    public var body: some Scene {
        Settings {
            EmptyView()
        }
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button(L10n.tr("Settings…")) {
                    Task { @MainActor in
                        PreferencesWindowController.shared.show()
                    }
                }
                .keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}
