import AppKit

/// 模拟鼠标操作。主要用途是「按住 ⌘ 拖动菜单栏图标」，调整真实菜单栏里图标的顺序。
/// 需要辅助功能权限。坐标是全局坐标，原点在主屏左上角（和 CGWindowList 一致）。
enum MenuBarMover {
    private static let commandKey: CGKeyCode = 0x37

    /// 按住 ⌘ 从 start 拖到 end，完成后把鼠标放回原处。
    /// - Parameters:
    ///   - hold: 拖到终点后停多久再松手（测试时可以加长，方便截图）
    ///   - approach: 先像用户一样把鼠标分几步移过去、停一下再按下。菜单要先「看到」鼠标停在某一行上，
    ///     才会把按下交给那一行；鼠标瞬移过去马上按下，偶尔会被菜单吞掉
    static func commandDrag(from start: CGPoint, to end: CGPoint, hold: TimeInterval = 0.12, approach: Bool = false,
                            completion: @escaping () -> Void) {
        let originalCursor = CGEvent(source: nil)?.location ?? start
        DispatchQueue.global(qos: .userInitiated).async {
            let poster = EventPoster(flags: .maskCommand)
            if approach {
                let plain = EventPoster(flags: [])
                for i in 0...4 {
                    plain.mouse(.mouseMoved, CGPoint(x: start.x - CGFloat(4 - i) * 8, y: start.y))
                    usleep(30_000)
                }
                usleep(150_000)
            }
            poster.key(commandKey, down: true)
            usleep(30_000)
            poster.mouse(.mouseMoved, start)
            usleep(approach ? 100_000 : 40_000)
            poster.mouse(.leftMouseDown, start)
            usleep(120_000)
            let steps = 12
            for i in 1...steps {
                let t = CGFloat(i) / CGFloat(steps)
                poster.mouse(.leftMouseDragged, CGPoint(x: start.x + (end.x - start.x) * t,
                                                        y: start.y + (end.y - start.y) * t))
                usleep(20_000)
            }
            usleep(useconds_t(hold * 1_000_000))
            poster.mouse(.leftMouseUp, end)
            usleep(60_000)
            poster.key(commandKey, down: false)
            usleep(30_000)
            CGWarpMouseCursorPosition(originalCursor)
            DispatchQueue.main.async { completion() }
        }
    }

    /// 测试用：在某个位置单击一下，完成后把鼠标放回原处
    static func click(at point: CGPoint) {
        let originalCursor = CGEvent(source: nil)?.location ?? point
        DispatchQueue.global(qos: .userInitiated).async {
            let poster = EventPoster(flags: [])
            // 和拖动一样，先分几步移过去、停一下，菜单才会把点击交给这一行
            for i in 0...4 {
                poster.mouse(.mouseMoved, CGPoint(x: point.x - CGFloat(4 - i) * 8, y: point.y))
                usleep(30_000)
            }
            usleep(150_000)
            poster.mouse(.leftMouseDown, point)
            usleep(60_000)
            poster.mouse(.leftMouseUp, point)
            usleep(30_000)
            CGWarpMouseCursorPosition(originalCursor)
        }
    }

    /// 按一下 Esc。用来关掉弹出菜单，和用户按 Esc 完全一样
    static func pressEscape() {
        let poster = EventPoster(flags: [])
        poster.key(0x35, down: true)
        poster.key(0x35, down: false)
    }

    private struct EventPoster {
        let source = CGEventSource(stateID: .hidSystemState)
        let flags: CGEventFlags

        func key(_ code: CGKeyCode, down: Bool) {
            let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down)
            event?.flags = down ? flags : []
            event?.post(tap: .cghidEventTap)
        }

        func mouse(_ type: CGEventType, _ point: CGPoint) {
            let event = CGEvent(mouseEventSource: source, mouseType: type,
                                mouseCursorPosition: point, mouseButton: .left)
            event?.flags = flags
            event?.post(tap: .cghidEventTap)
        }
    }
}
