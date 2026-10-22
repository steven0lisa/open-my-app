import AppKit

/// 菜单栏（托盘）图标与菜单；支持按用户偏好隐藏
@MainActor
final class StatusBarController: NSObject {
    var onShowPanel: (() -> Void)?
    var onShowClipboardPanel: (() -> Void)?
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

    private func localized(_ key: String) -> String {
        NSLocalizedString(key, comment: "menu / alert")
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()

        // 快捷键可在设置中自定义，标题动态显示当前组合键
        let showTitle = String(
            format: localized("Open Search Panel (%@)"),
            Preferences.hotkeyDisplay
        )
        menu.addItem(NSMenuItem(title: showTitle, action: #selector(showPanelClicked), keyEquivalent: ""))
        let clipboardTitle = String(
            format: localized("Open Clipboard (%@)"),
            Preferences.clipboardHotkeyDisplay
        )
        menu.addItem(NSMenuItem(title: clipboardTitle, action: #selector(showClipboardClicked), keyEquivalent: ""))

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: localized("Settings…"), action: #selector(settingsClicked), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: localized("Hide Menu Bar Icon"), action: #selector(hideIconClicked), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: localized("Quit OpenMyApp"), action: #selector(quitClicked), keyEquivalent: "q"))

        for item in menu.items {
            item.target = self
        }
        return menu
    }

    @objc private func showPanelClicked() { onShowPanel?() }
    @objc private func showClipboardClicked() { onShowClipboardPanel?() }
    @objc private func settingsClicked() { onOpenSettings?() }
    @objc private func quitClicked() { onQuit?() }

    @objc private func hideIconClicked() {
        let alert = NSAlert()
        alert.messageText = localized("Hide Menu Bar Icon?")
        alert.informativeText = String(
            format: localized("You can still summon the panel with %@ anytime. Re-enable it from the ⚙ Settings button in the panel."),
            Preferences.hotkeyDisplay
        )
        alert.alertStyle = .informational
        alert.addButton(withTitle: localized("Hide"))
        alert.addButton(withTitle: localized("Cancel"))
        if alert.runModal() == .alertFirstButtonReturn {
            Preferences.showMenuBarIcon = false
            refresh()
        }
    }
}
