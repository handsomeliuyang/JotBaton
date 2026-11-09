// Reproducible vector-drawn assets for the development app. No production assets are modified.
import AppKit
import Foundation

let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let assets = root.appendingPathComponent("app/Remarc/Assets.xcassets")
let iconSet = assets.appendingPathComponent("AppIconDev.appiconset")
let menuSet = assets.appendingPathComponent("MenuBarIconDev.imageset")
try FileManager.default.createDirectory(at: iconSet, withIntermediateDirectories: true)
try FileManager.default.createDirectory(at: menuSet, withIntermediateDirectories: true)

func render(size: Int, draw: () -> Void) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let scale = CGFloat(size) / 1024
    let transform = AffineTransform(scale: scale)
    (transform as NSAffineTransform).concat()
    draw()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

func drawIcon() {
    let background = NSBezierPath(roundedRect: NSRect(x: 82, y: 82, width: 860, height: 860), xRadius: 192, yRadius: 192)
    NSGradient(starting: NSColor(calibratedRed: 0.23, green: 0.18, blue: 0.65, alpha: 1),
               ending: NSColor(calibratedRed: 0.10, green: 0.10, blue: 0.27, alpha: 1))!.draw(in: background, angle: -90)
    NSColor.white.setFill()
    NSBezierPath(roundedRect: NSRect(x: 225, y: 375, width: 574, height: 378), xRadius: 100, yRadius: 100).fill()
    let tail = NSBezierPath()
    tail.move(to: NSPoint(x: 285, y: 420)); tail.line(to: NSPoint(x: 285, y: 300)); tail.line(to: NSPoint(x: 440, y: 420)); tail.close(); tail.fill()
    let ink = NSColor(calibratedRed: 0.23, green: 0.18, blue: 0.65, alpha: 1)
    ink.setStroke()
    for x in [CGFloat(360), 650] {
        let sign: CGFloat = x < 500 ? -1 : 1
        let path = NSBezierPath(); path.lineWidth = 38; path.lineCapStyle = .round; path.lineJoinStyle = .round
        path.move(to: NSPoint(x: x - sign * 42, y: 650)); path.line(to: NSPoint(x: x + sign * 30, y: 570)); path.line(to: NSPoint(x: x - sign * 42, y: 490)); path.stroke()
    }
    NSColor(calibratedRed: 1, green: 0.65, blue: 0.12, alpha: 1).setFill()
    NSBezierPath(roundedRect: NSRect(x: 410, y: 160, width: 460, height: 180), xRadius: 60, yRadius: 60).fill()
    let text = "DEV" as NSString
    let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 126, weight: .black), .foregroundColor: ink]
    let width = text.size(withAttributes: attrs).width
    text.draw(at: NSPoint(x: 640 - width / 2, y: 178), withAttributes: attrs)
}

for size in [16, 32, 64, 128, 256, 512, 1024] {
    try render(size: size, draw: drawIcon).write(to: iconSet.appendingPathComponent("icon_\(size)x\(size).png"))
}
try Data(contentsOf: assets.appendingPathComponent("AppIcon.appiconset/Contents.json")).write(to: iconSet.appendingPathComponent("Contents.json"))
for scale in [1, 2] {
    let data = render(size: 20 * scale) {
        NSColor.black.setFill()
        NSBezierPath(roundedRect: NSRect(x: 20, y: 170, width: 670, height: 650), xRadius: 130, yRadius: 130).fill()
        let text = "D" as NSString
        text.draw(at: NSPoint(x: 575, y: 80), withAttributes: [.font: NSFont.systemFont(ofSize: 620, weight: .heavy), .foregroundColor: NSColor.black])
        NSColor.white.setFill()
        NSBezierPath(roundedRect: NSRect(x: 150, y: 445, width: 390, height: 100), xRadius: 40, yRadius: 40).fill()
    }
    try data.write(to: menuSet.appendingPathComponent(scale == 1 ? "MenuBarIconDev.png" : "MenuBarIconDev@2x.png"))
}
let contents = #"{"images":[{"filename":"MenuBarIconDev.png","idiom":"mac","scale":"1x"},{"filename":"MenuBarIconDev@2x.png","idiom":"mac","scale":"2x"}],"info":{"author":"xcode","version":1},"properties":{"template-rendering-intent":"template"}}"#
try contents.write(to: menuSet.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
print("Generated independent DEV app and menu bar icons")
