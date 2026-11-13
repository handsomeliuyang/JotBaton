// Reproducible JotBaton vector artwork. Default: DEV only; --all also updates production and extension assets.
import AppKit
import Foundation

let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let assets = root.appendingPathComponent("app/Remarc/Assets.xcassets")
let allChannels = CommandLine.arguments.contains("--all")

func render(size: Int, canvas: CGFloat = 256, draw: () -> Void) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let transform = NSAffineTransform()
    transform.translateX(by: 0, yBy: CGFloat(size))
    transform.scaleX(by: CGFloat(size) / canvas, yBy: -CGFloat(size) / canvas)
    transform.concat()
    draw()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

// Coordinates match docs/brand-proposals/jotbaton-app-icon.svg.
func mark(color: NSColor, frameAlpha: CGFloat = 0.65) {
    color.withAlphaComponent(frameAlpha).setStroke()
    let frame = NSBezierPath()
    frame.lineWidth = 12; frame.lineCapStyle = .round; frame.lineJoinStyle = .round
    frame.move(to: NSPoint(x: 88, y: 68)); frame.line(to: NSPoint(x: 62, y: 68))
    frame.line(to: NSPoint(x: 62, y: 194)); frame.line(to: NSPoint(x: 182, y: 194))
    frame.line(to: NSPoint(x: 182, y: 170)); frame.stroke()
    color.setStroke()
    let baton = NSBezierPath()
    baton.lineWidth = 26; baton.lineCapStyle = .round
    baton.move(to: NSPoint(x: 100, y: 156)); baton.line(to: NSPoint(x: 132, y: 124))
    baton.move(to: NSPoint(x: 156, y: 100)); baton.line(to: NSPoint(x: 184, y: 72)); baton.stroke()
}

func drawIcon(development: Bool) {
    let shadow = NSBezierPath(roundedRect: NSRect(x: 16, y: 20, width: 224, height: 224), xRadius: 52, yRadius: 52)
    NSColor(calibratedWhite: 0.15, alpha: 0.12).setFill(); shadow.fill()
    let background = NSBezierPath(roundedRect: NSRect(x: 16, y: 14, width: 224, height: 224), xRadius: 52, yRadius: 52)
    // Existing remarcBrandIndigo / remarcPrimary light palette.
    NSGradient(starting: NSColor(calibratedRed: 0.388, green: 0.400, blue: 0.945, alpha: 1),
               ending: NSColor(calibratedRed: 0.263, green: 0.220, blue: 0.792, alpha: 1))!.draw(in: background, angle: 45)
    NSColor.white.withAlphaComponent(0.25).setStroke(); background.lineWidth = 1.6; background.stroke()
    mark(color: .white)
    if development {
        NSColor(calibratedRed: 0.09, green: 0.11, blue: 0.18, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: 124, y: 181, width: 102, height: 42), xRadius: 13, yRadius: 13).fill()
        // Text is drawn in its normal AppKit coordinate system.
        NSGraphicsContext.saveGraphicsState()
        let flip = NSAffineTransform(); flip.translateX(by: 0, yBy: 404); flip.scaleX(by: 1, yBy: -1); flip.concat()
        let text = "DEV" as NSString
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 25, weight: .black), .foregroundColor: NSColor.white]
        text.draw(at: NSPoint(x: 175 - text.size(withAttributes: attrs).width / 2, y: 187), withAttributes: attrs)
        NSGraphicsContext.restoreGraphicsState()
    }
}

for development in (allChannels ? [false, true] : [true]) {
    let iconName = development ? "AppIconDev" : "AppIcon"
    let menuName = development ? "MenuBarIconDev" : "MenuBarIcon"
    let iconSet = assets.appendingPathComponent(iconName + ".appiconset")
    let menuSet = assets.appendingPathComponent(menuName + ".imageset")
    try FileManager.default.createDirectory(at: iconSet, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: menuSet, withIntermediateDirectories: true)
    for size in [16, 32, 64, 128, 256, 512, 1024] {
        try render(size: size) { drawIcon(development: development) }.write(to: iconSet.appendingPathComponent("icon_\(size)x\(size).png"))
    }
    if development {
        try Data(contentsOf: assets.appendingPathComponent("AppIcon.appiconset/Contents.json")).write(to: iconSet.appendingPathComponent("Contents.json"))
    }
    for scale in [1, 2] {
        let data = render(size: 20 * scale, canvas: 200) {
            let transform = NSAffineTransform(); transform.translateX(by: -42, yBy: -34); transform.concat()
            mark(color: .black, frameAlpha: 1)
            if development {
                NSColor.black.setFill()
                NSBezierPath(ovalIn: NSRect(x: 187, y: 184, width: 23, height: 23)).fill()
            }
        }
        try data.write(to: menuSet.appendingPathComponent(menuName + (scale == 1 ? ".png" : "@2x.png")))
    }
    let contents: [String: Any] = ["images": [1, 2].map { scale in ["filename": menuName + (scale == 1 ? ".png" : "@2x.png"), "idiom": "mac", "scale": "\(scale)x"] }, "info": ["author": "xcode", "version": 1], "properties": ["template-rendering-intent": "template"]]
    try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys]).write(to: menuSet.appendingPathComponent("Contents.json"))
}
if allChannels {
    for size in [16, 32, 48, 128] {
        try render(size: size) { drawIcon(development: false) }.write(to: root.appendingPathComponent("extension/icons/icon\(size).png"))
    }
    // Keep the PopClip package path and callback stable, with independently drawn artwork.
    let svg = "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"48 48 168 168\"><g fill=\"none\" stroke=\"black\" stroke-linecap=\"round\" stroke-linejoin=\"round\"><path d=\"M88 68H62V194H182V170\" stroke-width=\"12\"/><path d=\"M100 156L132 124M156 100L184 72\" stroke-width=\"26\"/></g></svg>\n"
    try svg.write(to: root.appendingPathComponent("popclip/Remarc.popclipext/remarc-logo.svg"), atomically: true, encoding: .utf8)
}
print("Generated JotBaton artwork with distinct DEV application and menu bar icons")
