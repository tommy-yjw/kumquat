import AppKit
import ImageIO
import OSLog
import UniformTypeIdentifiers

// MARK: - 子进程运行器

enum ProcError: Error, CustomStringConvertible {
    case launchFailed(path: String, underlying: String)
    case nonZeroExit(status: Int32, stderr: String)
    case timedOut(timeout: TimeInterval, stderr: String)

    var description: String {
        switch self {
        case let .launchFailed(path, underlying):
            return "无法启动 \(path):\(underlying)"
        case let .nonZeroExit(status, stderr):
            let tail = Self.tail(of: stderr)
            return tail.isEmpty ? "子进程退出码 \(status)" : tail
        case let .timedOut(timeout, stderr):
            let tail = Self.tail(of: stderr)
            return tail.isEmpty ? "转换超时(>\(Int(timeout))s)" : tail
        }
    }

    /// stderr 末尾几行——sips/ffmpeg 的报错都在 stderr(报告 §3.4-⑤)。
    static func tail(of text: String, lines: Int = 2) -> String {
        let nonEmpty = text.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        return nonEmpty.suffix(lines).joined(separator: " / ")
    }
}

enum ProcessRunner {
    /// 同步语义的异步子进程运行:管道在 run() 之前挂好,readabilityHandler 持续排空,
    /// 防止子进程写满 64KB 管道缓冲造成三方死锁(reverse-report.md §3.4-①)。
    /// 超时后 terminate();非 0 退出码把 stderr 带进错误信息。
    static func run(executablePath: String, arguments: [String],
                    timeout: TimeInterval = 600, cancel: CancelToken? = nil) async throws {
        if let cancel, cancel.isCancelled { throw KumquatCancelled.user }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.qualityOfService = .userInitiated

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        // OSAllocatedUnfairLock(macOS 13+):可在并发/异步闭包里安全更新状态
        struct RunnerState {
            var stderr = Data()
            var timedOut = false
            var cancelled = false
        }
        let state = OSAllocatedUnfairLock(initialState: RunnerState())

        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty { // EOF
                handle.readabilityHandler = nil
                return
            }
            state.withLock { $0.stderr.append(chunk) }
        }
        // stdout 不使用,但同样必须持续排空
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            if handle.availableData.isEmpty { handle.readabilityHandler = nil }
        }

        do {
            try process.run()
        } catch {
            throw ProcError.launchFailed(path: executablePath, underlying: error.localizedDescription)
        }

        let watchdog = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        watchdog.schedule(deadline: .now() + timeout)
        watchdog.setEventHandler { [weak process] in
            guard let process, process.isRunning else { return }
            state.withLock { $0.timedOut = true }
            process.terminate()
        }
        watchdog.resume()

        // 取消轮询:进度窗点"取消"后 0.25s 内 terminate 子进程。
        // 注意:有 cancel 令牌才创建——对从未 resume 的挂起 dispatch 源调 cancel(),
        // 释放时会踩中 libdispatch 断言(SIGTRAP),v2 曾因此首次转换必崩。
        var cancelPoller: DispatchSourceTimer?
        if let cancel {
            let poller = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
            poller.schedule(deadline: .now(), repeating: 0.25)
            poller.setEventHandler { [weak process] in
                guard cancel.isCancelled, let process, process.isRunning else { return }
                state.withLock { $0.cancelled = true }
                process.terminate()
            }
            poller.resume()
            cancelPoller = poller
        }

        let status: Int32 = await withCheckedContinuation { continuation in
            process.terminationHandler = { proc in
                continuation.resume(returning: proc.terminationStatus)
            }
        }
        watchdog.cancel()
        cancelPoller?.cancel()

        // 进程已退出:摘掉 handler 后同步读走残余(此时不会再有并发读)
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        let tail = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        let finalState = state.withLock { current -> RunnerState in
            current.stderr.append(tail)
            return current
        }

        let stderrText = String(decoding: finalState.stderr, as: UTF8.self)
        if finalState.cancelled { throw KumquatCancelled.user }
        if finalState.timedOut { throw ProcError.timedOut(timeout: timeout, stderr: stderrText) }
        if status != 0 { throw ProcError.nonZeroExit(status: status, stderr: stderrText) }
    }
}

// MARK: - 取消令牌与取消错误

enum KumquatCancelled: Error, CustomStringConvertible {
    case user
    var description: String { "已取消" }
}

/// 线程安全的取消令牌:进度窗的取消按钮置位,子进程轮询器据此 terminate。
final class CancelToken: @unchecked Sendable {
    private let state = OSAllocatedUnfairLock(initialState: false)
    var isCancelled: Bool { state.withLock { $0 } }
    func cancel() { state.withLock { $0 = true } }
}

// MARK: - 格式定义(UI 无关部分)

enum ImageFormat: String, CaseIterable, Identifiable {
    case jpg, png, heic, tiff

    var id: String { rawValue }
    /// sips `-s format` 取值(jpg → jpeg)
    var sipsFormat: String {
        switch self {
        case .jpg: "jpeg"
        case .png: "png"
        case .heic: "heic"
        case .tiff: "tiff"
        }
    }
    var fileExtension: String { rawValue }
    var title: String { "转为 " + rawValue.uppercased() }
    /// 与目标同格式的扩展名:这些文件无需转换
    var equivalentExtensions: Set<String> {
        switch self {
        case .jpg: ["jpg", "jpeg"]
        case .png: ["png"]
        case .heic: ["heic", "heics"]
        case .tiff: ["tif", "tiff"]
        }
    }
}

