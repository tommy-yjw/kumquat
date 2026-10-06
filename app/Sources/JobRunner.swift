import Foundation

// MARK: - 动作与结果模型

/// 一次菜单动作的种类,决定逐文件的执行路径与输出命名。
enum ActionKind {
    // 图片(sips / ImageIO,始终可用)
    case convertImage(ImageFormat)
    case convertImageWebP
    case compressImage
    case stripExif
    case rotateImage(Int)          // ±90,正值顺时针
    case flipImage(String)         // "horizontal" / "vertical"
    case scaleImageLongest(Int)    // 长边压到 N px
    case scaleImagePercent(Int)    // 等比缩放百分比
    case grayscaleImage
    case collageImages             // 多图拼贴

    // 视频/音频(仅检测到 ffmpeg 才出现)
    case convertVideo(VideoFormat)
    case convertAudio(AudioFormat)
    case extractAudio(AudioFormat)
    case speedVideo(Double)        // 0.5 / 1.5 / 2
    case extractVideoFrame         // 1s 处抽帧为 PNG

    // PDF(PDFKit + CoreGraphics,始终可用)
    case mergePDF
    case splitPDF
    case compressPDF               // 位图化 150dpi 有损压缩
    case rotatePDF(Int)            // ±90
    case pdfToPNG                  // 每页一张 2× PNG
    case imagesToPDF               // 图片合成 PDF

    // 归档(系统 ditto / tar,始终可用)
    case createZip
    case extractZip
    case extractTar

    // 文档(pandoc 条件启用;textutil 兜底 .doc)
    case convertDocPandoc(PandocTarget)
    case convertDocTextUtil(String) // textutil 目标格式:docx/rtf/html/txt
    case convertOfficePDF           // docx/xlsx/pptx 等 → PDF(LibreOffice 无头)
    case trimVideo(Double, Double)  // 剪短:起止秒(编辑器窗口发起)
}

struct JobOutcome {
    let source: URL
    var output: URL?
    var skipped = false
    var errorText: String?

    var succeeded: Bool { errorText == nil && !skipped && output != nil }
}

// MARK: - 输出命名(Tangerine 式:副本存原文件旁)

enum OutputNamer {
    /// 格式转换 = "原名.新扩展名";原地动作(压缩/去EXIF)= "原名 + 动作.原扩展名"。
    /// 重名自动追加 " 2"、" 3"…
    static func uniqueOutput(for source: URL, suffix: String?, fileExtension: String) -> URL {
        let stem = source.deletingPathExtension().lastPathComponent
        let base = suffix.map { "\(stem) \($0)" } ?? stem
        let directory = source.deletingLastPathComponent()
        var candidate = directory.appendingPathComponent("\(base).\(fileExtension)")
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(base) \(counter).\(fileExtension)")
            counter += 1
        }
        return candidate
    }
}

// MARK: - 任务执行

final class JobRunner {
    /// 对一组文件执行同一动作;两个并发 worker(报告 §5.1-6 的限流),
    /// 结果按输入顺序返回。单文件失败不影响其余文件。
    /// cancel 令牌逐文件检查,并传入 ffmpeg 子进程(长任务可终止)。
    func run(kind: ActionKind, files: [URL], cancel: CancelToken? = nil) async -> [JobOutcome] {
        guard files.count > 1 else {
            return [await processOne(file: files[0], kind: kind, allFiles: files, cancel: cancel)]
        }
        // 切两半,各自顺序执行 → 总并发 = 2
        let mid = (files.count + 1) / 2
        let halves = [Array(files[..<mid]), Array(files[mid...])]
        let results = await withTaskGroup(of: [JobOutcome].self) { group -> [JobOutcome] in
            for half in halves {
                group.addTask {
                    var outcomes: [JobOutcome] = []
                    for file in half {
                        if let cancel, cancel.isCancelled {
                            outcomes.append(JobOutcome(source: file, output: nil, errorText: KumquatCancelled.user.description))
                            continue
                        }
                        outcomes.append(await self.processOne(file: file, kind: kind, allFiles: files, cancel: cancel))
                    }
                    return outcomes
                }
            }
            var collected: [JobOutcome] = []
            for await partial in group { collected.append(contentsOf: partial) }
            return collected
        }
        // 两个 worker 的汇合顺序不确定,按输入顺序重排
        let bySource = Dictionary(uniqueKeysWithValues: results.map { ($0.source, $0) })
        return files.compactMap { bySource[$0] }
    }

