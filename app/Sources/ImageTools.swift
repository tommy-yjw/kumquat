import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// MARK: - ImageIO 能力探测(运行时,不写死)

enum ImageIOCapability {
    /// 本机 ImageIO 能否编码 WebP(sips 只读不可写,reverse-report §5.2 已实测;
    /// macOS 较新版本的 ImageIO 可以,探测到才在菜单出现"转为 WebP")。
    static let canWriteWebP: Bool = {
        guard let identifiers = CGImageDestinationCopyTypeIdentifiers() as? [String] else {
            return false
        }
        return identifiers.contains(UTType.webP.identifier)
    }()
}

// MARK: - ImageIO 引擎(WebP 输出 + 属性读取)

enum ImageIOEngine {
    /// 解码后按目标类型重写(与去 EXIF 同一条 ImageIO 路径)。
    static func convert(input: URL, output: URL, type: UTType, quality: Double) throws {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(input as CFURL, options),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw NSError(domain: "Kumquat.ImageIO", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "无法读取图像 \(input.lastPathComponent)"])
        }
        guard let destination = CGImageDestinationCreateWithURL(output as CFURL, type.identifier as CFString, 1, nil) else {
            throw NSError(domain: "Kumquat.ImageIO", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "无法写出 \(output.lastPathComponent)"])
        }
        CGImageDestinationAddImage(destination, image,
                                   [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw NSError(domain: "Kumquat.ImageIO", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "写出失败 \(output.lastPathComponent)"])
        }
    }

    static func pixelSize(of url: URL) -> (width: Int, height: Int)? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, options),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, options) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return (width, height)
    }

    static func hasAnyAlpha(_ urls: [URL]) -> Bool {
        for url in urls {
            let options = [kCGImageSourceShouldCache: false] as CFDictionary
            guard let source = CGImageSourceCreateWithURL(url as CFURL, options),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { continue }
            switch image.alphaInfo {
            case .none, .noneSkipFirst, .noneSkipLast:
                continue
            default:
                return true
            }
        }
        return false
    }
}

// MARK: - 图片工具引擎(sips 系统能力 + CoreGraphics 拼贴)

enum ImageToolsEngine {
    static let sips = SipsEngine.executablePath
    /// 系统灰度 ICC Profile(matchTo 转灰度的标准路径)
    static let grayProfilePath = "/System/Library/ColorSync/Profiles/Generic Gray Profile.icc"

    /// 旋转:sips -r 度数(正值顺时针)
    static func rotate(input: URL, output: URL, degrees: Int) async throws {
        try await ProcessRunner.run(executablePath: sips,
                                    arguments: ["-r", "\(degrees)", input.path, "--out", output.path],
                                    timeout: 180)
    }

    /// 翻转:sips -f horizontal|vertical
    static func flip(input: URL, output: URL, direction: String) async throws {
        try await ProcessRunner.run(executablePath: sips,
                                    arguments: ["-f", direction, input.path, "--out", output.path],
                                    timeout: 180)
    }

    /// 等比缩放:长边压到指定像素(竖图压高)
    static func resampleLongestSide(input: URL, output: URL, longestSide: Int) async throws {
        guard let size = ImageIOEngine.pixelSize(of: input) else {
            throw NSError(domain: "Kumquat.ImageTools", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "无法读取尺寸 \(input.lastPathComponent)"])
        }
        let key = size.width >= size.height ? "--resampleWidth" : "--resampleHeight"
        try await ProcessRunner.run(executablePath: sips,
                                    arguments: [key, "\(longestSide)", input.path, "--out", output.path],
                                    timeout: 180)
    }

    /// 等比缩放:按百分比
    static func resamplePercent(input: URL, output: URL, percent: Int) async throws {
        guard let size = ImageIOEngine.pixelSize(of: input) else {
            throw NSError(domain: "Kumquat.ImageTools", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "无法读取尺寸 \(input.lastPathComponent)"])
        }
        let key = size.width >= size.height ? "--resampleWidth" : "--resampleHeight"
        let value = max(1, Int((max(size.width, size.height) * percent) / 100))
        try await ProcessRunner.run(executablePath: sips,
                                    arguments: [key, "\(value)", input.path, "--out", output.path],
                                    timeout: 180)
    }

    /// 灰度:matchTo 系统 Gray Profile
    static func grayscale(input: URL, output: URL) async throws {
        try await ProcessRunner.run(executablePath: sips,
                                    arguments: ["--matchTo", grayProfilePath, input.path, "--out", output.path],
                                    timeout: 180)
    }

    /// 拼贴:2 张横排;3-4 张 2×2;5-6 张 3×2;7-9 张 3×3(取前 9)。
    /// 单元格 720px,aspect-fill 居中裁切;任一源带透明 → PNG,否则 JPEG(q0.9)。
    static func collage(inputs: [URL], output: URL) throws {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        var images: [CGImage] = []
        for url in inputs.prefix(9) {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, options),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { continue }
            images.append(image)
        }
        guard !images.isEmpty else {
            throw NSError(domain: "Kumquat.ImageTools", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "没有可解码的图片"])
        }
        let count = images.count
        let columns = count <= 2 ? count : (count <= 4 ? 2 : 3)
        let rows = Int(ceil(Double(count) / Double(columns)))
        let cell = 720
        let width = cell * columns
        let height = cell * rows

        guard let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw NSError(domain: "Kumquat.ImageTools", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "无法创建画布"])
        }
        // 透明才保留底;否则铺白底(避免 JPEG 变黑)
        if ImageIOEngine.hasAnyAlpha(inputs) {
            context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        } else {
            context.setFillColor(CGColor(gray: 1.0, alpha: 1.0))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        for (index, image) in images.enumerated() {
            let column = index % columns
            let row = index / columns
            // 行 0 在顶部:CGContext 原点在左下,翻转 y
            let rect = CGRect(x: CGFloat(column) * CGFloat(cell),
                              y: CGFloat(height) - CGFloat(row + 1) * CGFloat(cell),
                              width: CGFloat(cell), height: CGFloat(cell))
            let scale = max(rect.width / CGFloat(image.width), rect.height / CGFloat(image.height))
            let drawWidth = CGFloat(image.width) * scale
            let drawHeight = CGFloat(image.height) * scale
            context.saveGState()
            context.clip(to: rect)
            context.draw(image, in: CGRect(x: rect.midX - drawWidth / 2,
                                           y: rect.midY - drawHeight / 2,
                                           width: drawWidth, height: drawHeight))
            context.restoreGState()
        }
        guard let composed = context.makeImage() else {
            throw NSError(domain: "Kumquat.ImageTools", code: 4,
                          userInfo: [NSLocalizedDescriptionKey: "拼贴合成失败"])
        }
        let type: UTType = ImageIOEngine.hasAnyAlpha(inputs) ? .png : .jpeg
        guard let destination = CGImageDestinationCreateWithURL(output as CFURL, type.identifier as CFString, 1, nil) else {
            throw NSError(domain: "Kumquat.ImageTools", code: 5,
                          userInfo: [NSLocalizedDescriptionKey: "无法写出 \(output.lastPathComponent)"])
        }
        CGImageDestinationAddImage(destination, composed,
                                   [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw NSError(domain: "Kumquat.ImageTools", code: 6,
                          userInfo: [NSLocalizedDescriptionKey: "写出失败 \(output.lastPathComponent)"])
        }
    }
}
