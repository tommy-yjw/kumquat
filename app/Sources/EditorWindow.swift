import AppKit
import AVKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

// MARK: - 编辑器请求与模式

enum EditorMode {
    case image       // 裁剪 / 涂黑 / 标注
    case trimVideo   // 视频剪短
    case redactVideo // 视频涂黑
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

/// 标注:from/to 为归一化坐标(y 向下,左上原点);var 以支持画布内移动。
struct EditorAnnotation: Identifiable {
    let id = UUID()
    let kind: DrawTool   // 仅 arrow / rect / text
    var from: CGPoint
    var to: CGPoint
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
    @Published var redactions: [RedactionRect] = []
    @Published var redactStyle: RedactStyle = .solid
    @Published var selectedID: UUID?
    @Published var annotations: [EditorAnnotation] = []
    @Published var liveFrom: CGPoint?
    @Published var liveTo: CGPoint?
    // 视频剪短 / 涂黑
    @Published var duration: Double = 0
    @Published var trimStart: Double = 0
    @Published var trimEnd: Double = 0
    @Published var videoRedactions: [CGRect] = []   // 归一化(y 向下),实色整段涂黑
    @Published var videoSize: CGSize?               // 视频帧尺寸(letterbox 换算用)

    var aspect: CGFloat { CGFloat(image?.width ?? 16) / CGFloat(image?.height ?? 9) }

    /// 像素化预览的低清整图(降到 1/24)。
    lazy var pixelatedSource: CGImage? = {
        guard let image else { return nil }
        let smallWidth = max(2, image.width / 24)
        let smallHeight = max(2, image.height / 24)
        guard let context = CGContext(data: nil, width: smallWidth, height: smallHeight,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .low
        context.draw(image, in: CGRect(x: 0, y: 0, width: smallWidth, height: smallHeight))
        return context.makeImage()
    }()

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
        let composed = try ImageComposer.render(source: cgImage,
                                                crop: cropRect,
                                                redactions: redactions,
                                                annotations: annotations)

        // 写出:原为无损格式(png/gif/bmp)→ png;否则 jpeg q0.92
        let losslessExtensions: Set<String> = ["png", "gif", "bmp", "tif", "tiff"]
        let outputExtension = losslessExtensions.contains(source.pathExtension.lowercased()) ? "png" : "jpg"
        let output = OutputNamer.uniqueOutput(for: source, suffix: "编辑", fileExtension: outputExtension)
        let outputType: UTType = outputExtension == "png" ? .png : .jpeg
        guard let destination = CGImageDestinationCreateWithURL(output as CFURL,
                                                                outputType.identifier as CFString, 1, nil) else {
            throw NSError(domain: "Kumquat.Editor", code: 4,
                          userInfo: [NSLocalizedDescriptionKey: "无法写出 \(output.lastPathComponent)"])
        }
        var properties: [CFString: Any] = [:]
        if outputExtension == "jpg" {
            properties[kCGImageDestinationLossyCompressionQuality] = 0.92
        }
        CGImageDestinationAddImage(destination, composed, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw NSError(domain: "Kumquat.Editor", code: 5,
                          userInfo: [NSLocalizedDescriptionKey: "写出失败 \(output.lastPathComponent)"])
        }
        return output
    }
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
    private var keyMonitor: Any?

