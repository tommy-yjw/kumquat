import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// 压缩到指定大小引擎。
enum CompressEngine {
    /// 图片:JPEG 质量二分逼近目标;压不进则降采样 20% 再试(最多 5 轮)。
    static func image(input: URL, output: URL, targetBytes: Int,
                      cancel: CancelToken? = nil) async throws {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(input as CFURL, options),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw NSError(domain: "Kumquat.Compress", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "无法读取图像 \(input.lastPathComponent)"])
        }
        var scale: CGFloat = 1
        for _ in 0..<5 {
            if let data = jpegByBisectingQuality(image: image, scale: scale,
                                                 targetBytes: targetBytes, cancel: cancel) {
                try data.write(to: output)
                return
            }
            if cancel?.isCancelled == true { throw KumquatCancelled.user }
            scale *= 0.8
        }
        guard let fallback = encode(image: image, scale: 0.45, quality: 25) else {
            throw NSError(domain: "Kumquat.Compress", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "压缩失败"])
        }
        try fallback.write(to: output)
    }

    /// 质量二分:返回 ≤ 目标的最大质量编码;压不进返回 nil。
    private static func jpegByBisectingQuality(image: CGImage, scale: CGFloat,
                                               targetBytes: Int, cancel: CancelToken?) -> Data? {
        var low = 5, high = 95
        var candidate: Data?
        while low <= high {
            if cancel?.isCancelled == true { return candidate }
            let mid = (low + high) / 2
            guard let data = encode(image: image, scale: scale, quality: mid) else { return candidate }
            if data.count <= targetBytes {
                candidate = data
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return candidate
    }

    private static func encode(image: CGImage, scale: CGFloat, quality: Int) -> Data? {
        let width = max(1, Int(CGFloat(image.width) * scale))
        let height = max(1, Int(CGFloat(image.height) * scale))
        guard let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setFillColor(CGColor(gray: 1, alpha: 1)) // JPEG 无透明:铺白底
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let rendered = context.makeImage() else { return nil }
        let mutableData = NSMutableData()
        guard let consumer = CGDataConsumer(data: mutableData as CFMutableData),
              let destination = CGImageDestinationCreateWithData(mutableData as CFMutableData,
                                                                 UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, rendered,
                                   [kCGImageDestinationLossyCompressionQuality: CGFloat(quality) / 100.0] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return mutableData as Data
    }

    /// ffprobe 探测:与 ffmpeg 同目录优先。
    static func detectFFprobe(ffmpeg: URL) -> URL? {
        let sameDirectory = ffmpeg.deletingLastPathComponent().appendingPathComponent("ffprobe")
        if FileManager.default.isExecutableFile(atPath: sameDirectory.path) { return sameDirectory }
        for candidate in ["/opt/homebrew/bin/ffprobe", "/usr/local/bin/ffprobe"] {
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return URL(fileURLWithPath: candidate)
            }
        }
        return nil
    }

    /// 读媒体时长(秒);失败返回 nil。
    static func duration(of url: URL, ffprobe: URL) async -> Double? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffprobe.path)
        process.arguments = ["-v", "error", "-show_entries", "format=duration",
                             "-of", "csv=p=0", url.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard let text = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            let seconds = Double(text), seconds > 0 else { return nil }
        return seconds
    }

    /// 视频按目标码率压制(音频固定 128k AAC)。
    static func videoWithBitrate(input: URL, output: URL, videoBitrate: Int,
                                 ffmpeg: URL, cancel: CancelToken? = nil) async throws {
        try await ProcessRunner.run(executablePath: ffmpeg.path,
                                    arguments: ["-y", "-i", input.path,
                                                "-b:v", "\(videoBitrate)",
                                                "-maxrate", "\(Int(Double(videoBitrate) * 1.45))",
                                                "-bufsize", "\(videoBitrate * 2)",
                                                "-c:a", "aac", "-b:a", "128k",
                                                output.path],
                                    timeout: 3600, cancel: cancel)
    }
}
