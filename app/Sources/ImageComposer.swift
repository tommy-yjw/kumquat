import AppKit
import CoreImage

// MARK: - 涂黑样式

enum RedactStyle: String, CaseIterable, Identifiable {
    case solid      // 实色
    case blur       // 高斯模糊
    case pixelate   // 像素化

    var id: String { rawValue }
    var title: String {
        switch self {
        case .solid: return "实色"
        case .blur: return "模糊"
        case .pixelate: return "像素化"
        }
    }
}

/// 一个涂黑区域:归一化矩形(y 向下)+ 样式。
struct RedactionRect: Identifiable {
    let id = UUID()
    var rect: CGRect
    var style: RedactStyle
}

// MARK: - 图片合成器(编辑器导出的纯渲染层,可独立测试)

enum ImageComposer {
    /// 把裁剪/涂黑(三种样式)/标注渲染到源图上,返回成品 CGImage。
    /// 所有归一化坐标均为 y 向下、左上原点。
    static func render(source: CGImage,
                       crop: CGRect?,
                       redactions: [RedactionRect],
                       annotations: [EditorAnnotation]) throws -> CGImage {
        let width = source.width, height = source.height
        let cropPixel = pixelRect(crop ?? CGRect(x: 0, y: 0, width: 1, height: 1),
                                  in: CGFloat(width), CGFloat(height))
        guard cropPixel.width >= 8, cropPixel.height >= 8 else {
            throw NSError(domain: "Kumquat.Composer", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "裁剪区域太小"])
        }

        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                         pixelsWide: Int(cropPixel.width), pixelsHigh: Int(cropPixel.height),
                                         bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0,
                                         bitsPerPixel: 0) else {
            throw NSError(domain: "Kumquat.Composer", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "无法创建画布"])
        }
        NSGraphicsContext.saveGraphicsState()
        let context = NSGraphicsContext(bitmapImageRep: rep)!
        NSGraphicsContext.current = context

        // 底图:源图 crop 区域 → 画布(NSImage 的 from 坐标系 y 向上)
        let base = NSImage(cgImage: source, size: NSSize(width: width, height: height))
        base.draw(in: NSRect(origin: .zero, size: cropPixel.size),
                  from: NSRect(x: cropPixel.minX,
                               y: CGFloat(height) - cropPixel.maxY,
                               width: cropPixel.width, height: cropPixel.height),
                  operation: .copy, fraction: 1.0)

        // 归一化(y 向下) → 画布本地坐标(y 向上)
        func local(_ normalized: CGRect) -> NSRect {
            let pixel = pixelRect(normalized, in: CGFloat(width), CGFloat(height))
            return NSRect(x: pixel.minX - cropPixel.minX,
                          y: cropPixel.height - (pixel.maxY - cropPixel.minY),
                          width: pixel.width, height: pixel.height)
        }
        func localPoint(_ normalized: CGPoint) -> NSPoint {
            let pixel = CGPoint(x: normalized.x * CGFloat(width), y: normalized.y * CGFloat(height))
            return NSPoint(x: pixel.x - cropPixel.minX, y: cropPixel.height - (pixel.y - cropPixel.minY))
        }

        // 涂黑区(三种样式)
        for redaction in redactions {
            let target = local(redaction.rect)
            switch redaction.style {
            case .solid:
                NSColor.black.setFill()
                target.fill()
            case .pixelate:
                try drawPixelated(source: source, sourceRect: redaction.rect,
                                  into: target, width: CGFloat(width), height: CGFloat(height))
            case .blur:
                try drawBlurred(source: source, sourceRect: redaction.rect,
                                into: target, width: CGFloat(width), height: CGFloat(height))
            }
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
                let normalizedRect = CGRect(x: min(annotation.from.x, annotation.to.x),
                                            y: min(annotation.from.y, annotation.to.y),
                                            width: abs(annotation.to.x - annotation.from.x),
                                            height: abs(annotation.to.y - annotation.from.y))
                let path = NSBezierPath(rect: local(normalizedRect).insetBy(dx: 1, dy: 1))
                path.lineWidth = max(2.5, fontSize * 0.12)
                NSColor.red.setStroke()
                path.stroke()
            case .text:
                guard let text = annotation.text, !text.isEmpty else { continue }
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: fontSize, weight: .semibold),
                    .foregroundColor: NSColor.red,
                    .strokeWidth: -2.0,
                    .strokeColor: NSColor.white,
                ]
                let string = NSAttributedString(string: text, attributes: attributes)
                let bounds = string.boundingRect(with: NSSize(width: CGFloat(width), height: .greatestFiniteMagnitude),
                                                 options: [.usesLineFragmentOrigin])
                let origin = localPoint(annotation.from)
                string.draw(in: NSRect(x: min(origin.x, cropPixel.width - bounds.width - 4),
                                       y: min(origin.y, cropPixel.height - bounds.height - 4),
                                       width: bounds.width, height: bounds.height))
            default:
                continue
            }
        }
        NSGraphicsContext.restoreGraphicsState()

        guard let composed = rep.cgImage else {
            throw NSError(domain: "Kumquat.Composer", code: 4,
                          userInfo: [NSLocalizedDescriptionKey: "合成失败"])
        }
        return composed
    }

    private static func pixelRect(_ normalized: CGRect, in width: CGFloat, _ height: CGFloat) -> CGRect {
        CGRect(x: normalized.minX * width, y: normalized.minY * height,
               width: normalized.width * width, height: normalized.height * height)
    }

    /// 像素化:源子区域降采样到最多 24px 宽,再以无插值放大回填。
    private static func drawPixelated(source: CGImage, sourceRect: CGRect,
                                      into target: NSRect, width: CGFloat, height: CGFloat) throws {
        let pixel = pixelRect(sourceRect, in: width, height)
        guard pixel.width >= 2, pixel.height >= 2,
              let cropped = source.cropping(to: CGRect(x: Int(pixel.minX),
                                                       y: Int(height - pixel.maxY),
                                                       width: Int(pixel.width),
                                                       height: Int(pixel.height))) else {
            throw NSError(domain: "Kumquat.Composer", code: 5,
                          userInfo: [NSLocalizedDescriptionKey: "像素化裁剪失败"])
        }
        let smallWidth = max(2, min(24, Int(pixel.width / 12)))
        let smallHeight = max(2, Int(round(CGFloat(smallWidth) / pixel.width * pixel.height)))
        guard let smallContext = CGContext(data: nil, width: smallWidth, height: smallHeight,
                                           bitsPerComponent: 8, bytesPerRow: 0,
                                           space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                           bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw NSError(domain: "Kumquat.Composer", code: 6,
                          userInfo: [NSLocalizedDescriptionKey: "像素化失败"])
        }
        smallContext.interpolationQuality = .low
        smallContext.draw(cropped, in: CGRect(x: 0, y: 0, width: smallWidth, height: smallHeight))
        guard let smallImage = smallContext.makeImage() else {
            throw NSError(domain: "Kumquat.Composer", code: 7,
                          userInfo: [NSLocalizedDescriptionKey: "像素化失败"])
        }
        let previousInterpolation = NSGraphicsContext.current?.imageInterpolation
        NSGraphicsContext.current?.imageInterpolation = .none
        NSImage(cgImage: smallImage, size: NSSize(width: smallWidth, height: smallHeight))
            .draw(in: target, from: NSRect(origin: .zero, size: NSSize(width: smallWidth, height: smallHeight)),
                  operation: .copy, fraction: 1.0)
        NSGraphicsContext.current?.imageInterpolation = previousInterpolation ?? .default
    }

    /// 高斯模糊:源区域外扩 3σ → CIClamp 防边缘发虚 → CIGaussianBlur →
    /// 把模糊图中"原区域"的子块贴回目标矩形。
    private static func drawBlurred(source: CGImage, sourceRect: CGRect,
                                    into target: NSRect, width: CGFloat, height: CGFloat) throws {
        let pixel = pixelRect(sourceRect, in: width, height)
        guard pixel.width >= 2, pixel.height >= 2 else { return }
        let sigma: CGFloat = 10
        let padding = sigma * 3
        let expanded = pixel.insetBy(dx: -padding, dy: -padding)
            .intersection(CGRect(x: 0, y: 0, width: width, height: height))
        guard expanded.width >= 2, expanded.height >= 2,
              let cropped = source.cropping(to: CGRect(x: Int(expanded.minX),
                                                       y: Int(height - expanded.maxY),
                                                       width: Int(expanded.width),
                                                       height: Int(expanded.height))) else {
            throw NSError(domain: "Kumquat.Composer", code: 8,
                          userInfo: [NSLocalizedDescriptionKey: "模糊裁剪失败"])
        }

        guard let clamp = CIFilter(name: "CIAffineClamp") else {
            throw NSError(domain: "Kumquat.Composer", code: 9,
                          userInfo: [NSLocalizedDescriptionKey: "CIFilter 不可用"])
        }
        let inputCIImage = CIImage(cgImage: cropped)
        clamp.setValue(inputCIImage, forKey: kCIInputImageKey)
        guard let filter = CIFilter(name: "CIGaussianBlur") else {
            throw NSError(domain: "Kumquat.Composer", code: 9,
                          userInfo: [NSLocalizedDescriptionKey: "CIFilter 不可用"])
        }
        filter.setValue(clamp.outputImage, forKey: kCIInputImageKey)
        filter.setValue(sigma, forKey: kCIInputRadiusKey)
        guard let output = filter.outputImage,
              let rendered = CIContext().createCGImage(output, from: inputCIImage.extent) else {
            throw NSError(domain: "Kumquat.Composer", code: 10,
                          userInfo: [NSLocalizedDescriptionKey: "模糊渲染失败"])
        }

        // 模糊图与 expanded 一一对应;原区域在其中的偏移(y 向下像素)
        let offsetX = pixel.minX - expanded.minX
        let offsetY = pixel.minY - expanded.minY
        // NSImage 的 from 坐标系 y 向上
        let from = NSRect(x: offsetX,
                          y: expanded.height - (offsetY + pixel.height),
                          width: pixel.width, height: pixel.height)
        NSImage(cgImage: rendered, size: NSSize(width: rendered.width, height: rendered.height))
            .draw(in: target, from: from, operation: .copy, fraction: 1.0)
    }
}
