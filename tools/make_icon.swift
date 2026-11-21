import AppKit
import Foundation

let size = 1024.0
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()

guard let context = NSGraphicsContext.current?.cgContext else { exit(1) }

// 圆角方形底：深蓝渐变
let bounds = CGRect(x: 0, y: 0, width: size, height: size)
let rounded = CGPath(roundedRect: bounds.insetBy(dx: 28, dy: 28), cornerWidth: 210, cornerHeight: 210, transform: nil)
context.saveGState()
context.addPath(rounded)
context.clip()
let background = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                            colors: [NSColor(srgbRed: 0.11, green: 0.15, blue: 0.26, alpha: 1).cgColor,
                                     NSColor(srgbRed: 0.05, green: 0.07, blue: 0.13, alpha: 1).cgColor] as CFArray,
                            locations: [0, 1])!
context.drawLinearGradient(background, start: CGPoint(x: 0, y: size), end: CGPoint(x: 0, y: 0), options: [])

// 暖色光锥：从灯条射向屏幕
let lampRect = CGRect(x: 292, y: 706, width: 440, height: 52)
let screenRect = CGRect(x: 202, y: 208, width: 620, height: 372)
let cone = CGMutablePath()
cone.move(to: CGPoint(x: lampRect.minX + 26, y: lampRect.minY))
cone.addLine(to: CGPoint(x: lampRect.maxX - 26, y: lampRect.minY))
cone.addLine(to: CGPoint(x: screenRect.maxX - 40, y: screenRect.maxY - 30))
cone.addCurve(to: CGPoint(x: screenRect.minX + 40, y: screenRect.maxY - 30),
              control1: CGPoint(x: screenRect.maxX - 150, y: screenRect.maxY + 150),
              control2: CGPoint(x: screenRect.minX + 150, y: screenRect.maxY + 150))
cone.closeSubpath()
context.addPath(cone)
context.clip()
let glow = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                      colors: [NSColor(srgbRed: 1.0, green: 0.80, blue: 0.45, alpha: 0.62).cgColor,
                               NSColor(srgbRed: 1.0, green: 0.72, blue: 0.35, alpha: 0.0).cgColor] as CFArray,
                      locations: [0, 1])!
context.drawLinearGradient(glow, start: CGPoint(x: 512, y: lampRect.minY), end: CGPoint(x: 512, y: screenRect.maxY - 40), options: [])
context.restoreGState()

context.saveGState()
context.addPath(rounded)
context.clip()

// 灯条
let lampPath = CGPath(roundedRect: lampRect, cornerWidth: 26, cornerHeight: 26, transform: nil)
context.setShadow(offset: .zero, blur: 60, color: NSColor(srgbRed: 1.0, green: 0.76, blue: 0.40, alpha: 0.85).cgColor)
context.addPath(lampPath)
context.setFillColor(NSColor(srgbRed: 0.99, green: 0.85, blue: 0.62, alpha: 1).cgColor)
context.fillPath()
context.setShadow(offset: .zero, blur: 0, color: nil)

// 灯条下缘的高光
let strip = CGRect(x: lampRect.minX + 18, y: lampRect.minY + 10, width: lampRect.width - 36, height: 10)
context.addPath(CGPath(roundedRect: strip, cornerWidth: 5, cornerHeight: 5, transform: nil))
context.setFillColor(NSColor(srgbRed: 1, green: 0.95, blue: 0.82, alpha: 1).cgColor)
context.fillPath()

// 屏幕外框
let screenPath = CGPath(roundedRect: screenRect, cornerWidth: 40, cornerHeight: 40, transform: nil)
context.addPath(screenPath)
context.setFillColor(NSColor(srgbRed: 0.09, green: 0.12, blue: 0.19, alpha: 1).cgColor)
context.fillPath()
context.addPath(screenPath)
context.setStrokeColor(NSColor(srgbRed: 0.30, green: 0.38, blue: 0.54, alpha: 1).cgColor)
context.setLineWidth(12)
context.strokePath()

// 屏幕内容：两行亮度条
let barDark = CGRect(x: screenRect.minX + 56, y: screenRect.minY + 210, width: 330, height: 26)
let barWarm = CGRect(x: screenRect.minX + 56, y: screenRect.minY + 150, width: 200, height: 26)
context.addPath(CGPath(roundedRect: barDark, cornerWidth: 13, cornerHeight: 13, transform: nil))
context.setFillColor(NSColor(srgbRed: 0.42, green: 0.50, blue: 0.66, alpha: 1).cgColor)
context.fillPath()
context.addPath(CGPath(roundedRect: barWarm, cornerWidth: 13, cornerHeight: 13, transform: nil))
context.setFillColor(NSColor(srgbRed: 0.99, green: 0.78, blue: 0.45, alpha: 1).cgColor)
context.fillPath()

// 屏幕顶部被照亮的高光
let topGlow = CGRect(x: screenRect.minX + 24, y: screenRect.maxY - 46, width: screenRect.width - 48, height: 22)
context.addPath(CGPath(roundedRect: topGlow, cornerWidth: 11, cornerHeight: 11, transform: nil))
context.setFillColor(NSColor(srgbRed: 1, green: 0.86, blue: 0.58, alpha: 0.55).cgColor)
context.fillPath()

// 屏幕底座
let stand = CGRect(x: 462, y: 150, width: 100, height: 46)
context.addPath(CGPath(roundedRect: stand, cornerWidth: 12, cornerHeight: 12, transform: nil))
context.setFillColor(NSColor(srgbRed: 0.24, green: 0.30, blue: 0.44, alpha: 1).cgColor)
context.fillPath()
let base = CGRect(x: 372, y: 96, width: 280, height: 26)
context.addPath(CGPath(roundedRect: base, cornerWidth: 13, cornerHeight: 13, transform: nil))
context.setFillColor(NSColor(srgbRed: 0.28, green: 0.35, blue: 0.50, alpha: 1).cgColor)
context.fillPath()

context.restoreGState()
image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: tiff),
      let png = bitmap.representation(using: .png, properties: [:]) else { exit(1) }
let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon-1024.png"
try png.write(to: URL(fileURLWithPath: output))
print("wrote \(output)")