enum VideoFormat: String, CaseIterable, Identifiable {
    case mp4, mov, mkv, webm, gif

    var id: String { rawValue }
    var fileExtension: String { rawValue }
    var title: String { "转为 " + rawValue.uppercased() }
    var equivalentExtensions: Set<String> { [rawValue] }
    /// mp4 加 faststart 便于流式播放;gif 限 12fps、最长边 720 控制体积
    var extraArguments: [String] {
        switch self {
        case .mp4: ["-movflags", "+faststart"]
        case .gif: ["-vf", "fps=12,scale='min(720,iw)':-2:flags=lanczos", "-loop", "0"]
        case .mov, .mkv, .webm: []
        }
    }
}

enum AudioFormat: String, CaseIterable, Identifiable {
    case mp3, m4a, wav, flac

    var id: String { rawValue }
    var fileExtension: String { rawValue }
    var title: String { "转为 " + rawValue.uppercased() }
    var equivalentExtensions: Set<String> { [rawValue] }
}

extension URL {
    var lowercasedExtension: String { pathExtension.lowercased() }
}

// MARK: - Sips 引擎(硬编码 /usr/bin/sips,勿依赖 PATH —— 报告 §3.4)

enum SipsEngine {
    static let executablePath = "/usr/bin/sips"

    /// `sips -s format <fmt> <in> --out <out>`(四格式互转参数已于 2026-10-05 本机实测通过)
    static func convert(input: URL, format: ImageFormat, output: URL) async throws {
        try await ProcessRunner.run(
            executablePath: executablePath,
            arguments: ["-s", "format", format.sipsFormat, input.path, "--out", output.path],
            timeout: 180
        )
    }

    /// 压缩:重编码为 JPEG(质量 60)。sips 无"仅压缩"开关,
    /// JPEG 重编码是零依赖的压缩路径(实测 69.7KB → q60 42.6KB 生效)。
    static func compress(input: URL, output: URL) async throws {
        try await ProcessRunner.run(
            executablePath: executablePath,
            arguments: ["-s", "format", "jpeg", "-s", "formatOptions", "60",
                        input.path, "--out", output.path],
            timeout: 180
        )
    }
}

// MARK: - 元数据引擎(系统 ImageIO)

enum MetadataEngine {
    /// 去除 EXIF/GPS/TIFF/XMP:用 ImageIO 解码后以"空属性字典"重写。
    /// 本机实测(2026-10-05):sips 跨格式转换会原样保留 EXIF/GPS,
    /// `--deleteProperty` 对 JPEG 报 Error 13——去 EXIF 无法用 sips 实现;
    /// ImageIO 是系统框架,不引入任何外部依赖。JPEG 输出按质量 1.0 重编码。
    static func stripMetadata(input: URL, output: URL) throws {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(input as CFURL, options),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw NSError(domain: "Kumquat.Metadata", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "无法读取图像 \(input.lastPathComponent)"])
        }
        let type = CGImageSourceGetType(source) ?? UTType.jpeg.identifier as CFString
        guard let destination = CGImageDestinationCreateWithURL(output as CFURL, type, 1, nil) else {
            throw NSError(domain: "Kumquat.Metadata", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "无法写入 \(output.lastPathComponent)"])
        }
        // 空属性(仅压缩质量)→ 不写任何 EXIF/GPS/TIFF/XMP
        CGImageDestinationAddImage(destination, image,
                                   [kCGImageDestinationLossyCompressionQuality: 1.0] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw NSError(domain: "Kumquat.Metadata", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "写出失败 \(output.lastPathComponent)"])
        }
    }
}

// MARK: - FFmpeg 引擎(可选;未安装则对应动作整体隐藏)

enum FFmpegEngine {
    /// 探测顺序(报告 §3.4):bundle 内 → Homebrew 两条标准路径 → $PATH 逐目录。
    static func detect() -> URL? {
        var candidates: [String] = []
        if let bundleDir = Bundle.main.executableURL?.deletingLastPathComponent().path {
            candidates.append(bundleDir + "/ffmpeg")
        }
        candidates.append(contentsOf: ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"])
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            candidates.append(contentsOf: path.split(separator: ":").map { "\($0)/ffmpeg" })
        }
        for candidate in candidates {
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return URL(fileURLWithPath: candidate)
            }
        }
        return nil
    }

    /// `ffmpeg -y [输入选项] -i <in> [输出选项] <out>`:输出格式由扩展名推断。
    /// inputOptions 必须在 -i 之前(如 -ss 输入快进)。
    static func convert(executable: URL, input: URL, output: URL,
                        inputOptions: [String] = [], extraArguments: [String] = [],
                        cancel: CancelToken? = nil) async throws {
        try await ProcessRunner.run(executablePath: executable.path,
                                    arguments: ["-y"] + inputOptions + ["-i", input.path]
                                        + extraArguments + [output.path],
                                    timeout: 1800, cancel: cancel)
    }
}
