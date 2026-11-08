// 测试用的小 App：在菜单栏放一个带标准菜单的「PROBE」图标。
// 新图标默认出现在最左边，刘海屏上通常会被挡住，正好用来测试。
import AppKit

final class ProbeDelegate: NSObject, NSApplicationDelegate {
    var item: NSStatusItem?
    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "PROBE"
        let menu = NSMenu()
        menu.addItem(withTitle: "Probe menu item", action: nil, keyEquivalent: "")
        item.menu = menu
        self.item = item
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = ProbeDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
