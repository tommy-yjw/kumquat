import AppKit
import CoreGraphics
import PDFKit
import UniformTypeIdentifiers

// MARK: - PDF 工具引擎(PDFKit + CoreGraphics,系统框架零依赖)

enum PDFToolsEngine {
    /// 合并多个 PDF:按传入顺序串接所有页。
    static func merge(inputs: [URL], output: URL) throws {
        let merged = PDFDocument()
        var pageIndex = 0
        for url in inputs {
            guard let document = PDFDocument(url: url) else {
                throw NSError(domain: "Kumquat.PDF", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "无法读取 \(url.lastPathComponent)"])
            }
            for pageNumber in 0..<document.pageCount {
                if let page = document.page(at: pageNumber) {
                    merged.insert(page, at: pageIndex)
                    pageIndex += 1
                }
            }
        }
        guard pageIndex > 0, merged.write(to: output) else {
            throw NSError(domain: "Kumquat.PDF", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "合并写出失败"])
        }
    }

    /// 拆分:每页一个 PDF,命名"原名 页N.pdf"。
    static func split(input: URL, outputNamer: (Int) -> URL) throws -> [URL] {
        guard let document = PDFDocument(url: input) else {
            throw NSError(domain: "Kumquat.PDF", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "无法读取 \(input.lastPathComponent)"])
        }
        var outputs: [URL] = []
        for pageNumber in 0..<document.pageCount {
            guard let page = document.page(at: pageNumber) else { continue }
            let single = PDFDocument()
            single.insert(page.copy() as! PDFPage, at: 0)
            let output = outputNamer(pageNumber + 1)
            guard single.write(to: output) else {
                throw NSError(domain: "Kumquat.PDF", code: 3,
                              userInfo: [NSLocalizedDescriptionKey: "写出失败 \(output.lastPathComponent)"])
            }
            outputs.append(output)
        }
        guard !outputs.isEmpty else {
            throw NSError(domain: "Kumquat.PDF", code: 4,
                          userInfo: [NSLocalizedDescriptionKey: "没有可拆分的页"])
        }
        return outputs
    }

    /// 压缩:逐页位图化(150dpi)后重写 PDF。对扫描件/截图类内容压缩明显;
    /// 纯矢量文本页会被转成位图(诚实标注:压缩有损)。
    static func compress(input: URL, output: URL, dpi: CGFloat = 150) throws {
        guard let document = PDFDocument(url: input) else {
            throw NSError(domain: "Kumquat.PDF", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "无法读取 \(input.lastPathComponent)"])
        }
        guard let consumer = CGDataConsumer(url: output as CFURL) else {
            throw NSError(domain: "Kumquat.PDF", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "无法写出 \(output.lastPathComponent)"])
        }
        var mediaBox = document.page(at: 0)?.bounds(for: .mediaBox) ?? CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw NSError(domain: "Kumquat.PDF", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "无法创建 PDF 上下文"])
        }
        let scale = dpi / 72
        for pageNumber in 0..<document.pageCount {
            guard let page = document.page(at: pageNumber) else { continue }
            let box = page.bounds(for: .mediaBox)
            let pixelWidth = max(1, Int(box.width * scale))
            let pixelHeight = max(1, Int(box.height * scale))
            guard let bitmap = CGContext(data: nil, width: pixelWidth, height: pixelHeight,
                                         bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { continue }
            bitmap.setFillColor(CGColor(gray: 1.0, alpha: 1.0))
            bitmap.fill(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
            bitmap.saveGState()
            bitmap.translateBy(x: 0, y: CGFloat(pixelHeight))
            bitmap.scaleBy(x: scale, y: -scale)
            if let pdfPage = page.pageRef {
                bitmap.drawPDFPage(pdfPage)
            }
            bitmap.restoreGState()
            guard let rasterized = bitmap.makeImage() else { continue }
            context.beginPDFPage([kCGPDFContextMediaBox: NSValue(rect: box)] as CFDictionary)
            context.draw(rasterized, in: CGRect(origin: .zero, size: box.size))
            context.endPDFPage()
        }
        context.closePDF()
    }

    /// 整体旋转 ±90°(PDFPage.rotation 可写,度数为 90 的倍数)。
    static func rotate(input: URL, output: URL, degrees: Int) throws {
        guard let document = PDFDocument(url: input) else {
            throw NSError(domain: "Kumquat.PDF", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "无法读取 \(input.lastPathComponent)"])
        }
        for pageNumber in 0..<document.pageCount {
            if let page = document.page(at: pageNumber) {
                page.rotation = ((page.rotation + degrees) % 360 + 360) % 360
            }
        }
        guard document.write(to: output) else {
            throw NSError(domain: "Kumquat.PDF", code: 5,
                          userInfo: [NSLocalizedDescriptionKey: "写出失败 \(output.lastPathComponent)"])
        }
    }

    /// 导出为 PNG:每页 2×(144dpi) 位图,命名"原名 页N.png"。
    static func renderPNGs(input: URL, outputNamer: (Int) -> URL) throws -> [URL] {
        guard let document = PDFDocument(url: input) else {
            throw NSError(domain: "Kumquat.PDF", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "无法读取 \(input.lastPathComponent)"])
        }
        var outputs: [URL] = []
        let scale: CGFloat = 2
        for pageNumber in 0..<document.pageCount {
            guard let page = document.page(at: pageNumber) else { continue }
            let box = page.bounds(for: .mediaBox)
            let pixelWidth = max(1, Int(box.width * scale))
            let pixelHeight = max(1, Int(box.height * scale))
            guard let bitmap = CGContext(data: nil, width: pixelWidth, height: pixelHeight,
                                         bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { continue }
            bitmap.setFillColor(CGColor(gray: 1.0, alpha: 1.0))
            bitmap.fill(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
            bitmap.saveGState()
            bitmap.translateBy(x: 0, y: CGFloat(pixelHeight))
            bitmap.scaleBy(x: scale, y: -scale)
            if let pdfPage = page.pageRef {
                bitmap.drawPDFPage(pdfPage)
            }
            bitmap.restoreGState()
            guard let image = bitmap.makeImage(),
                  let destination = CGImageDestinationCreateWithURL(outputNamer(pageNumber + 1) as CFURL,
                                                                    UTType.png.identifier as CFString, 1, nil) else { continue }
            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination) else { continue }
            outputs.append(outputNamer(pageNumber + 1))
        }
        guard !outputs.isEmpty else {
            throw NSError(domain: "Kumquat.PDF", code: 6,
                          userInfo: [NSLocalizedDescriptionKey: "没有导出任何页"])
        }
        return outputs
    }

    /// 图片合成 PDF:每张图一页(页尺寸=图片像素尺寸,96dpi 语义)。
    static func imagesToPDF(inputs: [URL], output: URL) throws {
        let document = PDFDocument()
        for url in inputs {
            guard let image = NSImage(contentsOf: url),
                  let page = PDFPage(image: image) else { continue }
            document.insert(page, at: document.pageCount)
        }
        guard document.pageCount > 0, document.write(to: output) else {
            throw NSError(domain: "Kumquat.PDF", code: 7,
                          userInfo: [NSLocalizedDescriptionKey: "合成 PDF 失败"])
        }
    }
}
