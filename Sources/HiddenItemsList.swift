import AppKit

/// 「看不到的图标」列表。NSMenu 自带的菜单项不能拖动，所以这几行用自定义视图：
/// 自己画高亮；单击打开图标的菜单；按住 ⌘ 上下拖动调整顺序。
/// 列表从上到下就是菜单栏上从左到右的顺序。
@MainActor
final class HiddenItemsList {
    /// 拖到哪里：放在某个图标的前面（左边），或者放在最后一个图标的后面（右边）
    enum Destination {
        case before(MenuBarItemInfo)
        case after(MenuBarItemInfo)

        var reference: MenuBarItemInfo {
            switch self {
            case .before(let item), .after(let item): return item
            }
        }

        var logText: String {
            switch self {
            case .before(let item): return "before \(item.displayName)"
            case .after(let item): return "after \(item.displayName)"
            }
        }
    }

    private(set) var rows: [HiddenItemRowView] = []
    private(set) var isDragging = false
    /// 菜单关掉以后要做的事（打开图标或调整顺序）。菜单还开着时就去点别的图标会互相干扰
    private var pendingAction: (@MainActor () -> Void)?
    private let onOpen: (MenuBarItemInfo) -> Void
    private let onMove: (MenuBarItemInfo, Destination) -> Void

    init(onOpen: @escaping (MenuBarItemInfo) -> Void,
         onMove: @escaping (MenuBarItemInfo, Destination) -> Void) {
        self.onOpen = onOpen
        self.onMove = onMove
    }

    func makeRow(for item: MenuBarItemInfo, title: String, icon: NSImage?) -> HiddenItemRowView {
        let row = HiddenItemRowView(item: item, title: title, icon: icon, list: self)
        rows.append(row)
        return row
    }

    /// 菜单关闭后由控制器调用
    func takePendingAction() -> (@MainActor () -> Void)? {
        defer { pendingAction = nil }
        return pendingAction
    }

    func closeMenu() {
        rows.first?.enclosingMenuItem?.menu?.cancelTracking()
    }

    private func finish(_ action: @escaping @MainActor () -> Void) {
        pendingAction = action
        closeMenu()
    }

    // MARK: - 鼠标

    fileprivate func mouseDown(on row: HiddenItemRowView, with event: NSEvent) {
        debugLog("list: mouseDown \(row.title) cmd=\(event.modifierFlags.contains(.command))")
        guard event.modifierFlags.contains(.command) else { return }
        trackDrag(of: row)
    }

    fileprivate func mouseUp(on row: HiddenItemRowView) {
        debugLog("list: mouseUp \(row.title) dragging=\(isDragging)")
        guard !isDragging else { return }
        let item = row.item
        finish { [onOpen] in onOpen(item) }
    }

    /// 按住 ⌘ 按下后，自己接管鼠标直到松开：画出插入位置，松手时决定挪到哪里
    private func trackDrag(of source: HiddenItemRowView) {
        guard let sourceIndex = rows.firstIndex(where: { $0 === source }) else { return }
        let start = NSEvent.mouseLocation
        var moved = false
        var cancelled = false
        var destination: Int?

        isDragging = true
        source.isDragSource = true
        redrawRows()

        while let event = NSApp.nextEvent(matching: [.leftMouseDragged, .leftMouseUp, .keyDown],
                                          until: .distantFuture, inMode: .eventTracking, dequeue: true) {
            if event.type == .leftMouseUp { break }
            if event.type == .keyDown {
                if event.keyCode == 53 { cancelled = true; break }   // Esc 取消拖动
                continue
            }
            let point = NSEvent.mouseLocation
            if !moved && hypot(point.x - start.x, point.y - start.y) < 3 { continue }
            moved = true
            destination = insertionIndex(at: point)
            if let index = destination, index == sourceIndex || index == sourceIndex + 1 {
                destination = nil   // 原地不动
            }
            showDropLine(at: destination)
        }

        isDragging = false
        source.isDragSource = false
        showDropLine(at: nil)
        debugLog("list: drag ended moved=\(moved) cancelled=\(cancelled) destination=\(destination.map(String.init) ?? "nil")")

        if cancelled { return }
        if !moved {
            // ⌘ 单击当作普通单击
            let item = source.item
            finish { [onOpen] in onOpen(item) }
            return
        }
        guard let index = destination else { return }
        let target: Destination = index < rows.count ? .before(rows[index].item) : .after(rows[rows.count - 1].item)
        let item = source.item
        finish { [onMove] in onMove(item, target) }
    }

