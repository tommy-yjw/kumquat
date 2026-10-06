import AppKit

// 金桔 / Kumquat —— 常驻投递气泡 + 径向动作菜单的纯本地文件转换工具。
// LSUIElement 应用:无 Dock 图标,通过菜单栏状态项与悬浮气泡交互。

// 顶层代码跑在主线程;显式进入 MainActor 上下文组装 AppKit(delegate 与其余
// AppKit/SwiftUI 对象均在 @MainActor 隔离下)。
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let appDelegate = AppDelegate() // 局部 let 足够:app.run() 永不返回
    app.delegate = appDelegate
    app.setActivationPolicy(.accessory) // 双保险(Info.plist 已声明 LSUIElement)
    app.run()
}
