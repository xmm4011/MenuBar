// 测试辅助工具：读取菜单栏窗口、弹出菜单、鼠标位置（不需要任何权限）
//   inspect windows        菜单栏图标窗口：x  宽  on/off  名字
//   inspect popups         屏幕上的弹出菜单：所属App  x  y  宽  高
//   inspect screen         主屏宽度
//   inspect mouse          鼠标是否在菜单栏上：menubar / elsewhere
import AppKit

let args = CommandLine.arguments
let mode = args.count > 1 ? args[1] : "windows"

func windows(_ options: CGWindowListOption) -> [[String: Any]] {
    CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] ?? []
}
func bounds(_ w: [String: Any]) -> CGRect {
    guard let dict = w[kCGWindowBounds as String] as? NSDictionary else { return .zero }
    return CGRect(dictionaryRepresentation: dict) ?? .zero
}
func layer(_ w: [String: Any]) -> Int { w[kCGWindowLayer as String] as? Int ?? -1 }

switch mode {
case "windows":
    for w in windows([.optionAll]) where layer(w) == 25 {
        let b = bounds(w)
        guard b.height <= 50 else { continue }
        let on = (w[kCGWindowIsOnscreen as String] as? Bool) ?? false
        print("\(Int(b.minX))\t\(Int(b.width))\t\(on ? "on" : "off")\t\(w[kCGWindowName as String] as? String ?? "")")
    }
case "popups":
    for w in windows([.optionOnScreenOnly]) where layer(w) == 101 {
        let b = bounds(w)
        print("\(w[kCGWindowOwnerName as String] as? String ?? "?")\t\(Int(b.minX))\t\(Int(b.minY))\t\(Int(b.width))\t\(Int(b.height))")
    }
case "screen":
    print(Int(NSScreen.screens.first?.frame.width ?? 0))
case "mouse":
    let p = NSEvent.mouseLocation
    let screen = NSScreen.screens.first { NSMouseInRect(p, $0.frame, false) }
    if let screen, p.y >= screen.frame.maxY - max(screen.frame.maxY - screen.visibleFrame.maxY, 24) - 1 {
        print("menubar")
    } else {
        print("elsewhere")
    }
default:
    print("unknown mode")
}
