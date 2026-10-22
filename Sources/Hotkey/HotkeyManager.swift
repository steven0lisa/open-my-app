import Carbon.HIToolbox
import Foundation

/// 全局快捷键 —— Carbon RegisterEventHotKey，无需辅助功能权限。
/// 双热键：主热键（唤出普通面板）+ 剪切板热键（唤出剪切板模式）。
/// 快捷键可在设置中自定义（Preferences 持久化），变更后调用 reRegister()。
final class HotkeyManager {
    enum Action {
        case main
        case clipboard
    }

    /// 快捷键触发回调（事件回调在主线程派发）
    var onAction: ((Action) -> Void)?

    private var mainKeyRef: EventHotKeyRef?
    private var clipboardKeyRef: EventHotKeyRef?
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
        if let mainKeyRef {
            UnregisterEventHotKey(mainKeyRef)
            self.mainKeyRef = nil
        }
        if let clipboardKeyRef {
            UnregisterEventHotKey(clipboardKeyRef)
            self.clipboardKeyRef = nil
        }
        mainKeyRef = register(keyCode: Preferences.hotkeyKeyCode, mask: Preferences.hotkeyCarbonMask, id: 1)
        clipboardKeyRef = register(keyCode: Preferences.clipboardHotkeyKeyCode, mask: Preferences.clipboardHotkeyCarbonMask, id: 2)
    }

    private func register(keyCode: Int, mask: Int, id: UInt32) -> EventHotKeyRef? {
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            UInt32(keyCode),
            UInt32(mask),
            EventHotKeyID(signature: signature, id: id),
            GetApplicationEventTarget(),
            0,
            &ref
        )
        if status != noErr {
            // 常见于快捷键已被其他应用占用
            NSLog("[OpenMyApp] RegisterEventHotKey failed: \(status), id=\(id)")
            return nil
        }
        return ref
    }

    private func installEventHandler() {
        var eventSpec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let context = Unmanaged.passUnretained(self).toOpaque()

        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let userData, let event else { return noErr }
                var hotKeyID = EventHotKeyID()
                let paramStatus = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                guard paramStatus == noErr else { return noErr }
                let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
                manager.onAction?(hotKeyID.id == 2 ? .clipboard : .main)
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
