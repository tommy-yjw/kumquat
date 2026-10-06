import AppKit
import AVKit
import SwiftUI

// MARK: - 编辑器请求与模式

enum EditorMode {
    case image      // 裁剪 / 涂黑 / 标注
    case trimVideo  // 视频剪短
}

struct EditorRequest {
    let urls: [URL]
    let mode: EditorMode
}

// MARK: - 工具与标注模型

enum DrawTool: String, CaseIterable, Identifiable {
    case crop, redact, arrow, rect, text

    var id: String { rawValue }
    var title: String {
        switch self {
        case .crop: return "裁剪"
        case .redact: return "涂黑"
        case .arrow: return "箭头"
        case .rect: return "方框"
        case .text: return "文字"
        }
    }
    var systemImage: String {
        switch self {
        case .crop: return "crop"
        case .redact: return "rectangle.fill"
        case .arrow: return "arrow.up.right"
        case .rect: return "rectangle"
        case .text: return "textformat"
        }
    }
}

/// 标注:from/to 为归一化坐标(y 向下,左上原点)。
struct EditorAnnotation: Identifiable {
    let id = UUID()
    let kind: DrawTool   // 仅 arrow / rect / text
    let from: CGPoint
    let to: CGPoint
    let text: String?
}

// MARK: - 编辑器模型

@MainActor
final class EditorModel: ObservableObject {
    let source: URL
    let image: CGImage?
    let videoURL: URL?

    @Published var tool: DrawTool = .crop
    @Published var cropRect: CGRect?            // 归一化(y 向下)
    @Published var redactions: [CGRect] = []
    @Published var annotations: [EditorAnnotation] = []
    @Published var liveFrom: CGPoint?
    @Published var liveTo: CGPoint?
    // 视频剪短
    @Published var duration: Double = 0
    @Published var trimStart: Double = 0
    @Published var trimEnd: Double = 0

    var aspect: CGFloat { CGFloat(image?.width ?? 16) / CGFloat(image?.height ?? 9) }

    private init(source: URL, image: CGImage?, videoURL: URL?) {
        self.source = source
        self.image = image
        self.videoURL = videoURL
    }

