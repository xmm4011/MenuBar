import Foundation

enum Prefs {
    private static let d = UserDefaults.standard

    private enum Key {
        static let autoCollapseSeconds = "autoCollapseSeconds"
        static let collapseOnLaunch = "collapseOnLaunch"
        static let hotKeyEnabled = "hotKeyEnabled"
        static let hasShownWelcome = "hasShownWelcome"
        static let clickShowsList = "clickShowsList"
    }

    static func registerDefaults() {
        d.register(defaults: [
            Key.autoCollapseSeconds: 10,
            Key.collapseOnLaunch: true,
            Key.hotKeyEnabled: true,
            Key.hasShownWelcome: false,
            Key.clickShowsList: true,
        ])
    }

    /// 展开后多少秒自动收起，0 表示不自动收起
    static var autoCollapseSeconds: Int {
        get { d.integer(forKey: Key.autoCollapseSeconds) }
        set { d.set(newValue, forKey: Key.autoCollapseSeconds) }
    }

    static var collapseOnLaunch: Bool {
        get { d.bool(forKey: Key.collapseOnLaunch) }
        set { d.set(newValue, forKey: Key.collapseOnLaunch) }
    }

    static var hotKeyEnabled: Bool {
        get { d.bool(forKey: Key.hotKeyEnabled) }
        set { d.set(newValue, forKey: Key.hotKeyEnabled) }
    }

    /// 左键点箭头：true 显示「看不到的图标」列表，false 直接收起/展开
    static var clickShowsList: Bool {
        get { d.bool(forKey: Key.clickShowsList) }
        set { d.set(newValue, forKey: Key.clickShowsList) }
    }

    static var hasShownWelcome: Bool {
        get { d.bool(forKey: Key.hasShownWelcome) }
        set { d.set(newValue, forKey: Key.hasShownWelcome) }
    }
}
