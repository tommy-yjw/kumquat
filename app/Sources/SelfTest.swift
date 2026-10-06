import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// MARK: - 应用内自测模式(KUMQUAT_SELF_TEST=1)
//
// 引擎层有子进程+dispatch 的测试在裸 CLI 宿主下会触发 libdispatch 收尾陷阱
// (仅测试环境;App 宿主内同一路径经 v2 实战验证稳定)。因此进程类引擎测试
// 统一放进 app 自测模式:与生产完全相同的宿主,结果写 stderr,退出码判定。

enum SelfTest {
    static var passed = 0
    static var failed: [String] = []

    static func that(_ condition: Bool, _ name: String) {
        if condition {
            passed += 1
        } else {
            failed.append(name)
            FileHandle.standardError.write(Data("❌ \(name)\n".utf8))
        }
    }

    static func stage(_ name: String) {
        FileHandle.standardError.write(Data("▶️ \(name)\n".utf8))
    }

    @MainActor
    static func run() async {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("kumquat-selftest-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for subdirectory in ["img", "office", "video"] {
            try? FileManager.default.createDirectory(at: root.appendingPathComponent(subdirectory),
                                                     withIntermediateDirectories: true)
        }

        do {
            stage("图片引擎(sips 子进程)")
            try await testImageEngines(root.appendingPathComponent("img"))

            stage("Office 引擎(LibreOffice 子进程)")
            try await testOfficeEngine(root.appendingPathComponent("office"))

            if FFmpegEngine.detect() != nil {
                stage("视频引擎(ffmpeg 子进程)")
                try await testVideoEngine(root.appendingPathComponent("video"))
            } else {
                FileHandle.standardError.write(Data("⏭️ ffmpeg 未安装,视频引擎跳过\n".utf8))
            }

            stage("压缩到指定大小(图片二分)")
            try await testCompressToSize(root.appendingPathComponent("img"))

            if FFmpegEngine.detect() != nil {
                stage("音频工具组(归一化/声道/波形)")
                try await testAudioTools(root.appendingPathComponent("video"))
            }

            stage("Redact 三模式渲染(ImageComposer)")
            try testRedactRendering(root.appendingPathComponent("img"))
        } catch {
            that(false, "测试执行异常:\(error.localizedDescription)")
            FileHandle.standardError.write(Data("💥 \(error)\n".utf8))
        }

        FileHandle.standardError.write(Data("—— 自测结果:通过 \(passed),失败 \(failed.count) ——\n".utf8))
        try? FileManager.default.removeItem(at: root)
        exit(failed.isEmpty ? 0 : 1)
    }

    // MARK: 图片引擎(真实 sips 子进程)

    private static func makeJPEG(directory: URL, name: String,
                                 width: Int, height: Int, red: CGFloat) throws -> URL {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(srgbRed: red, green: 0.4, blue: 0.2, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = context.makeImage()!
        let path = directory.appendingPathComponent(name)
        guard let destination = CGImageDestinationCreateWithURL(path as CFURL,
                                                                UTType.jpeg.identifier as CFString, 1, nil) else {
            throw NSError(domain: "Kumquat.SelfTest", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "无法创建 CGImageDestination"])
        }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
        return path
    }

    private static func testImageEngines(_ directory: URL) async throws {
        let portrait = try makeJPEG(directory: directory, name: "b.jpg", width: 600, height: 800, red: 0.2)

        let rotated = OutputNamer.uniqueOutput(for: portrait, suffix: "旋转90", fileExtension: "jpg")
        try await ImageToolsEngine.rotate(input: portrait, output: rotated, degrees: 90)
        let rotatedSize = ImageIOEngine.pixelSize(of: rotated)
        that(rotatedSize?.width == 800 && rotatedSize?.height == 600, "图片:旋转90°交换宽高")

        let flipped = OutputNamer.uniqueOutput(for: portrait, suffix: "翻转", fileExtension: "jpg")
        try await ImageToolsEngine.flip(input: portrait, output: flipped, direction: "horizontal")
        that(FileManager.default.fileExists(atPath: flipped.path), "图片:水平翻转产出")

        let scaled = OutputNamer.uniqueOutput(for: portrait, suffix: "缩放", fileExtension: "jpg")
        try await ImageToolsEngine.resampleLongestSide(input: portrait, output: scaled, longestSide: 400)
        let scaledSize = ImageIOEngine.pixelSize(of: scaled)
        that(scaledSize?.width == 300 && scaledSize?.height == 400, "图片:竖图长边缩放 400")

        let gray = OutputNamer.uniqueOutput(for: portrait, suffix: "灰度", fileExtension: "jpg")
        try await ImageToolsEngine.grayscale(input: portrait, output: gray)
        that(FileManager.default.fileExists(atPath: gray.path), "图片:灰度产出")
    }

    // MARK: Office 引擎(真实 LibreOffice 子进程)

