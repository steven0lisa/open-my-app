import Carbon.HIToolbox
import Foundation

/// 全局快捷键 —— Carbon RegisterEventHotKey，无需辅助功能权限。
/// 快捷键可在设置中自定义（Preferences 持久化），变更后调用 reRegister()。
final class HotkeyManager {
    /// 快捷键触发回调（事件回调在主线程派发）
    var onToggle: (() -> Void)?

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private var handlerInstalled = false
    /// 四字符标识 'OMAP'（OpenMyApp）
    private let signature = OSType(0x4F4D4150)

    /// 应用启动时调用：安装事件处理器并注册当前偏好中的快捷键
    func install() {
        if !handlerInstalled {
            installEventHandler()
        }
        reRegister()
    }

    /// 快捷键偏好变化后重新注册
    func reRegister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }

        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            UInt32(Preferences.hotkeyKeyCode),
            UInt32(Preferences.hotkeyCarbonMask),
            EventHotKeyID(signature: signature, id: 1),
            GetApplicationEventTarget(),
            0,
            &ref
        )
        if status == noErr {
            hotKeyRef = ref
        } else {
            // 常见于快捷键已被其他应用占用
            NSLog("[OpenMyApp] RegisterEventHotKey failed: \(status), hotkey=\(Preferences.hotkeyDisplay)")
        }
    }

    private func installEventHandler() {
        var eventSpec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let context = Unmanaged.passUnretained(self).toOpaque()

        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, userData in
                guard let userData else { return noErr }
                let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
                manager.onToggle?()
                return noErr
            },
            1,
            &eventSpec,
            context,
            &handlerRef
        )
        guard status == noErr else {
            NSLog("[OpenMyApp] InstallEventHandler failed: \(status)")
            return
        }
        handlerInstalled = true
    }
}
