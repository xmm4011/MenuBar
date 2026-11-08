import AppKit
import ApplicationServices

/// 菜单栏上的一个图标（属于某个 App）
final class MenuBarItemInfo: NSObject {
    let element: AXUIElement
    let app: NSRunningApplication
    let appName: String
    let label: String?        // 图标自己的描述，比如 Wi‑Fi、电池、未读数
    let frame: CGRect         // 全局坐标，原点在主屏左上角
    var isVisible = true

    init(element: AXUIElement, app: NSRunningApplication, label: String?, frame: CGRect) {
        self.element = element
        self.app = app
        self.appName = MenuBarScanner.friendlyName(of: app)
        self.label = label
        self.frame = frame
    }

    var bundleID: String? { app.bundleIdentifier }
    var appIcon: NSImage? { app.icon }

    /// 菜单里显示的名字
    var displayName: String {
        let systemHosts: Set<String> = ["com.apple.controlcenter", "com.apple.systemuiserver"]
        guard let label, !label.isEmpty else { return appName }
        if let bundleID, systemHosts.contains(bundleID) { return label }
        if label.caseInsensitiveCompare(appName) == .orderedSame { return appName }
        return "\(appName) — \(label)"
    }
}

/// 用「辅助功能」接口读取所有 App 的菜单栏图标，并判断哪些被刘海挡住或被收起
enum MenuBarScanner {

    // MARK: - 权限

    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// 弹出系统的授权提示
    static func requestTrust() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - 缓存
    // 系统里有上百个进程，大部分没有菜单栏图标。记住每个进程的情况，
    // 点箭头时只问「有图标的」和「新出现的」，其余交给后台定时刷新。

    private enum Probe { case hasItems, noItems, unresponsive }
    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var probeCache: [pid_t: Probe] = [:]
    nonisolated(unsafe) private static var lastHealScan = Date.distantPast

    private static func cached(_ pid: pid_t) -> Probe? {
        cacheLock.lock(); defer { cacheLock.unlock() }
        return probeCache[pid]
    }

    private static func record(_ pid: pid_t, found: [MenuBarItemInfo]?) {
        cacheLock.lock(); defer { cacheLock.unlock() }
        if let found {
            probeCache[pid] = found.isEmpty ? .noItems : .hasItems
        } else if probeCache[pid] != .hasItems {
            // 超时不代表没有图标，只是这次没等到，记成「响应慢」，后台用更长的超时再问
            probeCache[pid] = .unresponsive
        }
    }

    private static func pruneCache(alive: Set<pid_t>) {
        cacheLock.lock(); defer { cacheLock.unlock() }
        probeCache = probeCache.filter { alive.contains($0.key) }
    }

    static var unresponsiveApps: [String] {
        let apps = candidateApps()
        cacheLock.lock(); defer { cacheLock.unlock() }
        return apps.filter { probeCache[$0.processIdentifier] == .unresponsive }.map { friendlyName(of: $0) }
    }

    // MARK: - 扫描

    /// 可能有菜单栏图标的 App：普通 App 和后台 Agent（LSUIElement），不含本 App。
    /// xpc 服务、网页内容进程这类辅助进程不会有菜单栏图标，而且常常不响应，直接排除
    private static func candidateApps() -> [NSRunningApplication] {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        return NSWorkspace.shared.runningApplications.filter { app in
            guard app.processIdentifier != ownPID, app.activationPolicy != .prohibited, !app.isTerminated else { return false }
            // 没有程序包的（网页内容进程等）、xpc 服务和扩展都不会有菜单栏图标
            guard let bundlePath = app.bundleURL?.path else { return false }
            let paths = [bundlePath, app.executableURL?.path].compactMap { $0 }
            return !paths.contains { $0.contains(".xpc") || $0.contains(".appex") }
        }
    }