    /// 图片编辑器入口(读取失败返回 nil)。
    convenience init?(imageURL url: URL) {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, options),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        self.init(source: url, image: cgImage, videoURL: nil)
    }

    /// 视频剪短入口。
    convenience init(videoURL url: URL) {
        self.init(source: url, image: nil, videoURL: url)
    }

    // MARK: 手势换算

    func normalized(_ point: CGPoint, in size: CGSize) -> CGPoint {
        CGPoint(x: min(1, max(0, point.x / max(1, size.width))),
                y: min(1, max(0, point.y / max(1, size.height))))
    }

    func rect(from: CGPoint, to: CGPoint) -> CGRect {
        CGRect(x: min(from.x, to.x), y: min(from.y, to.y),
               width: abs(to.x - from.x), height: abs(to.y - from.y))
    }

    /// 当前拖拽是否够大(过小的框视为误触)。
    static func isSignificant(_ rect: CGRect) -> Bool {
        rect.width > 0.008 && rect.height > 0.008
    }

    // MARK: 导出(裁剪 + 涂黑 + 标注 → 副本)

    func exportImage() throws -> URL {
        guard let cgImage = image else {
            throw NSError(domain: "Kumquat.Editor", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "没有可导出的图像"])
        }
        let width = cgImage.width, height = cgImage.height
        let crop = pixelRect(cropRect ?? CGRect(x: 0, y: 0, width: 1, height: 1),
                             in: CGFloat(width), CGFloat(height))
        guard crop.width >= 8, crop.height >= 8 else {
            throw NSError(domain: "Kumquat.Editor", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "裁剪区域太小"])
        }

        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                         pixelsWide: Int(crop.width), pixelsHigh: Int(crop.height),
                                         bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0,
                                         bitsPerPixel: 0) else {
            throw NSError(domain: "Kumquat.Editor", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "无法创建画布"])
        }
        NSGraphicsContext.saveGraphicsState()
        let context = NSGraphicsContext(bitmapImageRep: rep)!
        NSGraphicsContext.current = context

        // 底图:原图的 crop 区域 → 画布(NSImage draw 的 from 是 y 向上坐标)
        let base = NSImage(cgImage: cgImage, size: NSSize(width: width, height: height))
        let sourceRect = NSRect(x: crop.minX,
                                y: CGFloat(height) - crop.maxY,
                                width: crop.width, height: crop.height)
        base.draw(in: NSRect(origin: .zero, size: crop.size),
                  from: sourceRect, operation: .copy, fraction: 1.0)

        // 归一化(y 向下) → 画布本地坐标(y 向上)
        func local(_ normalized: CGRect) -> NSRect {
            let pixel = pixelRect(normalized, in: CGFloat(width), CGFloat(height))
            return NSRect(x: pixel.minX - crop.minX,
                          y: crop.height - (pixel.maxY - crop.minY),
                          width: pixel.width, height: pixel.height)
        }
        func localPoint(_ normalized: CGPoint) -> NSPoint {
            let pixel = CGPoint(x: normalized.x * CGFloat(width), y: normalized.y * CGFloat(height))
            return NSPoint(x: pixel.x - crop.minX, y: crop.height - (pixel.y - crop.minY))
        }

        // 涂黑:永久像素级
        NSColor.black.setFill()
        for redaction in redactions {
            local(redaction).fill()
        }

        // 标注
        let fontSize = max(16, CGFloat(width) * 0.022)
        for annotation in annotations {
            switch annotation.kind {
            case .arrow:
                let from = localPoint(annotation.from), to = localPoint(annotation.to)
                let path = NSBezierPath()
                path.move(to: from)
                path.line(to: to)
                path.lineWidth = max(2.5, fontSize * 0.12)
                NSColor.red.setStroke()
                path.stroke()
                // 箭头头部:两条短线
                let angle = Foundation.atan2(to.y - from.y, to.x - from.x)
                let headLength = max(10, fontSize * 0.5)
                for spread in [CGFloat.pi * 0.82, -CGFloat.pi * 0.82] {
                    let tip = NSPoint(x: to.x + Foundation.cos(angle + spread) * headLength,
                                      y: to.y + Foundation.sin(angle + spread) * headLength)
                    let head = NSBezierPath()
                    head.move(to: to)
                    head.line(to: tip)
                    head.lineWidth = path.lineWidth
                    head.stroke()
                }
            case .rect:
                let path = NSBezierPath(rect: local(self.rect(from: annotation.from, to: annotation.to)).insetBy(dx: 1, dy: 1))
                path.lineWidth = max(2.5, fontSize * 0.12)
                NSColor.red.setStroke()
                path.stroke()
            case .text:
                guard let text = annotation.text, !text.isEmpty else { continue }
                let paragraph = NSMutableParagraphStyle()
                paragraph.lineBreakMode = .byWordWrapping
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: fontSize, weight: .semibold),
                    .foregroundColor: NSColor.red,
                    .strokeWidth: -2.0, // 描边增强可读性
                    .strokeColor: NSColor.white,
                    .paragraphStyle: paragraph,
                ]
                let string = NSAttributedString(string: text, attributes: attributes)
                let bounds = string.boundingRect(with: NSSize(width: CGFloat(width), height: .greatestFiniteMagnitude),
                                                 options: [.usesLineFragmentOrigin])
                let origin = localPoint(annotation.from)
                let drawRect = NSRect(x: min(origin.x, crop.width - bounds.width - 4),
                                      y: min(origin.y, crop.height - bounds.height - 4),
                                      width: bounds.width, height: bounds.height)
                string.draw(in: drawRect)
            default:
                continue
            }
        }
        NSGraphicsContext.restoreGraphicsState()

        // 写出:原为无损格式(png/gif/bmp)→ png;否则 jpeg q0.92
        let losslessExtensions: Set<String> = ["png", "gif", "bmp", "tif", "tiff"]
        let outputExtension = losslessExtensions.contains(source.pathExtension.lowercased()) ? "png" : "jpg"
        let outputType: NSBitmapImageRep.FileType = outputExtension == "png" ? .png : .jpeg
        let properties: [NSBitmapImageRep.PropertyKey: Any] = outputExtension == "png"
            ? [:]
            : [.compressionFactor: 0.92]
        guard let data = rep.representation(using: outputType, properties: properties) else {
            throw NSError(domain: "Kumquat.Editor", code: 4,
                          userInfo: [NSLocalizedDescriptionKey: "编码失败"])
        }
        let output = OutputNamer.uniqueOutput(for: source, suffix: "编辑", fileExtension: outputExtension)
        try data.write(to: output)
        return output
    }

    private func imageSourceRect() -> CGRect? { image == nil ? nil : .zero }
}

