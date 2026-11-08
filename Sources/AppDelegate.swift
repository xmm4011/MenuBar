import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: StatusBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Prefs.registerDefaults()
        let controller = StatusBarController()
        self.controller = controller

        if !Prefs.hasShownWelcome {
            Prefs.hasShownWelcome = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                controller.showHelp()
                // 列出「看不到的图标」需要辅助功能权限，看完说明后顺便申请
                if !MenuBarScanner.isTrusted { MenuBarScanner.requestTrust() }
            }
        } else if Prefs.collapseOnLaunch {
            // 等菜单栏布局完成后再收起，否则拿不到图标位置
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                controller.collapse(silent: true)
            }
        }
    }

    /// 支持 URL Scheme：menubar://toggle | collapse | expand
    /// 方便配合快捷指令、Raycast、Alfred 使用
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { controller?.handle(url: url) }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // 再次双击 App 时展开图标
        controller?.expand()
        return false
    }
}
