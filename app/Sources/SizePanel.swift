import AppKit
import SwiftUI

/// 压缩到指定大小面板:预设 + 自定义 MB。
@MainActor
final class SizePanelController {
    static let shared = SizePanelController()
    private var window: NSWindow?

    func show(files: [URL], onRun: @escaping (ActionKind, [URL]) -> Void) {
        close()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 200),
                              styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        window.title = "压到指定大小"
        window.contentView = NSHostingView(rootView: SizePanelView(
            files: files,
            onApply: { [weak self] megabytes in
                let bytes = Int((megabytes * 1_048_576).rounded())
                onRun(.compressToSize(bytes), files)
                self?.close()
            },
            onCancel: { [weak self] in self?.close() }
        ))
        window.center()
        window.isReleasedWhenClosed = false
        self.window = window
        window.makeKeyAndOrderFront(nil)
    }

    func close() {
        window?.orderOut(nil)
        window = nil
    }
}

private struct SizePanelView: View {
    let files: [URL]
    let onApply: (Double) -> Void
    let onCancel: () -> Void

    @State private var megabytesText = "2"

    private let presets = [0.5, 1, 2, 5, 10]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("目标大小(MB)")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                ForEach(presets, id: \.self) { size in
                    Button(size < 1 ? String(format: "%.1f", size) : String(Int(size))) {
                        megabytesText = size < 1 ? String(format: "%.1f", size) : String(Int(size))
                    }
                    .controlSize(.small)
                }
                TextField("自定义", text: $megabytesText)
                    .frame(width: 70)
                    .textFieldStyle(.roundedBorder)
            }
            Text("图片:JPEG 质量二分 + 自动降采样;视频:按时长换算码率(音频 128k)。")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
            HStack {
                Button("取消") { onCancel() }
                Spacer()
                Button("开始压缩") {
                    if let megabytes = Double(megabytesText), megabytes > 0.05 {
                        onApply(megabytes)
                    }
                }
                .keyboardShortcut(.return, modifiers: .command)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
        .frame(width: 420, alignment: .leading)
    }
}
