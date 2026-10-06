import AppKit

/// 无边框、非激活、常驻悬浮面板基类。
///
/// 要点(对应 reverse-report.md §3.1):
/// - `.borderless + .nonactivatingPanel`:出现/交互都不会抢走前台应用焦点;
/// - `level = .floating`、`canJoinAllSpaces + .fullScreenAuxiliary`:浮在全部 Space 与全屏 App 之上;
/// - `hidesOnDeactivate = false`:拖拽来自别的应用,面板绝不能因失焦而隐藏;
/// - borderless 窗口默认不能成为 key window,必须重写 `canBecomeKey`(否则收不到键盘事件)。
class FloatingPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(contentRect: contentRect,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered,
                   defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false // 阴影由 SwiftUI 内容自绘,避免透明窗口出现方形阴影
        hidesOnDeactivate = false
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isMovableByWindowBackground = false
        worksWhenModal = true
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
