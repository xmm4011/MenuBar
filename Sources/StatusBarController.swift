import AppKit

/// 原理：
/// 用户只看到一个箭头「‹ / ›」。
/// 收起时，在箭头左边紧贴着放一个看不见的分隔图标，宽度设成 10000，它左边的所有图标都会被挤出屏幕，
/// 箭头和箭头右边的常驻图标不受影响。展开时把分隔图标从菜单栏拿掉，不占任何位置。
/// 用户按住 ⌘ 拖动箭头或其他图标即可决定哪些要被收起。
@MainActor
final class StatusBarController: NSObject, NSMenuDelegate {
    private let toggleItem: NSStatusItem
    /// 只在收起时显示：每次收起都新建一个，紧贴在箭头左边；展开时隐藏，下次收起前删掉
    private var separatorItem: NSStatusItem?
    private let hotKey = GlobalHotKey()

    private(set) var isCollapsed = false
    private var autoCollapseTimer: Timer?
    private var postponeCount = 0
    private var scanRefreshTimer: Timer?
    private var isApplyingCollapse = false            // 收起要分几步完成，这期间为 true
    private var expandRequestedDuringCollapse = false  // 收起过程中收到了展开请求
    private let collapsedSeparatorLength: CGFloat = 10_000
    private let maxPostpone = 30   // 用户在操作菜单栏时最多推迟 30 次 × 2 秒

    private static let toggleAutosaveName = "MenuBar.Toggle"
    private static let separatorAutosaveName = "MenuBar.Separator"
    private static let positionPrefix = "NSStatusItem Preferred Position "

    override init() {
        Self.setInitialPositionsIfNeeded()

        toggleItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        toggleItem.autosaveName = Self.toggleAutosaveName
        super.init()

        toggleItem.isVisible = true

        configureToggleButton()
        applyState()
        updateHotKey()
        startScanRefresh()
    }

