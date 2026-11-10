// 测试辅助工具：读取菜单栏窗口、弹出菜单、鼠标位置（不需要任何权限）
//   inspect windows        箭头所在那一排的菜单栏图标窗口：x  宽  on/off  名字  窗口编号
//   inspect allwindows     所有屏幕上的菜单栏图标窗口（接了外接显示器时每块屏幕都有一份），多一列 y
//   inspect popups         屏幕上的弹出菜单：所属App  x  y  宽  高
//   inspect screen         主屏宽度
//   inspect mouse          鼠标是否在菜单栏上：menubar / elsewhere
//   inspect cursor         鼠标位置（取整）：x y
//   inspect idle           距离上一次鼠标或键盘操作的秒数（取整）
//   inspect keyidle        距离上一次按键的秒数（取整）
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

func name(_ w: [String: Any]) -> String { w[kCGWindowName as String] as? String ?? "" }
func number(_ w: [String: Any]) -> Int { w[kCGWindowNumber as String] as? Int ?? 0 }

/// 箭头（MenuBar.Toggle）所在的那一排：同一排的窗口首尾相接，从箭头往两边连着找。
/// 外接显示器上的副本在另一排，不会混进来。找不到箭头时返回全部
func homeRow(_ all: [[String: Any]]) -> [[String: Any]] {
    guard let anchor = all.first(where: { name($0) == "MenuBar.Toggle" }) else { return all }
    var row = [anchor]
    var used: Set<Int> = [number(anchor)]
    for leftward in [true, false] {
        var current = bounds(anchor)
        while true {
            let edge = leftward ? current.minX : current.maxX
            let matches = all.filter { w in
                let b = bounds(w)
                return !used.contains(number(w)) && abs(b.minY - current.minY) < 2 && abs(b.height - current.height) < 2
                    && abs((leftward ? b.maxX : b.minX) - edge) < 2
            }
            guard matches.count == 1 else { break }
            used.insert(number(matches[0]))
            row.append(matches[0])
            current = bounds(matches[0])
        }
    }
    return row.sorted { bounds($0).minX < bounds($1).minX }
}

switch mode {
case "windows", "allwindows":
    let all = windows([.optionAll]).filter { layer($0) == 25 && bounds($0).height <= 50 }
    for w in mode == "windows" ? homeRow(all) : all {
        let b = bounds(w)
        let on = (w[kCGWindowIsOnscreen as String] as? Bool) ?? false
        let y = mode == "allwindows" ? "\t\(Int(b.minY))" : ""
        print("\(Int(b.minX))\t\(Int(b.width))\t\(on ? "on" : "off")\t\(name(w))\t\(number(w))\(y)")
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
case "cursor":
    let p = CGEvent(source: nil)?.location ?? .zero
    print("\(Int(p.x.rounded())) \(Int(p.y.rounded()))")
case "idle":
    // 只算键盘、鼠标移动、点击和滚动。触控板上搭着手指会不停产生手势事件，不算
    let types: [CGEventType] = [.keyDown, .flagsChanged, .mouseMoved, .leftMouseDown, .leftMouseUp, .leftMouseDragged,
                                .rightMouseDown, .rightMouseUp, .otherMouseDown, .scrollWheel]
    let seconds = types.map { CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: $0) }.min() ?? 0
    print(Int(seconds))
case "keyidle":
    // 距离上一次按键的秒数（取整）。测试模拟的 ⌘ 是修饰键事件，不算按键
    print(Int(CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: .keyDown)))
default:
    print("unknown mode")
}
