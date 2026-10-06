import AppKit
import SwiftUI

// MARK: - 投放轮盘模型

@MainActor
final class DropWheelModel: ObservableObject {
    /// 拖拽悬停命中的扇区下标(nil = 未命中)。
    @Published var hovered: Int?
}

/// 投放轮盘的 SwiftUI 内容:与径向菜单同款视觉,但扇区不响应点击——
/// 选择动作的方式是"把文件投到扇区上"。
struct DropWheelView: View {
    let summary: String
    let actions: [MenuAction]
    @ObservedObject var model: DropWheelModel

    var body: some View {
        let radius = RadialMetrics.radius(for: actions.count)
        let disc = radius * 2 + RadialMetrics.itemDiameter

        ZStack {
            Circle()
                .fill(.ultraThinMaterial)
                .frame(width: disc, height: disc)
                .overlay(Circle().strokeBorder(.white.opacity(0.3), lineWidth: 1.5))
                .shadow(color: .black.opacity(0.32), radius: 20, y: 8)

            RadialLayout(radius: radius) {
                ForEach(Array(actions.enumerated()), id: \.element.id) { index, action in
                    RadialItemButton(action: action, isHovered: model.hovered == index, badgeNumber: nil)
                }
            }

            VStack(spacing: 6) {
                CenterCapsule(text: model.hovered.map { actions[$0].title } ?? summary)
                Text("投放到扇区执行 · 中心或圈外取消")
                    .font(.system(size: 8.5, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
    }
}

/// 承载投放轮盘的悬浮面板(层级高于气泡,拖拽会话可重定向进来)。
final class DropWheelPanel: FloatingPanel {
    private(set) var catcher: DropWheelCatcher!

    init(actions: [MenuAction], model: DropWheelModel, files: [URL],
         onDrop: @escaping (Int?, [URL]) -> Void,
         onMouseDown: @escaping () -> Void) {
        let side = RadialMetrics.panelSide(for: actions.count)
        super.init(contentRect: NSRect(x: 0, y: 0, width: side, height: side))
        level = .statusBar // 拖拽进行中出现,要在几乎所有内容之上

        let hosting = NSHostingView(rootView: DropWheelView(
            summary: RadialMenuController.summaryText(for: files),
            actions: actions, model: model
        ))
        contentView = hosting

        let catcher = DropWheelCatcher(frame: hosting.bounds,
                                       model: model,
                                       actions: actions,
                                       onDrop: onDrop,
                                       onMouseDown: onMouseDown)
        catcher.autoresizingMask = [.width, .height]
        hosting.addSubview(catcher)
        self.catcher = catcher
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

/// 投放轮盘的拖拽捕获层:文件拖进来时按命中扇区高亮,松手即执行该动作。
/// 命中判定与 RadialLayout 的摆放公式一致(y 翻转对齐 SwiftUI 坐标)。
final class DropWheelCatcher: NSView {
    private let model: DropWheelModel
    private let actions: [MenuAction]
    private let onDrop: (Int?, [URL]) -> Void
    private let onMouseDown: () -> Void
    private(set) var isDragHovering = false

    init(frame: NSRect, model: DropWheelModel, actions: [MenuAction],
         onDrop: @escaping (Int?, [URL]) -> Void,
         onMouseDown: @escaping () -> Void) {
        self.model = model
        self.actions = actions
        self.onDrop = onDrop
        self.onMouseDown = onMouseDown
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: NSDraggingDestination

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        isDragHovering = true
        updateHover(with: sender)
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        updateHover(with: sender)
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        isDragHovering = false
        Task { @MainActor in model.hovered = nil }
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = (sender.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                          options: [.urlReadingFileURLsOnly: true])
                    as? [URL])?.filter(\.isFileURL) ?? []
        let index = model.hovered
        dragLog("drop-wheel perform index=\(String(describing: index)) urls=\(urls.map(\.lastPathComponent))")
        onDrop(index, urls)
        return true
    }

    // MARK: 鼠标

    override func mouseDown(with event: NSEvent) {
        // 按住拖动 = 微调轮盘位置;双击 = 收起(拖拽会话中通常按 Esc / 投放 / 移出收起)
        if event.clickCount >= 2 {
            onMouseDown()
        } else {
            window?.performDrag(with: event)
        }
    }

    // MARK: 命中判定

    private func updateHover(with sender: NSDraggingInfo) {
        let location = convert(sender.draggingLocation, from: nil)
        let index = sectorIndex(at: location)
        Task { @MainActor in model.hovered = index }
    }

    /// 扇区中心与 RadialLayout 相同公式(SwiftUI y 向下,此处翻转 y 对齐)。
    private func sectorIndex(at point: CGPoint) -> Int? {
        let count = actions.count
        guard count > 0 else { return nil }
        let radius = RadialMetrics.radius(for: count)
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let threshold = RadialMetrics.itemDiameter * 0.75
        for index in 0..<count {
            let angle = Double(index) / Double(count) * 2 * .pi - .pi / 2
            let sectorCenter = CGPoint(x: center.x + cos(angle) * radius,
                                       y: center.y - sin(angle) * radius)
            if hypot(point.x - sectorCenter.x, point.y - sectorCenter.y) <= threshold {
                return index
            }
        }
        return nil
    }
}

// MARK: - 全局 Shift 拖拽手势控制器

/// Tangerine 签名交互的免权限实现:
/// - 拖文件时按住 Shift → 指针处弹出投放轮盘,拖拽会话自动重定向进来,投到扇区即执行;
/// - 修饰键用 CGEventSource.flagsState 读取(查询状态不需要辅助功能/输入监控权限);
/// - 拖拽起点用 NSPasteboard.general.changeCount 轮询感知(拖拽开始即写入拖拽粘贴板);
/// - 轮盘消失条件:松开 Shift 且无悬停 / 点按 / 投放 / 15 秒超时。
@MainActor
final class ShiftDragController {
    static let enabledDefaultsKey = "ShiftGestureEnabled"

    private var timer: Timer?
    private var panel: DropWheelPanel?
    private var model: DropWheelModel?
    private var shownAt = Date.distantPast

    private let onBuildActions: ([URL]) -> [MenuAction]
    private let onRun: (ActionKind, [URL]) -> Void

    /// 拖拽会话专用粘贴板:Finder 拖拽写入这里,不写 general
    /// (v2 初版轮询 general.changeCount 因此从未命中,已实测确认并修正)。
    private let dragPasteboard = NSPasteboard(name: NSPasteboard.Name("Apple CFPasteboard drag"))
    private var lastDragChangeCount = 0
    private var lastDragChangeAt = Date.distantPast
    private var dragCountAtShow = -1
    private var lastDebugLogAt = Date.distantPast
    /// 备用 Shift 通道:全局修饰键事件(flagsChanged)。主通道 CGEventSource.flagsState
    /// 若读不到(权限/实现差异),事件通道兜底;首次注册可能触发"输入监控"授权。
    private var monitorShiftDown = false

    var isEnabled: Bool {
        UserDefaults.standard.object(forKey: Self.enabledDefaultsKey) as? Bool ?? true
    }

    func setEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: Self.enabledDefaultsKey)
        if !enabled { dismiss() }
    }

    init(onBuildActions: @escaping ([URL]) -> [MenuAction],
         onRun: @escaping (ActionKind, [URL]) -> Void) {
        self.onBuildActions = onBuildActions
        self.onRun = onRun
        lastDragChangeCount = dragPasteboard.changeCount // 启动时不把陈旧内容当新拖拽
    }

    func start() {
        guard timer == nil else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            let shiftDown = event.modifierFlags.contains(.shift)
            DispatchQueue.main.async {
                self?.monitorShiftDown = shiftDown
            }
        }
        // 本地通道:投放轮盘自己是 key 窗口时,松 Shift 走本地事件,
        // 全局监听收不到 → 状态会卡死在 true(v2 实测),本地监听补上。
        NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            let shiftDown = event.modifierFlags.contains(.shift)
            DispatchQueue.main.async {
                self?.monitorShiftDown = shiftDown
            }
            return event
        }
    }

    func dismiss() {
        panel?.orderOut(nil)
        panel = nil
        model = nil
        shownAt = Date()
    }

    private func tick() {
        let dragCount = dragPasteboard.changeCount
        if dragCount != lastDragChangeCount {
            lastDragChangeCount = dragCount
            lastDragChangeAt = Date()
        }
        let flagsStateShift = CGEventSource.flagsState(.combinedSessionState).contains(.maskShift)
        let shiftHeld = flagsStateShift || monitorShiftDown

        if panel != nil {
            let hovering = panel?.catcher.isDragHovering ?? false
            // 收起:松开 Shift 且无悬停;拖拽会话已结束(拖拽粘贴板又变化);超时兜底
            if (!shiftHeld && !hovering)
                || dragCount != dragCountAtShow
                || Date().timeIntervalSince(shownAt) > 15 {
                dismiss()
            }
            return
        }

        // 弹出条件:按住 Shift + 拖拽粘贴板刚变化(新拖拽会话开始)+ 里面是文件 URL。
        // dragCount != dragCountAtShow:同一次拖拽会话只弹一次,取消后不再复读。
        guard isEnabled,
              shiftHeld,
              dragCount != dragCountAtShow,
              Date().timeIntervalSince(lastDragChangeAt) < 8,
              Date().timeIntervalSince(shownAt) > 1.5,
              radialMenuIdle,
              let files = dragFileURLs(), !files.isEmpty else {
            if dragDebugEnabled, Date().timeIntervalSince(lastDebugLogAt) > 2 {
                lastDebugLogAt = Date()
                let filesCount = dragFileURLs()?.count ?? 0
                dragLog("tick 心跳 shift(状态)=\(flagsStateShift) shift(事件)=\(monitorShiftDown) dragCount=\(dragCount) shownFor=\(dragCountAtShow) dragFiles=\(filesCount) enabled=\(isEnabled) idle=\(radialMenuIdle)")
            }
            return
        }
        showWheel(files: files)
    }

    /// 径向菜单(投放后菜单)正在显示时不弹轮盘,避免两个轮盘叠罗汉。
    private var radialMenuIdle: Bool {
        // AppDelegate 持有 RadialMenuController;经注入的查询闭包解耦
        radialIdleQuery?() ?? true
    }
    var radialIdleQuery: (() -> Bool)?

    private func showWheel(files: [URL]) {
        let actions = onBuildActions(files)
        guard !actions.isEmpty else { return }
        dragLog("shift-wheel show count=\(actions.count) files=\(files.map(\.lastPathComponent))")

        let wheelModel = DropWheelModel()
        let wheelPanel = DropWheelPanel(actions: actions, model: wheelModel, files: files,
                                        onDrop: { [weak self] index, urls in
                                            self?.handleDrop(index: index, urls: urls)
                                        },
                                        onMouseDown: { [weak self] in self?.dismiss() })
        position(wheelPanel, at: NSEvent.mouseLocation)
        wheelPanel.makeKeyAndOrderFront(nil)
        panel = wheelPanel
        model = wheelModel
        shownAt = Date()
        dragCountAtShow = dragPasteboard.changeCount
    }

    private func handleDrop(index: Int?, urls: [URL]) {
        defer { dismiss() }
        // 命中扇区 → 执行该动作;中心/圈外(index 为 nil)→ 仅收起
        guard let index else { return }
        let actions = onBuildActions(urls)
        guard let action = actions[safe: index] else { return }
        dragLog("shift-wheel run action=\(action.id)")
        action.perform()
    }

    /// 轮盘中心对准指针,夹紧到所在屏幕可见区域。
    private func position(_ wheelPanel: DropWheelPanel, at location: NSPoint) {
        let screen = NSScreen.screens.first { NSMouseInRect(location, $0.frame, false) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let side = wheelPanel.frame.width
        var origin = CGPoint(x: location.x - side / 2, y: location.y - side / 2)
        origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - side - 8)
        origin.y = min(max(origin.y, visible.minY + 8), visible.maxY - side - 8)
        wheelPanel.setFrameOrigin(origin)
    }

    /// 拖拽粘贴板里的文件 URL(拖拽进行中与结束后短时间内都可读)。
    private func dragFileURLs() -> [URL]? {
        (dragPasteboard.readObjects(forClasses: [NSURL.self],
                                    options: [.urlReadingFileURLsOnly: true])
         as? [URL])?.filter(\.isFileURL)
    }
}

// MARK: - 小工具

extension Array {
    /// 安全下标(投放轮盘的 index 来自坐标判定,必须防越界)。
    subscript(safe index: Int?) -> Element? {
        guard let index, indices.contains(index) else { return nil }
        return self[index]
    }
}
