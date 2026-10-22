import AppKit
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panelController: PanelController?
    private var statusBarController: StatusBarController?
    private var settingsController: SettingsWindowController?
    private var hotkeyManager: HotkeyManager?
    private var directoryWatcher: AppDirectoryWatcher?
    /// 剪切板历史：常驻监听系统粘贴板（后台 1s 轮询 changeCount）
    private let clipboardManager = ClipboardManager()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 默认开启登录自启动（一次性引导）：之后一切以设置页开关为准
        if !Preferences.launchAtLoginAutoConfigured {
            Preferences.launchAtLoginAutoConfigured = true
            if SMAppService.mainApp.status != .enabled {
                do {
                    try SMAppService.mainApp.register()
                    NSLog("[OpenMyApp] 已默认开启登录自启动")
                } catch {
                    NSLog("[OpenMyApp] 登录自启动注册失败: \(error.localizedDescription)")
                }
            }
        }

        clipboardManager.start()

        panelController = PanelController(clipboardManager: clipboardManager)
        panelController?.onOpenSettings = { [weak self] in self?.showSettings() }

        settingsController = SettingsWindowController()
        settingsController?.onPreferenceChanged = { [weak self] in
            // 托盘显示与全局快捷键都可能由设置页改动，统一刷新
            self?.statusBarController?.refresh()
            self?.hotkeyManager?.reRegister()
        }

        statusBarController = StatusBarController()
        statusBarController?.onShowPanel = { [weak self] in self?.panelController?.togglePanel() }
        statusBarController?.onShowClipboardPanel = { [weak self] in self?.panelController?.toggleClipboardPanel() }
        statusBarController?.onOpenSettings = { [weak self] in self?.showSettings() }
        statusBarController?.onQuit = { NSApp.terminate(nil) }
        statusBarController?.refresh()

        hotkeyManager = HotkeyManager()
        hotkeyManager?.onAction = { [weak self] action in
            Task { @MainActor in
                guard let panelController = self?.panelController else { return }
                switch action {
                case .main:
                    panelController.togglePanel()
                case .clipboard:
                    panelController.toggleClipboardPanel()
                }
            }
        }
        hotkeyManager?.install()

        // 监听应用目录：新装 / 删除应用后自动更新搜索索引
        directoryWatcher = AppDirectoryWatcher(directories: AppIndexer.searchDirectories)
        directoryWatcher?.onChange = { [weak self] in
            Task { @MainActor in
                self?.panelController?.rescanIndex(force: true)
            }
        }
        directoryWatcher?.start()

        // 启动即出现搜索框
        panelController?.showPanel()

        // 真实环境验证辅助：OMA_DEBUG_MODE=clipboard 启动 1.5s 后切到剪切板模式
        if ProcessInfo.processInfo.environment["OMA_DEBUG_MODE"] == "clipboard" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                self?.panelController?.showPanel(mode: .clipboard)
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        panelController?.togglePanel()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Carbon 事件处理器随进程销毁，无需显式反注册
    }

    private func showSettings() {
        settingsController?.show()
    }
}
