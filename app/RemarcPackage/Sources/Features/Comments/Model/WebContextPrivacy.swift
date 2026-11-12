import Foundation

/// Privacy choices belong to the context contract. Browser and composer callers
/// provide their current choices; stored comments never reach into app settings.
public struct WebContextPrivacy: Sendable {
    public var webContextReactEnabled: Bool
    public var webContextStylesEnabled: Bool
    public var webContextAccessibilityEnabled: Bool
    public var webContextLayoutEnabled: Bool
    public var webContextIdentityEnabled: Bool
    public var webContextHyperframesEnabled: Bool

    public init(react: Bool, styles: Bool, accessibility: Bool, layout: Bool, identity: Bool, hyperframes: Bool) {
        webContextReactEnabled = react
        webContextStylesEnabled = styles
        webContextAccessibilityEnabled = accessibility
        webContextLayoutEnabled = layout
        webContextIdentityEnabled = identity
        webContextHyperframesEnabled = hyperframes
    }
}
