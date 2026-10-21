import AppKit
import SwiftUI

/// Alfred 风格悬浮面板的窗口控制器：
/// - 非激活式 NSPanel（不抢夺当前应用焦点）
/// - 点击面板外部 / Esc / 启动应用后自动隐藏
/// - ⌥Space 由 HotkeyManager 触发 toggle
@MainActor
final class PanelController: NSObject, NSWindowDelegate {
    var onOpenSettings: (() -> Void)?

    var isVisible: Bool { panel?.isVisible ?? false }

    private var panel: NSPanel?
    private let model = LauncherModel()
    private var globalClickMonitor: Any?
    private var localClickMonitor: Any?
    private var keyDownMonitor: Any?
    /// 面板变高（结果增多）时保持顶边不动
    private var pinnedTopY: CGFloat = 0

    override init() {
        super.init()
        buildPanel()
        setupModelCallbacks()
        setupMonitors()
    }

    // MARK: - 显示 / 隐藏

    func togglePanel() {
        isVisible ? hidePanel() : showPanel()
    }

    func showPanel() {
        guard let panel else { return }
        model.prepare()
        positionPanel()
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
    }

    func hidePanel() {
        guard let panel, panel.isVisible else { return }
        panel.orderOut(nil)
    }

    // MARK: - 窗口构建

    private func buildPanel() {
        let hosting = NSHostingController(rootView: LauncherView(model: model))
        hosting.sizingOptions = [.preferredContentSize]

        let panel = NSPanel(contentViewController: hosting)
        panel.styleMask = [.titled, .nonactivatingPanel, .fullSizeContentView]
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = false
        panel.delegate = self
        // SwiftUI 布局完成前 preferredContentSize 可能还是 0，先给定初始尺寸，
        // 否则 positionPanel 按 0 宽度计算会导致面板偏右
        panel.setContentSize(NSSize(width: PanelMetrics.width, height: 110))
        self.panel = panel
    }

    /// 居中于主屏水平方向，垂直位于屏幕上 1/3 偏上（Alfred 默认位置附近）
    private func positionPanel() {
        guard let panel, let screen = NSScreen.main else { return }
        let visibleFrame = screen.visibleFrame
        let x = visibleFrame.midX - panel.frame.width / 2
        pinnedTopY = visibleFrame.maxY - visibleFrame.height * 0.28
        panel.setFrameTopLeftPoint(NSPoint(x: x, y: pinnedTopY))
    }

    func windowDidResize(_ notification: Notification) {
        guard let panel, panel.isVisible, pinnedTopY > 0 else { return }
        panel.setFrameTopLeftPoint(NSPoint(x: panel.frame.minX, y: pinnedTopY))
    }

    // MARK: - 回调与监听

    private func setupModelCallbacks() {
        model.onActivate = { [weak self] result in
            self?.activate(result)
        }
        model.onOpenSettings = { [weak self] in
            self?.hidePanel()
            self?.onOpenSettings?()
        }
    }

    private func setupMonitors() {
        // 其他应用内的点击：全局监听
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            Task { @MainActor in self?.handleOutsideClick() }
        }
        // 本应用其他窗口（设置窗、菜单栏图标）内的点击：本地监听
        localClickMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] event in
            if let self, let panel = self.panel, panel.isVisible, event.window !== panel {
                self.hidePanel()
            }
            return event
        }
        // 键盘：↑↓ 选择、回车打开、Esc 关闭
        keyDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let panel = self.panel, panel.isVisible, event.window === panel else {
                return event
            }
            return self.handleKeyDown(event)
        }
    }

    private func handleOutsideClick() {
        guard let panel, panel.isVisible else { return }
        if !panel.frame.contains(NSEvent.mouseLocation) {
            hidePanel()
        }
    }

    /// 返回 nil 表示事件已消费
    private func handleKeyDown(_ event: NSEvent) -> NSEvent? {
        // 输入法组字状态（正在打拼音候选）：交给输入法处理
        if let editor = panel?.firstResponder as? NSTextView, editor.hasMarkedText() {
            return event
        }

        let commandPressed = event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command)
        if commandPressed, let characters = event.charactersIgnoringModifiers {
            switch characters.lowercased() {
            case "q":
                NSApp.terminate(nil)
                return nil
            case "w":
                hidePanel()
                return nil
            case ",":
                hidePanel()
                onOpenSettings?()
                return nil
            default:
                return event
            }
        }

        switch event.keyCode {
        case 36, 76: // return / keypad enter
            model.activateSelected()
            return nil
        case 125: // down
            model.moveSelection(1)
            return nil
        case 126: // up
            model.moveSelection(-1)
            return nil
        case 53: // esc
            hidePanel()
            model.reset()
            return nil
        default:
            return event
        }
    }

    // MARK: - 启动动作

    private func activate(_ result: SearchResult) {
        switch result.kind {
        case .application:
            if let path = result.appPath {
                let url = URL(fileURLWithPath: path)
                NSWorkspace.shared.openApplication(
                    at: url,
                    configuration: NSWorkspace.OpenConfiguration(),
                    completionHandler: nil
                )
                Preferences.recordUsage(for: result.id)
            }
        case .systemSetting:
            if let anchor = result.settingAnchor {
                SystemSettingsCatalog.open(anchor: anchor)
                Preferences.recordUsage(for: result.id)
            }
        }
        hidePanel()
    }
}
