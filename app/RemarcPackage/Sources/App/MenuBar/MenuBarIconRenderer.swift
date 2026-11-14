import FeatureSettings
import AppKit

/// What the menu bar icon reports, independent of how it is drawn.
struct MenuBarIconState: Equatable {
    var style: MenuBarIndicatorStyle
    var unresolvedCount: Int
    var needsSyncAttention: Bool

    var indicator: MenuBarIndicator { style.indicator(forCommentCount: unresolvedCount) }

    /// Something new arrived: a task was added, or sync started needing the
    /// user. Only then does the badge pop; removals and setting changes repaint
    /// silently.
    func announcesChange(since old: MenuBarIconState) -> Bool {
        if needsSyncAttention && !old.needsSyncAttention { return true }
        return style == old.style && indicator != .none && unresolvedCount > old.unresolvedCount
    }
}

/// Draws the status item as a single image on a canvas whose width depends only
/// on the chosen style, so tasks coming and going never reflow the menu bar
/// (a count only widens past 99).
///
/// Everything is monochrome and template-rendered like the system's own items,
/// except the sync warning: a problem the user must fix is the one state that
/// earns color.
enum MenuBarIconRenderer {
    /// Badge sizes. The ring is background knocked out of the glyph, so a badge
    /// stays legible against both the glyph and any wallpaper behind the bar.
    static let dotDiameter: CGFloat = 5.5
    static let warningDiameter: CGFloat = 8
    static let ringGap: CGFloat = 1.5
    /// How far a corner badge hangs past the glyph. The mark fills its box, so a
    /// badge placed inside would cut through the letterform.
    static let cornerOverhang: CGFloat = 4
    static let verticalPadding: CGFloat = 1
    static let countFontSize: CGFloat = 11
    static let countGap: CGFloat = 1

    /// Pop-in: quick grow, slight overshoot, settle. Six frames at 40ms.
    static let popScales: [CGFloat] = [0.45, 0.8, 1.08, 1.12, 1.04, 1.0]

    static func countLabel(_ count: Int) -> String { count > 99 ? "99+" : "\(count)" }

    private static func countFont(scale: CGFloat = 1) -> NSFont {
        NSFont.monospacedDigitSystemFont(ofSize: countFontSize * scale, weight: .semibold)
    }

    private static func width(of label: String) -> CGFloat {
        (label as NSString).size(withAttributes: [.font: countFont()]).width
    }

    static func image(glyph: NSImage, state: MenuBarIconState, badgeScale: CGFloat = 1) -> NSImage {
        let glyphSize = glyph.size
        let indicator = state.indicator
        var label: String?
        if case .count(let count) = indicator { label = countLabel(count) }
        // Two digits are always reserved, so 1 through 99 share one width.
        let reserved = width(of: "88")
        let labelWidth = label.map(width(of:)) ?? 0
        let countArea = state.style == .count ? countGap + ceil(max(reserved, labelWidth)) : 0
        let canvas = NSSize(width: glyphSize.width + cornerOverhang + countArea,
                            height: glyphSize.height + verticalPadding * 2)
        let colored = state.needsSyncAttention

        let image = NSImage(size: canvas, flipped: false) { _ in
            // Template images only use alpha. The warning variant cannot be a
            // template, so its glyph takes the menu bar's label color, resolved
            // against the appearance the item is drawn in.
            let ink: NSColor = colored ? .labelColor : .black
            let glyphRect = CGRect(x: 0, y: verticalPadding, width: glyphSize.width, height: glyphSize.height)
            if colored { tinted(glyph, ink).draw(in: glyphRect) } else { glyph.draw(in: glyphRect) }

            let corner = CGPoint(x: glyphSize.width + cornerOverhang - warningDiameter / 2 - ringGap,
                                 y: canvas.height - warningDiameter / 2 - ringGap)
            if colored {
                drawWarning(centeredAt: corner, scale: badgeScale)
            } else if indicator == .dot {
                let center = CGPoint(x: glyphSize.width + cornerOverhang - dotDiameter / 2 - ringGap,
                                     y: canvas.height - dotDiameter / 2 - ringGap)
                knockOut(diameter: (dotDiameter + ringGap * 2) * badgeScale, at: center)
                ink.setFill()
                circle(diameter: dotDiameter * badgeScale, at: center).fill()
            }

            if let label {
                drawCount(label, ink: ink, scale: badgeScale,
                          in: CGRect(x: glyphSize.width + cornerOverhang + countGap, y: 0,
                                     width: countArea - countGap, height: canvas.height))
            }
            return true
        }
        image.isTemplate = !colored
        return image
    }

    private static func circle(diameter: CGFloat, at center: CGPoint) -> NSBezierPath {
        NSBezierPath(ovalIn: CGRect(x: center.x - diameter / 2, y: center.y - diameter / 2, width: diameter, height: diameter))
    }

    /// Clears alpha instead of painting, so the ring reads as background.
    private static func knockOut(diameter: CGFloat, at center: CGPoint) {
        NSGraphicsContext.current?.compositingOperation = .destinationOut
        NSColor.black.setFill()
        circle(diameter: diameter, at: center).fill()
        NSGraphicsContext.current?.compositingOperation = .sourceOver
    }

    private static func drawWarning(centeredAt center: CGPoint, scale: CGFloat) {
        let diameter = warningDiameter * scale
        guard diameter > 1 else { return }
        knockOut(diameter: diameter + ringGap * 2 * scale, at: center)
        NSColor.systemOrange.setFill()
        circle(diameter: diameter, at: center).fill()
        // An exclamation mark drawn as shapes stays crisp at this size.
        NSColor.white.setFill()
        let bar = CGSize(width: 1.4 * scale, height: 3.4 * scale)
        NSBezierPath(roundedRect: CGRect(x: center.x - bar.width / 2, y: center.y - 0.6 * scale,
                                         width: bar.width, height: bar.height),
                     xRadius: bar.width / 2, yRadius: bar.width / 2).fill()
        circle(diameter: 1.5 * scale, at: CGPoint(x: center.x, y: center.y - 2.1 * scale)).fill()
    }

    private static func drawCount(_ label: String, ink: NSColor, scale: CGFloat, in area: CGRect) {
        guard scale > 0.05 else { return }
        let font = countFont(scale: scale)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: ink]
        let size = (label as NSString).size(withAttributes: attributes)
        // Leading-aligned beside the glyph, scaled about the label's own centre,
        // with digits centred on cap height.
        let origin = CGPoint(x: area.minX + (width(of: label) - size.width) / 2,
                             y: area.midY - font.capHeight / 2 + font.descender)
        (label as NSString).draw(at: origin, withAttributes: attributes)
    }

    private static func tinted(_ glyph: NSImage, _ color: NSColor) -> NSImage {
        NSImage(size: glyph.size, flipped: false) { rect in
            glyph.draw(in: rect)
            color.set()
            rect.fill(using: .sourceIn)
            return true
        }
    }
}