    /// 鼠标位置对应的插入位置：0 表示第一行上面，rows.count 表示最后一行下面
    private func insertionIndex(at point: NSPoint) -> Int? {
        let frames = rows.map(\.screenFrame)
        guard let first = frames.first, let last = frames.last, let menuFrame = rows[0].window?.frame else { return nil }
        // 拖出菜单左右两边太远，视为不放
        guard point.x >= menuFrame.minX - 40, point.x <= menuFrame.maxX + 40 else { return nil }
        if point.y >= first.maxY { return 0 }
        if point.y < last.minY { return rows.count }
        for (index, frame) in frames.enumerated() where point.y >= frame.minY && point.y < frame.maxY {
            return point.y >= frame.midY ? index : index + 1
        }
        return nil
    }

    private func showDropLine(at index: Int?) {
        for (i, row) in rows.enumerated() {
            if let index, index == i {
                row.dropLine = .top
            } else if let index, index == rows.count, i == rows.count - 1 {
                row.dropLine = .bottom
            } else {
                row.dropLine = .none
            }
        }
        redrawRows()
    }

    /// 拖动时主线程一直在等鼠标事件，不会自动刷新界面，所以手动画一次
    private func redrawRows() {
        for row in rows { row.needsDisplay = true }
        rows.first?.window?.displayIfNeeded()
    }

    /// 测试用：某一行在屏幕上的位置（全局坐标，原点在主屏左上角）
    func screenRect(ofRowMatching query: String) -> CGRect? {
        let q = query.lowercased()
        guard let row = rows.first(where: { $0.title.lowercased().contains(q) || ($0.item.bundleID?.lowercased().contains(q) ?? false) }) else {
            return nil
        }
        let frame = row.screenFrame
        let primaryHeight = NSScreen.screens.first?.frame.maxY ?? 0
        return CGRect(x: frame.minX, y: primaryHeight - frame.maxY, width: frame.width, height: frame.height)
    }

    var lastRowScreenRect: CGRect? {
        guard let title = rows.last?.title else { return nil }
        return screenRect(ofRowMatching: title)
    }
}

/// 列表里的一行：应用图标 + 名字，样式和系统菜单项一致
@MainActor
final class HiddenItemRowView: NSView {
    enum DropLine { case none, top, bottom }

    static let height: CGFloat = 24
    private static let iconSize: CGFloat = 18
    private static let contentInset: CGFloat = 14     // 图标离菜单左边缘的距离
    private static let highlightInset: CGFloat = 5    // 高亮背景离菜单边缘的距离
    private static let iconTitleGap: CGFloat = 6

    let item: MenuBarItemInfo
    let title: String
    private let icon: NSImage?
    private unowned let list: HiddenItemsList

    var isDragSource = false {
        didSet { if oldValue != isDragSource { needsDisplay = true } }
    }
    var dropLine: DropLine = .none {
        didSet { if oldValue != dropLine { needsDisplay = true } }
    }

