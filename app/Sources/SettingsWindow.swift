import AppKit
import SwiftUI

// MARK: - 设置窗口(正式设置入口:手势/气泡/引擎状态/关于)

@MainActor
final class SettingsController {
    static let shared = SettingsController()
    private var window: NSWindow?

    func show(onToggleBubble: @escaping () -> Void) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 340),
                              styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        window.title = "金桔设置"
        window.contentView = NSHostingView(rootView: SettingsView(
            onToggleBubble: onToggleBubble
        ))
        window.center()
        window.isReleasedWhenClosed = false
        self.window = window
        window.makeKeyAndOrderFront(nil)
    }
}

private struct EngineRow: View {
    let name: String
    let installed: Bool
    let hint: String
    let guideURL: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: installed ? "checkmark.circle.fill" : "xmark.circle")
                .foregroundStyle(installed ? Color.green : Color.secondary)
                .frame(width: 16)
            Text(name).font(.system(size: 12, weight: .medium))
            Spacer()
            Text(hint).font(.system(size: 10.5)).foregroundStyle(.secondary)
            if !installed, let url = URL(string: guideURL) {
                Button("安装页") { NSWorkspace.shared.open(url) }
                    .controlSize(.mini)
            }
        }
    }
}

private struct SettingsView: View {
    @AppStorage(ShiftDragController.enabledDefaultsKey) private var shiftGestureEnabled = true
    @AppStorage(BubblePanel.visibleDefaultsKey) private var bubbleVisible = true
    let onToggleBubble: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("交互")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Toggle("拖拽时按 Shift 弹出投放轮盘", isOn: $shiftGestureEnabled)
            Toggle("显示投递气泡", isOn: $bubbleVisible)
                .onChange(of: bubbleVisible) { _ in onToggleBubble() }

            Divider()
            Text("转换引擎")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            EngineRow(name: "ffmpeg(视频/音频)", installed: FFmpegEngine.detect() != nil,
                      hint: "mov/mp4/mkv/gif、mp3/m4a…",
                      guideURL: "https://formulae.brew.sh/formula/ffmpeg")
            EngineRow(name: "pandoc(文档互转)", installed: PandocEngine.detect() != nil,
                      hint: "md/docx/epub/html…",
                      guideURL: "https://pandoc.org/installing")
            EngineRow(name: "LibreOffice(Office→PDF)", installed: OfficeEngine.detect() != nil,
                      hint: "docx/xlsx/pptx→PDF",
                      guideURL: "https://www.libreoffice.org/download")

            Divider()
            HStack {
                Text("关于").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
                Text("金桔 Kumquat v\(version) · 纯本地 · 灵感来自 Tangerine 的开源复刻")
                    .font(.system(size: 10.5)).foregroundStyle(.secondary)
            }
        }
        .padding(18)
        .frame(width: 440, alignment: .leading)
    }
}