    func show(_ request: EditorRequest,
              onRun: @escaping (ActionKind, [URL]) -> Void) {
        close()
        guard let url = request.urls.first else { return }
        let model: EditorModel?
        switch request.mode {
        case .image: model = EditorModel(imageURL: url)
        case .trimVideo, .redactVideo: model = EditorModel(videoURL: url)
        }
        guard let model else {
            Notifier.shared.post(title: "金桔", body: "无法读取文件:\(url.lastPathComponent)")
            return
        }

        // 应用动作(按钮与 Cmd+S 共用)
        let applyAction: () -> Void = { [weak self] in
            switch request.mode {
            case .image:
                do {
                    let output = try model.exportImage()
                    Notifier.shared.post(title: "金桔 · 编辑完成",
                                         body: output.lastPathComponent, reveal: output)
                    self?.close()
                } catch {
                    Notifier.shared.post(title: "金桔 · 编辑失败",
                                         body: error.localizedDescription)
                }
            case .trimVideo:
                onRun(.trimVideo(model.trimStart, model.trimEnd), [url])
                self?.close()
            case .redactVideo:
                guard !model.videoRedactions.isEmpty else { return }
                onRun(.redactVideo(model.videoRedactions), [url])
                self?.close()
            }
        }

        let root = EditorRootView(
            model: model,
            onCancel: { [weak self] in self?.close() },
            onApplyImage: { applyAction() },
            onApplyTrim: { _, _ in applyAction() },
            onApplyRedact: { applyAction() })

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 720),
                              styleMask: [.titled, .closable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "金桔编辑器 — \(url.lastPathComponent)"
        window.contentView = NSHostingView(rootView: root)
        window.center()
        window.isReleasedWhenClosed = false
        self.window = window
        installKeyMonitor(model: model, applyAction: applyAction)
        window.makeKeyAndOrderFront(nil)
    }

    /// 编辑器键盘:Esc=关闭;Delete/Backspace=删除选中;Cmd+S=应用。
    private func installKeyMonitor(model: EditorModel, applyAction: @escaping () -> Void) {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let window = self.window, event.window === window else { return event }
            switch event.keyCode {
            case 53: // Esc
                self.close()
                return nil
            case 51: // Delete/Backspace
                if let selectedID = model.selectedID {
                    model.redactions.removeAll { $0.id == selectedID }
                    model.annotations.removeAll { $0.id == selectedID }
                    model.selectedID = nil
                    return nil
                }
            case 1 where event.modifierFlags.contains(.command): // Cmd+S
                applyAction()
                return nil
            default:
                break
            }
            return event
        }
    }

    func close() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
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
    var onApplyRedact: () -> Void = {}

