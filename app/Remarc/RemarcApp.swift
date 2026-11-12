import SwiftUI
import RemarcFeature

@main
struct RemarcApp: App {
    @NSApplicationDelegateAdaptor(RemarcApplicationDelegate.self) var appDelegate

    var body: some Scene {
        RemarcSettingsScene()
    }
}
