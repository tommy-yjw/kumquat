import Foundation
import UniformTypeIdentifiers

// MARK: - pandoc 引擎(可选;未安装则对应动作整体隐藏)

enum PandocTarget: String, CaseIterable, Identifiable {
    case docx, epub, html, markdown, plain

    var id: String { rawValue }

    var fileExtension: String {
        switch self {
        case .docx: return "docx"
        case .epub: return "epub"
        case .html: return "html"
        case .markdown: return "md"
        case .plain: return "txt"
        }
    }

    var title: String {
        switch self {
        case .docx: return "转为 DOCX"
        case .epub: return "转为 EPUB"
        case .html: return "转为 HTML"
        case .markdown: return "转为 MD"
        case .plain: return "转为 TXT"
        }
    }

    /// 已是该目标的扩展名:不再出现该动作。
    var equivalentExtensions: Set<String> {
        switch self {
        case .docx: return ["docx"]
        case .epub: return ["epub"]
        case .html: return ["html", "htm"]
        case .markdown: return ["md", "markdown"]
        case .plain: return ["txt"]
        }
    }
}

enum PandocEngine {
    /// 探测顺序与 ffmpeg 相同:bundle 内 → Homebrew 两条标准路径 → $PATH。
    static func detect() -> URL? {
        var candidates: [String] = []
        if let bundleDirectory = Bundle.main.executableURL?.deletingLastPathComponent().path {
            candidates.append(bundleDirectory + "/pandoc")
        }
        candidates.append(contentsOf: ["/opt/homebrew/bin/pandoc", "/usr/local/bin/pandoc"])
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            candidates.append(contentsOf: path.split(separator: ":").map { "\($0)/pandoc" })
        }
        for candidate in candidates {
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return URL(fileURLWithPath: candidate)
            }
        }
        return nil
    }

    /// `pandoc [输入格式] 输入 [-s] -o 输出`:.txt 按 markdown 方言读;
    /// html 输出加 -s 生成独立文档。
    static func convert(executable: URL, input: URL, target: PandocTarget, output: URL) async throws {
        var arguments: [String] = []
        if input.lowercasedExtension == "txt" { arguments += ["-f", "markdown"] }
        arguments.append(input.path)
        if target == .html { arguments.append("-s") }
        arguments += ["-o", output.path]
        try await ProcessRunner.run(executablePath: executable.path, arguments: arguments, timeout: 600)
    }
}

// MARK: - textutil 引擎(系统自带;负责 .doc 老 Word 格式,兼作 pandoc 缺席时的兜底)

enum TextUtilEngine {
    static let executablePath = "/usr/bin/textutil"

    /// `textutil -convert 格式 输入 -output 输出`(格式:text/html/rtf/docx)。
    static func convert(input: URL, output: URL, format: String) async throws {
        try await ProcessRunner.run(executablePath: executablePath,
                                    arguments: ["-convert", format, input.path, "-output", output.path],
                                    timeout: 600)
    }
}

// MARK: - PDF → Word 引擎(可选;经 python3 调开源 pdf2docx,运行时探测)

import os

enum PDFWordEngine {
    private struct EngineState {
        var checked = false
        var ready = false
        var python: URL?
    }
    private static let state = OSAllocatedUnfairLock(initialState: EngineState())

    private static func candidatePythons() -> [URL] {
        var paths: [URL] = []
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            paths += path.split(separator: ":").map { URL(fileURLWithPath: "\($0)/python3") }
        }
        paths += [URL(fileURLWithPath: "/usr/bin/python3"),
                  URL(fileURLWithPath: "/opt/homebrew/bin/python3"),
                  URL(fileURLWithPath: "/usr/local/bin/python3")]
        return paths
    }

    /// 真实探测(逐个 python 试 `import pdf2docx`),结果缓存整个进程周期。
    /// 启动时在后台任务调用;菜单与任务只读缓存,不触发子进程。
    static func prime() {
        state.withLock { if $0.checked { return } }
        for python in candidatePythons() {
            guard FileManager.default.isExecutableFile(atPath: python.path) else { continue }
            let process = Process()
            process.executableURL = python
            process.arguments = ["-c", "import pdf2docx"]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do { try process.run() } catch { continue }
            process.waitUntilExit()
            if process.terminationStatus == 0 {
                state.withLock {
                    $0.checked = true
                    $0.ready = true
                    $0.python = python
                }
                return
            }
        }
        state.withLock { $0.checked = true }
    }

    /// 菜单用:只读缓存,不触发探测。
    static var cachedReady: Bool { state.withLock { $0.ready } }
    static var cachedPython: URL? { state.withLock { $0.python } }

    static func convert(python: URL, input: URL, output: URL,
                        cancel: CancelToken? = nil) async throws {
        try await ProcessRunner.run(
            executablePath: python.path,
            arguments: ["-c",
                        "from pdf2docx import parse; parse(r'\(input.path)', r'\(output.path)')"],
            timeout: 1200, cancel: cancel)
        // 后处理(随 bundle 分发):合并跨页表格碎片 + 按字号重建标题层级。
        // 失败不影响主体结果(docx 已产出),故 try?。
        if let resourceURL = Bundle.main.resourceURL {
            let postfix = resourceURL.appendingPathComponent("pdf2docx_postfix.py")
            if FileManager.default.fileExists(atPath: postfix.path) {
                try? await ProcessRunner.run(executablePath: python.path,
                                             arguments: [postfix.path, output.path],
                                             timeout: 600, cancel: cancel)
            }
        }
    }
}
