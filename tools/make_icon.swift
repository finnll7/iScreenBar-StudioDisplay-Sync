import AppKit
import Foundation

// 参考官方视觉语言重绘：深色圆角底 + 顶部灯条 + 柔和扩散的暖→冷光
let size = 1024.0
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()
guard let context = NSGraphicsContext.current?.cgContext else { exit(1) }

let bounds = CGRect(x: 0, y: 0, width: size, height: size)
let rounded = CGPath(roundedRect: bounds.insetBy(dx: 24, dy: 24), cornerWidth: 220, cornerHeight: 220, transform: nil)

func grad(_ colors: [NSColor], _ locations: [CGFloat]) -> CGGradient {
    CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
               colors: colors.map { $0.cgColor } as CFArray,
               locations: locations)!
}

func radial(_ colors: [NSColor], _ locations: [CGFloat], center: CGPoint, radius: CGFloat, scaleY: CGFloat = 1) {
    context.saveGState()
    context.translateBy(x: center.x, y: center.y)
    context.scaleBy(x: 1, y: scaleY)
    context.drawRadialGradient(grad(colors, locations),
                               startCenter: .zero, startRadius: 0,
                               endCenter: .zero, endRadius: radius,
                               options: [])
    context.restoreGState()
}

context.saveGState()
context.addPath(rounded)
context.clip()

// 1) 深色底
context.drawLinearGradient(
    grad([NSColor(white: 0.13, alpha: 1), NSColor(white: 0.06, alpha: 1), NSColor(white: 0.02, alpha: 1)],
         [0, 0.5, 1]),
    start: CGPoint(x: size * 0.5, y: size), end: CGPoint(x: size * 0.5, y: 0), options: []
)

// 2) 主光池：从灯条向下柔和扩散（椭圆径向渐变，没有硬边）
radial([NSColor(white: 1.0, alpha: 0.92),
        NSColor(white: 1.0, alpha: 0.42),
        NSColor(white: 1.0, alpha: 0.0)],
       [0, 0.5, 1],
       center: CGPoint(x: size * 0.5, y: size * 0.46),
       radius: size * 0.56,
       scaleY: 1.05)

// 2b) 灯条正下方的窄光斑，让光源与光圈连起来
radial([NSColor(white: 1.0, alpha: 0.85), NSColor(white: 1.0, alpha: 0.0)], [0, 1],
       center: CGPoint(x: size * 0.5, y: size * 0.74), radius: size * 0.30, scaleY: 0.75)

// 3) 左侧暖色
radial([NSColor(srgbRed: 1.0, green: 0.78, blue: 0.38, alpha: 0.80),
        NSColor(srgbRed: 1.0, green: 0.76, blue: 0.36, alpha: 0.0)],
       [0, 1],
       center: CGPoint(x: size * 0.34, y: size * 0.34),
       radius: size * 0.36,
       scaleY: 1.25)

// 4) 右侧冷色
radial([NSColor(srgbRed: 0.70, green: 0.84, blue: 1.0, alpha: 0.82),
        NSColor(srgbRed: 0.70, green: 0.84, blue: 1.0, alpha: 0.0)],
       [0, 1],
       center: CGPoint(x: size * 0.66, y: size * 0.32),
       radius: size * 0.36,
       scaleY: 1.25)

// 5) 顶部压暗，让灯条区域更聚焦
context.drawLinearGradient(
    grad([NSColor(white: 0, alpha: 0.85), NSColor(white: 0, alpha: 0.35), NSColor(white: 0, alpha: 0.0)], [0, 0.55, 1]),
    start: CGPoint(x: 0, y: size), end: CGPoint(x: 0, y: size * 0.62), options: []
)

// 6) 灯条（亮白胶囊 + 强光晕）
let lampWidth = size * 0.46
let lampHeight = size * 0.028
let lampRect = CGRect(x: (size - lampWidth) / 2, y: size * 0.795, width: lampWidth, height: lampHeight)
let lampPath = CGPath(roundedRect: lampRect, cornerWidth: lampHeight / 2, cornerHeight: lampHeight / 2, transform: nil)
context.saveGState()
context.setShadow(offset: .zero, blur: 90, color: NSColor(white: 1, alpha: 0.95).cgColor)
context.addPath(lampPath)
context.setFillColor(NSColor(white: 1, alpha: 1).cgColor)
context.fillPath()
context.restoreGState()

// 7) 灯条上方很淡的机壳反光（暗示这是灯条而非一条白线）
let housing = CGRect(x: lampRect.minX - size * 0.01, y: lampRect.maxY + size * 0.004, width: lampRect.width + size * 0.02, height: size * 0.075)
context.saveGState()
context.addPath(CGPath(roundedRect: housing, cornerWidth: size * 0.035, cornerHeight: size * 0.035, transform: nil))
context.clip()
context.drawLinearGradient(
    grad([NSColor(white: 0.30, alpha: 0.85), NSColor(white: 0.22, alpha: 0.55), NSColor(white: 0.16, alpha: 0.0)],
         [0, 0.5, 1]),
    start: CGPoint(x: 0, y: housing.maxY), end: CGPoint(x: 0, y: housing.minY), options: []
)
context.restoreGState()

// 8) 外层玻璃边
context.addPath(rounded)
context.setStrokeColor(NSColor(white: 1, alpha: 0.10).cgColor)
context.setLineWidth(4)
context.strokePath()

context.restoreGState()
image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: tiff),
      let png = bitmap.representation(using: .png, properties: [:]) else { exit(1) }
let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"
try png.write(to: URL(fileURLWithPath: output))
print("wrote \(output)")