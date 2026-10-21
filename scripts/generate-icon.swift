// generate-icon.swift — 生成 AppIcon 全尺寸 PNG（macOS Big Sur 风格圆角矩形 + rocket 符号）
// 用法：在仓库根目录执行 `swift scripts/generate-icon.swift`

import AppKit

let masterSize = 1024

func renderMasterIcon() -> NSImage {
    let image = NSImage(size: NSSize(width: masterSize, height: masterSize))
    image.lockFocus()

    // 图标主体占 824/1024（Apple 官方网格），圆角半径约 22.37%
    let side: CGFloat = 824
    let rect = NSRect(
        x: (CGFloat(masterSize) - side) / 2,
        y: (CGFloat(masterSize) - side) / 2,
        width: side,
        height: side
    )
    let rounded = NSBezierPath(roundedRect: rect, xRadius: side * 0.2237, yRadius: side * 0.2237)
    rounded.addClip()

    let gradient = NSGradient(colors: [
        NSColor(calibratedRed: 0.28, green: 0.50, blue: 0.99, alpha: 1),
        NSColor(calibratedRed: 0.58, green: 0.34, blue: 0.96, alpha: 1),
    ])
    gradient?.draw(in: rounded, angle: -90)

    // 居中绘制白色 rocket 符号
    if let base = NSImage(systemSymbolName: "rocket.fill", accessibilityDescription: nil) {
        let configured = base.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: 400, weight: .medium)
        ) ?? base
        let symbolSize = configured.size
        let tinted = NSImage(size: symbolSize)
        tinted.lockFocus()
        configured.draw(in: NSRect(origin: .zero, size: symbolSize))
        NSColor.white.setFill()
        NSRect(origin: .zero, size: symbolSize).fill(using: .sourceAtop)
        tinted.unlockFocus()

        let drawSide: CGFloat = 480
        tinted.draw(
            in: NSRect(
                x: (CGFloat(masterSize) - drawSide) / 2,
                y: (CGFloat(masterSize) - drawSide) / 2,
                width: drawSide,
                height: drawSide
            )
        )
    }

    image.unlockFocus()
    return image
}

func writePNG(_ image: NSImage, pixelSize: Int, to path: String) {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixelSize,
        pixelsHigh: pixelSize,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )!
    rep.size = NSSize(width: pixelSize, height: pixelSize)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: NSRect(x: 0, y: 0, width: pixelSize, height: pixelSize))
    NSGraphicsContext.restoreGraphicsState()
    let data = rep.representation(using: .png, properties: [:])!
    try! data.write(to: URL(fileURLWithPath: path))
}

let outputDirectory = "Resources/Assets.xcassets/AppIcon.appiconset"
try? FileManager.default.createDirectory(atPath: outputDirectory, withIntermediateDirectories: true)

let icon = renderMasterIcon()
let specs: [(name: String, pixels: Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]
for spec in specs {
    writePNG(icon, pixelSize: spec.pixels, to: "\(outputDirectory)/\(spec.name)")
}
print("AppIcon written to \(outputDirectory) (\(specs.count) files)")
