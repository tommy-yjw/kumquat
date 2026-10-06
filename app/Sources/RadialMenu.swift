import AppKit
import SwiftUI

// MARK: - 菜单项模型

/// 径向菜单里的一个动作。`perform` 由上层注入(启动 JobRunner + 通知)。
struct MenuAction: Identifiable {
    let id: String
    let title: String
    let systemImage: String
    let accent: Color
    let files: [URL]
    let perform: () -> Void
}

// MARK: - 径向布局(WWDC22 "Compose custom layouts with SwiftUI" 的 MyRadialLayout 模式)

/// 把子视图沿圆周均分摆放,第一项从正上方开始。
struct RadialLayout: Layout {
    var radius: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard !subviews.isEmpty else { return .zero }
        let maxSide = subviews
            .map { $0.sizeThatFits(.unspecified) }
            .max { max($0.width, $0.height) < max($1.width, $1.height) } ?? .zero
        let d = max(maxSide.width, maxSide.height)
        return CGSize(width: radius * 2 + d, height: radius * 2 + d)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let count = subviews.count
        guard count > 0 else { return }
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        for (index, subview) in subviews.enumerated() {
            let angle = Double(index) / Double(count) * 2 * .pi - .pi / 2
            let point = CGPoint(x: center.x + Foundation.cos(angle) * radius,
                                y: center.y + Foundation.sin(angle) * radius)
            subview.place(at: point, anchor: .center, proposal: .unspecified)
        }
    }
}

/// 依据动作数量选择半径,并据此推算面板边长(AppKit 侧用同一把尺子定位)。
enum RadialMetrics {
    static let itemDiameter: CGFloat = 62

    static func radius(for count: Int) -> CGFloat {
        switch count {
        case 0: return 0
        case 1...4: return 76
        case 5...6: return 92
        case 7...8: return 108
        default: return 122
        }
    }

    /// 面板边长 = 圆环直径 + 菜单项直径 + 底部取消按钮与阴影余量。
    static func panelSide(for count: Int) -> CGFloat {
        radius(for: count) * 2 + itemDiameter + 64
    }
}

// MARK: - SwiftUI 菜单视图

struct RadialMenuView: View {
    let summary: String
    let actions: [MenuAction]
    var onCancel: () -> Void

    @State private var hoveredID: String?
    @State private var appeared = false

    private var hoveredTitle: String? {
        actions.first { $0.id == hoveredID }?.title
    }

