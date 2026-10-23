import SwiftUI

/// 面板尺寸常量
enum PanelMetrics {
    static let width: CGFloat = 720
    static let searchRowHeight: CGFloat = 64
    static let rowHeight: CGFloat = 46
    static let rowSpacing: CGFloat = 4
    static let listPadding: CGFloat = 10
    static let maxVisibleRows = 9

    static var maxListHeight: CGFloat {
        CGFloat(maxVisibleRows) * rowHeight + CGFloat(maxVisibleRows - 1) * rowSpacing + 2 * listPadding
    }

    /// 必须与 LazyVStack 实际内容高度一致（count*行高 + (count-1)*行距 + 上下 padding），
    /// 小了会出滚动条，大了面板底部留白（实测踩过）
    static func listHeight(forCount count: Int) -> CGFloat {
        let contentHeight = CGFloat(count) * rowHeight + CGFloat(count - 1) * rowSpacing + 2 * listPadding
        return min(contentHeight, maxListHeight)
    }

    // MARK: 应用网格（空查询浏览态，Launchpad 风）

    static let gridColumns = 7
    static let gridSpacing: CGFloat = 6
    static let gridPadding: CGFloat = 12
    /// 单元格统一高度：上 8 + 图标 48 + 间距 6 + 两行名称 26 + 下 8
    static let gridCellHeight: CGFloat = 96
    static let gridIconSize: CGFloat = 48
    /// 网格最多直接露出 4 行，其余滚动
    static let gridMaxVisibleRows = 4

    static var gridColumnsSpec: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: gridSpacing), count: gridColumns)
    }

    /// 与 LazyVGrid 实际内容高度一致（行数*格高 + (行数-1)*格距 + 上下 padding），约束同 listHeight
    static func gridHeight(forCount count: Int) -> CGFloat {
        let rows = max(1, Int(ceil(Double(count) / Double(gridColumns))))
        let visibleRows = min(rows, gridMaxVisibleRows)
        return CGFloat(visibleRows) * gridCellHeight + CGFloat(visibleRows - 1) * gridSpacing + 2 * gridPadding
    }
}

/// Spotlight 风格搜索主界面：顶部搜索框 + 下方结果列表
struct LauncherView: View {
    @ObservedObject var model: LauncherModel
    @FocusState private var fieldFocused: Bool

    var body: some View {
        ZStack {
            VisualEffectBackground()
            VStack(spacing: 0) {
                searchRow
                // 空态只显示一条搜索框；有输入/结果时才展示下方区域
                if !(model.results.isEmpty && model.query.isEmpty) {
                    Divider().overlay(Color.white.opacity(0.12))
                    content
                }
            }
        }
        .frame(width: PanelMetrics.width)
        .ignoresSafeArea()
        .environment(\.colorScheme, .dark)
        .onAppear { fieldFocused = true }
        .onChange(of: model.focusToken) { _, _ in
            fieldFocused = true
        }
    }

    // MARK: - 搜索框

    private var searchRow: some View {
        HStack(spacing: 12) {
            TextField(
                model.searchMode == .clipboard
                    ? NSLocalizedString("Search clipboard history…", comment: "search placeholder (clipboard mode)")
                    : NSLocalizedString("Search apps or System Settings…", comment: "search placeholder"),
                text: $model.query
            )
                .textFieldStyle(.plain)
                .font(.system(size: 22))
                .focused($fieldFocused)
                .onSubmit { model.activateSelected() }
            Button {
                model.onOpenSettings?()
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(.secondary)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("设置")
        }
        .padding(.horizontal, 18)
        .frame(height: PanelMetrics.searchRowHeight)
    }

    // MARK: - 结果 / 提示区

    @ViewBuilder
    private var content: some View {
        if model.results.isEmpty {
            // 空态只可能是「无输入且索引尚未就绪」或「有输入无命中」；前者保持干净面板
            if !model.query.isEmpty {
                Text(NSLocalizedString("No results", comment: "empty search result"))
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
                    .frame(height: 40)
                    .padding(.bottom, 8)
            }
        } else if model.isBrowsingApps {
            appGrid
        } else {
            resultList
        }
    }

    private var resultList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: PanelMetrics.rowSpacing) {
                    ForEach(model.results) { result in
                        ResultRow(result: result, isSelected: result.id == model.selectedID)
                            .id(result.id)
                            .contentShape(Rectangle())
                            .onTapGesture { model.activate(result) }
                    }
                }
                .padding(PanelMetrics.listPadding)
            }
            .frame(height: PanelMetrics.listHeight(forCount: model.results.count))
            .onChange(of: model.selectedID) { _, newID in
                guard let newID else { return }
                withAnimation(.easeOut(duration: 0.1)) {
                    proxy.scrollTo(newID, anchor: .center)
                }
            }
        }
    }

    /// 空查询浏览态：全量应用网格，按最常用排序（Launchpad 风）
    private var appGrid: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(columns: PanelMetrics.gridColumnsSpec, spacing: PanelMetrics.gridSpacing) {
                    ForEach(model.results) { result in
                        AppGridCell(result: result, isSelected: result.id == model.selectedID)
                            .id(result.id)
                            .contentShape(Rectangle())
                            .onTapGesture { model.activate(result) }
                    }
                }
                .padding(PanelMetrics.gridPadding)
            }
            .frame(height: PanelMetrics.gridHeight(forCount: model.results.count))
            .onChange(of: model.selectedID) { _, newID in
                guard let newID else { return }
                withAnimation(.easeOut(duration: 0.1)) {
                    proxy.scrollTo(newID, anchor: .center)
                }
            }
        }
    }
}

