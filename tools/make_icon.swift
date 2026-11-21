import AppKit
import Foundation

let size = 1024.0
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()
guard let context = NSGraphicsContext.current?.cgContext else { exit(1) }

let bounds = CGRect(x: 0, y: 0, width: size, height: size)
let rounded = CGPath(roundedRect: bounds.insetBy(dx: 26, dy: 26), cornerWidth: 214, cornerHeight: 214, transform: nil)

func gradient(_ colors: [NSColor], _ locations: [CGFloat]) -> CGGradient {
    CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
               colors: colors.map { $0.cgColor } as CFArray,
               locations: locations)!
}

// 玻璃底：半透明冷色渐变
context.saveGState()
context.addPath(rounded)
context.clip()
context.drawLinearGradient(
    gradient([NSColor(srgbRed: 0.42, green: 0.56, blue: 0.86, alpha: 0.92),
              NSColor(srgbRed: 0.16, green: 0.23, blue: 0.42, alpha: 0.96),
              NSColor(srgbRed: 0.07, green: 0.10, blue: 0.20, alpha: 1.0)],
             [0, 0.52, 1]),
    start: CGPoint(x: size * 0.12, y: size),
    end: CGPoint(x: size * 0.90, y: 0),
    options: []
)

// 左上高光，模拟玻璃反射
context.drawRadialGradient(
    gradient([NSColor(white: 1, alpha: 0.55), NSColor(white: 1, alpha: 0)], [0, 1]),
    startCenter: CGPoint(x: size * 0.28, y: size * 0.82), startRadius: 10,
    endCenter: CGPoint(x: size * 0.28, y: size * 0.82), endRadius: size * 0.62,
    options: []
)

// 暖光从灯条向下扩散
context.drawRadialGradient(
    gradient([NSColor(srgbRed: 1.0, green: 0.83, blue: 0.55, alpha: 0.60),
              NSColor(srgbRed: 1.0, green: 0.72, blue: 0.36, alpha: 0.0)], [0, 1]),
    startCenter: CGPoint(x: size * 0.5, y: size * 0.70), startRadius: 20,
    endCenter: CGPoint(x: size * 0.5, y: size * 0.70), endRadius: size * 0.5,
    options: []
)
context.restoreGState()

// 玻璃边框：内外两层营造厚度
context.saveGState()
context.addPath(rounded)
context.setStrokeColor(NSColor(white: 1, alpha: 0.42).cgColor)
context.setLineWidth(6)
context.strokePath()
context.addPath(CGPath(roundedRect: bounds.insetBy(dx: 40, dy: 40), cornerWidth: 200, cornerHeight: 200, transform: nil))
context.setStrokeColor(NSColor(white: 1, alpha: 0.12).cgColor)
context.setLineWidth(2)
context.strokePath()
context.restoreGState()

// 内容
context.saveGState()
context.addPath(rounded)
context.clip()

// 灯条：玻璃胶囊 + 柔光
let lamp = CGRect(x: 306, y: 700, width: 412, height: 58)
context.saveGState()
context.setShadow(offset: .zero, blur: 70, color: NSColor(srgbRed: 1, green: 0.82, blue: 0.5, alpha: 0.9).cgColor)
context.addPath(CGPath(roundedRect: lamp, cornerWidth: 29, cornerHeight: 29, transform: nil))
context.setFillColor(NSColor(srgbRed: 1.0, green: 0.93, blue: 0.78, alpha: 0.95).cgColor)
context.fillPath()
context.restoreGState()

context.saveGState()
context.addPath(CGPath(roundedRect: lamp, cornerWidth: 29, cornerHeight: 29, transform: nil))
context.clip()
context.drawLinearGradient(
    gradient([NSColor(white: 1, alpha: 0.85), NSColor(srgbRed: 1, green: 0.85, blue: 0.58, alpha: 0.9)], [0, 1]),
    start: CGPoint(x: 0, y: lamp.maxY), end: CGPoint(x: 0, y: lamp.minY), options: []
)
context.restoreGState()

// 屏幕：玻璃面板
let screen = CGRect(x: 196, y: 214, width: 632, height: 372)
let screenPath = CGPath(roundedRect: screen, cornerWidth: 44, cornerHeight: 44, transform: nil)
context.addPath(screenPath)
context.setFillColor(NSColor(srgbRed: 0.10, green: 0.14, blue: 0.24, alpha: 0.86).cgColor)
context.fillPath()
context.addPath(screenPath)
context.setStrokeColor(NSColor(white: 1, alpha: 0.55).cgColor)
context.setLineWidth(10)
context.strokePath()

// 屏幕内：顶部被照亮的高光带 + 两条亮度条
let topGlow = CGRect(x: screen.minX + 28, y: screen.maxY - 58, width: screen.width - 56, height: 26)
context.addPath(CGPath(roundedRect: topGlow, cornerWidth: 13, cornerHeight: 13, transform: nil))
context.setFillColor(NSColor(srgbRed: 1, green: 0.88, blue: 0.62, alpha: 0.55).cgColor)
context.fillPath()

let barWarm = CGRect(x: screen.minX + 60, y: screen.minY + 196, width: 350, height: 28)
context.addPath(CGPath(roundedRect: barWarm, cornerWidth: 14, cornerHeight: 14, transform: nil))
context.setFillColor(NSColor(srgbRed: 1, green: 0.82, blue: 0.52, alpha: 0.95).cgColor)
context.fillPath()

let barCool = CGRect(x: screen.minX + 60, y: screen.minY + 134, width: 216, height: 28)
context.addPath(CGPath(roundedRect: barCool, cornerWidth: 14, cornerHeight: 14, transform: nil))
context.setFillColor(NSColor(white: 1, alpha: 0.42).cgColor)
context.fillPath()

// 支架
let stem = CGRect(x: 470, y: 150, width: 84, height: 50)
context.addPath(CGPath(roundedRect: stem, cornerWidth: 14, cornerHeight: 14, transform: nil))
context.setFillColor(NSColor(white: 1, alpha: 0.28).cgColor)
context.fillPath()
let base = CGRect(x: 372, y: 92, width: 280, height: 28)
context.addPath(CGPath(roundedRect: base, cornerWidth: 14, cornerHeight: 14, transform: nil))
context.setFillColor(NSColor(white: 1, alpha: 0.34).cgColor)
context.fillPath()

context.restoreGState()
image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: tiff),
      let png = bitmap.representation(using: .png, properties: [:]) else { exit(1) }
let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon-glass.png"
try png.write(to: URL(fileURLWithPath: output))
print("wrote \(output)")