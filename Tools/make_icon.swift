// 生成 1024x1024 的 App 图标 PNG：swift Tools/make_icon.swift out.png
import AppKit

let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon_1024.png"
let size = 1024
guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                                 bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                 colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { exit(1) }
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

// 背景：圆角方块 + 渐变
let bg = NSRect(x: 100, y: 100, width: 824, height: 824)
let bgPath = NSBezierPath(roundedRect: bg, xRadius: 185, yRadius: 185)
NSGradient(starting: NSColor(calibratedRed: 0.36, green: 0.55, blue: 1.0, alpha: 1),
           ending: NSColor(calibratedRed: 0.48, green: 0.33, blue: 0.95, alpha: 1))!
    .draw(in: bgPath, angle: -90)

// 顶部一条“菜单栏”
let bar = NSRect(x: 180, y: 560, width: 664, height: 150)
NSColor.white.withAlphaComponent(0.22).setFill()
NSBezierPath(roundedRect: bar, xRadius: 75, yRadius: 75).fill()

// 菜单栏里的小图标，越往左越淡（被收起）
let dotAlphas: [CGFloat] = [0.25, 0.45, 0.7]
for (i, alpha) in dotAlphas.enumerated() {
    NSColor.white.withAlphaComponent(alpha).setFill()
    let x = 240 + CGFloat(i) * 120
    NSBezierPath(ovalIn: NSRect(x: x, y: 600, width: 70, height: 70)).fill()
}

// 分隔线
NSColor.white.setFill()
NSBezierPath(roundedRect: NSRect(x: 618, y: 590, width: 16, height: 90), xRadius: 8, yRadius: 8).fill()

// 箭头 ‹
let chevron = NSBezierPath()
chevron.lineWidth = 30
chevron.lineCapStyle = .round
chevron.lineJoinStyle = .round
chevron.move(to: NSPoint(x: 760, y: 680))
chevron.line(to: NSPoint(x: 710, y: 635))
chevron.line(to: NSPoint(x: 760, y: 590))
NSColor.white.setStroke()
chevron.stroke()

// 下方大号的“收纳盒”
let box = NSBezierPath(roundedRect: NSRect(x: 300, y: 230, width: 424, height: 250), xRadius: 50, yRadius: 50)
NSColor.white.withAlphaComponent(0.9).setFill()
box.fill()
let slot = NSBezierPath(roundedRect: NSRect(x: 420, y: 380, width: 184, height: 36), xRadius: 18, yRadius: 18)
NSColor(calibratedRed: 0.42, green: 0.44, blue: 0.98, alpha: 1).setFill()
slot.fill()

NSGraphicsContext.restoreGraphicsState()
guard let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
try png.write(to: URL(fileURLWithPath: outPath))
print("icon written: \(outPath)")
