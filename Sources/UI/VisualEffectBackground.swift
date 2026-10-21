import SwiftUI
import AppKit

/// 毛玻璃背景（NSVisualEffectView 封装），带圆角与描边
struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow
    var cornerRadius: CGFloat = 12

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .active
        view.wantsLayer = true
        if let layer = view.layer {
            layer.cornerRadius = cornerRadius
            layer.masksToBounds = true
            layer.cornerCurve = .continuous
            layer.borderWidth = 1
            layer.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor
        }
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