    /// 并发询问一批 App，返回它们的菜单栏图标，并更新缓存。
    /// 每个 App 单独一个任务，总耗时取决于最慢的那个，而不是累加
    private static func query(_ apps: [NSRunningApplication], timeout: (NSRunningApplication) -> Float) -> [MenuBarItemInfo] {
        var items: [MenuBarItemInfo] = []
        let lock = NSLock()
        let group = DispatchGroup()
        let queue = DispatchQueue(label: "MenuBar.scan", qos: .userInitiated, attributes: .concurrent)
        for app in apps {
            let appTimeout = timeout(app)
            queue.async(group: group) {
                let found = menuBarItems(of: app, timeout: appTimeout)
                record(app.processIdentifier, found: found)
                guard let found, !found.isEmpty else { return }
                lock.lock()
                items.append(contentsOf: found)
                lock.unlock()
            }
        }
        group.wait()
        return items
    }

    private static func query(_ apps: [NSRunningApplication], timeout: Float) -> [MenuBarItemInfo] {
        query(apps) { _ in timeout }
    }

    /// 返回所有菜单栏图标，按从左到右排序，并标好是否可见。在主线程调用。
    static func scan() -> [MenuBarItemInfo] {
        guard isTrusted else { return [] }
        let apps = candidateApps()
        let windows = statusBarWindows()

        // 快速路径：只问有图标的和没见过的。已知有图标的 App 多等一会儿（有的 App 响应慢）
        var items = query(apps.filter { app in
            let probe = cached(app.processIdentifier)
            return probe == nil || probe == .hasItems
        }, timeout: { cached($0.processIdentifier) == .hasItems ? 1.0 : 0.3 })
        markVisibility(items, windows: windows)

        // 自我纠正：系统说看不到的图标比我们读到的多，说明有 App 被漏掉了，
        // 把这一轮没读到的 App 全部用更长的超时再问一遍（最多 20 秒一次，避免每次都慢）
        let hiddenFound = items.filter { !$0.isVisible }.count
        if hiddenFound < hiddenStatusWindowCount(windows), Date().timeIntervalSince(lastHealScan) > 20 {
            lastHealScan = Date()
            let known = Set(items.map(\.app.processIdentifier))
            let extra = query(apps.filter { !known.contains($0.processIdentifier) }, timeout: 1.5)
            markVisibility(extra, windows: windows)
            items += extra
        }
        return items.sorted { $0.frame.minX < $1.frame.minX }
    }

    private static func markVisibility(_ items: [MenuBarItemInfo], windows: [StatusWindow]) {
        for item in items {
            item.isVisible = isVisible(item.frame, windows: windows)
        }
    }

    /// 后台把所有进程都问一遍，更新缓存。可以在任意线程调用。
    static func refreshCache() {
        guard isTrusted else { return }
        let apps = candidateApps()
        pruneCache(alive: Set(apps.map(\.processIdentifier)))
        _ = query(apps, timeout: 1.5)
    }

    /// 诊断用：每个有菜单栏图标（或不响应）的 App 的响应耗时，单位毫秒
    static func latencyReport() -> [(name: String, ms: Int, result: String)] {
        guard isTrusted else { return [] }
        var report: [(String, Int, String)] = []
        let lock = NSLock()
        let group = DispatchGroup()
        let queue = DispatchQueue(label: "MenuBar.latency", attributes: .concurrent)
        for app in candidateApps() {
            queue.async(group: group) {
                let start = Date()
                let found = menuBarItems(of: app, timeout: 3.0)
                let ms = Int(Date().timeIntervalSince(start) * 1000)
                guard found == nil || !(found!.isEmpty) || ms > 200 else { return }
                let result = found.map { "\($0.count) 个图标" } ?? "超时"
                lock.lock(); report.append((friendlyName(of: app), ms, result)); lock.unlock()
            }
        }
        group.wait()
        return report.sorted { $0.1 > $1.1 }
    }

