import AppKit
import Carbon.HIToolbox
import SwiftUI
import ServiceManagement

/// 设置窗口控制器（懒创建、单例窗口）
@MainActor
final class SettingsWindowController: NSObject {
    /// 偏好变化后回调（如刷新托盘图标、重注册快捷键）
    var onPreferenceChanged: (() -> Void)?

    private var window: NSWindow?

    func show() {
        if window == nil {
            let hosting = NSHostingController(
                rootView: SettingsView(
                    onPreferenceChanged: { [weak self] in self?.onPreferenceChanged?() }
                )
            )
            let window = NSWindow(contentViewController: hosting)
            window.title = "OpenMyApp 设置"
            window.styleMask = [.titled, .closable]
            window.setContentSize(NSSize(width: 520, height: 400))
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct SettingsView: View {
    var onPreferenceChanged: () -> Void

    @State private var showMenuBarIcon = Preferences.showMenuBarIcon
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginItemsError: String?

    var body: some View {
        Form {
            Section("通用") {
                Toggle("登录时自动启动", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        setLoginItem(enabled: enabled)
                    }
                Toggle("显示菜单栏图标", isOn: $showMenuBarIcon)
                    .onChange(of: showMenuBarIcon) { _, enabled in
                        Preferences.showMenuBarIcon = enabled
                        onPreferenceChanged()
                    }
                if !showMenuBarIcon {
                    Text("菜单栏图标已隐藏：随时按 ⌥Space 唤出搜索框；点搜索框右上角的 ⚙ 可回到这里重新开启。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if let loginItemsError {
                    Text("登录项设置失败：\(loginItemsError)")
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }

            Section("快捷键") {
                HotkeyRecorderButton { onPreferenceChanged() }
                LabeledContent("结果间移动", value: "↑ / ↓")
                LabeledContent("打开选中项", value: "↩")
                LabeledContent("隐藏面板", value: "Esc / 点击面板外")
            }

            Section("关于") {
                LabeledContent("版本", value: Self.appVersion)
                LabeledContent("简介", value: "极简应用启动器：拼音搜索 App 与系统设置")
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 400)
    }

    private static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "-"
    }

    private func setLoginItem(enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            loginItemsError = nil
        } catch {
            loginItemsError = error.localizedDescription
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}

/// 自定义快捷键录制控件：点击进入录制态，下一个组合键即生效；Esc 取消
private struct HotkeyRecorderButton: View {
    /// 录制成功后回调（keyCode, Carbon 修饰键掩码）
    var onChange: () -> Void

    @State private var isRecording = false
    @State private var errorMessage: String?
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 8) {
            LabeledContent {
                Button {
                    isRecording = true
                } label: {
                    Text(isRecording ? "按下新快捷键…" : Preferences.hotkeyDisplay)
                        .monospaced()
                        .frame(minWidth: 90)
                }
                .buttonStyle(.bordered)
                .disabled(isRecording)
            } label: {
                Text("唤出 / 隐藏搜索框")
            }

            if isRecording {
                Text("按新组合键即生效，Esc 取消")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else if let errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
        .onChange(of: isRecording) { _, recording in
            if recording { startListening() } else { stopListening() }
        }
        .onDisappear { stopListening() }
    }

    private func startListening() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handleKeyEvent(event)
        }
    }

    private func stopListening() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
    }

    /// 返回 nil 表示按键已被录制消费
    private func handleKeyEvent(_ event: NSEvent) -> NSEvent? {
        guard isRecording else { return event }

        // Esc 取消录制
        if event.keyCode == 53 {
            isRecording = false
            errorMessage = nil
            return nil
        }

        let mask = HotkeyDisplay.carbonMask(from: event.modifierFlags)
        let hasRequiredModifier = mask & UInt32(cmdKey | optionKey | controlKey) != 0
        guard hasRequiredModifier else {
            errorMessage = "需包含 ⌘ / ⌥ / ⌃ 至少一个修饰键"
            return nil
        }

        Preferences.hotkeyKeyCode = Int(event.keyCode)
        Preferences.hotkeyCarbonMask = Int(mask)
        errorMessage = nil
        isRecording = false
        onChange()
        return nil
    }
}