    init(item: MenuBarItemInfo, title: String, icon: NSImage?, list: HiddenItemsList) {
        self.item = item
        self.title = title
        self.icon = icon
        self.list = list
        let textWidth = (title as NSString).size(withAttributes: [.font: Self.font]).width
        let width = Self.contentInset + Self.iconSize + Self.iconTitleGap + ceil(textWidth) + 28
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: Self.height))
        autoresizingMask = [.width]
        setAccessibilityElement(true)
        setAccessibilityRole(.menuItem)
        setAccessibilityLabel(title)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private static var font: NSFont { NSFont.menuFont(ofSize: 0) }

    var screenFrame: NSRect {
        guard let window else { return .zero }
        return window.convertToScreen(convert(bounds, to: nil))
    }

    override func draw(_ dirtyRect: NSRect) {
        let highlighted = !list.isDragging && (enclosingMenuItem?.isHighlighted ?? false)
        if highlighted {
            NSColor.selectedContentBackgroundColor.setFill()
            let rect = bounds.insetBy(dx: Self.highlightInset, dy: 0)
            NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5).fill()
        }

        let alpha: CGFloat = isDragSource ? 0.35 : 1
        let color = highlighted ? NSColor.selectedMenuItemTextColor : NSColor.labelColor
        let iconRect = NSRect(x: Self.contentInset, y: (bounds.height - Self.iconSize) / 2,
                              width: Self.iconSize, height: Self.iconSize)
        drawIcon(in: iconRect, color: color, alpha: alpha)

        let attributes: [NSAttributedString.Key: Any] = [
            .font: Self.font,
            .foregroundColor: color.withAlphaComponent(alpha),
        ]
        let size = (title as NSString).size(withAttributes: attributes)
        let titleX = iconRect.maxX + Self.iconTitleGap
        let titleRect = NSRect(x: titleX, y: (bounds.height - size.height) / 2,
                               width: bounds.width - titleX - 12, height: size.height)
        (title as NSString).draw(with: titleRect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                 attributes: attributes)

        drawDropLine()
    }

    /// 图标按自己的尺寸居中画在图标位里。单色的模板图（输入法图标）和菜单栏上一样，用文字颜色着色
    private func drawIcon(in slot: NSRect, color: NSColor, alpha: CGFloat) {
        guard let icon else { return }
        let size = NSSize(width: min(icon.size.width, slot.width), height: min(icon.size.height, slot.height))
        let rect = NSRect(x: slot.midX - size.width / 2, y: slot.midY - size.height / 2,
                          width: size.width, height: size.height)
        guard icon.isTemplate, let context = NSGraphicsContext.current?.cgContext else {
            icon.draw(in: rect, from: .zero, operation: .sourceOver, fraction: alpha)
            return
        }
        context.saveGState()
        context.setAlpha(alpha)
        context.beginTransparencyLayer(in: rect, auxiliaryInfo: nil)
        icon.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
        color.setFill()
        rect.fill(using: .sourceAtop)
        context.endTransparencyLayer()
        context.restoreGState()
    }

    /// 插入位置：一条强调色的横线，左端一个小圆圈（和访达里拖动排序的样子一样）
    private func drawDropLine() {
        guard dropLine != .none else { return }
        let y = dropLine == .top ? bounds.maxY - 1.5 : bounds.minY + 1.5
        let left = Self.contentInset - 4
        NSColor.controlAccentColor.set()
        let line = NSBezierPath()
        line.move(to: NSPoint(x: left + 6, y: y))
        line.line(to: NSPoint(x: bounds.maxX - 10, y: y))
        line.lineWidth = 2
        line.stroke()
        let circle = NSBezierPath(ovalIn: NSRect(x: left, y: y - 3, width: 6, height: 6))
        circle.lineWidth = 1.5
        circle.stroke()
    }

    override func mouseDown(with event: NSEvent) {
        list.mouseDown(on: self, with: event)
    }

    override func mouseUp(with event: NSEvent) {
        list.mouseUp(on: self)
    }

    /// 旁白（VoiceOver）按下这一行时，和单击一样打开图标
    override func accessibilityPerformPress() -> Bool {
        list.mouseUp(on: self)
        return true
    }
}