    private func processOne(file: URL, kind: ActionKind, allFiles: [URL], cancel: CancelToken?) async -> JobOutcome {
        if let cancel, cancel.isCancelled {
            return JobOutcome(source: file, output: nil, errorText: KumquatCancelled.user.description)
        }
        do {
            switch kind {
            // MARK: 图片(sips / ImageIO)

            case let .convertImage(format):
                if format.equivalentExtensions.contains(file.lowercasedExtension) {
                    return JobOutcome(source: file, skipped: true)
                }
                let output = OutputNamer.uniqueOutput(for: file, suffix: nil,
                                                      fileExtension: format.fileExtension)
                try await SipsEngine.convert(input: file, format: format, output: output)
                return JobOutcome(source: file, output: output)

            case .convertImageWebP:
                let output = OutputNamer.uniqueOutput(for: file, suffix: nil, fileExtension: "webp")
                try ImageIOEngine.convert(input: file, output: output, type: .webP, quality: 0.85)
                return JobOutcome(source: file, output: output)

            case .compressImage:
                let output = OutputNamer.uniqueOutput(for: file, suffix: "压缩", fileExtension: "jpg")
                try await SipsEngine.compress(input: file, output: output)
                return JobOutcome(source: file, output: output)

            case .stripExif:
                let output = OutputNamer.uniqueOutput(for: file, suffix: "无EXIF",
                                                      fileExtension: file.pathExtension)
                try MetadataEngine.stripMetadata(input: file, output: output)
                return JobOutcome(source: file, output: output)

            case let .rotateImage(degrees):
                let output = OutputNamer.uniqueOutput(for: file, suffix: "旋转\(degrees)",
                                                      fileExtension: file.pathExtension)
                try await ImageToolsEngine.rotate(input: file, output: output, degrees: degrees)
                return JobOutcome(source: file, output: output)

            case let .flipImage(direction):
                let output = OutputNamer.uniqueOutput(for: file, suffix: "翻转",
                                                      fileExtension: file.pathExtension)
                try await ImageToolsEngine.flip(input: file, output: output, direction: direction)
                return JobOutcome(source: file, output: output)

            case let .scaleImageLongest(side):
                let output = OutputNamer.uniqueOutput(for: file, suffix: "缩放\(side)",
                                                      fileExtension: file.pathExtension)
                try await ImageToolsEngine.resampleLongestSide(input: file, output: output, longestSide: side)
                return JobOutcome(source: file, output: output)

            case let .scaleImagePercent(percent):
                let output = OutputNamer.uniqueOutput(for: file, suffix: "缩放\(percent)%",
                                                      fileExtension: file.pathExtension)
                try await ImageToolsEngine.resamplePercent(input: file, output: output, percent: percent)
                return JobOutcome(source: file, output: output)

            case .grayscaleImage:
                let output = OutputNamer.uniqueOutput(for: file, suffix: "灰度",
                                                      fileExtension: file.pathExtension)
                try await ImageToolsEngine.grayscale(input: file, output: output)
                return JobOutcome(source: file, output: output)

            case .collageImages:
                let imageExtension = ImageIOEngine.hasAnyAlpha(allFiles) ? "png" : "jpg"
                let output = OutputNamer.uniqueOutput(for: file, suffix: "拼贴", fileExtension: imageExtension)
                try ImageToolsEngine.collage(inputs: allFiles, output: output)
                return JobOutcome(source: file, output: output)

            // MARK: 视频/音频(ffmpeg)

            case let .convertVideo(format):
                if file.lowercasedExtension == format.rawValue {
                    return JobOutcome(source: file, skipped: true)
                }
                return try await runFFmpeg(file: file, fileExtension: format.fileExtension,
                                           extraArguments: format.extraArguments, cancel: cancel)

            case let .convertAudio(format):
                if file.lowercasedExtension == format.rawValue {
                    return JobOutcome(source: file, skipped: true)
                }
                return try await runFFmpeg(file: file, fileExtension: format.fileExtension, cancel: cancel)

            case let .extractAudio(format):
                return try await runFFmpeg(file: file, fileExtension: format.fileExtension,
                                           extraArguments: ["-vn"], cancel: cancel)

            case let .speedVideo(factor):
                return try await runFFmpeg(file: file, fileExtension: file.lowercasedExtension,
                                           suffix: "变速\(factor)x",
                                           extraArguments: ["-filter:v", "setpts=PTS/\(factor)",
                                                            "-filter:a", "atempo=\(factor)"],
                                           cancel: cancel)

            case .extractVideoFrame:
                return try await runFFmpeg(file: file, fileExtension: "png", suffix: "帧",
                                           extraArguments: ["-ss", "1", "-frames:v", "1"],
                                           cancel: cancel)

            // MARK: PDF

            case .mergePDF:
                let output = OutputNamer.uniqueOutput(for: file, suffix: "合并", fileExtension: "pdf")
                try PDFToolsEngine.merge(inputs: allFiles, output: output)
                return JobOutcome(source: file, output: output)

            case .splitPDF:
                let outputs = try PDFToolsEngine.split(input: file) { pageNumber in
                    OutputNamer.uniqueOutput(for: file, suffix: "页\(pageNumber)", fileExtension: "pdf")
                }
                return JobOutcome(source: file, output: outputs.first)

            case .compressPDF:
                let output = OutputNamer.uniqueOutput(for: file, suffix: "压缩", fileExtension: "pdf")
                try PDFToolsEngine.compress(input: file, output: output)
                return JobOutcome(source: file, output: output)

            case let .rotatePDF(degrees):
                let output = OutputNamer.uniqueOutput(for: file, suffix: "旋转\(degrees)",
                                                      fileExtension: "pdf")
                try PDFToolsEngine.rotate(input: file, output: output, degrees: degrees)
                return JobOutcome(source: file, output: output)

            case .pdfToPNG:
                let outputs = try PDFToolsEngine.renderPNGs(input: file) { pageNumber in
                    OutputNamer.uniqueOutput(for: file, suffix: "页\(pageNumber)", fileExtension: "png")
                }
                return JobOutcome(source: file, output: outputs.first)

            case .imagesToPDF:
                let output = OutputNamer.uniqueOutput(for: file, suffix: nil, fileExtension: "pdf")
                try PDFToolsEngine.imagesToPDF(inputs: allFiles, output: output)
                return JobOutcome(source: file, output: output)

            // MARK: 归档

            case .createZip:
                let output = OutputNamer.uniqueOutput(for: file, suffix: "归档", fileExtension: "zip")
                try await ArchiveEngine.createZip(inputs: allFiles, output: output, cancel: cancel)
                return JobOutcome(source: file, output: output)

            case .extractZip:
                let directory = ArchiveEngine.uniqueExtractionDirectory(for: file)
                try await ArchiveEngine.extractZip(input: file, outputDirectory: directory)
                return JobOutcome(source: file, output: directory)

            case .extractTar:
                let directory = ArchiveEngine.uniqueExtractionDirectory(for: file)
                try await ArchiveEngine.extractTar(input: file, outputDirectory: directory)
                return JobOutcome(source: file, output: directory)

            // MARK: 文档

            case let .convertDocPandoc(target):
                guard let pandoc = PandocEngine.detect() else {
                    return JobOutcome(source: file, output: nil, skipped: true)
                }
                let output = OutputNamer.uniqueOutput(for: file, suffix: nil,
                                                      fileExtension: target.fileExtension)
                try await PandocEngine.convert(executable: pandoc, input: file,
                                               target: target, output: output)
                return JobOutcome(source: file, output: output)

            case let .convertDocTextUtil(format):
                let output = OutputNamer.uniqueOutput(for: file, suffix: nil, fileExtension: format)
                try await TextUtilEngine.convert(input: file, output: output, format: format)
                return JobOutcome(source: file, output: output)

            case .convertOfficePDF:
                guard let soffice = OfficeEngine.detect() else {
                    return JobOutcome(source: file, output: nil, skipped: true)
                }
                let tempDirectory = OfficeEngine.makeTempOutputDirectory()
                defer { try? FileManager.default.removeItem(at: tempDirectory) }
                do {
                    try await OfficeEngine.convertToPDF(executable: soffice, input: file,
                                                        outputDirectory: tempDirectory, cancel: cancel)
                    let produced = tempDirectory.appendingPathComponent(
                        file.deletingPathExtension().lastPathComponent + ".pdf")
                    let output = OutputNamer.uniqueOutput(for: file, suffix: nil, fileExtension: "pdf")
                    try FileManager.default.moveItem(at: produced, to: output)
                    return JobOutcome(source: file, output: output)
                } catch {
                    throw error
                }

            case let .trimVideo(start, end):
                return try await runFFmpeg(file: file, fileExtension: file.lowercasedExtension,
                                           suffix: String(format: "剪短%.0f-%.0fs", start, end),
                                           inputOptions: ["-ss", String(format: "%.2f", start)],
                                           extraArguments: ["-t", String(format: "%.2f", end - start)],
                                           cancel: cancel)
            }
        } catch {
            let text: String
            if let procError = error as? ProcError {
                text = procError.description // sips/ffmpeg 的 stderr 报错
            } else {
                text = error.localizedDescription
            }
            return JobOutcome(source: file, output: nil, errorText: text)
        }
    }

    private func runFFmpeg(file: URL, fileExtension: String,
                           suffix: String? = nil, inputOptions: [String] = [],
                           extraArguments: [String] = [],
                           cancel: CancelToken? = nil) async throws -> JobOutcome {
        guard let ffmpeg = FFmpegEngine.detect() else {
            return JobOutcome(source: file, output: nil, skipped: true)
        }
        let output = OutputNamer.uniqueOutput(for: file, suffix: suffix, fileExtension: fileExtension)
        try await FFmpegEngine.convert(executable: ffmpeg, input: file, output: output,
                                       inputOptions: inputOptions,
                                       extraArguments: extraArguments, cancel: cancel)
        return JobOutcome(source: file, output: output)
    }
}