    /// 诊断用：把某个 App 的菜单栏图标原始信息全部打印出来
    static func rawDump(_ query: String) -> [String] {
        let q = query.lowercased()
        var lines: [String] = []
        for app in NSWorkspace.shared.runningApplications
        where friendlyName(of: app).lowercased().contains(q) || (app.bundleIdentifier?.lowercased().contains(q) ?? false) {
            let axApp = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(axApp, 3.0)
            var barValue: CFTypeRef?
            let error = AXUIElementCopyAttributeValue(axApp, "AXExtrasMenuBar" as CFString, &barValue)
            lines.append("app=\(friendlyName(of: app)) pid=\(app.processIdentifier) candidate=\(candidateApps().contains(app)) bundle=\(app.bundleURL?.path ?? "nil") exec=\(app.executableURL?.path ?? "nil") extrasError=\(error.rawValue)")
            var names: CFArray?
            AXUIElementCopyAttributeNames(axApp, &names)
            lines.append("  appAttributes=\((names as? [String]) ?? [])")
            guard error == .success, let barValue, CFGetTypeID(barValue) == AXUIElementGetTypeID() else { continue }
            let children = attribute(barValue as! AXUIElement, kAXChildrenAttribute) as? [AXUIElement] ?? []
            lines.append("  children=\(children.count)")
            for child in children {
                var actions: CFArray?
                AXUIElementCopyActionNames(child, &actions)
                let texts = [kAXRoleAttribute, kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute]
                    .map { "\($0)=\(attribute(child, $0) as? String ?? "nil")" }.joined(separator: " ")
                lines.append("  child frame=\(frame(of: child).map { NSStringFromRect($0) } ?? "nil") \(texts) actions=\((actions as? [String]) ?? [])")
            }
        }
        return lines.isEmpty ? ["no running app matches \(query)"] : lines
    }

    /// 按名字找图标：先找看不到的，再找全部。名字可以是 App 名、图标描述或 Bundle ID 的一部分
    static func find(_ query: String) -> MenuBarItemInfo? {
        let q = query.lowercased()
        let items = scan()
        func matches(_ item: MenuBarItemInfo) -> Bool {
            item.displayName.lowercased().contains(q) || (item.bundleID?.lowercased().contains(q) ?? false)
        }
        return items.first { !$0.isVisible && matches($0) } ?? items.first(where: matches)
    }

    /// nil 表示进程没响应（超时），[] 表示确实没有菜单栏图标
    private static func menuBarItems(of app: NSRunningApplication, timeout: Float) -> [MenuBarItemInfo]? {
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(axApp, timeout)   // 防止卡死的 App 拖慢整个扫描

        var barValue: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(axApp, "AXExtrasMenuBar" as CFString, &barValue)
        if error == .cannotComplete { return nil }
        guard error == .success, let barValue, CFGetTypeID(barValue) == AXUIElementGetTypeID(),
              let children = attribute(barValue as! AXUIElement, kAXChildrenAttribute) as? [AXUIElement] else { return [] }

        return children.compactMap { child in
            guard let frame = frame(of: child), frame.width > 0 else { return nil }
            let label = [kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute]
                .lazy
                .compactMap { cleanLabel(attribute(child, $0) as? String) }
                .first
            return MenuBarItemInfo(element: child, app: app, label: label, frame: frame)
        }
    }

    // MARK: - 名字

    private static let friendlyNames: [String: String] = [
        "com.apple.TextInputMenuAgent": "输入法",
        "com.apple.Passwords.MenuBarExtra": "密码",
        "com.apple.Spotlight": "聚焦搜索",
    ]

    static func friendlyName(of app: NSRunningApplication) -> String {
        if let id = app.bundleIdentifier, let name = friendlyNames[id] { return name }
        var name = app.localizedName ?? app.bundleIdentifier ?? "未知应用"
        // 「Lark Helper」这类辅助进程，显示主程序名
        if name.hasSuffix(" Helper") { name = String(name.dropLast(" Helper".count)) }
        return name
    }

    private static func cleanLabel(_ raw: String?) -> String? {
        guard let text = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        // 图标的内部名字（如 key.horizontal、apple.passwords）对用户没意义
        if text.range(of: "^[a-z0-9]+(\\.[a-z0-9]+)+$", options: .regularExpression) != nil { return nil }
        return String(text.prefix(40))
    }

