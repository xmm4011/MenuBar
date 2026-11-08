import Carbon.HIToolbox

// Carbon 的回调是 C 函数指针，不能捕获上下文，所以用全局变量转发
nonisolated(unsafe) private var hotKeyAction: (() -> Void)?

/// 全局快捷键（RegisterEventHotKey 不需要辅助功能权限）
final class GlobalHotKey {
    static let toggleKeyCode = UInt32(kVK_ANSI_B)
    static let toggleModifiers = UInt32(cmdKey | optionKey | controlKey)   // ⌃⌥⌘B
    static let toggleDisplay = "⌃⌥⌘B"

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    @discardableResult
    func register(keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) -> Bool {
        unregister()
        hotKeyAction = action

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        let installStatus = InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { hotKeyAction?() }
            return noErr
        }, 1, &eventType, nil, &handlerRef)
        guard installStatus == noErr else { return false }

        let id = EventHotKeyID(signature: OSType(0x4D4E_4252), id: 1)   // 'MNBR'
        let status = RegisterEventHotKey(keyCode, modifiers, id,
                                         GetApplicationEventTarget(), 0, &hotKeyRef)
        if status != noErr {
            unregister()
            return false
        }
        return true
    }

    func unregister() {
        if let ref = hotKeyRef { UnregisterEventHotKey(ref) }
        if let handler = handlerRef { RemoveEventHandler(handler) }
        hotKeyRef = nil
        handlerRef = nil
        hotKeyAction = nil
    }
}
