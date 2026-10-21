import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panelController: PanelController?
    private var statusBarController: StatusBarController?
    private var settingsController: SettingsWindowController?
    private var hotkeyManager: HotkeyManager?
    private var directoryWatcher: AppDirectoryWatcher?

    func applicationDidFinishLaunching(_ notification: Notification) {
        panelController = PanelController()
        panelController?.onOpenSettings = { [weak self] in self?.showSettings() }

        settingsController = SettingsWindowController()
        settingsController?.onPreferenceChanged = { [weak self] in
            // 托盘显示与全局快捷键都可能由设置页改动，统一刷新
            self?.statusBarController?.refresh()
            self?.hotkeyManager?.reRegister()
        }

        statusBarController = StatusBarController()
        statusBarController?.onShowPanel = { [weak self] in self?.panelController?.togglePanel() }
        statusBarController?.onOpenSettings = { [weak self] in self?.showSettings() }
        statusBarController?.onQuit = { NSApp.terminate(nil) }
        statusBarController?.refresh()

        hotkeyManager = HotkeyManager()
        hotkeyManager?.onToggle = { [weak self] in
            Task { @MainActor in
                self?.panelController?.togglePanel()
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