    // MARK: - 可见性

    private struct StatusWindow {
        let frame: CGRect
        let onScreen: Bool
    }

    /// 菜单栏图标的窗口（macOS 26 起这些窗口都归「控制中心」所有，但位置和是否显示是准的）
    private static func statusBarWindows() -> [StatusWindow] {
        let statusLevel = Int(CGWindowLevelForKey(.statusWindow))
        guard let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] else { return [] }
        return list.compactMap { info in
            guard (info[kCGWindowLayer as String] as? Int) == statusLevel,
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict) else { return nil }
            let onScreen = (info[kCGWindowIsOnscreen as String] as? Bool) ?? false
            return StatusWindow(frame: bounds, onScreen: onScreen)
        }
    }

    /// 系统窗口列表里「没显示在屏幕上」的菜单栏图标数量（不需要辅助功能权限）
    static func hiddenStatusWindowCount() -> Int {
        hiddenStatusWindowCount(statusBarWindows())
    }

    /// 本 App 自己的窗口（箭头、隐形分隔线），统计时排除。由主线程在扫描前设置
    nonisolated(unsafe) static var ownWindowFrames: [CGRect] = []

    private static func hiddenStatusWindowCount(_ windows: [StatusWindow]) -> Int {
        // 排除本 App 自己的窗口、收起时拉得很宽的分隔线，以及挂在这一层的大面板
        windows.filter { window in
            !window.onScreen && window.frame.height <= 50 && window.frame.width <= 200
                && !ownWindowFrames.contains { abs($0.minX - window.frame.minX) < 2 && abs($0.width - window.frame.width) < 2 }
        }.count
    }

    private static func isVisible(_ frame: CGRect, windows: [StatusWindow]) -> Bool {
        let center = CGPoint(x: frame.midX, y: frame.midY)
        // 1. 优先看系统窗口是否真的显示在屏幕上（被刘海挡住的会是 false）
        if let match = windows.first(where: { $0.frame.insetBy(dx: -1, dy: -1).contains(center) }) {
            return match.onScreen
        }
        // 2. 找不到对应窗口时，用几何位置兜底
        guard let primary = NSScreen.screens.first else { return true }
        let cocoaPoint = NSPoint(x: center.x, y: primary.frame.maxY - center.y)
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(cocoaPoint, $0.frame, false) }) else {
            return false   // 被挤到屏幕外面了
        }
        if let rightArea = screen.auxiliaryTopRightArea, frame.minX < rightArea.minX {
            return false   // 在刘海左边或刘海下面
        }
        return true
    }

    /// 重新读取某个图标当前的位置
    static func currentFrame(of item: MenuBarItemInfo) -> CGRect? {
        AXUIElementSetMessagingTimeout(item.element, 0.2)
        return frame(of: item.element)
    }

    // MARK: - 点击

    /// 替用户「点一下」这个图标，打开它的菜单
    static func press(_ item: MenuBarItemInfo) {
        let element = item.element
        let name = item.displayName
        DispatchQueue.global(qos: .userInitiated).async {
            // 目标 App 弹出菜单时会一直占着，等不到回复属于正常情况，所以超时设短一点
            AXUIElementSetMessagingTimeout(element, 1.0)
            let result = AXUIElementPerformAction(element, kAXPressAction as CFString)
            if result == .actionUnsupported {
                _ = AXUIElementPerformAction(element, kAXShowMenuAction as CFString)
            }
            debugLog("press \(name) result=\(result.rawValue)")
        }
    }

    // MARK: - AX 工具函数

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        guard let positionValue = attribute(element, kAXPositionAttribute),
              let sizeValue = attribute(element, kAXSizeAttribute),
              CFGetTypeID(positionValue) == AXValueGetTypeID(),
              CFGetTypeID(sizeValue) == AXValueGetTypeID() else { return nil }
        var position = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(positionValue as! AXValue, .cgPoint, &position)
        AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
        return CGRect(origin: position, size: size)
    }
}
