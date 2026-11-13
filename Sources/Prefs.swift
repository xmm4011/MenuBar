import Foundation

enum Prefs {
    private static let d = UserDefaults.standard

    private enum Key {
        static let autoCollapseSeconds = "autoCollapseSeconds"
        static let collapseOnLaunch = "collapseOnLaunch"
        static let hotKeyEnabled = "hotKeyEnabled"
        static let hasShownWelcome = "hasShownWelcome"
        static let clickShowsList = "clickShowsList"
        static let separatorOffset = "separatorOffset"
    }

    static func registerDefaults() {
        d.register(defaults: [
            Key.autoCollapseSeconds: 10,
            Key.collapseOnLaunch: true,
            Key.hotKeyEnabled: true,
            Key.hasShownWelcome: false,
            Key.clickShowsList: true,
            Key.separatorOffset: 1.0,
        ])
    }

    /// 分隔图标的「偏好位置」比箭头大多少：数值越大越靠左。
    /// 默认 1（紧挨着箭头左边），收起时如果没贴住会按实际差距自动纠正并记下来
    static var separatorOffset: Double {
        get { d.double(forKey: Key.separatorOffset) }
        set { d.set(newValue, forKey: Key.separatorOffset) }
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
