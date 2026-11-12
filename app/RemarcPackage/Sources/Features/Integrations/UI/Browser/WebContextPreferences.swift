import FeatureComments
import FeatureSettings
import Foundation

extension WebContext {
    @MainActor
    public func filtered() -> WebContext? {
        let settings = SettingsManager.shared
        return filtered(using: WebContextPrivacy(
            react: settings.webContextReactEnabled, styles: settings.webContextStylesEnabled,
            accessibility: settings.webContextAccessibilityEnabled, layout: settings.webContextLayoutEnabled,
            identity: settings.webContextIdentityEnabled, hyperframes: settings.webContextHyperframesEnabled))
    }
}
