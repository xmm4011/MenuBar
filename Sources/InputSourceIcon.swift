import AppKit
import Carbon

/// 菜单栏上的输入法图标由系统的 TextInputMenuAgent 代为显示，显示的是「当前输入法」自己的图标
/// （比如微信输入法的圆形 P、U.S. 键盘的国旗），而 TextInputMenuAgent 的 App 图标只是个通用图标。
/// 这里通过系统的输入法接口（TIS）读出当前输入法的图标
@MainActor
enum InputSourceIcon {
    static let hostBundleID = "com.apple.TextInputMenuAgent"

    static func current() -> NSImage? {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let image = icon(of: source)?.copy() as? NSImage else { return nil }
        // 大多数输入法的图标是黑色单色图，菜单栏会按文字颜色给它着色（深色菜单栏里显示成白色）；
        // 国旗这类彩色图标原样显示
        image.isTemplate = image.isTemplate || isMonochrome(image)
        return image
    }

    private static func icon(of source: TISInputSource) -> NSImage? {
        if let raw = TISGetInputSourceProperty(source, kTISPropertyIconImageURL) {
            let url = Unmanaged<CFURL>.fromOpaque(raw).takeUnretainedValue() as URL
            if let image = NSImage(contentsOf: url) { return image }
        }
        // 系统自带的键盘布局（U.S.、ABC 等）没有图片文件，只有旧式的 IconRef
        if let ref = TISGetInputSourceProperty(source, kTISPropertyIconRef) {
            return NSImage(iconRef: OpaquePointer(ref))
        }
        return nil
    }

    /// 图标里所有不透明的像素都是黑色或深灰色，就当成单色图
    private static func isMonochrome(_ image: NSImage) -> Bool {
        let side = 32
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: side * 4, bitsPerPixel: 32),
              let context = NSGraphicsContext(bitmapImageRep: rep),
              let pixels = rep.bitmapData else { return false }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        image.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
        NSGraphicsContext.restoreGraphicsState()

        var painted = 0
        for i in 0..<(side * side) {
            // 像素是预乘过透明度的：颜色值不会超过透明度
            let r = Int(pixels[i * 4]), g = Int(pixels[i * 4 + 1]), b = Int(pixels[i * 4 + 2]), a = Int(pixels[i * 4 + 3])
            guard a > 25 else { continue }
            painted += 1
            let colorful = max(r, g, b) - min(r, g, b) > 24
            let light = max(r, g, b) > a / 2
            if colorful || light { return false }
        }
        return painted > 0
    }
}
