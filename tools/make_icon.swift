import AppKit
import Foundation

// 玻璃风图标：上方护眼灯条照亮显示器，一眼可读为“屏幕灯控制”
let size = 1024.0
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()
guard let context = NSGraphicsContext.current?.cgContext else { exit(1) }

let bounds = CGRect(x: 0, y: 0, width: size, height: size)
let rounded = CGPath(roundedRect: bounds.insetBy(dx: 26, dy: 26), cornerWidth: 216, cornerHeight: 216, transform: nil)

func gradient(_ colors: [NSColor], _ locations: [CGFloat]) -> CGGradient {
    CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
               colors: colors.map { $0.cgColor } as CFArray,
               locations: locations)!
}

// 底色：冷调玻璃渐变
context.saveGState()
context.addPath(rounded)
context.clip()
context.drawLinearGradient(
    gradient([NSColor(srgbRed: 0.40, green: 0.55, blue: 0.88, alpha: 0.95),
              NSColor(srgbRed: 0.14, green: 0.21, blue: 0.40, alpha: 0.98),
              NSColor(srgbRed: 0.06, green: 0.08, blue: 0.17, alpha: 1.0)],
             [0, 0.58, 1]),
    start: CGPoint(x: size * 0.08, y: size),
    end: CGPoint(x: size * 0.95, y: 0),
    options: []
)
context.restoreGState()

let screen = CGRect(x: 148, y: 236, width: 728, height: 424)
let lamp = CGRect(x: 300, y: 726, width: 424, height: 58)

// 灯条柔光（先画，位于灯条与屏幕之间）
context.saveGState()
context.addPath(rounded)
context.clip()
context.drawRadialGradient(
    gradient([NSColor(srgbRed: 1.0, green: 0.86, blue: 0.58, alpha: 0.55),
              NSColor(srgbRed: 1.0, green: 0.80, blue: 0.45, alpha: 0.0)], [0, 1]),
    startCenter: CGPoint(x: size * 0.5, y: lamp.minY), startRadius: 20,
    endCenter: CGPoint(x: size * 0.5, y: lamp.minY), endRadius: size * 0.46,
    options: []
)
context.restoreGState()

// 显示器本体
let bodyPath = CGPath(roundedRect: screen, cornerWidth: 54, cornerHeight: 54, transform: nil)
context.addPath(bodyPath)
context.setFillColor(NSColor(srgbRed: 0.05, green: 0.07, blue: 0.14, alpha: 1).cgColor)
context.fillPath()

// 屏幕面：顶部受光、越往下越暗
let panel = screen.insetBy(dx: 24, dy: 24)
let panelPath = CGPath(roundedRect: panel, cornerWidth: 36, cornerHeight: 36, transform: nil)
context.saveGState()
context.addPath(panelPath)
context.clip()
context.drawLinearGradient(
    gradient([NSColor(srgbRed: 1.0, green: 0.90, blue: 0.66, alpha: 0.95),
              NSColor(srgbRed: 0.55, green: 0.66, blue: 0.92, alpha: 0.55),
              NSColor(srgbRed: 0.06, green: 0.08, blue: 0.17, alpha: 1.0)],
             [0, 0.32, 1]),
    start: CGPoint(x: size * 0.5, y: panel.maxY),
    end: CGPoint(x: size * 0.5, y: panel.minY),
    options: []
)
context.restoreGState()

// 顶部受光衰减（柔和光斑，不用硬边白条）
context.saveGState()
context.addPath(panelPath)
context.clip()
context.drawLinearGradient(
    gradient([NSColor(white: 1, alpha: 0.42), NSColor(white: 1, alpha: 0.0)], [0, 1]),
    start: CGPoint(x: size * 0.5, y: panel.maxY),
    end: CGPoint(x: size * 0.5, y: panel.maxY - panel.height * 0.55),
    options: []
)
context.restoreGState()

// 玻璃外框高光
context.saveGState()
context.addPath(bodyPath)
context.setStrokeColor(NSColor(white: 1, alpha: 0.62).cgColor)
context.setLineWidth(14)
context.strokePath()
context.restoreGState()

// 灯条：亮胶囊 + 强光晕
context.saveGState()
context.setShadow(offset: CGSize(width: 0, height: -14), blur: 80, color: NSColor(srgbRed: 1, green: 0.85, blue: 0.54, alpha: 1).cgColor)
context.addPath(CGPath(roundedRect: lamp, cornerWidth: 29, cornerHeight: 29, transform: nil))
context.setFillColor(NSColor(srgbRed: 1.0, green: 0.96, blue: 0.85, alpha: 1).cgColor)
context.fillPath()
context.restoreGState()
context.saveGState()
context.addPath(CGPath(roundedRect: lamp, cornerWidth: 29, cornerHeight: 29, transform: nil))
context.clip()
context.drawLinearGradient(
    gradient([NSColor(white: 1, alpha: 0.95), NSColor(srgbRed: 1, green: 0.82, blue: 0.50, alpha: 1)], [0, 1]),
    start: CGPoint(x: 0, y: lamp.maxY), end: CGPoint(x: 0, y: lamp.minY), options: []
)
context.restoreGState()

// 支架与底座
let stem = CGRect(x: 470, y: 176, width: 84, height: 62)
context.addPath(CGPath(roundedRect: stem, cornerWidth: 16, cornerHeight: 16, transform: nil))
context.setFillColor(NSColor(white: 1, alpha: 0.38).cgColor)
context.fillPath()
let base = CGRect(x: 348, y: 118, width: 328, height: 32)
context.addPath(CGPath(roundedRect: base, cornerWidth: 16, cornerHeight: 16, transform: nil))
context.setFillColor(NSColor(white: 1, alpha: 0.44).cgColor)
context.fillPath()

// 玻璃外圈
context.saveGState()
context.addPath(rounded)
context.setStrokeColor(NSColor(white: 1, alpha: 0.40).cgColor)
context.setLineWidth(6)
context.strokePath()
context.restoreGState()

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: tiff),
      let png = bitmap.representation(using: .png, properties: [:]) else { exit(1) }
let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"
try png.write(to: URL(fileURLWithPath: output))
print("wrote \(output)")