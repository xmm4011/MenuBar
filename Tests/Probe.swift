// 测试用的小 App。
// 默认：在菜单栏放一个带标准菜单的「PROBE」图标。新图标默认出现在最左边，刘海屏上通常会被挡住，正好用来测试。
// 带 --trio 参数：放三个图标「ALPHA」「BRAVO」「CHARLIE」，各有固定的保存名，测试脚本事先写好它们的位置，用来测试调整顺序。
import AppKit

final class ProbeDelegate: NSObject, NSApplicationDelegate {
    var items: [NSStatusItem] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        if CommandLine.arguments.contains("--trio") {
            items = ["ALPHA", "BRAVO", "CHARLIE"].map { makeItem($0, autosaveName: "Probe" + $0.capitalized) }
        } else {
            items = [makeItem("PROBE", autosaveName: nil)]
        }
    }

    private func makeItem(_ title: String, autosaveName: String?) -> NSStatusItem {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let autosaveName { item.autosaveName = autosaveName }
        item.button?.title = title
        let menu = NSMenu()
        menu.addItem(withTitle: "\(title) menu item", action: nil, keyEquivalent: "")
        item.menu = menu
        return item
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = ProbeDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