/// 单条结果行：图标 + 名称 + 类别 + 回车提示
private struct ResultRow: View {
    let result: SearchResult
    let isSelected: Bool

    var body: some View {
        if let openPath = result.openPath {
            row.help(openPath)
        } else {
            row
        }
    }

    private var row: some View {
        HStack(spacing: 12) {
            Group {
                if let icon = Self.icon(for: result) {
                    Image(nsImage: icon).resizable().interpolation(.high)
                } else {
                    Image(systemName: "app.fill").resizable()
                }
            }
            .frame(width: 32, height: 32)

            Text(result.title)
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(isSelected ? .white : .primary)
                .lineLimit(1)

            Spacer(minLength: 8)

            Text(result.kind.label)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(isSelected ? .white.opacity(0.85) : .secondary)

            Text("↩")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white.opacity(0.9))
                .opacity(isSelected ? 1 : 0)
                .padding(.trailing, 2)
        }
        .padding(.horizontal, 10)
        .frame(height: PanelMetrics.rowHeight)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(isSelected ? Color.accentColor : Color.clear)
        )
    }

    /// 图标按需解析：应用走 NSWorkspace（系统内部缓存），设置项走 SF Symbol，
    /// 索引不常驻任何 NSImage，只有可见的行产生图标对象；网格单元用大尺寸
    static func icon(for result: SearchResult, size: CGFloat = 32) -> NSImage? {
        switch result.kind {
        case .application:
            guard let path = result.appPath else { return nil }
            let icon = NSWorkspace.shared.icon(forFile: path)
            icon.size = NSSize(width: size, height: size)
            return icon
        case .systemSetting:
            return NSImage(
                systemSymbolName: result.symbolName ?? "gearshape.fill",
                accessibilityDescription: result.title
            )
        case .terminal:
            return NSWorkspace.shared.icon(forFile: "/System/Applications/Utilities/Terminal.app")
        case .finder:
            return NSWorkspace.shared.icon(forFile: "/System/Library/CoreServices/Finder.app")
        case .customApp(let appPath, _):
            let icon = NSWorkspace.shared.icon(forFile: appPath)
            icon.size = NSSize(width: size, height: size)
            return icon
        case .clipboardText:
            return NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: result.title)
        case .clipboardImage:
            return clipboardImage(for: result)
        case .clipboardFile:
            guard let path = result.clipItem?.filePath else { return nil }
            let icon = NSWorkspace.shared.icon(forFile: path)
            icon.size = NSSize(width: size, height: size)
            return icon
        }
    }

    /// 剪切板缩略图：优先缩略图文件，缺失（小图）退回原图；NSCache 限量缓存，
    /// 只有可见行触发解码。countLimit 16：可见 ≤9 行 + 翻页余量，每张解码后
    /// 最多 ~770KB（缩略图策略保证原图 ≤880px），缓存过多只会白占内存
    private static let imageCache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 16
        return cache
    }()

    private static func clipboardImage(for result: SearchResult) -> NSImage? {
        guard let item = result.clipItem,
              let path = item.thumbPath ?? item.filePath else { return nil }
        if let cached = imageCache.object(forKey: path as NSString) { return cached }
        guard let image = NSImage(contentsOfFile: path) else { return nil }
        image.size = NSSize(width: 32, height: 32)
        imageCache.setObject(image, forKey: path as NSString)
        return image
    }
}

/// 浏览态网格单元格：大图标 + 两行名称（Launchpad 风），高度必须与
/// PanelMetrics.gridCellHeight 一致（8 + 48 + 6 + 26 + 8），否则行高错位出滚动条
private struct AppGridCell: View {
    let result: SearchResult
    let isSelected: Bool

    var body: some View {
        cell.help(result.appPath ?? result.title)
    }

    private var cell: some View {
        VStack(spacing: 6) {
            Group {
                if let icon = ResultRow.icon(for: result, size: PanelMetrics.gridIconSize) {
                    Image(nsImage: icon).resizable().interpolation(.high)
                } else {
                    Image(systemName: "app.fill").resizable()
                }
            }
            .frame(width: PanelMetrics.gridIconSize, height: PanelMetrics.gridIconSize)

            Text(result.title)
                .font(.system(size: 11))
                .foregroundColor(.primary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(height: 26)
        }
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .frame(height: PanelMetrics.gridCellHeight)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isSelected ? Color.white.opacity(0.16) : Color.clear)
        )
    }
}