/// 归一化矩形(y 向下) → 像素矩形。
private func pixelRect(_ normalized: CGRect, in width: CGFloat, _ height: CGFloat) -> CGRect {
    CGRect(x: normalized.minX * width, y: normalized.minY * height,
           width: normalized.width * width, height: normalized.height * height)
}

// MARK: - 编辑器窗口控制器

@MainActor
final class EditorController {
    static let shared = EditorController()
    private var window: NSWindow?

    func show(_ request: EditorRequest,
              onRun: @escaping (ActionKind, [URL]) -> Void) {
        close()
        guard let url = request.urls.first else { return }
        let model: EditorModel?
        switch request.mode {
        case .image: model = EditorModel(imageURL: url)
        case .trimVideo: model = EditorModel(videoURL: url)
        }
        guard let model else {
            Notifier.shared.post(title: "金桔", body: "无法读取文件:\(url.lastPathComponent)")
            return
        }

        let root = EditorRootView(
            model: model,
            onCancel: { [weak self] in self?.close() },
            onApplyImage: { [weak self] in
                guard let self else { return }
                do {
                    let output = try model.exportImage()
                    Notifier.shared.post(title: "金桔 · 编辑完成",
                                         body: output.lastPathComponent, reveal: output)
                    self.close()
                } catch {
                    Notifier.shared.post(title: "金桔 · 编辑失败",
                                         body: error.localizedDescription)
                }
            },
            onApplyTrim: { [weak self] start, end in
                onRun(.trimVideo(start, end), [url])
                self?.close()
            })

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 720),
                              styleMask: [.titled, .closable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "金桔编辑器 — \(url.lastPathComponent)"
        window.contentView = NSHostingView(rootView: root)
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.isReleasedWhenClosed = false
        self.window = window
    }

    func close() {
        window?.orderOut(nil)
        window = nil
    }
}

// MARK: - 根视图

struct EditorRootView: View {
    @ObservedObject var model: EditorModel
    let onCancel: () -> Void
    let onApplyImage: () -> Void
    let onApplyTrim: (Double, Double) -> Void

    var body: some View {
        VStack(spacing: 0) {
            switch model.videoURL {
            case .some(let url):
                TrimEditorView(model: model, url: url,
                               onApply: { onApplyTrim(model.trimStart, model.trimEnd) },
                               onCancel: onCancel)
            case .none:
                ImageEditorView(model: model, onApply: onApplyImage, onCancel: onCancel)
            }
        }
        .frame(minWidth: 720, minHeight: 540)
    }
}

// MARK: - 图片编辑

private struct ImageEditorView: View {
    @ObservedObject var model: EditorModel
    let onApply: () -> Void
    let onCancel: () -> Void
    @State private var needsText = false

