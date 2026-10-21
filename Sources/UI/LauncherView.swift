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
            TextField("搜索应用程序或系统设置…", text: $model.query)
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
            Text("没有匹配的结果")
                .font(.system(size: 13))
                .foregroundColor(.secondary)
                .frame(height: 40)
                .padding(.bottom, 8)
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
}

/// 单条结果行：图标 + 名称 + 类别 + 回车提示
private struct ResultRow: View {
    let result: SearchResult
    let isSelected: Bool

    var body: some View {
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
    /// 索引不常驻任何 NSImage，只有可见的 ≤9 行产生图标对象
    static func icon(for result: SearchResult) -> NSImage? {
        switch result.kind {
        case .application:
            guard let path = result.appPath else { return nil }
            let icon = NSWorkspace.shared.icon(forFile: path)
            icon.size = NSSize(width: 32, height: 32)
            return icon
        case .systemSetting:
            return NSImage(
                systemSymbolName: result.symbolName ?? "gearshape.fill",
                accessibilityDescription: result.title
            )
        }
    }
}