    /// 后台定时把所有进程问一遍，让点箭头时的扫描足够快
    private func startScanRefresh() {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) {
            MenuBarScanner.refreshCache()
        }
        scanRefreshTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            DispatchQueue.global(qos: .utility).async { MenuBarScanner.refreshCache() }
        }
    }

    /// 新建的图标默认出现在最左边，刘海屏上很容易被刘海挡住。
    /// 首次启动时把箭头放到最右边（紧挨控制中心）。数值越小越靠右；之后用户拖动会自动更新。
    private static func setInitialPositionsIfNeeded() {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: positionPrefix + toggleAutosaveName) == nil {
            defaults.set(0, forKey: positionPrefix + toggleAutosaveName)
        }
    }

    // MARK: - 隐形分隔图标

    private var separatorFrame: NSRect? {
        guard let item = separatorItem, item.isVisible else { return nil }
        return item.button?.window?.frame
    }
    private var toggleFrame: NSRect? { toggleItem.button?.window?.frame }

    /// 新建分隔图标：先把它的「偏好位置」设成比箭头稍微靠左，系统就会把它放在箭头左边
    private func placeSeparator() {
        removeSeparator()
        let defaults = UserDefaults.standard
        let togglePosition = defaults.double(forKey: Self.positionPrefix + Self.toggleAutosaveName)
        defaults.set(togglePosition + 1, forKey: Self.positionPrefix + Self.separatorAutosaveName)

        let item = NSStatusBar.system.statusItem(withLength: collapsedSeparatorLength)
        item.autosaveName = Self.separatorAutosaveName
        item.button?.image = nil
        item.button?.title = ""
        item.isVisible = true
        separatorItem = item
    }

    private func removeSeparator() {
        if let item = separatorItem { NSStatusBar.system.removeStatusItem(item) }
        separatorItem = nil
    }

    /// 展开时用「隐藏」而不是「删除」：macOS 26 上直接删除，别的 App 收不到位置变化的通知，
    /// 它们以为自己的图标还在屏幕外，点开的菜单会弹到屏幕外面去
    private func hideSeparator() {
        separatorItem?.isVisible = false
    }

    /// 分隔图标的右边缘正好贴着箭头的左边缘，中间没有别的图标
    private func separatorIsGlued() -> Bool {
        guard let sep = separatorFrame, let tog = toggleFrame else { return false }
        if NSApp.userInterfaceLayoutDirection == .rightToLeft {
            return abs(sep.minX - tog.maxX) <= 3
        }
        return abs(sep.maxX - tog.minX) <= 3
    }

    /// 分隔图标必须在箭头左边，否则会把箭头自己也挤出去，再也点不到
    private func separatorIsLeftOfToggle() -> Bool {
        guard let sep = separatorFrame, let tog = toggleFrame else { return false }
        if NSApp.userInterfaceLayoutDirection == .rightToLeft {
            return sep.minX > tog.minX
        }
        return sep.minX < tog.minX
    }

    /// 系统排位置需要一点时间：每 50 毫秒看一次，连续两次贴住才算数，最多等到 deadline
    private func waitUntilGlued(deadline: Date, confirmed: Int = 0, completion: @escaping (Bool) -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self else { return }
            let count = self.separatorIsGlued() ? confirmed + 1 : 0
            if count >= 2 {
                completion(true)
            } else if Date() > deadline {
                completion(false)
            } else {
                self.waitUntilGlued(deadline: deadline, confirmed: count, completion: completion)
            }
        }
    }

    // MARK: - 收起 / 展开

    func toggle() {
        isCollapsed || isApplyingCollapse ? expand() : collapse()
    }

    /// - Parameter silent: 自动收起时为 true，位置不对时不弹窗
    func collapse(silent: Bool = false) {
        guard !isCollapsed, !isApplyingCollapse else { return }
        isApplyingCollapse = true
        expandRequestedDuringCollapse = false
        autoCollapseTimer?.invalidate()
        let started = Date()

        placeSeparator()
        waitUntilGlued(deadline: started.addingTimeInterval(1.5)) { [weak self] glued in
            guard let self else { return }
            self.isApplyingCollapse = false
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            let sepText = NSStringFromRect(self.separatorFrame ?? .zero)

            // 收起过程中用户又要展开：撤销这次收起
            if self.expandRequestedDuringCollapse {
                debugLog("collapse: cancelled by expand after \(ms)ms")
                self.hideSeparator()
                self.postponeCount = 0
                self.scheduleAutoCollapse()
                return
            }
            // 分隔图标跑到了箭头右边：立刻撤回，不然箭头会被挤出去
            guard self.separatorIsLeftOfToggle() else {
                debugLog("collapse: separator not left of toggle sep=\(sepText), aborted")
                self.hideSeparator()
                if !silent { self.showWrongOrderAlert() }
                return
            }
            debugLog("collapse: glued=\(glued) in \(ms)ms sep=\(sepText)")
            self.isCollapsed = true
            self.applyState()
        }
    }

    func expand() {
        if isApplyingCollapse {
            expandRequestedDuringCollapse = true
            return
        }
        guard isCollapsed else { return }
        isCollapsed = false
        applyState()
        postponeCount = 0
        scheduleAutoCollapse()
    }

    private func applyState() {
        if isCollapsed {
            autoCollapseTimer?.invalidate()
            autoCollapseTimer = nil
            toggleItem.button?.image = Self.expandImage
            toggleItem.button?.toolTip = "箭头左边的图标已收起"
        } else {
            hideSeparator()   // 展开时不占位置
            toggleItem.button?.image = Self.collapseImage
            toggleItem.button?.toolTip = "按住 ⌘ 拖动：箭头左边的图标可以收起，右边的常驻显示"
        }
    }

    // MARK: - 自动收起

    private func scheduleAutoCollapse(after seconds: TimeInterval? = nil) {
        autoCollapseTimer?.invalidate()
        autoCollapseTimer = nil
        let configured = Prefs.autoCollapseSeconds
        guard configured > 0, !isCollapsed else { return }

        let interval = seconds ?? TimeInterval(configured)
        autoCollapseTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.autoCollapseTimerFired() }
        }
    }

    private func autoCollapseTimerFired() {
        guard !isCollapsed else { return }
        // 鼠标还停在菜单栏上，或者某个菜单正打开着，就稍后再收
        let reason = menuBarInteraction()
        if postponeCount < maxPostpone, let reason {
            postponeCount += 1
            debugLog("auto-collapse: postponed (\(reason)) #\(postponeCount)")
            scheduleAutoCollapse(after: 2)
            return
        }
        debugLog("auto-collapse: collapse")
        collapse(silent: true)
    }

    /// 用户是否正在用菜单栏：返回原因，nil 表示没有
    private func menuBarInteraction() -> String? {
        let mouse = NSEvent.mouseLocation
        if let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) {
            let barHeight = max(screen.frame.maxY - screen.visibleFrame.maxY, 24)
            if mouse.y >= screen.frame.maxY - barHeight - 1 { return "鼠标在菜单栏上" }
        }

        // 有下拉菜单正在显示（窗口层级 = popUpMenu）
        let popUpLevel = Int(CGWindowLevelForKey(.popUpMenuWindow))
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                 kCGNullWindowID) as? [[String: Any]] ?? []
        if let menu = windows.first(where: { ($0[kCGWindowLayer as String] as? Int) == popUpLevel }) {
            return "菜单开着：\(menu[kCGWindowOwnerName as String] as? String ?? "?")"
        }
        return nil
    }

    // MARK: - 按钮

    private func configureToggleButton() {
        guard let button = toggleItem.button else { return }
        button.target = self
        button.action = #selector(toggleButtonClicked(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.imagePosition = .imageOnly
    }

    private func isMenuClick() -> Bool {
        guard let event = NSApp.currentEvent else { return false }
        return event.type == .rightMouseUp
            || event.modifierFlags.contains(.control)
            || event.modifierFlags.contains(.option)
    }

    @objc private func toggleButtonClicked(_ sender: NSStatusBarButton) {
        if Prefs.clickShowsList || isMenuClick() {
            showMenu(from: toggleItem)
        } else {
            toggle()
        }
    }

    // MARK: - 菜单

    private func showMenu(from item: NSStatusItem) {
        let menu = buildMenu()
        menu.delegate = self
        item.menu = menu
        item.button?.performClick(nil)
    }

    func menuDidClose(_ menu: NSMenu) {
        // 用完就拿掉，否则左键点击也会弹菜单
        toggleItem.menu = nil
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        addHiddenItemsSection(to: menu)
        menu.addItem(.separator())

        let toggleTitle = isCollapsed ? "展开菜单栏" : "收起菜单栏"
        let toggleMenuItem = addItem(to: menu, title: toggleTitle, action: #selector(menuToggle))
        if Prefs.hotKeyEnabled {
            toggleMenuItem.keyEquivalent = "b"
            toggleMenuItem.keyEquivalentModifierMask = [.control, .option, .command]
        }
        menu.addItem(.separator())

        let settingsItem = NSMenuItem(title: "设置", action: nil, keyEquivalent: "")
        settingsItem.submenu = buildSettingsMenu()
        menu.addItem(settingsItem)
        addItem(to: menu, title: "使用说明…", action: #selector(menuShowHelp))
        let quit = addItem(to: menu, title: "退出 MenuBar", action: #selector(menuQuit))
        quit.keyEquivalent = "q"
        return menu
    }

    /// 列出被刘海挡住、或被收起的图标，点一下就打开它的菜单
    private func addHiddenItemsSection(to menu: NSMenu) {
        guard MenuBarScanner.isTrusted else {
            let header = NSMenuItem(title: "看不到的图标", action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            let grant = addItem(to: menu, title: "开启「辅助功能」权限后才能列出…", action: #selector(menuRequestAccessibility))
            grant.image = NSImage(systemSymbolName: "lock.shield", accessibilityDescription: nil)
            return
        }

        publishOwnWindowFrames()
        let hidden = MenuBarScanner.scan().filter { !$0.isVisible }
        // 系统窗口列表里被挡住的比读到的多：有 App 不允许读取，如实告诉用户
        let unknown = max(0, MenuBarScanner.hiddenStatusWindowCount() - hidden.count)
        let total = hidden.count + unknown
        let headerTitle = total == 0 ? "所有图标都能看到" : "看不到的图标（\(total) 个）"
        let header = NSMenuItem(title: headerTitle, action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        // 同一个 App 有多个图标又没有描述时，加上序号区分
        var nameCount: [String: Int] = [:]
        for item in hidden { nameCount[item.displayName, default: 0] += 1 }
        var nameIndex: [String: Int] = [:]

        for item in hidden {
            var title = item.displayName
            if nameCount[title, default: 0] > 1 {
                nameIndex[title, default: 0] += 1
                title += " \(nameIndex[title]!)"
            }
            let menuItem = addItem(to: menu, title: title, action: #selector(menuOpenHiddenItem(_:)))
            menuItem.representedObject = item
            menuItem.image = Self.menuIcon(item.appIcon)
            menuItem.toolTip = "打开「\(item.displayName)」的菜单"
        }

        if unknown > 0 {
            let row = NSMenuItem(title: "另有 \(unknown) 个无法识别", action: nil, keyEquivalent: "")
            row.isEnabled = false
            row.toolTip = "这些图标所属的 App 不允许读取信息。可以把它们拖到箭头右边常驻，或重启对应的 App 再试。"
            menu.addItem(row)
        }
    }

    /// 告诉扫描器本 App 自己的窗口位置，统计「被挡住的图标」时排除掉（隐形分隔线不算）
    private func publishOwnWindowFrames() {
        let primaryHeight = NSScreen.screens.first?.frame.maxY ?? 0
        MenuBarScanner.ownWindowFrames = [separatorFrame, toggleFrame].compactMap { $0 }.map {
            CGRect(x: $0.minX, y: primaryHeight - $0.maxY, width: $0.width, height: $0.height)
        }
    }

    private func buildSettingsMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        let clickItem = NSMenuItem(title: "左键点击箭头", action: nil, keyEquivalent: "")
        let clickMenu = NSMenu()
        clickMenu.autoenablesItems = false
        addItem(to: clickMenu, title: "显示看不到的图标", action: #selector(menuSetClickShowsList))
            .state = Prefs.clickShowsList ? .on : .off
        addItem(to: clickMenu, title: "直接收起 / 展开", action: #selector(menuSetClickToggles))
            .state = Prefs.clickShowsList ? .off : .on
        clickItem.submenu = clickMenu
        menu.addItem(clickItem)

        let autoItem = NSMenuItem(title: "自动收起", action: nil, keyEquivalent: "")
        let autoMenu = NSMenu()
        autoMenu.autoenablesItems = false
        let choices: [(Int, String)] = [(0, "从不"), (5, "5 秒后"), (10, "10 秒后"), (30, "30 秒后"), (60, "1 分钟后")]
        for (seconds, title) in choices {
            let item = addItem(to: autoMenu, title: title, action: #selector(menuSetAutoCollapse(_:)))
            item.tag = seconds
            item.state = Prefs.autoCollapseSeconds == seconds ? .on : .off
        }
        autoItem.submenu = autoMenu
        menu.addItem(autoItem)

        addItem(to: menu, title: "启动时自动收起", action: #selector(menuToggleCollapseOnLaunch))
            .state = Prefs.collapseOnLaunch ? .on : .off

        addItem(to: menu, title: "全局快捷键 \(GlobalHotKey.toggleDisplay)", action: #selector(menuToggleHotKey))
            .state = Prefs.hotKeyEnabled ? .on : .off

        let loginItem = addItem(to: menu, title: "开机自动启动", action: #selector(menuToggleLoginItem))
        loginItem.state = LoginItem.isEnabled ? .on : (LoginItem.needsApproval ? .mixed : .off)

        if !MenuBarScanner.isTrusted {
            menu.addItem(.separator())
            addItem(to: menu, title: "开启「辅助功能」权限…", action: #selector(menuRequestAccessibility))
        }
        return menu
    }

    private static func menuIcon(_ image: NSImage?) -> NSImage? {
        guard let image = image?.copy() as? NSImage else { return nil }
        image.size = NSSize(width: 18, height: 18)
        return image
    }

    @discardableResult
    private func addItem(to menu: NSMenu, title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        return item
    }

    @objc private func menuToggle() { toggle() }

    @objc private func menuOpenHiddenItem(_ sender: NSMenuItem) {
        guard let item = sender.representedObject as? MenuBarItemInfo else { return }
        open(item)
    }

    /// 打开某个图标的菜单。被收起的图标在屏幕外，先展开让它回到菜单栏，再点它
    private func open(_ item: MenuBarItemInfo) {
        guard isCollapsed else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { MenuBarScanner.press(item) }
            return
        }
        let offscreenX = item.frame.minX
        expand()
        pressWhenMoved(item, from: offscreenX, deadline: Date().addingTimeInterval(2))
    }

    /// 展开后，对方 App 要过一会儿才知道自己的图标挪回来了（实测约半秒）。
    /// 太早点它，菜单会弹在屏幕外。所以等它的位置真的变了，再留一点余量才点。
    private func pressWhenMoved(_ item: MenuBarItemInfo, from oldX: CGFloat, deadline: Date) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            let moved = MenuBarScanner.currentFrame(of: item).map { abs($0.minX - oldX) > 1 } ?? false
            if moved || Date() > deadline {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { MenuBarScanner.press(item) }
            } else {
                self?.pressWhenMoved(item, from: oldX, deadline: deadline)
            }
        }
    }

    @objc private func menuRequestAccessibility() {
        MenuBarScanner.requestTrust()
        MenuBarScanner.openAccessibilitySettings()
    }

    @objc private func menuSetClickShowsList() { Prefs.clickShowsList = true }

    @objc private func menuSetClickToggles() { Prefs.clickShowsList = false }

    @objc private func menuSetAutoCollapse(_ sender: NSMenuItem) {
        Prefs.autoCollapseSeconds = sender.tag
        if !isCollapsed {
            postponeCount = 0
            scheduleAutoCollapse()
        }
    }

    @objc private func menuToggleCollapseOnLaunch() {
        Prefs.collapseOnLaunch.toggle()
    }

    @objc private func menuToggleHotKey() {
        Prefs.hotKeyEnabled.toggle()
        updateHotKey()
    }

    @objc private func menuToggleLoginItem() {
        do {
            if LoginItem.needsApproval {
                LoginItem.openSystemSettings()
                return
            }
            try LoginItem.setEnabled(!LoginItem.isEnabled)
            if LoginItem.needsApproval {
                LoginItem.openSystemSettings()
            }
        } catch {
            showAlert(title: "设置开机启动失败",
                      message: "\(error.localizedDescription)\n\n建议先把 MenuBar.app 放到「应用程序」文件夹再试。")
        }
    }

    @objc private func menuShowHelp() { showHelp() }

    @objc private func menuQuit() { NSApp.terminate(nil) }

    // MARK: - 快捷键 / URL

    private func updateHotKey() {
        guard Prefs.hotKeyEnabled else {
            hotKey.unregister()
            return
        }
        let ok = hotKey.register(keyCode: GlobalHotKey.toggleKeyCode,
                                 modifiers: GlobalHotKey.toggleModifiers) { [weak self] in
            MainActor.assumeIsolated { self?.toggle() }
        }
        if !ok {
            debugLog("快捷键 \(GlobalHotKey.toggleDisplay) 注册失败，可能已被其他软件占用")
        }
    }

    func handle(url: URL) {
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func param(_ name: String) -> String? { query.first { $0.name == name }?.value }
        let command = (url.host ?? "").lowercased()
        if command != "debug" { debugLog("url \(command)") }

        switch command {
        case "toggle": toggle()
        case "collapse", "hide": collapse()
        case "expand", "show": expand()
        case "debug":
            // menubar://debug                诊断信息
            // menubar://debug?latency=1      另外测每个 App 的响应耗时（会慢几秒）
            // menubar://debug?app=KeyDock    打印某个 App 的原始辅助功能信息
            // 带 token=xxx 时，最后写一行 done token=xxx，方便测试脚本对上号
            if let app = param("app") {
                MenuBarScanner.rawDump(app).forEach { debugLog("raw: " + $0) }
            } else {
                logDebugInfo(includeLatency: param("latency") == "1")
            }
            if let token = param("token") { debugLog("debug: done token=\(token)") }
        case "dismiss":
            // 测试用：只有确实有弹出菜单开着时，才发一个 Esc 把它关掉，避免影响别的窗口
            if let reason = menuBarInteraction(), reason.hasPrefix("菜单开着") {
                let source = CGEventSource(stateID: .hidSystemState)
                CGEvent(keyboardEventSource: source, virtualKey: 0x35, keyDown: true)?.post(tap: .cghidEventTap)
                CGEvent(keyboardEventSource: source, virtualKey: 0x35, keyDown: false)?.post(tap: .cghidEventTap)
                debugLog("dismiss: sent Esc (\(reason))")
            }
        case "open":
            // menubar://open?app=微信 打开指定图标的菜单
            let name = param("app") ?? param("name") ?? ""
            guard !name.isEmpty else { return }
            guard MenuBarScanner.isTrusted else {
                MenuBarScanner.requestTrust()
                return
            }
            if let item = MenuBarScanner.find(name) {
                debugLog("open \(name) -> \(item.displayName) visible=\(item.isVisible)")
                open(item)
            } else {
                debugLog("open \(name) -> not found")
            }
        default: break
        }
    }

    /// menubar://debug 把当前状态写到系统日志，排查问题用：
    /// log show --last 1m --predicate 'process == "MenuBar"'
    private func logDebugInfo(includeLatency: Bool = false) {
        publishOwnWindowFrames()
        let sep = separatorFrame ?? .zero
        let tog = toggleFrame ?? .zero
        debugLog("debug: collapsed=\(isCollapsed) separator=\(NSStringFromRect(sep)) toggle=\(NSStringFromRect(tog)) orderOK=\(separatorIsLeftOfToggle()) glued=\(separatorIsGlued()) autoCollapse=\(Prefs.autoCollapseSeconds)s")
        let started = Date()
        let scanned = MenuBarScanner.scan()
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        debugLog("debug: trusted=\(MenuBarScanner.isTrusted) scanned=\(scanned.count) hidden=\(scanned.filter { !$0.isVisible }.count) hiddenWindows=\(MenuBarScanner.hiddenStatusWindowCount()) in \(ms)ms unresponsive=\(MenuBarScanner.unresponsiveApps)")
        if includeLatency {
            for entry in MenuBarScanner.latencyReport() {
                debugLog("debug:   latency \(entry.ms)ms \(entry.name) \(entry.result)")
            }
        }
        for item in scanned {
            debugLog("debug:   \(item.isVisible ? "visible" : "HIDDEN ") x=\(Int(item.frame.minX)) w=\(Int(item.frame.width)) \(item.displayName)")
        }
        let titles = buildMenu().items.map { item in
            item.isSeparatorItem ? "—" : item.title + (item.state == .on ? "✓" : "")
        }
        debugLog("debug: menu=\(titles.joined(separator: " | "))")
    }

    // MARK: - 弹窗

    func showHelp() {
        if isCollapsed { expand() }
        showAlert(title: "MenuBar 使用说明", message: """
        菜单栏右上角、控制中心旁边多了一个箭头「›」。

        【找回看不到的图标】
        点箭头，会列出被刘海挡住、或者被收起的图标，点一下就能打开它的菜单。
        第一次使用需要在「系统设置 › 隐私与安全性 › 辅助功能」里打开 MenuBar。

        【收起不常用的图标】
        1. 按住 ⌘ 键拖动箭头，把它放到常驻图标的左边。
        2. 箭头右边的图标一直显示；箭头左边的图标可以收起。
        3. 点箭头菜单里的「收起菜单栏」，或按 \(GlobalHotKey.toggleDisplay)，收起或展开。
        4. 展开后默认 10 秒自动收起，鼠标停在菜单栏上时不会收。
        """)
    }

    private func showWrongOrderAlert() {
        showAlert(title: "暂时无法收起", message: """
        没能把收起的边界放到箭头左边。

        可以按住 ⌘ 把箭头稍微拖动一下，或者退出后重新打开 MenuBar 再试。
        """)
    }

    private func showAlert(title: String, message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "好的")
        alert.runModal()
    }

    // MARK: - 图标

    private static func symbol(_ name: String, fallback: String) -> NSImage {
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
        if let image = NSImage(systemSymbolName: name, accessibilityDescription: fallback)?
            .withSymbolConfiguration(config) {
            image.isTemplate = true
            return image
        }
        let image = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 14, weight: .semibold)]
            (fallback as NSString).draw(in: rect, withAttributes: attrs)
            return true
        }
        image.isTemplate = true
        return image
    }

    /// 已收起时显示：点击向左展开
    private static let expandImage = symbol("chevron.left", fallback: "‹")
    /// 已展开时显示：点击向右收起
    private static let collapseImage = symbol("chevron.right", fallback: "›")
}
