import AppKit
import SwiftUI

/// 气泡的 UI 状态(AppKit 侧写入,SwiftUI 侧观察)。
@MainActor
final class BubbleModel: ObservableObject {
    /// 有拖拽悬停在气泡上时高亮。
    @Published var isDragTarget = false
    /// 拖入了不支持的文件:短暂闪红。
    @Published var rejected = false

    func flashRejected() {
        rejected = true
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(0.9))
            self?.rejected = false
        }
    }
}

/// 气泡的 SwiftUI 内容:橙色圆球,拖入时点亮 + 呼吸圈,拒绝时闪红。
struct BubbleRootView: View {
    @ObservedObject var model: BubbleModel

    private let diameter: CGFloat = 64

    var body: some View {
        ZStack {
            Circle()
                .fill(LinearGradient(colors: [Color(red: 1.00, green: 0.73, blue: 0.30),
                                               Color(red: 0.96, green: 0.44, blue: 0.11)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: diameter, height: diameter)
                .shadow(color: .black.opacity(0.35), radius: 9, y: 3)

            Image(systemName: model.isDragTarget ? "plus.circle.fill" : "tray.and.arrow.down.fill")
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(.white)

            if model.isDragTarget {
                RingView()
                    .frame(width: diameter, height: diameter)
            }
            if model.rejected {
                Circle()
                    .strokeBorder(Color.red.opacity(0.9), lineWidth: 3)
                    .frame(width: diameter, height: diameter)
            }
        }
        .frame(width: 96, height: 96) // 留出阴影与呼吸圈的余量
        .animation(.easeInOut(duration: 0.15), value: model.isDragTarget)
        .animation(.easeInOut(duration: 0.15), value: model.rejected)
    }
}

/// 拖拽悬停时向外扩散的呼吸圈。
private struct RingView: View {
    @State private var animating = false
    var body: some View {
        Circle()
            .strokeBorder(Color.white.opacity(animating ? 0.0 : 0.85), lineWidth: 2)
            .scaleEffect(animating ? 1.45 : 1.0)
            .onAppear {
                withAnimation(.easeOut(duration: 0.9).repeatForever(autoreverses: false)) {
                    animating = true
                }
            }
    }
}

// MARK: - 拖拽捕获层

/// 拖放目标的旧式文件名类型(部分来源不提供 .fileURL,只有它)。
private let legacyFilenamesType = NSPasteboard.PasteboardType("NSFilenamesPboardType")

/// KUMQUAT_DEBUG=1 时输出拖拽链路日志,便于远程诊断"拖上去没反应"。
let dragDebugEnabled = ProcessInfo.processInfo.environment["KUMQUAT_DEBUG"] == "1"
func dragLog(_ line: @autoclosure () -> String) {
    if dragDebugEnabled { NSLog("[kumquat] %@", line()) }
}

/// 置顶的透明拖拽捕获视图:专职接收文件投递与气泡的鼠标操作。
///
/// 为什么不让 NSHostingView 子类直接当拖放目标:SwiftUI 的 hosting view 会在
/// 内容更新时按自身需要重新 registerForDraggedTypes,可能把 `.fileURL` 冲掉,
/// 表现为"文件拖上去毫无反应"(已实测复现)。拖放职责必须放在 SwiftUI
/// 碰不到的普通 NSView 层;hosting view 只负责渲染。
final class DragCatcherView: NSView {
    var onFilesDropped: (([URL]) -> Void)?
    var onContextMenu: ((NSEvent) -> Void)?
    /// 拖拽悬停状态变化(true 进入 / false 离开)。
    var onDragHover: ((Bool) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: NSDraggingDestination

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        dragLog("draggingEntered types=\(sender.draggingPasteboard.types ?? [])")
        guard Self.containsFileURLs(sender) else { return [] }
        onDragHover?(true)
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        Self.containsFileURLs(sender) ? .copy : []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        onDragHover?(false)
    }

    /// 本应用未开启 App Sandbox(Developer ID 直发),可直接读取拖拽 URL,
    /// 不涉及 FB13520048 描述的沙盒扩展问题。
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = Self.readFileURLs(from: sender.draggingPasteboard)
        dragLog("performDragOperation urls=\(urls.map(\.lastPathComponent))")
        onDragHover?(false)
        guard !urls.isEmpty else { return false }
        onFilesDropped?(urls)
        return true
    }

    override func concludeDragOperation(_ sender: NSDraggingInfo?) {}

    // MARK: 鼠标:按住拖动 = 移动气泡;右键 = 菜单

    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }

