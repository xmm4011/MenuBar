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
    private var hiddenList: HiddenItemsList?           // 当前打开的「看不到的图标」列表
    private var isReordering = false                   // 正在调整图标顺序，这期间不响应收起/展开
    private var menuOpenedAt: Date?                    // 列表打开的时间，测试时等菜单完全出现再操作
    private weak var openMenu: NSMenu?                 // 正在显示的菜单（系统实际在跟踪的那个对象）
    /// 测试脚本发起的调整：不弹窗，只写日志。reopenFor 为 nil 时调完不重新打开列表，否则打开后过几秒自动关掉
    private struct ReorderTest { let reopenFor: TimeInterval? }
    private var reorderTest: ReorderTest?
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
        // 扫描器靠箭头的位置认出图标真正所在的那一排（接了外接显示器时每块屏幕都有一份）
        MenuBarScanner.toggleFrameProvider = { [weak self] in
            MainActor.assumeIsolated { self?.toggleFrame.map(Self.globalRect) }
        }

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
        // 上次退出时分隔图标若是隐藏的，系统会记下「隐藏过」，下次新建时就不按指定位置放了，先清掉
        defaults.removeObject(forKey: "NSStatusItem VisibleCC " + Self.separatorAutosaveName)
        defaults.removeObject(forKey: "NSStatusItem Visible " + Self.separatorAutosaveName)
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
        guard !isReordering else { return }
        isCollapsed || isApplyingCollapse ? expand() : collapse()
    }

    /// - Parameter silent: 自动收起时为 true，位置不对时不弹窗
    func collapse(silent: Bool = false) {
        guard !isCollapsed, !isApplyingCollapse else { return }
        isApplyingCollapse = true
        expandRequestedDuringCollapse = false
        autoCollapseTimer?.invalidate()
        attemptCollapse(silent: silent, attempt: 1, started: Date())
    }

    /// 放分隔图标并等它贴住箭头。没贴住就再放一次；两次都不行就放弃，
    /// 宁可不收，也不要收一半（分隔图标和箭头之间的图标会留在屏幕上）
    private func attemptCollapse(silent: Bool, attempt: Int, started: Date) {
        placeSeparator()
        waitUntilGlued(deadline: Date().addingTimeInterval(1.0)) { [weak self] glued in
            guard let self else { return }
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            let sepText = NSStringFromRect(self.separatorFrame ?? .zero)

            // 收起过程中用户又要展开：撤销这次收起
            if self.expandRequestedDuringCollapse {
                self.isApplyingCollapse = false
                debugLog("collapse: cancelled by expand after \(ms)ms")
                self.hideSeparator()
                self.postponeCount = 0
                self.scheduleAutoCollapse()
                return
            }
            if !glued && attempt < 2 {
                debugLog("collapse: not glued (sep=\(sepText)), retry")
                self.attemptCollapse(silent: silent, attempt: attempt + 1, started: started)
                return
            }
            self.isApplyingCollapse = false
            guard glued, self.separatorIsLeftOfToggle() else {
                debugLog("collapse: failed after \(attempt) attempts in \(ms)ms sep=\(sepText), stay expanded")
                self.hideSeparator()
                if !silent { self.showWrongOrderAlert() }
                return
            }
            debugLog("collapse: glued in \(ms)ms (attempt \(attempt)) sep=\(sepText)")
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
        guard !isCollapsed, !isReordering else { return }   // 调整顺序结束后会自己恢复状态
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
        guard !isReordering else { return }
        if Prefs.clickShowsList || isMenuClick() {
            showMenu(from: toggleItem)
        } else {
            toggle()
        }
    }

    // MARK: - 菜单

    private func showMenu(from item: NSStatusItem) {
        let (menu, list) = buildMenu()
        hiddenList = list
        menu.delegate = self
        item.menu = menu
        item.button?.performClick(nil)
    }

    func menuWillOpen(_ menu: NSMenu) {
        menuOpenedAt = Date()
        openMenu = menu
    }

    func menuDidClose(_ menu: NSMenu) {
        menuOpenedAt = nil
        openMenu = nil
        // 用完就拿掉，否则左键点击也会弹菜单
        toggleItem.menu = nil
        // 列表里点了图标或拖完了顺序：等菜单真正关掉再去做
        let action = hiddenList?.takePendingAction()
        hiddenList = nil
        if let action { DispatchQueue.main.async { action() } }
    }

    /// 返回菜单和其中「看不到的图标」列表（没有权限时为 nil）
    private func buildMenu() -> (menu: NSMenu, list: HiddenItemsList?) {
        let menu = NSMenu()
        menu.autoenablesItems = false

        let list = addHiddenItemsSection(to: menu)
        if menu.numberOfItems > 0 { menu.addItem(.separator()) }   // 没有看不到的图标时，顶上不留分隔线

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
        return (menu, list)
    }

    /// 列出被刘海挡住、或被收起的图标，点一下就打开它的菜单
    private func addHiddenItemsSection(to menu: NSMenu) -> HiddenItemsList? {
        guard MenuBarScanner.isTrusted else {
            let header = NSMenuItem(title: "看不到的图标", action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            let grant = addItem(to: menu, title: "开启「辅助功能」权限后才能列出…", action: #selector(menuRequestAccessibility))
            grant.image = NSImage(systemSymbolName: "lock.shield", accessibilityDescription: nil)
            return nil
        }

        publishOwnWindowFrames()
        let hidden = MenuBarScanner.scan().filter { !$0.isVisible }
        // 系统窗口列表里被挡住的比读到的多：有 App 不允许读取，如实告诉用户
        let unknown = max(0, MenuBarScanner.hiddenStatusWindowCount() - hidden.count)
        // 不加标题行：带数字的标题容易让人以为算多了，列表本身已经够清楚

        // 同一个 App 有多个图标又没有描述时，加上序号区分
        var nameCount: [String: Int] = [:]
        for item in hidden { nameCount[item.displayName, default: 0] += 1 }
        var nameIndex: [String: Int] = [:]

        // 每行是可以拖动的自定义视图：单击打开，按住 ⌘ 拖动调整顺序
        let list = HiddenItemsList(
            onOpen: { [weak self] item in self?.open(item) },
            onMove: { [weak self] item, destination in self?.reorder(item, to: destination) })
        for item in hidden {
            var title = item.displayName
            if nameCount[title, default: 0] > 1 {
                nameIndex[title, default: 0] += 1
                title += " \(nameIndex[title]!)"
            }
            let menuItem = addItem(to: menu, title: title, action: #selector(menuOpenHiddenItem(_:)))
            menuItem.representedObject = item
            menuItem.toolTip = "打开「\(item.displayName)」的菜单"
            menuItem.view = list.makeRow(for: item, title: title, icon: Self.menuIcon(item.icon))
        }
        // 系统窗口列表里还有被挡住的图标，但读不到是哪个 App 的，没法列出来
        if unknown > 0 {
            let row = NSMenuItem(title: "另有 \(unknown) 个图标读不到是哪个 App 的", action: nil, keyEquivalent: "")
            row.isEnabled = false
            menu.addItem(row)
            let refused = MenuBarScanner.refusedApps
            if refused.isEmpty {
                addHint(to: menu, "对应的 App 没有响应，重启那个 App 一般就好")
            } else {
                addHint(to: menu, "可能是「\(refused.joined(separator: "」「"))」：它拒绝读取，重启它一般就好")
            }
        }
        return list
    }

    /// 灰色小字的说明行
    private func addHint(to menu: NSMenu, _ text: String) {
        let hint = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        hint.attributedTitle = NSAttributedString(string: text, attributes: [
            .font: NSFont.menuFont(ofSize: 11),
            .foregroundColor: NSColor.secondaryLabelColor,
        ])
        hint.isEnabled = false
        menu.addItem(hint)
    }

    /// 告诉扫描器本 App 自己的窗口位置，统计「被挡住的图标」时排除掉（隐形分隔线不算）
    private func publishOwnWindowFrames() {
        MenuBarScanner.ownWindowFrames = [separatorFrame, toggleFrame].compactMap { $0 }.map(Self.globalRect)
    }

    /// 屏幕坐标（原点在主屏左下角）换成全局坐标（原点在主屏左上角，和系统窗口列表一致）
    private static func globalRect(_ rect: NSRect) -> CGRect {
        let primaryHeight = NSScreen.screens.first?.frame.maxY ?? 0
        return CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
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
        guard let image = image?.copy() as? NSImage, image.size.width > 0, image.size.height > 0 else { return nil }
        // App 图标四周自带留白，画 18pt；单色的菜单栏图标（输入法）几乎占满画布，画 16pt 看起来才一样大。
        // 按原比例缩放，宽的图标不压扁
        let box: CGFloat = image.isTemplate ? 16 : 18
        let scale = min(box / image.size.width, box / image.size.height)
        image.size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
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
        expand()
        whenMoved([(item, item.frame.minX)], deadline: Date().addingTimeInterval(2)) {
            MenuBarScanner.press(item)
        }
    }

    /// 收起、展开或拖动之后，对方 App 要过一会儿才知道自己的图标挪了位置（实测约半秒）。
    /// 太早去点或去读，菜单会弹在屏幕外、读到的也是旧位置。所以等这些图标离开原来的 x，再留一点余量
    private func whenMoved(_ items: [(item: MenuBarItemInfo, oldX: CGFloat)], deadline: Date,
                           then action: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            let allMoved = items.allSatisfy { entry in
                MenuBarScanner.currentFrame(of: entry.item).map { abs($0.minX - entry.oldX) > 1 } ?? false
            }
            if allMoved || Date() > deadline {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: action)
            } else {
                self?.whenMoved(items, deadline: deadline, then: action)
            }
        }
    }

    // MARK: - 调整顺序
    //
    // 系统没有提供改别的 App 图标位置的接口，只能像用户一样按住 ⌘ 拖动，而且只能拖屏幕上看得见的图标。
    // 展开时菜单栏放不下，系统会挑一些图标藏到刘海后面，被藏的不一定在最左边，所以展开时看到的顺序不完整。
    // 收起后所有图标在屏幕外排成连续的一排，顺序才是准的。所以每次都是：
    // 展开 → 拖动 → 收起 → 按系统窗口编号核对两个图标是否挨着，不对就再来一次（最多 3 次）。

    private struct ReorderMove {
        let item: MenuBarItemInfo
        let destination: HiddenItemsList.Destination
        let itemWindow: Int         // 系统窗口编号，图标挪了位置也不变
        let referenceWindow: Int
    }

    /// 把图标挪到列表里拖到的位置，完成后恢复原来的收起/展开状态
    private func reorder(_ item: MenuBarItemInfo, to destination: HiddenItemsList.Destination) {
        guard !isReordering else { return }
        isReordering = true
        autoCollapseTimer?.invalidate()
        let started = Date()
        let wasCollapsed = isCollapsed || isApplyingCollapse
        debugLog("reorder: \(item.displayName) \(destination.logText) collapsed=\(wasCollapsed)")

        let finish: (Bool, String?) -> Void = { [weak self] success, message in
            self?.finishReorder(success: success, message: message, wasCollapsed: wasCollapsed, started: started)
        }
        guard let itemWindow = MenuBarScanner.itemWindow(of: item),
              let referenceWindow = MenuBarScanner.itemWindow(of: destination.reference),
              itemWindow.number != referenceWindow.number else {
            finish(false, "读不到图标的位置，请稍后再试。")
            return
        }
        let move = ReorderMove(item: item, destination: destination,
                               itemWindow: itemWindow.number, referenceWindow: referenceWindow.number)
        if isCollapsed && isPlaced(move) == true {
            finish(true, nil)
            return
        }
        attemptReorder(move, attempt: 1, completion: finish)
    }

    private func attemptReorder(_ move: ReorderMove, attempt: Int, completion: @escaping (Bool, String?) -> Void) {
        expandForReorder(waitingFor: move.itemWindow) { [weak self] in
            guard let self else { return }
            guard let a = MenuBarScanner.itemWindow(number: move.itemWindow),
                  let r = MenuBarScanner.itemWindow(number: move.referenceWindow) else {
                completion(false, "读不到图标的位置，请稍后再试。")
                return
            }
            guard a.onScreen else {
                // 第一次就看不见：本来就在刘海后面。拖过一次之后才看不见：挪过去以后被系统藏起来了
                completion(false, attempt == 1 ? Self.notchMessage(move.item) : Self.hiddenAfterMoveMessage(move.item))
                return
            }
            guard r.onScreen else { completion(false, Self.notchMessage(move.destination.reference)); return }

            // 拖动中的图标越过旁边图标的中线，两者就交换。
            // 往左拖，停在参照图标的左半边；往右拖，停在参照图标左边那个图标的右半边
            let margin: CGFloat = 6
            let dropX: CGFloat
            switch move.destination {
            case .before: dropX = a.frame.midX > r.frame.midX ? r.frame.minX + margin : r.frame.minX - margin
            case .after:  dropX = a.frame.midX < r.frame.midX ? r.frame.maxX - margin : r.frame.maxX + margin
            }
            debugLog("reorder: drag \(Int(a.frame.midX)) -> \(Int(dropX)) attempt \(attempt)")
            MenuBarMover.commandDrag(from: CGPoint(x: a.frame.midX, y: a.frame.midY),
                                     to: CGPoint(x: dropX, y: a.frame.midY)) { [weak self] in
                // 等松手后的动画结束，再收起核对
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    self?.verifyReorder(move, attempt: attempt, completion: completion)
                }
            }
        }
    }

    private func verifyReorder(_ move: ReorderMove, attempt: Int, completion: @escaping (Bool, String?) -> Void) {
        collapseThen { [weak self] collapsed in
            guard let self else { return }
            guard collapsed else {
                completion(false, "调整后没能收起菜单栏，无法确认顺序。")
                return
            }
            let placed = self.isPlaced(move) ?? false
            debugLog("reorder: verify attempt \(attempt) placed=\(placed)")
            if placed {
                completion(true, nil)
            } else if attempt < 3 {
                self.attemptReorder(move, attempt: attempt + 1, completion: completion)
            } else {
                completion(false, "拖了 3 次顺序还是不对。可以稍后再试，或者展开后直接按住 ⌘ 在菜单栏上拖动。")
            }
        }
    }

    /// 收起状态下核对：箭头左边的图标窗口从左到右排一排，看两个窗口是否挨着。nil 表示找不到窗口
    private func isPlaced(_ move: ReorderMove) -> Bool? {
        guard let row = MenuBarScanner.itemWindow(number: move.itemWindow)?.frame.midY,
              let toggleX = toggleFrame?.minX else { return nil }
        let order = MenuBarScanner.itemWindows()
            .filter { abs($0.frame.midY - row) < 10 && $0.frame.maxX <= toggleX + 1 }
            .sorted { $0.frame.minX < $1.frame.minX }
            .map(\.number)
        guard let i = order.firstIndex(of: move.itemWindow), let j = order.firstIndex(of: move.referenceWindow) else {
            return nil
        }
        let placed: Bool
        switch move.destination {
        case .before: placed = i + 1 == j
        case .after:  placed = i == j + 1
        }
        if !placed { debugLog("reorder: order item=#\(i) reference=#\(j) of \(order.count)") }
        return placed
    }

    /// 展开，并等布局稳定：要拖的图标显示到屏幕上，且连续两次读到的位置一样（最多等 1.5 秒）
    private func expandForReorder(waitingFor window: Int, then action: @escaping () -> Void) {
        if isCollapsed || isApplyingCollapse { expand() }
        autoCollapseTimer?.invalidate()
        waitForStableLayout(window: window, last: nil, deadline: Date().addingTimeInterval(1.5), then: action)
    }

    private func waitForStableLayout(window: Int, last: CGRect?, deadline: Date, then action: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            let current = MenuBarScanner.itemWindow(number: window)
            let stable = current.map { $0.onScreen && $0.frame == last } ?? false
            if stable || Date() > deadline {
                action()
            } else {
                self?.waitForStableLayout(window: window, last: current?.frame, deadline: deadline, then: action)
            }
        }
    }

    private func collapseThen(_ action: @escaping (_ collapsed: Bool) -> Void) {
        collapse(silent: true)
        whenCollapseFinished(then: action)
    }

    private static func notchMessage(_ item: MenuBarItemInfo) -> String {
        """
        「\(item.displayName)」展开后仍然被刘海挡住，系统不允许拖动看不见的图标。

        菜单栏放不下时，系统会把一部分图标藏到刘海后面。可以在「系统设置 › 菜单栏」里关掉几个用不到的图标，腾出位置后再调整。
        """
    }

    private static func hiddenAfterMoveMessage(_ item: MenuBarItemInfo) -> String {
        """
        「\(item.displayName)」已经挪过去了，但离刘海太近：菜单栏放不下时，系统会自己挑一些图标藏到刘海后面，这次把它藏了起来，没法再微调位置。

        现在列表里的顺序就是它在菜单栏上的实际位置。想让它显示出来，可以把它往右拖一些。
        """
    }

    private func finishReorder(success: Bool, message: String?, wasCollapsed: Bool, started: Date) {
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        debugLog("reorder: \(success ? "done" : "failed") in \(ms)ms" + (message.map { " — " + $0.prefix(40) } ?? ""))
        isReordering = false
        // 调完重新打开列表，让用户看到新顺序
        let test = reorderTest
        reorderTest = nil
        let reopen = success && (test == nil || test?.reopenFor != nil)
        let closeAfter = test?.reopenFor

        if wasCollapsed {
            collapseThen { [weak self] collapsed in
                if reopen && collapsed { self?.reopenMenuWhenSettled(closeAfter: closeAfter) }
            }
        } else {
            expand()
            postponeCount = 0
            scheduleAutoCollapse()
            if reopen {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in self?.reopenMenu(closeAfter: closeAfter) }
            }
        }
        if !success, let message, test == nil {
            showAlert(title: "没能调整顺序", message: message)
        }
    }

    /// 收起后各 App 的图标位置也要过一会儿才更新，读到的还是展开时的位置就会被当成「看得见」。
    /// 等列表里的图标都挪到屏幕外再打开
    private func reopenMenuWhenSettled(closeAfter: TimeInterval?) {
        let toggleX = toggleFrame?.minX ?? 0
        // 箭头可能在外接显示器上，那块屏幕的左边缘不一定是 0
        let screenLeft = toggleItem.button?.window?.screen?.frame.minX ?? 0
        let stale = MenuBarScanner.scan().filter { $0.frame.minX >= screenLeft && $0.frame.maxX <= toggleX + 1 }
        whenMoved(stale.map { ($0, $0.frame.minX) }, deadline: Date().addingTimeInterval(1.5)) { [weak self] in
            guard let self, self.isCollapsed else { return }
            self.reopenMenu(closeAfter: closeAfter)
        }
    }

    private func reopenMenu(closeAfter seconds: TimeInterval?) {
        performOutsideQueue { [weak self] in
            guard let self else { return }
            debugLog("reorder: reopen menu")
            if let seconds { self.closeMenu(after: seconds) }
            self.showMenu(from: self.toggleItem)
        }
    }

    /// 打开菜单、弹窗会一直「卡在」这次调用里，直到用户关掉。主队列是串行的，如果在 DispatchQueue.main
    /// 的任务里打开，菜单开着期间排在主队列上的其他任务（收起、定时器、测试命令）全都会被堵住。
    /// 交给 RunLoop 在下一轮执行就没有这个问题
    /// 测试用：像用户一样按 Esc 关掉打开着的菜单
    private func dismissOpenMenu() {
        guard openMenu != nil else { return }
        MenuBarMover.pressEscape()
    }

    private func performOutsideQueue(_ block: @escaping @MainActor () -> Void) {
        RunLoop.main.perform(inModes: [.default]) {
            MainActor.assumeIsolated { block() }
        }
    }

    /// 测试用：几秒后关掉打开着的菜单（菜单开着时主队列照样执行）
    private func closeMenu(after seconds: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self else { return }
            debugLog("menu: close timer fired (open=\(self.openMenu != nil))")
            self.dismissOpenMenu()
        }
    }

    /// 等这次收起结束（成功或放弃），告诉调用方现在是否收起着
    private func whenCollapseFinished(deadline: Date = Date().addingTimeInterval(3), then action: @escaping (_ collapsed: Bool) -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self else { return }
            if !self.isApplyingCollapse || Date() > deadline {
                action(self.isCollapsed)
            } else {
                self.whenCollapseFinished(deadline: deadline, then: action)
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
        case "drag":
            // 调试用：menubar://drag?from=x&to=x  在箭头所在那一排菜单栏上从 from 拖到 to（全局坐标）
            if let from = param("from").flatMap(Double.init), let to = param("to").flatMap(Double.init) {
                let y = toggleFrame.map { Self.globalRect($0).midY } ?? 15
                debugLog("drag: from \(from) to \(to)")
                MenuBarMover.commandDrag(from: CGPoint(x: from, y: y), to: CGPoint(x: to, y: y)) {
                    debugLog("drag: done")
                }
            }
        case "menu":
            // menubar://menu 打开图标列表（和点箭头一样）。测试用：close=秒数，到时自动关掉
            if let seconds = param("close").flatMap(Double.init) {
                closeMenu(after: seconds)
            }
            showMenu(from: toggleItem)
        case "testreorder", "testclick":
            // 测试用，走的是和用户手动操作完全相同的流程：
            // menubar://testreorder?item=A&before=B  打开列表，模拟按住 ⌘ 把 A 拖到 B 前面（不带 before 表示拖到最后）
            //                                        hold=秒数：拖到位后停一会儿再松手，方便截图
            //                                        reopen=秒数：像用户操作一样调完重新打开列表，过几秒自动关掉
            // menubar://testclick?item=A             打开列表，模拟单击 A 这一行
            if let name = param("item") {
                if command == "testreorder" { reorderTest = ReorderTest(reopenFor: param("reopen").flatMap(Double.init)) }
                simulateListAction(itemName: name, click: command == "testclick", beforeName: param("before"),
                                   hold: param("hold").flatMap(Double.init) ?? 0.12)
            }
        case "dismiss":
            // 测试用：只有确实有弹出菜单开着时，才发一个 Esc 把它关掉，避免影响别的窗口
            if let reason = menuBarInteraction(), reason.hasPrefix("菜单开着") {
                MenuBarMover.pressEscape()
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

    /// 测试用：打开列表，再从后台线程发出鼠标事件（单击某一行，或按住 ⌘ 拖动）
    private func simulateListAction(itemName: String, click: Bool, beforeName: String?, hold: TimeInterval) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            // 菜单开着时主线程在跟踪鼠标，但主队列里的任务照样会执行。
            // 菜单弹出有个渐显动画，刚出现时点下去会被忽略，所以等它完全出现（打开 0.5 秒后）再操作
            let deadline = Date().addingTimeInterval(8)
            var ready = false
            while !ready && Date() < deadline {
                usleep(100_000)
                ready = DispatchQueue.main.sync {
                    MainActor.assumeIsolated { (self?.menuOpenedAt.map { Date().timeIntervalSince($0) > 0.5 }) ?? false }
                }
            }
            let points = DispatchQueue.main.sync {
                MainActor.assumeIsolated { self?.listDragPoints(itemName: itemName, beforeName: beforeName) }
            }
            guard ready, let points else {
                let rows = DispatchQueue.main.sync {
                    MainActor.assumeIsolated { self?.hiddenList?.rows.map(\.title) ?? [] }
                }
                debugLog("testlist: row not found (menu ready=\(ready), rows=\(rows))")
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.dismissOpenMenu() } }
                return
            }
            if click {
                debugLog("testlist: click \(points.from)")
                MenuBarMover.click(at: points.from)
            } else {
                debugLog("testlist: drag \(points.from) -> \(points.to)")
                MenuBarMover.commandDrag(from: points.from, to: points.to, hold: hold, approach: true) {
                    // 原地松手（没挪位置）时列表会一直开着，测试就卡住了，关掉它
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        guard let self, self.openMenu != nil, !self.isReordering else { return }
                        debugLog("testlist: menu still open after drop, closing")
                        self.dismissOpenMenu()
                    }
                }
            }
        }
        showMenu(from: toggleItem)
    }

    private func listDragPoints(itemName: String, beforeName: String?) -> (from: CGPoint, to: CGPoint)? {
        guard let list = hiddenList, let source = list.screenRect(ofRowMatching: itemName) else { return nil }
        let target: CGPoint
        if let beforeName {
            guard let row = list.screenRect(ofRowMatching: beforeName) else { return nil }
            target = CGPoint(x: row.midX, y: row.minY + 5)       // 这一行的上半部分 = 插到它前面
        } else {
            guard let last = list.lastRowScreenRect else { return nil }
            target = CGPoint(x: last.midX, y: last.maxY - 5)     // 最后一行的下半部分 = 插到最后
        }
        return (CGPoint(x: source.midX, y: source.midY), target)
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
        debugLog("debug: trusted=\(MenuBarScanner.isTrusted) scanned=\(scanned.count) hidden=\(scanned.filter { !$0.isVisible }.count) hiddenWindows=\(MenuBarScanner.hiddenStatusWindowCount()) row=\(MenuBarScanner.homeRowSummary()) in \(ms)ms unresponsive=\(MenuBarScanner.unresponsiveApps) refused=\(MenuBarScanner.refusedApps)")
        if includeLatency {
            for entry in MenuBarScanner.latencyReport() {
                debugLog("debug:   latency \(entry.ms)ms \(entry.name) \(entry.result)")
            }
        }
        for item in scanned {
            debugLog("debug:   \(item.isVisible ? "visible" : "HIDDEN ") x=\(Int(item.frame.minX)) w=\(Int(item.frame.width)) \(item.displayName)")
        }
        let titles = buildMenu().menu.items.map { item in
            item.isSeparatorItem ? "—" : item.title + (item.state == .on ? "✓" : "")
        }
        debugLog("debug: menu=\(titles.joined(separator: " | "))")
    }

    // MARK: - 弹窗

    /// - Parameter then: 用户关掉说明后执行
    func showHelp(then: (@MainActor () -> Void)? = nil) {
        if isCollapsed { expand() }
        showAlert(title: "MenuBar 使用说明", then: then, message: """
        菜单栏右上角、控制中心旁边多了一个箭头「›」。

        【找回看不到的图标】
        点箭头，会列出被刘海挡住、或者被收起的图标，点一下就能打开它的菜单。
        第一次使用需要在「系统设置 › 隐私与安全性 › 辅助功能」里打开 MenuBar。

        【调整图标顺序】
        列表从上到下就是菜单栏上从左到右的顺序。
        在列表里按住 ⌘ 上下拖动某一行，菜单栏上的图标会跟着挪过去。

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

    private func showAlert(title: String, then: (@MainActor () -> Void)? = nil, message: String) {
        performOutsideQueue {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = title
            alert.informativeText = message
            alert.addButton(withTitle: "好的")
            alert.runModal()
            then?()
        }
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
