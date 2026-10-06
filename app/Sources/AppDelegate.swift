import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private var bubblePanel: BubblePanel?
    private let bubbleModel = BubbleModel()
    private let radialController = RadialMenuController()
    private let runner = JobRunner()
    private let jobList = JobListModel()
    private var progressController: ProgressPanelController?
    private var shiftDrag: ShiftDragController?
    private var activeJobCount = 0
    private var statusFlashTask: Task<Void, Never>?

    // MARK: 生命周期

    nonisolated func applicationWillFinishLaunching(_ notification: Notification) {
        // delegate 必须在 app 完成启动前就位
        Notifier.shared.install()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 自测模式:引擎测试跑在 App 宿主内(与生产一致),不装 UI
        if ProcessInfo.processInfo.environment["KUMQUAT_SELF_TEST"] == "1" {
            Task { await SelfTest.run() }
            return
        }
        setupStatusItem()
        setupBubblePanel()
        setupShiftDrag()
        progressController = ProgressPanelController(model: jobList)

        // 调试/验证钩子:KUMQUAT_PREVIEW_MENU=1 启动后 0.8s 用样例图弹出径向菜单
        if ProcessInfo.processInfo.environment["KUMQUAT_PREVIEW_MENU"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                self?.showPreviewMenu()
            }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        radialController.dismiss()
        shiftDrag?.dismiss()
        return .terminateNow
    }

    // MARK: 组装

    private func setupBubblePanel() {
        let panel = BubblePanel(model: bubbleModel,
                                onFilesDropped: { [weak self] urls in
                                    self?.handleDroppedFiles(urls)
                                },
                                onContextMenu: { [weak self] event in
                                    self?.showContextMenu()
                                })
        panel.placeAtDefaultPosition()
        panel.orderFront(nil)
        panel.applyPersistedVisibility()
        bubblePanel = panel
    }

    private func setupShiftDrag() {
        let controller = ShiftDragController(
            onBuildActions: { [weak self] files in
                self?.buildActions(for: files) ?? []
            },
            onRun: { [weak self] kind, files in
                self?.startJob(kind: kind, files: files)
            })
        controller.radialIdleQuery = { [weak self] in !(self?.radialController.isShowing ?? false) }
        controller.start()
        shiftDrag = controller
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.title = "🍊"
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
    }

    /// 菜单每次展开时重建,ffmpeg/手势状态保持新鲜。
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let ffmpeg = FFmpegEngine.detect()
        if ffmpeg != nil {
            let item = NSMenuItem(title: "ffmpeg:已就绪", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        } else {
            let item = NSMenuItem(title: "ffmpeg:未安装(视频/音频动作已隐藏)",
                                  action: #selector(openFFmpegGuide), keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        if let pandoc = PandocEngine.detect() {
            let item = NSMenuItem(title: "pandoc:已就绪(\(pandoc.path))", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        } else {
            let item = NSMenuItem(title: "pandoc:未安装(文档转换受限,brew install pandoc)",
                                  action: #selector(openPandocGuide), keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let shiftTitle = (shiftDrag?.isEnabled ?? true) ? "关闭 Shift 拖拽手势" : "开启 Shift 拖拽手势"
        let shiftItem = NSMenuItem(title: shiftTitle,
                                   action: #selector(toggleShiftGesture), keyEquivalent: "g")
        shiftItem.target = self
        menu.addItem(shiftItem)
        let toggle = NSMenuItem(title: "显示 / 隐藏投递气泡",
                                action: #selector(toggleBubble), keyEquivalent: "b")
        toggle.target = self
        menu.addItem(toggle)
        let settings = NSMenuItem(title: "设置…",
                                  action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "退出金桔",
                                action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    // MARK: 动作目录

    private func buildActions(for files: [URL]) -> [MenuAction] {
        ActionCatalog.actions(
            for: files,
            onRun: { [weak self] kind, runFiles in self?.startJob(kind: kind, files: runFiles) },
            onTools: { [weak self] toolFiles in self?.showToolWheel(for: toolFiles) },
            onEdit: { [weak self] request in self?.openEditor(request) }
        )
    }

    private func openEditor(_ request: EditorRequest) {
        EditorController.shared.show(request, onRun: { [weak self] kind, files in
            self?.startJob(kind: kind, files: files)
        })
    }

    // MARK: 拖入 → 菜单

    private func handleDroppedFiles(_ urls: [URL]) {
        guard let panel = bubblePanel else { return }
        let actions = buildActions(for: urls)
        guard !actions.isEmpty else {
            bubbleModel.flashRejected()
            if urls.contains(where: ActionCatalog.isSupportedMedia) {
                Notifier.shared.post(title: "金桔",
                                     body: "未检测到 ffmpeg,视频/音频动作不可用。可执行:brew install ffmpeg")
            } else {
                Notifier.shared.post(title: "金桔",
                                     body: "不支持的文件类型:支持图片(jpg/png/heic/tiff 互转、压缩、去EXIF、旋转、缩放、灰度、拼贴)、PDF、常见文档、归档;音视频需安装 ffmpeg")
            }
            return
        }
        radialController.show(files: urls, actions: actions, anchoredTo: panel.frame)
    }

    private func showToolWheel(for files: [URL]) {
        guard let panel = bubblePanel else { return }
        let tools = ActionCatalog.toolActions(
            for: files,
            onRun: { [weak self] kind, runFiles in self?.startJob(kind: kind, files: runFiles) })
        guard !tools.isEmpty else {
            Notifier.shared.post(title: "金桔", body: "这类文件没有可用的工具动作")
            return
        }
        radialController.show(files: files, actions: tools, anchoredTo: panel.frame)
    }

    /// 预览/验证用:不经过真实拖拽,直接用一张样例图弹出径向菜单。
    private func showPreviewMenu() {
        guard let panel = bubblePanel else { return }
        let sample = URL(fileURLWithPath: "/System/Library/Desktop Pictures/Mac Blue.heic")
        let actions = buildActions(for: [sample])
        guard !actions.isEmpty else { return }
        radialController.show(files: [sample], actions: actions, anchoredTo: panel.frame)
    }

    // MARK: 执行与汇报

    private func startJob(kind: ActionKind, files: [URL]) {
        let row = jobList.add(title: Self.jobTitle(kind: kind, files: files))
        if files.count > 1 { row.detail = "\(files.count) 个文件" }
        activeJobCount += 1
        progressController?.show()

        let runner = self.runner
        let token = row.cancelToken
        Task.detached(priority: .userInitiated) {
            let outcomes = await runner.run(kind: kind, files: files, cancel: token)
            await MainActor.run {
                self.finishJob(row: row, outcomes: outcomes)
            }
        }
    }

    private func finishJob(row: JobRow, outcomes: [JobOutcome]) {
        activeJobCount = max(0, activeJobCount - 1)

        let cancelledText = KumquatCancelled.user.description
        let failures = outcomes.filter { !$0.skipped && $0.errorText != nil }
        let allCancelled = !outcomes.isEmpty && outcomes.allSatisfy { $0.errorText == cancelledText || $0.skipped }

        if allCancelled {
            row.status = .cancelled
            row.detail = "已取消"
        } else if !failures.isEmpty {
            row.status = .failed
            row.detail = failures.prefix(1)
                .map { "\($0.source.lastPathComponent): \($0.errorText ?? "")" }
                .joined()
        } else {
            row.status = .done
            let outputs = outcomes.compactMap(\.output)
            row.detail = outputs.isEmpty ? "无输出" : outputs.prefix(3).map(\.lastPathComponent).joined(separator: "、")
        }

        if activeJobCount == 0 {
            progressController?.hideAfter(seconds: 2.5)
        }
        if outcomes.contains(where: \.succeeded) {
            flashStatusItem()
        }
        reportOutcomes(outcomes)
    }

    private func reportOutcomes(_ outcomes: [JobOutcome]) {
        let succeeded = outcomes.filter(\.succeeded)
        let skipped = outcomes.filter(\.skipped)
        let failed = outcomes.filter { !$0.skipped && $0.errorText != nil }

        var parts: [String] = []
        if !succeeded.isEmpty { parts.append("\(succeeded.count) 个成功") }
        if !skipped.isEmpty { parts.append("\(skipped.count) 个跳过") }
        if !failed.isEmpty { parts.append("\(failed.count) 个失败") }
        guard !parts.isEmpty else { return }

        if !failed.isEmpty {
            let detail = failed.prefix(2)
                .map { "\($0.source.lastPathComponent): \($0.errorText ?? "")" }
                .joined(separator:";")
            Notifier.shared.post(title: "金桔 · \(parts.joined(separator:","))",
                                 body: detail,
                                 reveal: succeeded.first?.output)
        } else {
            let outputs = succeeded.compactMap(\.output)
            let names = outputs.prefix(3).map(\.lastPathComponent).joined(separator: "、")
            Notifier.shared.post(title: "金桔 · 完成",
                                 body: "\(parts.joined(separator: ", "))\n\(names)",
                                 reveal: outputs.first)
        }
    }

    /// 进度窗/通知里的任务标题。
    private static func jobTitle(kind: ActionKind, files: [URL]) -> String {
        let name = files.count == 1 ? files[0].lastPathComponent : "\(files.count) 个文件"
        let verb: String
        switch kind {
        case let .convertImage(format): verb = "转换 \(format.rawValue.uppercased())"
        case .convertImageWebP: verb = "转换 WebP"
        case .compressImage: verb = "压缩"
        case .stripExif: verb = "去 EXIF"
        case let .rotateImage(degrees): verb = degrees > 0 ? "顺时针旋转90°" : "逆时针旋转90°"
        case .flipImage: verb = "翻转"
        case let .scaleImageLongest(side): verb = "缩放 长边\(side)"
        case let .scaleImagePercent(percent): verb = "缩放 \(percent)%"
        case .grayscaleImage: verb = "灰度"
        case .collageImages: verb = "拼贴"
        case let .convertVideo(format): verb = "转换 \(format.rawValue.uppercased())"
        case let .convertAudio(format): verb = "转换 \(format.rawValue.uppercased())"
        case let .extractAudio(format): verb = "提取 \(format.rawValue.uppercased())"
        case let .speedVideo(factor): verb = "变速 \(factor)x"
        case .extractVideoFrame: verb = "抽帧"
        case .mergePDF: verb = "合并 PDF"
        case .splitPDF: verb = "拆分 PDF"
        case .compressPDF: verb = "压缩 PDF"
        case let .rotatePDF(degrees): verb = degrees > 0 ? "PDF 顺时针90°" : "PDF 逆时针90°"
        case .pdfToPNG: verb = "PDF 转图片"
        case .imagesToPDF: verb = "合成 PDF"
        case .createZip: verb = "压缩 ZIP"
        case .extractZip: verb = "解压 ZIP"
        case .extractTar: verb = "解压 tar"
        case let .convertDocPandoc(target): verb = "文档 → \(target.fileExtension.uppercased())"
        case let .convertDocTextUtil(format): verb = "文档 → \(format.uppercased())"
        case .convertOfficePDF: verb = "Office → PDF"
        case let .trimVideo(start, end): verb = String(format: "剪短 %.0f-%.0fs", start, end)
        }
        return "\(verb) · \(name)"
    }

    // MARK: 动作

    @objc private func toggleBubble() {
        bubblePanel?.toggleVisible()
    }

    @objc private func showSettings() {
        SettingsController.shared.show(onToggleBubble: { [weak self] in
            self?.bubblePanel?.setVisible(UserDefaults.standard.bool(forKey: BubblePanel.visibleDefaultsKey))
        })
    }

    /// 任务全部完成时菜单栏图标闪一下 ✅。
    private func flashStatusItem() {
        guard let button = statusItem?.button else { return }
        statusFlashTask?.cancel()
        button.title = "✅"
        statusFlashTask = Task { [weak button] in
            try? await Task.sleep(for: .seconds(1.2))
            guard !Task.isCancelled else { return }
            button?.title = "🍊"
        }
    }

    @objc private func toggleShiftGesture() {
        guard let shiftDrag else { return }
        shiftDrag.setEnabled(!shiftDrag.isEnabled)
        Notifier.shared.post(title: "金桔",
                             body: shiftDrag.isEnabled ? "Shift 拖拽手势已开启" : "Shift 拖拽手势已关闭")
    }

    @objc private func openFFmpegGuide() {
        if let url = URL(string: "https://formulae.brew.sh/formula/ffmpeg") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func openPandocGuide() {
        if let url = URL(string: "https://pandoc.org/installing") {
            NSWorkspace.shared.open(url)
        }
    }

    private func showContextMenu() {
        let menu = NSMenu()
        menuNeedsUpdate(menu)
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }
}