    override func rightMouseDown(with event: NSEvent) {
        onContextMenu?(event)
    }

    private static func containsFileURLs(_ sender: NSDraggingInfo) -> Bool {
        let types = sender.draggingPasteboard.types ?? []
        return types.contains(.fileURL) || types.contains(legacyFilenamesType)
    }

    private static func readFileURLs(from pb: NSPasteboard) -> [URL] {
        var urls = (pb.readObjects(forClasses: [NSURL.self],
                                   options: [.urlReadingFileURLsOnly: true])
                    as? [URL])?.filter(\.isFileURL) ?? []
        if urls.isEmpty,
           let files = pb.propertyList(forType: legacyFilenamesType) as? [String] {
            urls = files.map { URL(fileURLWithPath: $0) }
        }
        return urls
    }
}

/// 气泡面板的内容视图:只承载 SwiftUI 渲染。
/// 防御性覆盖 registerForDraggedTypes:即使 SwiftUI 重写注册表,`.fileURL` 也
/// 永远在册——这样该视图仍是合法的拖放兜底目标(实际接收方是其上的 Catcher)。
final class BubbleContentView: NSHostingView<BubbleRootView> {
    private let model: BubbleModel

    init(model: BubbleModel) {
        self.model = model
        super.init(rootView: BubbleRootView(model: model))
    }

    /// NSHostingView 的 required initializer(我们不主动使用,但必须实现)
    required init(rootView: BubbleRootView) {
        self.model = BubbleModel()
        super.init(rootView: rootView)
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func registerForDraggedTypes(_ newTypes: [NSPasteboard.PasteboardType]) {
        super.registerForDraggedTypes(newTypes.contains(.fileURL) ? newTypes : newTypes + [.fileURL])
    }
}

/// 投递气泡面板。
final class BubblePanel: FloatingPanel {
    static let visibleDefaultsKey = "BubbleVisible"
    private(set) var content: BubbleContentView!

    init(model: BubbleModel,
         onFilesDropped: @escaping ([URL]) -> Void,
         onContextMenu: @escaping (NSEvent) -> Void) {
        // 先放一个占位 frame,setup() 里再精确定位
        super.init(contentRect: NSRect(x: 0, y: 0, width: 96, height: 96))
        let view = BubbleContentView(model: model)

        let catcher = DragCatcherView(frame: NSRect(x: 0, y: 0, width: 96, height: 96))
        catcher.autoresizingMask = [.width, .height]
        catcher.onFilesDropped = onFilesDropped
        catcher.onContextMenu = onContextMenu
        catcher.onDragHover = { hovered in
            Task { @MainActor in model.isDragTarget = hovered }
        }
        view.addSubview(catcher) // 置顶:命中测试与拖放都由 Catcher 接管

        contentView = view
        content = view
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// 放到主屏右上角、菜单栏下方。面板 frame 比可见圆球大,便于容纳阴影。
    func placeAtDefaultPosition() {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let side: CGFloat = 96
        let origin = CGPoint(x: visible.maxX - side - 18, y: visible.maxY - side + 6)
        setFrameOrigin(origin)
    }

    func toggleVisible() {
        let visible = !isVisible
        setVisible(visible)
    }

    func setVisible(_ visible: Bool) {
        UserDefaults.standard.set(visible, forKey: Self.visibleDefaultsKey)
        if visible { placeAtDefaultPosition(); orderFront(nil) } else { orderOut(nil) }
    }

    /// 启动时按上次状态恢复。
    func applyPersistedVisibility() {
        if UserDefaults.standard.object(forKey: Self.visibleDefaultsKey) as? Bool == false {
            orderOut(nil)
        }
    }
}
