@testable import FeatureSettings
@testable import RemarcFeature
import AppKit
import Testing

@Suite("Menu bar icon")
struct MenuBarIconRendererTests {
    private let glyph = NSImage(size: NSSize(width: 18, height: 18))

    private func width(_ style: MenuBarIndicatorStyle, count: Int, warning: Bool = false) -> CGFloat {
        MenuBarIconRenderer.image(glyph: glyph, state: MenuBarIconState(style: style, unresolvedCount: count,
                                                                        needsSyncAttention: warning)).size.width
    }

    @Test(arguments: MenuBarIndicatorStyle.allCases)
    func tasksAndSyncProblemsNeverChangeTheWidth(_ style: MenuBarIndicatorStyle) {
        let widths = Set([0, 1, 9, 10, 99].flatMap { [width(style, count: $0), width(style, count: $0, warning: true)] })
        #expect(widths.count == 1)
    }

    @Test func onlyACountAboveNinetyNineWidens() {
        #expect(width(.count, count: 100) > width(.count, count: 99))
        #expect(MenuBarIconRenderer.countLabel(100) == "99+")
        #expect(width(.dot, count: 1) == width(.off, count: 0))
    }

    @Test func onlyTheSyncWarningIsDrawnInColor() {
        let quiet = MenuBarIconRenderer.image(glyph: glyph, state: MenuBarIconState(style: .count, unresolvedCount: 3, needsSyncAttention: false))
        let warning = MenuBarIconRenderer.image(glyph: glyph, state: MenuBarIconState(style: .count, unresolvedCount: 3, needsSyncAttention: true))
        #expect(quiet.isTemplate)
        #expect(!warning.isTemplate)
    }

    @Test func repeatedAppearanceNotificationsDoNotInvalidateTheIcon() throws {
        let icon = MenuBarIconState(style: .count, unresolvedCount: 3, needsSyncAttention: false)
        let first = try #require(NSAppearance(named: .aqua))
        let repeated = try #require(NSAppearance(named: .aqua))
        let painted = MenuBarIconRenderState(icon: icon, appearance: first)
        #expect(painted == MenuBarIconRenderState(icon: icon, appearance: repeated))

        var changed = icon
        changed.unresolvedCount += 1
        #expect(painted != MenuBarIconRenderState(icon: changed, appearance: first))
        changed = icon
        changed.needsSyncAttention = true
        #expect(painted != MenuBarIconRenderState(icon: changed, appearance: first))
    }

    @Test func lightDarkAndHighContrastChangesInvalidateTheIcon() throws {
        let icon = MenuBarIconState(style: .count, unresolvedCount: 3, needsSyncAttention: true)
        let names: [NSAppearance.Name] = [.aqua, .darkAqua, .vibrantLight, .vibrantDark]
        for name in names {
            let appearance = try #require(NSAppearance(named: name))
            let state = MenuBarIconRenderState(icon: icon, appearance: appearance)
            #expect(state.appearance == name)
            // Some macOS versions resolve the high-contrast appearance to
            // the ordinary name. Track the accessibility setting separately.
            #expect(state != MenuBarIconRenderState(icon: icon, appearance: appearance, increasedContrast: true))
            for other in names where other != name {
                let otherAppearance = try #require(NSAppearance(named: other))
                #expect(state != MenuBarIconRenderState(icon: icon, appearance: otherAppearance))
            }
        }
    }

    @Test func onlyArrivalsPopTheBadge() {
        let base = MenuBarIconState(style: .count, unresolvedCount: 2, needsSyncAttention: false)
        var added = base
        added.unresolvedCount = 3
        var resolved = base
        resolved.unresolvedCount = 1
        var warning = base
        warning.needsSyncAttention = true
        var restyled = added
        restyled.style = .dot
        var hidden = added
        hidden.style = .off
        #expect(added.announcesChange(since: base))
        #expect(warning.announcesChange(since: base))
        #expect(!resolved.announcesChange(since: base))
        #expect(!restyled.announcesChange(since: base))
        #expect(!base.announcesChange(since: warning))
        #expect(!hidden.announcesChange(since: MenuBarIconState(style: .off, unresolvedCount: 2, needsSyncAttention: false)))
    }
}
