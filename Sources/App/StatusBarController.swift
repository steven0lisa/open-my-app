import AppKit

/// 菜单栏（托盘）图标与菜单；支持按用户偏好隐藏
@MainActor
final class StatusBarController: NSObject {
    var onShowPanel: (() -> Void)?
    var onOpenSettings: (() -> Void)?
    var onQuit: (() -> Void)?

    private var statusItem: NSStatusItem?

    /// 按偏好安装 / 移除图标
    func refresh() {
        if Preferences.showMenuBarIcon {
            install()
        } else {
            remove()
        }
    }

    private func install() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(
            systemSymbolName: "sparkles",
            accessibilityDescription: "OpenMyApp"
        )
        item.menu = buildMenu()
        statusItem = item
    }

    private func remove() {
        if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
        }
        statusItem = nil
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()

        // 快捷键可在设置中自定义，标题动态显示当前组合键
        let show = NSMenuItem(
            title: "打开搜索框（\(Preferences.hotkeyDisplay)）",
            action: #selector(showPanelClicked),
            keyEquivalent: ""
        )
        menu.addItem(show)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "设置…", action: #selector(settingsClicked), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "隐藏菜单栏图标", action: #selector(hideIconClicked), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "退出 OpenMyApp", action: #selector(quitClicked), keyEquivalent: "q"))

        for item in menu.items {
            item.target = self
        }
        return menu
    }

    @objc private func showPanelClicked() { onShowPanel?() }
    @objc private func settingsClicked() { onOpenSettings?() }
    @objc private func quitClicked() { onQuit?() }

    @objc private func hideIconClicked() {
        let alert = NSAlert()
        alert.messageText = "隐藏菜单栏图标？"
        alert.informativeText = "隐藏后仍可随时按 ⌥Space 唤出搜索框；在搜索框右上角的 ⚙ 设置里可以重新开启菜单栏图标。"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "隐藏")
        alert.addButton(withTitle: "取消")
        if alert.runModal() == .alertFirstButtonReturn {
            Preferences.showMenuBarIcon = false
            refresh()
        }
    }
}
