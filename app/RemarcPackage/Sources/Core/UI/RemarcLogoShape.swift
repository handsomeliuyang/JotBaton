import SwiftUI

// MARK: - R Logo Shape (for stroke-draw animation)

/// The Remarc "R" letterform as a SwiftUI Shape, suitable for .trim() animation.
/// Path data from assets/Icon-Components/R-shape.svg — the canonical icon shape.
package struct RemarcLogoShape: Shape {
    package init(part: Part) { self.part = part }
    package enum Part {
        case outline  // full outer contour (body + leg, one continuous stroke)
        case counter  // inner counter (the hole in the R bowl)
    }

    package let part: Part

    package func path(in rect: CGRect) -> Path {
        // SVG coordinate bounds: x 80..776, y 56..776
        // (includes control points for leg curve that extend to ~776)
        let svgMinX: CGFloat = 80
        let svgMinY: CGFloat = 56
        let svgWidth: CGFloat = 696   // 776 - 80
        let svgHeight: CGFloat = 720  // 776 - 56
        let scale = min(rect.width / svgWidth, rect.height / svgHeight)
        let offsetX = rect.midX - (svgWidth * scale) / 2
        let offsetY = rect.midY - (svgHeight * scale) / 2

        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: (x - svgMinX) * scale + offsetX, y: (y - svgMinY) * scale + offsetY)
        }

        var path = Path()

        switch part {
        case .outline:
            // Full R outer contour: body + leg as one continuous path
            // From R-shape.svg outer subpath
            path.move(to: p(452.273, 56))
            // Top of bowl curve (right side)
            path.addCurve(to: p(702.987, 306.714), control1: p(590.738, 56), control2: p(702.987, 168.249))
            // Bowl curve down to junction
            path.addCurve(to: p(553.532, 536.031), control1: p(702.987, 409.13), control2: p(641.538, 497.113))
            // Leg: extends from junction to bottom-right
            path.addCurve(to: p(767.565, 744.604), control1: p(622.091, 646.898), control2: p(692.824, 703.102))
            path.addCurve(to: p(763.084, 762.499), control1: p(775.975, 749.274), control2: p(772.704, 762.54))
            // Leg curves back to junction
            path.addCurve(to: p(427.549, 570.401), control1: p(576.277, 761.703), control2: p(573.236, 775.542))
            // Junction detail
            path.addCurve(to: p(402.632, 557.429), control1: p(421.841, 562.363), control2: p(412.491, 557.429))
            path.addLine(to: p(317.666, 557.429))
            path.addCurve(to: p(297.36, 565.209), control1: p(310.17, 557.429), control2: p(302.938, 560.199))
            // Down to bottom-left
            path.addLine(to: p(80, 760.422))
            // Up the left vertical stroke
            path.addLine(to: p(80, 200.351))
            // Top-left corner
            path.addCurve(to: p(224.351, 56), control1: p(80, 120.628), control2: p(144.628, 56))
            path.closeSubpath()

        case .counter:
            // Inner counter — same coordinate system as outline
            // From R-shape.svg inner subpath
            path.move(to: p(224.351, 162.364))
            path.addCurve(to: p(186.364, 200.351), control1: p(203.371, 162.364), control2: p(186.364, 179.371))
            path.addLine(to: p(186.364, 521.578))
            path.addLine(to: p(232.215, 480.327))
            path.addCurve(to: p(308.456, 451.065), control1: p(253.141, 461.493), control2: p(280.303, 451.065))
            path.addLine(to: p(452.273, 451.065))
            path.addCurve(to: p(596.623, 306.714), control1: p(531.995, 451.065), control2: p(596.623, 386.437))
            path.addCurve(to: p(452.273, 162.364), control1: p(596.623, 226.992), control2: p(531.995, 162.364))
            path.closeSubpath()
        }

        return path
    }
}