    private static func testOfficeEngine(_ directory: URL) async throws {
        guard let soffice = OfficeEngine.detect() else {
            FileHandle.standardError.write(Data("⏭️ 本机无 soffice,Office 引擎跳过\n".utf8))
            return
        }
        let rtf = directory.appendingPathComponent("t.rtf")
        try Data("{\\rtf1\\ansi Hello Kumquat}".utf8).write(to: rtf)
        let docx = directory.appendingPathComponent("t.docx")
        try await TextUtilEngine.convert(input: rtf, output: docx, format: "docx")

        // 与生产一致:经 JobRunner 跑完整任务路径
        let runner = JobRunner()
        let outcomes = await runner.run(kind: .convertOfficePDF, files: [docx])
        that(outcomes.first?.succeeded == true
             && outcomes.first?.output?.pathExtension == "pdf", "Office:docx → PDF(JobRunner 全链路)")
    }

    // MARK: 视频引擎(真实 ffmpeg 子进程)

    private static func testVideoEngine(_ directory: URL) async throws {
        guard let ffmpeg = FFmpegEngine.detect() else { return }
        // 生成 2 秒测试视频(lavfi 彩条)
        let source = directory.appendingPathComponent("src.mp4")
        try await ProcessRunner.run(executablePath: ffmpeg.path,
                                    arguments: ["-y", "-f", "lavfi",
                                                "-i", "testsrc=duration=2:size=320x240:rate=15",
                                                "-pix_fmt", "yuv420p", source.path],
                                    timeout: 120)

        let runner = JobRunner()
        // 剪短 0.5-1.5s(编辑器同路径)
        let trimmed = await runner.run(kind: .trimVideo(0.5, 1.5), files: [source])
        that(trimmed.first?.succeeded == true, "视频:剪短 0.5-1.5s")

        // 变速 2×
        let speed = await runner.run(kind: .speedVideo(2), files: [source])
        that(speed.first?.succeeded == true, "视频:变速 2×")

        // 转 GIF
        let gif = await runner.run(kind: .convertVideo(.gif), files: [source])
        that(gif.first?.succeeded == true
             && gif.first?.output?.pathExtension == "gif", "视频:转 GIF")

        // 抽帧
        let frame = await runner.run(kind: .extractVideoFrame, files: [source])
        that(frame.first?.succeeded == true
             && frame.first?.output?.pathExtension == "png", "视频:抽帧 PNG")

        // 抽音轨(lavfi 视频无音轨,先造一个带音轨的)
        let withAudio = directory.appendingPathComponent("audio-src.mp4")
        try await ProcessRunner.run(executablePath: ffmpeg.path,
                                    arguments: ["-y", "-f", "lavfi",
                                                "-i", "testsrc=duration=2:size=320x240:rate=15",
                                                "-f", "lavfi", "-i", "sine=frequency=440:duration=2",
                                                "-pix_fmt", "yuv420p", "-shortest", withAudio.path],
                                    timeout: 120)
        let audio = await runner.run(kind: .extractAudio(.m4a), files: [withAudio])
        that(audio.first?.succeeded == true
             && audio.first?.output?.pathExtension == "m4a", "视频:提取音轨 M4A")
    }

    private static func testCompressToSize(_ directory: URL) async throws {
        let source = try makeJPEG(directory: directory, name: "big.jpg", width: 800, height: 600, red: 0.9)
        let target = 40 * 1024
        let output = directory.appendingPathComponent("small-target.jpg")
        try await CompressEngine.image(input: source, output: output, targetBytes: target)
        let size = (try? FileManager.default.attributesOfItem(atPath: output.path)[.size] as? Int) ?? 0
        that(size > 0 && size <= target + 2048, "压缩到 40KB 内(实际 \(size)B)")
    }

    private static func testAudioTools(_ directory: URL) async throws {
        let source = directory.appendingPathComponent("audio-src.mp4")
        guard FileManager.default.fileExists(atPath: source.path) else { return }
        let runner = JobRunner()
        let normalized = await runner.run(kind: .normalizeAudio, files: [source])
        that(normalized.first?.succeeded == true, "音频:音量归一化(loudnorm)")
        let mono = await runner.run(kind: .convertChannels(1), files: [source])
        that(mono.first?.succeeded == true, "音频:转 Mono")
        let waveform = await runner.run(kind: .audioWaveform, files: [source])
        that(waveform.first?.succeeded == true
             && waveform.first?.output?.pathExtension == "png", "音频:波形图 PNG")
    }

    private static func testRedactRendering(_ directory: URL) throws {
        let source = try makeJPEG(directory: directory, name: "redact-src.jpg", width: 800, height: 600, red: 0.5)
        guard let cgImage = CGImageSourceCreateWithURL(source as CFURL, nil)
            .flatMap({ CGImageSourceCreateImageAtIndex($0, 0, nil) }) else {
            throw NSError(domain: "Kumquat.SelfTest", code: 4,
                          userInfo: [NSLocalizedDescriptionKey: "无法读取测试图"])
        }
        for style in RedactStyle.allCases {
            let composed = try ImageComposer.render(
                source: cgImage,
                crop: CGRect(x: 0.1, y: 0.1, width: 0.6, height: 0.6),
                redactions: [RedactionRect(rect: CGRect(x: 0.2, y: 0.2, width: 0.3, height: 0.3),
                                           style: style)],
                annotations: [EditorAnnotation(kind: .arrow,
                                               from: CGPoint(x: 0.15, y: 0.15),
                                               to: CGPoint(x: 0.45, y: 0.45), text: nil)])
            that(composed.width == 480 && composed.height == 360,
                 "Redact:\(style.title) 渲染 480×360")
        }
    }
}