    var body: some View {
        VStack(spacing: 0) {
            switch model.videoURL {
            case .some(let url):
                TrimEditorView(model: model, url: url,
                               onApply: { onApplyTrim(model.trimStart, model.trimEnd) },
                               onApplyRedact: onApplyRedact,
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
    @State private var zoom: CGFloat = 1
    private let zoomSteps: [CGFloat] = [1, 1.5, 2, 3, 4]

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

                if model.tool == .redact {
                    Picker("样式", selection: $model.redactStyle) {
                        ForEach(RedactStyle.allCases) { style in
                            Text(style.title).tag(style)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: 250)
                }

                Button("撤销一步") { model.undoLast() }
                    .disabled(model.annotations.isEmpty && model.redactions.isEmpty && model.cropRect == nil)
                Spacer()
                Button("−") { stepZoom(-1) }.controlSize(.small)
                Text("\(Int((zoom * 100).rounded()))%")
                    .monospacedDigit()
                    .font(.system(size: 10.5))
                    .frame(width: 40)
                Button("+") { stepZoom(1) }.controlSize(.small)
                Button("适应") {
                    withAnimation(.easeOut(duration: 0.15)) { zoom = 1 }
                }
                .controlSize(.small)
                Spacer()
                Button("取消") { onCancel() }
                Button("应用并保存") { onApply() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider()

            // 画布(缩放后可滚动;归一化坐标按缩放后尺寸换算,天然兼容)
            GeometryReader { outer in
                let availableWidth = outer.size.width - 24
                let availableHeight = outer.size.height - 24
                let fitWidth = min(availableWidth, availableHeight * model.aspect)
                let fitHeight = fitWidth / model.aspect
                ScrollView([.horizontal, .vertical]) {
                    canvas
                        .frame(width: fitWidth * zoom, height: fitHeight * zoom)
                        .frame(minWidth: availableWidth, minHeight: availableHeight)
                }
            }
            .padding(12)

            Text(model.hint)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .padding(.bottom, 8)
        }
    }

    @ViewBuilder
    private var canvas: some View {
        Color.clear
            .aspectRatio(model.aspect, contentMode: .fit)
            .overlay(
                Image(decorative: model.image!, scale: 1)
                    .resizable()
                    .scaledToFill()
            )
            .overlay(CanvasOverlay(model: model, requestText: requestText))
    }

    private func stepZoom(_ direction: Int) {
        let currentIndex = zoomSteps.firstIndex(of: zoom) ?? 0
        let next = max(0, min(zoomSteps.count - 1, currentIndex + direction))
        withAnimation(.easeOut(duration: 0.12)) { zoom = zoomSteps[next] }
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
        case .crop: return "空白拖=新框;框内拖=移动;边角拖=调整"
        case .redact: return "空白拖=新增「\(redactStyle.title)」;拖已有块=移动;轻点选中,再点=删除"
        case .arrow: return "空白拖=新箭头;拖已有=移动;轻点选中,再点=删除"
        case .rect: return "空白拖=新方框;拖已有=移动;轻点选中,再点=删除"
        case .text: return "空白点=输文字;拖已有=移动;轻点选中,再点=删除"
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

    /// 一次拖拽的语义:在起点命中判定后固定(画新 / 移动 / 调整)。
    private enum Operation {
        case draw
        case moveRedact(RedactionRect)
        case moveAnnotation(EditorAnnotation)
        case moveCrop(CGRect)
        case resizeCrop(CGRect, CropHandle)
    }

    private enum CropHandle { case nw, n, ne, e, se, s, sw, w }

    @State private var operation: Operation = .draw
    @State private var decisionMade = false
    @State private var lastTapID: UUID?
    @State private var lastTapAt = Date.distantPast

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            ZStack {
                // 兜底填充:没有此层时 ZStack 随内容收缩为零尺寸,
                // 手势命中区不存在——第一次拖画永远无法开始(已实测)。
                Color.clear

                // 已提交的涂黑(三样式)
                ForEach(model.redactions) { redaction in
                    RedactionPreviewView(redaction: redaction, size: size,
                                         source: model.image,
                                         pixelatedSource: model.pixelatedSource)
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
                // 选中描边(青色)
                if let selectedID = model.selectedID,
                   let frame = selectionFrame(selectedID, size: size) {
                    Rectangle()
                        .strokeBorder(Color.cyan, lineWidth: 1.5)
                        .background(Color.cyan.opacity(0.05))
                        .frame(width: frame.width * size.width, height: frame.height * size.height)
                        .position(x: frame.midX * size.width, y: frame.midY * size.height)
                }
                // 裁剪把手(仅裁剪工具)
                if model.tool == .crop, let crop = model.cropRect {
                    CropHandleView(crop: crop, size: size)
                }
            }
            .contentShape(Rectangle())
            .gesture(dragGesture(size: size))
        }
    }

    /// 选中元素的包围框(青色描边用)。
    private func selectionFrame(_ id: UUID, size: CGSize) -> CGRect? {
        if let redaction = model.redactions.first(where: { $0.id == id }) {
            return redaction.rect
        }
        if let annotation = model.annotations.first(where: { $0.id == id }) {
            return annotationBounds(annotation)
        }
        return nil
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
                .fill(Color.black.opacity(0.6))
                .overlay(Text(model.redactStyle.title)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white))
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
                let start = model.normalized(value.startLocation, in: size)
                let current = model.normalized(value.location, in: size)
                if !decisionMade {
                    decisionMade = true
                    operation = decideOperation(start: start, size: size)
                    if case .draw = operation {
                        model.selectedID = nil // 画新元素:清掉旧选中
                    }
                }
                let delta = CGSize(width: current.x - start.x, height: current.y - start.y)
                switch operation {
                case .draw:
                    model.liveFrom = start
                    model.liveTo = current
                case .moveRedact(let original):
                    if let index = model.redactions.firstIndex(where: { $0.id == original.id }) {
                        model.redactions[index].rect = offsetClamped(original.rect, by: delta)
                    }
                case .moveAnnotation(let original):
                    if let index = model.annotations.firstIndex(where: { $0.id == original.id }) {
                        let moved = offsetClamped(original, by: delta)
                        model.annotations[index].from = moved.from
                        model.annotations[index].to = moved.to
                    }
                case .moveCrop(let original):
                    model.cropRect = offsetClamped(original, by: delta)
                case .resizeCrop(let original, let handle):
                    model.cropRect = resized(original, handle: handle, to: current)
                }
            }
            .onEnded { value in
                defer {
                    decisionMade = false
                    operation = .draw
                    model.liveFrom = nil
                    model.liveTo = nil
                }
                let start = model.normalized(value.startLocation, in: size)
                let current = model.normalized(value.location, in: size)
                let rect = model.rect(from: start, to: current)
                let significant = Self.isSignificant(rect)

                switch operation {
                case .draw:
                    commitDraw(from: start, to: current, rect: rect,
                               significant: significant, size: size)
                case .moveRedact(let item):
                    guard !significant else { return }
                    handleTap(on: item.id, isRedaction: true)
                case .moveAnnotation(let item):
                    guard !significant else { return }
                    handleTap(on: item.id, isRedaction: false)
                case .moveCrop, .resizeCrop:
                    break
                }
            }
    }

    /// 轻点已选元素:第一次=选中,0.45s 内再点一次=删除。
    private func handleTap(on id: UUID, isRedaction: Bool) {
        if lastTapID == id, Date().timeIntervalSince(lastTapAt) < 0.45 {
            if isRedaction {
                model.redactions.removeAll { $0.id == id }
            } else {
                model.annotations.removeAll { $0.id == id }
            }
            model.selectedID = nil
            lastTapID = nil
        } else {
            model.selectedID = id
            lastTapID = id
            lastTapAt = Date()
        }
    }

    private func commitDraw(from: CGPoint, to: CGPoint, rect: CGRect,
                            significant: Bool, size: CGSize) {
        switch model.tool {
        case .crop:
            model.cropRect = significant ? rect : nil
        case .redact:
            guard significant else { return }
            let item = RedactionRect(rect: rect, style: model.redactStyle)
            model.redactions.append(item)
            model.selectedID = item.id
        case .arrow, .rect:
            guard significant else { return }
            let item = EditorAnnotation(kind: model.tool, from: from, to: to, text: nil)
            model.annotations.append(item)
            model.selectedID = item.id
        case .text:
            requestText { text in
                guard let text, !text.isEmpty else { return }
                let item = EditorAnnotation(kind: .text, from: from, to: to, text: text)
                model.annotations.append(item)
                model.selectedID = item.id
            }
        }
    }

    // MARK: 命中判定与操作路由

    private func decideOperation(start: CGPoint, size: CGSize) -> Operation {
        // 裁剪工具:先试把手,再试框内移动,空白处画新框
        if model.tool == .crop, let crop = model.cropRect {
            if let handle = cropHandle(at: start, crop: crop, size: size) {
                return .resizeCrop(crop, handle)
            }
            if expanded(crop, by: 4, size: size).contains(start) {
                return .moveCrop(crop)
            }
            return .draw
        }
        // 其他工具:已有元素优先(可拖动),空白处画新
        if let redaction = model.redactions.last(where: {
            expanded($0.rect, by: 4, size: size).contains(start)
        }) {
            return .moveRedact(redaction)
        }
        if let annotation = model.annotations.last(where: {
            expanded(annotationBounds($0), by: 4, size: size).contains(start)
        }) {
            return .moveAnnotation(annotation)
        }
        return .draw
    }

    private func expanded(_ rect: CGRect, by points: CGFloat, size: CGSize) -> CGRect {
        rect.insetBy(dx: -points / max(1, size.width), dy: -points / max(1, size.height))
    }

    private func cropHandle(at point: CGPoint, crop: CGRect, size: CGSize) -> CropHandle? {
        let toleranceX = 12.0 / max(1, size.width)
        let toleranceY = 12.0 / max(1, size.height)
        func near(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> Bool { abs(a - b) <= t }
        let corners: [(CropHandle, CGPoint)] = [
            (.nw, CGPoint(x: crop.minX, y: crop.minY)),
            (.ne, CGPoint(x: crop.maxX, y: crop.minY)),
            (.se, CGPoint(x: crop.maxX, y: crop.maxY)),
            (.sw, CGPoint(x: crop.minX, y: crop.maxY)),
        ]
        for (handle, corner) in corners where
            near(point.x, corner.x, toleranceX) && near(point.y, corner.y, toleranceY) {
            return handle
        }
        if near(point.y, crop.minY, toleranceY), point.x >= crop.minX, point.x <= crop.maxX { return .n }
        if near(point.y, crop.maxY, toleranceY), point.x >= crop.minX, point.x <= crop.maxX { return .s }
        if near(point.x, crop.minX, toleranceX), point.y >= crop.minY, point.y <= crop.maxY { return .w }
        if near(point.x, crop.maxX, toleranceX), point.y >= crop.minY, point.y <= crop.maxY { return .e }
        return nil
    }

    private func offsetClamped(_ rect: CGRect, by delta: CGSize) -> CGRect {
        var dx = delta.width, dy = delta.height
        if rect.minX + dx < 0 { dx = -rect.minX }
        if rect.maxX + dx > 1 { dx = 1 - rect.maxX }
        if rect.minY + dy < 0 { dy = -rect.minY }
        if rect.maxY + dy > 1 { dy = 1 - rect.maxY }
        return rect.offsetBy(dx: dx, dy: dy)
    }

    private func offsetClamped(_ annotation: EditorAnnotation, by delta: CGSize) -> EditorAnnotation {
        var moved = annotation
        var dx = delta.width, dy = delta.height
        let minX = min(annotation.from.x, annotation.to.x)
        let maxX = max(annotation.from.x, annotation.to.x)
        let minY = min(annotation.from.y, annotation.to.y)
        let maxY = max(annotation.from.y, annotation.to.y)
        if minX + dx < 0 { dx = -minX }
        if maxX + dx > 1 { dx = 1 - maxX }
        if minY + dy < 0 { dy = -minY }
        if maxY + dy > 1 { dy = 1 - maxY }
        moved.from.x += dx
        moved.from.y += dy
        moved.to.x += dx
        moved.to.y += dy
        return moved
    }

    private func resized(_ original: CGRect, handle: CropHandle, to current: CGPoint) -> CGRect {
        var minX = original.minX, minY = original.minY
        var maxX = original.maxX, maxY = original.maxY
        let minSize: CGFloat = 0.02
        switch handle {
        case .nw: minX = min(current.x, maxX - minSize); minY = min(current.y, maxY - minSize)
        case .n:  minY = min(current.y, maxY - minSize)
        case .ne: maxX = max(current.x, minX + minSize); minY = min(current.y, maxY - minSize)
        case .e:  maxX = max(current.x, minX + minSize)
        case .se: maxX = max(current.x, minX + minSize); maxY = max(current.y, minY + minSize)
        case .s:  maxY = max(current.y, minY + minSize)
        case .sw: minX = min(current.x, maxX - minSize); maxY = max(current.y, minY + minSize)
        case .w:  minX = min(current.x, maxX - minSize)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// 标注的包围框(命中判定与选中描边共用;文字按字数估宽)。
    private func annotationBounds(_ annotation: EditorAnnotation) -> CGRect {
        switch annotation.kind {
        case .arrow, .rect:
            return model.rect(from: annotation.from, to: annotation.to)
        case .text:
            let count = CGFloat(max(1, (annotation.text ?? "").count))
            return CGRect(x: annotation.from.x, y: annotation.from.y,
                          width: min(0.9, count * 0.016), height: 0.035)
        default:
            return .zero
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

/// 裁剪框的 8 个把手(白底黑边小方块)。
private struct CropHandleView: View {
    let crop: CGRect
    let size: CGSize

    var body: some View {
        ForEach(Array(handlePoints.enumerated()), id: \.offset) { _, point in
            Rectangle()
                .fill(Color.white)
                .frame(width: 9, height: 9)
                .overlay(Rectangle().strokeBorder(Color.black.opacity(0.5), lineWidth: 1))
                .position(x: point.x * size.width, y: point.y * size.height)
                .shadow(color: .black.opacity(0.5), radius: 1)
        }
    }

    private var handlePoints: [CGPoint] {
        [
            CGPoint(x: crop.minX, y: crop.minY),
            CGPoint(x: crop.midX, y: crop.minY),
            CGPoint(x: crop.maxX, y: crop.minY),
            CGPoint(x: crop.maxX, y: crop.midY),
            CGPoint(x: crop.maxX, y: crop.maxY),
            CGPoint(x: crop.midX, y: crop.maxY),
            CGPoint(x: crop.minX, y: crop.maxY),
            CGPoint(x: crop.minX, y: crop.midY),
        ]
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

/// 已提交涂黑区的三样式预览:实色=黑块;模糊=原区域实时高斯;像素化=低清源无插值铺放。
private struct RedactionPreviewView: View {
    let redaction: RedactionRect
    let size: CGSize
    let source: CGImage?
    let pixelatedSource: CGImage?

    private var frame: some View {
        Rectangle()
            .frame(width: redaction.rect.width * size.width,
                   height: redaction.rect.height * size.height)
            .position(x: redaction.rect.midX * size.width,
                      y: redaction.rect.midY * size.height)
    }

    var body: some View {
        switch redaction.style {
        case .solid:
            Rectangle()
                .fill(Color.black.opacity(0.92))
                .frame(width: redaction.rect.width * size.width,
                       height: redaction.rect.height * size.height)
                .position(x: redaction.rect.midX * size.width,
                          y: redaction.rect.midY * size.height)
        case .blur:
            Group {
                if let source {
                    Image(decorative: source, scale: 1)
                        .resizable()
                        .frame(width: size.width, height: size.height)
                        .clipped()
                        .blur(radius: 10)
                } else {
                    Rectangle().fill(Color.gray.opacity(0.6))
                }
            }
            .mask(frame)
        case .pixelate:
            Group {
                if let pixelatedSource {
                    Image(decorative: pixelatedSource, scale: 1)
                        .resizable()
                        .interpolation(.none)
                        .frame(width: size.width, height: size.height)
                        .clipped()
                } else {
                    Rectangle().fill(Color.gray.opacity(0.6))
                }
            }
            .mask(frame)
        }
    }
}

// MARK: - 视频剪短

private struct TrimEditorView: View {
    @ObservedObject var model: EditorModel
    let url: URL
    let onApply: () -> Void
    let onApplyRedact: () -> Void
    let onCancel: () -> Void

    @State private var redactMode = false
    @State private var liveRect: CGRect?

    var body: some View {
        VStack(spacing: 14) {
            // 播放器(+涂黑层)
            ZStack {
                PlayerSurface(url: url)

                // 视频显示区(letterbox 居中),涂黑框以视频帧为坐标系
                GeometryReader { geo in
                    let display = Self.displayRect(container: geo.size, videoSize: model.videoSize)
                    let scaleW = display.width / max(1, model.videoSize?.width ?? 1)
                    let scaleH = display.height / max(1, model.videoSize?.height ?? 1)

                    ZStack {
                        ForEach(Array(model.videoRedactions.enumerated()), id: \.offset) { _, rect in
                            Rectangle()
                                .fill(Color.black.opacity(0.92))
                                .frame(width: rect.width * scaleW, height: rect.height * scaleH)
                                .position(x: display.minX + rect.midX * scaleW,
                                          y: display.minY + rect.midY * scaleH)
                        }
                        if let live = liveRect {
                            Rectangle()
                                .fill(Color.black.opacity(0.55))
                                .frame(width: live.width * scaleW, height: live.height * scaleH)
                                .position(x: display.minX + live.midX * scaleW,
                                          y: display.minY + live.midY * scaleH)
                        }
                    }
                    .contentShape(Rectangle())
                    .gesture(redactGesture(display: display))
                    .opacity(redactMode ? 1 : 0)
                    .allowsHitTesting(redactMode)
                }
            }
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
            .opacity(redactMode ? 0.35 : 1)

            HStack {
                Button("取消") { onCancel() }
                Spacer()
                Toggle("涂黑模式", isOn: $redactMode)
                Button("撤销涂黑") { if !model.videoRedactions.isEmpty { model.videoRedactions.removeLast() } }
                    .disabled(model.videoRedactions.isEmpty || !redactMode)
                Button("应用涂黑") { onApplyRedact() }
                    .disabled(model.videoRedactions.isEmpty || !redactMode)
                    .buttonStyle(.bordered)
                Spacer()
                Button("应用剪短") { onApply() }
                    .disabled(model.duration <= 0 || model.trimEnd - model.trimStart < 0.5 || redactMode)
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 12)

            Text(redactMode
                 ? "涂黑模式:在视频画面上拖出矩形(整段生效),撤销逐个回退;关闭开关恢复剪短操作"
                 : "拖动滑块选剪短范围;打开涂黑模式标注要遮盖的区域")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .padding(.bottom, 8)
        }
        .task {
            let asset = AVURLAsset(url: url)
            if let seconds = try? await asset.load(.duration).seconds {
                model.duration = seconds
                model.trimEnd = seconds
            }
            if let track = try? await asset.loadTracks(withMediaType: .video).first,
               let size = try? await track.load(.naturalSize) {
                model.videoSize = size
            }
        }
    }

    /// AVPlayerView 内视频的 letterbox 显示区(y 向下,容器坐标)。
    private static func displayRect(container: CGSize, videoSize: CGSize?) -> CGRect {
        guard let videoSize, videoSize.width > 0, videoSize.height > 0,
              container.width > 0, container.height > 0 else {
            return CGRect(origin: .zero, size: container)
        }
        let scale = min(container.width / videoSize.width, container.height / videoSize.height)
        let width = videoSize.width * scale
        let height = videoSize.height * scale
        return CGRect(x: (container.width - width) / 2,
                      y: (container.height - height) / 2,
                      width: width, height: height)
    }

    private func redactGesture(display: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let start = normalized(value.startLocation, display: display)
                let current = normalized(value.location, display: display)
                liveRect = CGRect(x: min(start.x, current.x), y: min(start.y, current.y),
                                  width: abs(current.x - start.x), height: abs(current.y - start.y))
            }
            .onEnded { value in
                defer { liveRect = nil }
                let start = normalized(value.startLocation, display: display)
                let current = normalized(value.location, display: display)
                let rect = CGRect(x: min(start.x, current.x), y: min(start.y, current.y),
                                  width: abs(current.x - start.x), height: abs(current.y - start.y))
                if rect.width > 0.01, rect.height > 0.01 {
                    model.videoRedactions.append(rect)
                }
            }
    }

    private func normalized(_ point: CGPoint, display: CGRect) -> CGPoint {
        CGPoint(x: min(1, max(0, (point.x - display.minX) / max(1, display.width))),
                y: min(1, max(0, (point.y - display.minY) / max(1, display.height))))
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