    var body: some View {
        let radius = RadialMetrics.radius(for: actions.count)
        let disc = radius * 2 + RadialMetrics.itemDiameter

        ZStack {
            Circle()
                .fill(.ultraThinMaterial)
                .frame(width: disc, height: disc)
                .overlay(Circle().strokeBorder(.white.opacity(0.25), lineWidth: 1))
                .shadow(color: .black.opacity(0.28), radius: 20, y: 8)

            RadialLayout(radius: radius) {
                ForEach(Array(actions.enumerated()), id: \.element.id) { index, action in
                    RadialItemButton(action: action,
                                     isHovered: hoveredID == action.id,
                                     badgeNumber: actions.count > 1 ? index + 1 : nil)
                        .onHover { hovering in
                            if hovering {
                                hoveredID = action.id
                            } else if hoveredID == action.id {
                                hoveredID = nil
                            }
                        }
                }
            }

            VStack(spacing: 6) {
                CenterCapsule(text: hoveredTitle ?? summary)
                Text("点此取消")
                    .font(.system(size: 8.5, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .onTapGesture(perform: onCancel) // 空白区域(含透明四角)点击即取消
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture(perform: onCancel)
        .scaleEffect(appeared ? 1 : 0.55)
        .opacity(appeared ? 1 : 0)
        .animation(.spring(response: 0.24, dampingFraction: 0.72), value: appeared)
        .onAppear { appeared = true }
    }
}

/// 单个扇区按钮:悬停加深高亮 + 放大(Tangerine 式);可带数字角标(键盘快捷键提示)。
struct RadialItemButton: View {
    let action: MenuAction
    let isHovered: Bool
    var badgeNumber: Int?

    var body: some View {
        Button(action: action.perform) {
            VStack(spacing: 3) {
                Image(systemName: action.systemImage)
                    .font(.system(size: 18, weight: .semibold))
                Text(action.title)
                    .font(.system(size: 9.5, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(width: RadialMetrics.itemDiameter, height: RadialMetrics.itemDiameter)
            .foregroundStyle(isHovered ? Color.white : Color.primary)
            .background(
                Circle().fill(isHovered
                              ? AnyShapeStyle(action.accent)
                              : AnyShapeStyle(.ultraThickMaterial))
            )
            .overlay(Circle().strokeBorder(.white.opacity(isHovered ? 0.8 : 0.35), lineWidth: 1))
            .overlay(alignment: .topLeading) {
                if let badgeNumber {
                    Text("\(badgeNumber)")
                        .font(.system(size: 8.5, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .padding(3)
                        .background(Circle().fill(Color.black.opacity(0.55)))
                        .offset(x: 2, y: 2)
                }
            }
            .shadow(color: .black.opacity(isHovered ? 0.30 : 0.15), radius: isHovered ? 8 : 4, y: 2)
            .scaleEffect(isHovered ? 1.12 : 1.0)
        }
        .buttonStyle(.plain)
        .animation(.spring(response: 0.18, dampingFraction: 0.7), value: isHovered)
    }
}

/// 中心胶囊:指向扇区时显示动作名,空闲时显示文件摘要。
struct CenterCapsule: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .lineLimit(1)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(Capsule().fill(Color.black.opacity(0.62)))
            .foregroundStyle(.white)
            .frame(maxWidth: 150)
    }
}

// MARK: - AppKit 控制器:面板生命周期 + 关闭手势

/// 径向菜单面板控制器。
/// 关闭途径:① 选中动作;② Esc;③ 点击面板外;④ 点击中心胶囊 / 空白区。
@MainActor
final class RadialMenuController {
    private var panel: FloatingPanel?
    private var localClickMonitor: Any?
    private var globalClickMonitor: Any?
    private var keyMonitor: Any?
    private var actionCount = 0
    private var currentActions: [MenuAction] = []

    var isShowing: Bool { panel != nil }

    /// 数字键 1-9 与 keyCode 的对应(径向菜单键盘选择)。
    private static let digitKeyCodes: [UInt16: Int] = [18: 0, 19: 1, 20: 2, 21: 3, 23: 4,
                                                       22: 5, 26: 6, 28: 7, 25: 8]

    func show(files: [URL], actions: [MenuAction], anchoredTo bubbleFrame: NSRect) {
        dismiss()
        actionCount = actions.count
        currentActions = actions

        let side = RadialMetrics.panelSide(for: actions.count)
        let view = RadialMenuView(summary: Self.summaryText(for: files),
                                  actions: actions,
                                  onCancel: { [weak self] in self?.dismiss() })
        let panel = FloatingPanel(contentRect: NSRect(x: 0, y: 0, width: side, height: side))
        let hosting = NSHostingView(rootView: view)
        panel.contentView = hosting

        // 以气泡中心为锚点,夹紧到气泡所在屏幕的可见区域内
        let screen = screenContaining(bubbleFrame) ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        var origin = CGPoint(x: bubbleFrame.midX - side / 2, y: bubbleFrame.midY - side / 2)
        origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - side - 8)
        origin.y = min(max(origin.y, visible.minY + 8), visible.maxY - side - 8)
        panel.setFrameOrigin(origin)

        panel.makeKeyAndOrderFront(nil) // nonactivatingPanel:不抢焦点即成为 key(可收 Esc)
        self.panel = panel
        installMonitors()
    }

    func dismiss() {
        if let localClickMonitor { NSEvent.removeMonitor(localClickMonitor); self.localClickMonitor = nil }
        if let globalClickMonitor { NSEvent.removeMonitor(globalClickMonitor); self.globalClickMonitor = nil }
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor); self.keyMonitor = nil }
        panel?.orderOut(nil)
        panel = nil
        currentActions = []
    }

    private func installMonitors() {
        // Esc 取消;数字键 1-9 直接触发对应扇区(菜单里每个扇区带角标)
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if event.keyCode == 53 { // kVK_Escape
                self.dismiss()
                return nil
            }
            if let index = Self.digitKeyCodes[event.keyCode],
               let action = self.currentActions[safe: index] {
                self.dismiss()
                action.perform()
                return nil
            }
            return event
        }
        // 点击本面板但落在圆盘之外(透明四角):取消并吞掉事件;
        // 落在圆盘内的点击放行,交给 SwiftUI 的按钮 / 背景点按手势。
        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            guard let self, let panel = self.panel, event.window === panel else { return event }
            let center = CGPoint(x: panel.frame.midX, y: panel.frame.midY)
            let discRadius = RadialMetrics.radius(for: self.actionCount) + RadialMetrics.itemDiameter / 2
            let loc = NSEvent.mouseLocation
            if Foundation.hypot(loc.x - center.x, loc.y - center.y) > discRadius {
                self.dismiss()
                return nil
            }
            return event
        }
        // 点击其他应用(全局鼠标事件无需辅助功能权限)
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            self?.dismiss()
        }
    }

    private func screenContaining(_ frame: NSRect) -> NSScreen? {
        NSScreen.screens.first { NSIntersectsRect($0.frame, frame) }
    }

    static func summaryText(for files: [URL]) -> String {
        guard files.count > 1 else {
            let name = files.first?.lastPathComponent ?? ""
            return name.count > 20 ? name.prefix(17) + "…" : name
        }
        return "\(files.count) 个文件"
    }
}