    var body: some View {
        VStack(spacing: 0) {
            // 工具条
            HStack(spacing: 10) {
                Picker("工具", selection: $model.tool) {
                    ForEach(DrawTool.allCases) { tool in
                        Label(tool.title, systemImage: tool.systemImage).tag(tool)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 430)

                Button("撤销一步") { model.undoLast() }
                    .disabled(model.annotations.isEmpty && model.redactions.isEmpty && model.cropRect == nil)
                Spacer()
                Button("取消") { onCancel() }
                Button("应用并保存") { onApply() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider()

            // 画布
            Color.clear
                .aspectRatio(model.aspect, contentMode: .fit)
                .overlay(
                    Image(decorative: model.image!, scale: 1)
                        .resizable()
                        .scaledToFill()
                )
                .overlay(CanvasOverlay(model: model, requestText: requestText))
                .padding(12)

            Text(model.hint)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .padding(.bottom, 8)
        }
    }

    private func requestText(_ completion: @escaping (String?) -> Void) {
        let alert = NSAlert()
        alert.messageText = "标注文字"
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        alert.accessoryView = input
        alert.addButton(withTitle: "好")
        alert.addButton(withTitle: "取消")
        alert.window.initialFirstResponder = input
        let response = alert.runModal()
        completion(response == .alertFirstButtonReturn ? input.stringValue : nil)
    }
}

extension EditorModel {
    var hint: String {
        switch tool {
        case .crop: return "拖出裁剪区域,松手生效;“应用并保存”时才真正裁剪"
        case .redact: return "拖出矩形,松手即涂黑(导出时永久像素级涂黑,不可恢复)"
        case .arrow: return "拖出箭头(从起点指向终点)"
        case .rect: return "拖出方框标注"
        case .text: return "点击位置输入文字"
        }
    }

    func undoLast() {
        if let last = annotations.popLast() { _ = last }
        else if !redactions.isEmpty { redactions.removeLast() }
        else if cropRect != nil { cropRect = nil }
        isDirtyCleanup()
    }

    private func isDirtyCleanup() {}
}

/// 画布覆盖层:标注渲染 + 手势。
private struct CanvasOverlay: View {
    @ObservedObject var model: EditorModel
    let requestText: (@escaping (String?) -> Void) -> Void

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            ZStack {
                // 兜底填充:没有此层时 ZStack 随内容收缩为零尺寸,
                // 手势命中区不存在——第一次拖画永远无法开始(已实测)。
                Color.clear

                // 已提交的涂黑
                ForEach(Array(model.redactions.enumerated()), id: \.offset) { _, rect in
                    Rectangle()
                        .fill(Color.black.opacity(0.92))
                        .frame(width: rect.width * size.width, height: rect.height * size.height)
                        .position(x: (rect.midX) * size.width, y: (rect.midY) * size.height)
                }
                // 已提交的标注
                ForEach(model.annotations) { annotation in
                    annotationView(annotation, size: size)
                }
                // 拖拽中的预览
                if let from = model.liveFrom, let to = model.liveTo {
                    liveView(tool: model.tool, from: from, to: to, size: size)
                }
                // 裁剪框
                if let crop = model.cropRect {
                    Rectangle()
                        .strokeBorder(Color.white, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                        .background(Color.white.opacity(0.06))
                        .frame(width: crop.width * size.width, height: crop.height * size.height)
                        .position(x: crop.midX * size.width, y: crop.midY * size.height)
                        .shadow(color: .black.opacity(0.6), radius: 1)
                }
            }
            .contentShape(Rectangle())
            .gesture(dragGesture(size: size))
        }
    }

    @ViewBuilder
    private func annotationView(_ annotation: EditorAnnotation, size: CGSize) -> some View {
        switch annotation.kind {
        case .arrow:
            ArrowShape(from: annotation.from, to: annotation.to)
                .stroke(Color.red, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .shadow(color: .black.opacity(0.35), radius: 1)
        case .rect:
            Rectangle()
                .stroke(Color.red, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .frame(width: abs(annotation.to.x - annotation.from.x) * size.width,
                       height: abs(annotation.to.y - annotation.from.y) * size.height)
                .position(x: (annotation.from.x + annotation.to.x) / 2 * size.width,
                          y: (annotation.from.y + annotation.to.y) / 2 * size.height)
                .shadow(color: .black.opacity(0.35), radius: 1)
        case .text:
            Text(annotation.text ?? "")
                .font(.system(size: max(12, size.width * 0.022), weight: .semibold))
                .foregroundStyle(.red)
                .shadow(color: .white.opacity(0.9), radius: 2)
                .position(x: annotation.from.x * size.width, y: annotation.from.y * size.height)
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private func liveView(tool: DrawTool, from: CGPoint, to: CGPoint, size: CGSize) -> some View {
        let rect = model.rect(from: from, to: to)
        switch tool {
        case .crop:
            Rectangle()
                .strokeBorder(Color.white, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                .background(Color.white.opacity(0.06))
                .frame(width: rect.width * size.width, height: rect.height * size.height)
                .position(x: rect.midX * size.width, y: rect.midY * size.height)
                .shadow(color: .black.opacity(0.6), radius: 1)
        case .redact:
            Rectangle()
                .fill(Color.black.opacity(0.75))
                .frame(width: rect.width * size.width, height: rect.height * size.height)
                .position(x: rect.midX * size.width, y: rect.midY * size.height)
        case .arrow:
            ArrowShape(from: from, to: to)
                .stroke(Color.red.opacity(0.85), style: StrokeStyle(lineWidth: 3, lineCap: .round))
        case .rect:
            Rectangle()
                .stroke(Color.red.opacity(0.85), lineWidth: 3)
                .frame(width: rect.width * size.width, height: rect.height * size.height)
                .position(x: rect.midX * size.width, y: rect.midY * size.height)
        case .text:
            Crosshair(position: CGPoint(x: from.x * size.width, y: from.y * size.height))
        }
    }

    private func dragGesture(size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let from = model.normalized(value.startLocation, in: size)
                let to = model.normalized(value.location, in: size)
                model.liveFrom = from
                model.liveTo = to
            }
            .onEnded { value in
                let from = model.normalized(value.startLocation, in: size)
                let to = model.normalized(value.location, in: size)
                model.liveFrom = nil
                model.liveTo = nil
                let rect = model.rect(from: from, to: to)
                switch model.tool {
                case .crop:
                    if Self.isSignificant(rect) { model.cropRect = rect }
                    else { model.cropRect = nil }
                case .redact:
                    if Self.isSignificant(rect) { model.redactions.append(rect) }
                case .arrow, .rect:
                    if Self.isSignificant(rect) {
                        model.annotations.append(EditorAnnotation(kind: model.tool, from: from, to: to, text: nil))
                    }
                case .text:
                    requestText { text in
                        guard let text, !text.isEmpty else { return }
                        model.annotations.append(EditorAnnotation(kind: .text, from: from, to: to, text: text))
                    }
                }
            }
    }

    private static func isSignificant(_ rect: CGRect) -> Bool {
        rect.width > 0.008 && rect.height > 0.008
    }
}

/// 箭头形状(从 from 指向 to,归一化坐标)。
struct ArrowShape: Shape {
    let from: CGPoint
    let to: CGPoint

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let start = CGPoint(x: from.x * rect.width, y: from.y * rect.height)
        let end = CGPoint(x: to.x * rect.width, y: to.y * rect.height)
        path.move(to: start)
        path.addLine(to: end)
        let angle = Foundation.atan2(end.y - start.y, end.x - start.x)
        let headLength = max(12, rect.width * 0.02)
        for spread in [CGFloat.pi * 0.82, -CGFloat.pi * 0.82] {
            let tip = CGPoint(x: end.x + Foundation.cos(angle + spread) * headLength,
                              y: end.y + Foundation.sin(angle + spread) * headLength)
            path.move(to: end)
            path.addLine(to: tip)
        }
        return path
    }
}

/// 文字工具的定位十字准星。
private struct Crosshair: View {
    let position: CGPoint
    var body: some View {
        ZStack {
            Circle().strokeBorder(Color.red, lineWidth: 1.5).frame(width: 18, height: 18)
            Circle().fill(Color.red).frame(width: 3, height: 3)
        }
        .position(position)
    }
}

// MARK: - 视频剪短

private struct TrimEditorView: View {
    @ObservedObject var model: EditorModel
    let url: URL
    let onApply: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            PlayerSurface(url: url)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 14)
                .padding(.top, 12)

            VStack(spacing: 6) {
                HStack {
                    Text("起点 \(Self.timeString(model.trimStart))")
                        .monospacedDigit()
                    Spacer()
                    Text("时长 \(Self.timeString(max(0, model.trimEnd - model.trimStart)))")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("终点 \(Self.timeString(model.trimEnd))")
                        .monospacedDigit()
                }
                .font(.system(size: 12, weight: .medium))

                Slider(value: $model.trimStart,
                       in: 0...max(0.1, model.trimEnd - 0.5))
                Slider(value: $model.trimEnd,
                       in: min(model.duration, model.trimStart + 0.5)...max(model.trimStart + 0.6, model.duration))
                    .disabled(model.duration <= 0)
            }
            .padding(.horizontal, 18)

            HStack {
                Button("取消") { onCancel() }
                Spacer()
                Button("应用剪短") { onApply() }
                    .disabled(model.duration <= 0 || model.trimEnd - model.trimStart < 0.5)
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 12)
        }
        .task {
            let asset = AVURLAsset(url: url)
            if let seconds = try? await asset.load(.duration).seconds {
                model.duration = seconds
                model.trimEnd = seconds
            }
        }
    }

    static func timeString(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "--:--" }
        let total = Int(seconds.rounded())
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}

/// AVPlayerView 封装(系统播放控件,免自建预览)。
private struct PlayerSurface: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = AVPlayer(url: url)
        view.controlsStyle = .floating
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {}
}
