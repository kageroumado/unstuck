import AppKit

// Renders the Unstuck app icon: classic arrow cursor on a violet gradient
// rounded rect, 1024×1024 PNG. Usage: makeicon <output.png>

let canvasSize = 1024
let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: canvasSize, pixelsHigh: canvasSize,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

let canvas = NSRect(x: 0, y: 0, width: canvasSize, height: canvasSize)
let margin: CGFloat = 100
let background = NSBezierPath(roundedRect: canvas.insetBy(dx: margin, dy: margin), xRadius: 186, yRadius: 186)
NSGradient(
    starting: NSColor(calibratedRed: 0.13, green: 0.08, blue: 0.28, alpha: 1),
    ending: NSColor(calibratedRed: 0.47, green: 0.30, blue: 0.86, alpha: 1)
)!.draw(in: background, angle: 90)

// Classic arrow cursor outline, defined top-down in unit space.
let points: [(CGFloat, CGFloat)] = [
    (0.00, 0.00), (0.00, 0.88), (0.215, 0.705), (0.345, 0.99),
    (0.48, 0.93), (0.355, 0.655), (0.65, 0.655),
]
let scale: CGFloat = 500
let centerX: CGFloat = 512, centerY: CGFloat = 512
let arrow = NSBezierPath()
for (index, point) in points.enumerated() {
    let x = centerX + (point.0 - 0.325) * scale
    let y = centerY + (0.495 - point.1) * scale
    index == 0 ? arrow.move(to: NSPoint(x: x, y: y)) : arrow.line(to: NSPoint(x: x, y: y))
}
arrow.close()
arrow.lineJoinStyle = .round

let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.45)
shadow.shadowOffset = NSSize(width: 0, height: -14)
shadow.shadowBlurRadius = 34
shadow.set()

NSColor.white.setStroke()
arrow.lineWidth = 34
arrow.stroke()

NSShadow().set()
NSColor.black.setFill()
arrow.fill()

NSGraphicsContext.restoreGraphicsState()

let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon_1024.png"
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output))
print("wrote \(output)")
