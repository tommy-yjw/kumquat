import SwiftUI

// MARK: - 各格式的配色(菜单扇区)

extension ImageFormat {
    var accentColor: Color {
        switch self {
        case .jpg: .orange
        case .png: .blue
        case .heic: .purple
        case .tiff: .teal
        }
    }
}

extension VideoFormat {
    var accentColor: Color { self == .gif ? .mint : .pink }
    var systemImage: String { self == .gif ? "photo.stack.fill" : "video.fill" }
}

extension AudioFormat {
    var accentColor: Color { .cyan }
    var systemImage: String { "music.note" }
}

// MARK: - 动作清单

/// 依据拖入文件构建径向菜单动作(v2):
/// - 图片:格式互转(+WebP 探测到才出现)+ 压缩 + 去 EXIF;工具轮盘:旋转/翻转/缩放/灰度/拼贴;
/// - 视频/音频:ffmpeg 检测到才出现,含变速/抽帧;
/// - PDF:合并/拆分/压缩/转图片/旋转(PDFKit);
/// - 文档:pandoc(检测到才出现)+ textutil(.doc 兜底);
/// - 任意选择都可"压缩为 ZIP";归档文件出现"解压"。
/// 扇区过多时,低优先动作自动移入工具轮盘(每轮 ≤9 项,保证可读)。
enum ActionCatalog {
    static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "heic", "heics",
                                               "tif", "tiff", "gif", "bmp", "webp", "avif", "jp2"]
    static let videoExtensions: Set<String> = ["mov", "mp4", "m4v", "mkv", "webm", "avi", "wmv", "ts", "mts"]
    static let audioExtensions: Set<String> = ["mp3", "m4a", "wav", "flac", "aac", "ogg", "oga",
                                               "opus", "aiff", "aif", "wma"]
    static let pdfExtensions: Set<String> = ["pdf"]
    static let archiveExtractExtensions: Set<String> = ["zip", "tar", "tgz"]
    static let docExtensions: Set<String> = ["md", "markdown", "txt", "html", "htm", "rtf",
                                             "doc", "docx", "odt", "epub", "rst", "org", "tex"]

    static func isImage(_ url: URL) -> Bool { imageExtensions.contains(url.lowercasedExtension) }
    static func isVideo(_ url: URL) -> Bool { videoExtensions.contains(url.lowercasedExtension) }
    static func isAudio(_ url: URL) -> Bool { audioExtensions.contains(url.lowercasedExtension) }
    static func isPDF(_ url: URL) -> Bool { pdfExtensions.contains(url.lowercasedExtension) }
    static func isDoc(_ url: URL) -> Bool { docExtensions.contains(url.lowercasedExtension) }
    static func isArchiveExtract(_ url: URL) -> Bool {
        guard archiveExtractExtensions.contains(url.lowercasedExtension) else { return false }
        return true
    }
    static func isSupportedMedia(_ url: URL) -> Bool {
        isImage(url) || isVideo(url) || isAudio(url) || isPDF(url) || isDoc(url)
            || isArchiveExtract(url) || OfficeEngine.isOfficeDocument(url) || url.hasDirectoryPath
    }

    // MARK: 主轮盘

    /// 生成主菜单动作。onRun 由上层注入(启动 JobRunner 并负责完成通知);
    /// onTools 由上层注入(打开工具轮盘)。
    static func actions(for files: [URL],
                        onRun: @escaping (ActionKind, [URL]) -> Void,
                        onTools: @escaping ([URL]) -> Void,
                        onEdit: @escaping (EditorRequest) -> Void) -> [MenuAction] {
        var primary: [MenuAction] = []
        var tools: [MenuAction] = []
        let images = files.filter(isImage)
        let videos = files.filter(isVideo)
        let audios = files.filter(isAudio)
        let pdfs = files.filter(isPDF)
        let docs = files.filter(isDoc)
        let archives = files.filter(isArchiveExtract)

        // 图片
        if images.count == 1 {
            primary.append(MenuAction(
                id: "edit-image", title: "编辑…", systemImage: "pencil.and.outline",
                accent: .orange, files: images,
                perform: { onEdit(EditorRequest(urls: images, mode: .image)) }
            ))
        }
        if !images.isEmpty {
            for format in ImageFormat.allCases
            where images.contains(where: { !format.equivalentExtensions.contains($0.lowercasedExtension) }) {
                primary.append(MenuAction(
                    id: "convert-image-\(format.rawValue)",
                    title: format.title,
                    systemImage: "photo.fill",
                    accent: format.accentColor,
                    files: images,
                    perform: { onRun(.convertImage(format), images) }
                ))
            }
            if ImageIOCapability.canWriteWebP,
               images.contains(where: { $0.lowercasedExtension != "webp" }) {
                primary.append(MenuAction(
                    id: "convert-image-webp", title: "转为 WEBP",
                    systemImage: "photo.fill", accent: .green,
                    files: images, perform: { onRun(.convertImageWebP, images) }
                ))
            }
            primary.append(MenuAction(
                id: "compress-image", title: "压缩",
                systemImage: "arrow.down.doc.fill", accent: .indigo,
                files: images, perform: { onRun(.compressImage, images) }
            ))
            primary.append(MenuAction(
                id: "strip-exif", title: "去 EXIF",
                systemImage: "eye.slash.fill", accent: .red,
                files: images, perform: { onRun(.stripExif, images) }
            ))
            // 图片工具 → 工具轮盘
            tools.append(contentsOf: [
                MenuAction(id: "rotate-image-cw", title: "顺时针90°", systemImage: "rotate.right.fill",
                           accent: .orange, files: images, perform: { onRun(.rotateImage(90), images) }),
                MenuAction(id: "rotate-image-ccw", title: "逆时针90°", systemImage: "rotate.left.fill",
                           accent: .orange, files: images, perform: { onRun(.rotateImage(-90), images) }),
                MenuAction(id: "flip-image-h", title: "水平翻转", systemImage: "arrow.left.and.right.righttriangle.left.righttriangle.right.fill",
                           accent: .orange, files: images, perform: { onRun(.flipImage("horizontal"), images) }),
                MenuAction(id: "flip-image-v", title: "垂直翻转", systemImage: "arrow.up.and.down.righttriangle.left.fill.righttriangle.right.fill",
                           accent: .orange, files: images, perform: { onRun(.flipImage("vertical"), images) }),
                MenuAction(id: "scale-image-1920", title: "长边1920", systemImage: "arrow.down.right.and.arrow.up.left",
                           accent: .orange, files: images, perform: { onRun(.scaleImageLongest(1920), images) }),
                MenuAction(id: "scale-image-50", title: "缩放50%", systemImage: "minus.magnifyingglass",
                           accent: .orange, files: images, perform: { onRun(.scaleImagePercent(50), images) }),
                MenuAction(id: "grayscale-image", title: "灰度", systemImage: "circle.lefthalf.filled",
                           accent: .gray, files: images, perform: { onRun(.grayscaleImage, images) }),
            ])
            if images.count >= 2 {
                tools.append(MenuAction(
                    id: "collage-images", title: "拼贴", systemImage: "square.grid.2x2.fill",
                    accent: .orange, files: images, perform: { onRun(.collageImages, images) }
                ))
            }
            if pdfs.isEmpty {
                tools.append(MenuAction(
                    id: "images-to-pdf", title: "合成PDF", systemImage: "doc.richtext.fill",
                    accent: .red, files: images, perform: { onRun(.imagesToPDF, images) }
                ))
            }
        }

        // 视频/音频(ffmpeg 缺席时整体隐藏)
        if FFmpegEngine.detect() != nil {
            if videos.count == 1 {
                primary.append(MenuAction(
                    id: "trim-video", title: "剪短…", systemImage: "timeline.selection",
                    accent: .pink, files: videos,
                    perform: { onEdit(EditorRequest(urls: videos, mode: .trimVideo)) }
                ))
            }
            if !videos.isEmpty {
                for format in VideoFormat.allCases
                where videos.contains(where: { $0.lowercasedExtension != format.rawValue }) {
                    primary.append(MenuAction(
                        id: "convert-video-\(format.rawValue)",
                        title: format.title,
                        systemImage: format.systemImage,
                        accent: format.accentColor,
                        files: videos,
                        perform: { onRun(.convertVideo(format), videos) }
                    ))
                }
                for format in [AudioFormat.mp3, .m4a] {
                    primary.append(MenuAction(
                        id: "extract-audio-\(format.rawValue)",
                        title: "提取 \(format.rawValue.uppercased())",
                        systemImage: format.systemImage,
                        accent: .green,
                        files: videos,
                        perform: { onRun(.extractAudio(format), videos) }
                    ))
                }
                tools.append(contentsOf: [
                    MenuAction(id: "speed-video-05", title: "变速0.5×", systemImage: "gauge.with.dots.needle.bottom.0percent",
                               accent: .pink, files: videos, perform: { onRun(.speedVideo(0.5), videos) }),
                    MenuAction(id: "speed-video-15", title: "变速1.5×", systemImage: "gauge.with.dots.needle.33percent",
                               accent: .pink, files: videos, perform: { onRun(.speedVideo(1.5), videos) }),
                    MenuAction(id: "speed-video-2", title: "变速2×", systemImage: "gauge.with.dots.needle.67percent",
                               accent: .pink, files: videos, perform: { onRun(.speedVideo(2), videos) }),
                    MenuAction(id: "extract-frame", title: "抽帧PNG", systemImage: "camera.viewfinder",
                               accent: .pink, files: videos, perform: { onRun(.extractVideoFrame, videos) }),
                ])
            }
            if !audios.isEmpty {
                for format in AudioFormat.allCases
                where audios.contains(where: { $0.lowercasedExtension != format.rawValue }) {
                    primary.append(MenuAction(
                        id: "convert-audio-\(format.rawValue)",
                        title: format.title,
                        systemImage: format.systemImage,
                        accent: format.accentColor,
                        files: audios,
                        perform: { onRun(.convertAudio(format), audios) }
                    ))
                }
            }
        }

        // PDF
        if !pdfs.isEmpty {
            if pdfs.count >= 2 {
                primary.append(MenuAction(
                    id: "merge-pdf", title: "合并PDF", systemImage: "doc.on.doc.fill",
                    accent: .red, files: pdfs, perform: { onRun(.mergePDF, pdfs) }
                ))
            }
            primary.append(MenuAction(
                id: "split-pdf", title: "拆分PDF", systemImage: "doc.text.magnifyingglass",
                accent: .red, files: pdfs, perform: { onRun(.splitPDF, pdfs) }
            ))
            primary.append(MenuAction(
                id: "compress-pdf", title: "压缩PDF", systemImage: "arrow.down.doc.fill",
                accent: .red, files: pdfs, perform: { onRun(.compressPDF, pdfs) }
            ))
            primary.append(MenuAction(
                id: "pdf-to-png", title: "转为图片", systemImage: "photo.on.rectangle.angled",
                accent: .red, files: pdfs, perform: { onRun(.pdfToPNG, pdfs) }
            ))
            tools.append(contentsOf: [
                MenuAction(id: "rotate-pdf-cw", title: "顺时针90°", systemImage: "rotate.right.fill",
                           accent: .red, files: pdfs, perform: { onRun(.rotatePDF(90), pdfs) }),
                MenuAction(id: "rotate-pdf-ccw", title: "逆时针90°", systemImage: "rotate.left.fill",
                           accent: .red, files: pdfs, perform: { onRun(.rotatePDF(-90), pdfs) }),
            ])
            if !images.isEmpty {
                // 混选拖入图片+PDF 时,图片也可以进 PDF
                primary.append(MenuAction(
                    id: "images-to-pdf-mixed", title: "图片合成PDF", systemImage: "doc.richtext.fill",
                    accent: .red, files: images, perform: { onRun(.imagesToPDF, images) }
                ))
            }
        }

        // Office 文档(LibreOffice 检测到才出现)
        let offices = files.filter(OfficeEngine.isOfficeDocument)
        if !offices.isEmpty, OfficeEngine.detect() != nil {
            primary.append(MenuAction(
                id: "convert-office-pdf", title: "转为 PDF", systemImage: "doc.badge.gearshape.fill",
                accent: .brown, files: offices,
                perform: { onRun(.convertOfficePDF, offices) }
            ))
        }

        // 文档
        if !docs.isEmpty {
            if let _ = PandocEngine.detect() {
                for target in PandocTarget.allCases
                where docs.contains(where: { !target.equivalentExtensions.contains($0.lowercasedExtension) }) {
                    primary.append(MenuAction(
                        id: "convert-doc-\(target.rawValue)",
                        title: target.title,
                        systemImage: "doc.badge.arrowup",
                        accent: .brown,
                        files: docs,
                        perform: { onRun(.convertDocPandoc(target), docs) }
                    ))
                }
            }
            // .doc 老 Word:pandoc 读不了,用系统 textutil 兜底
            let legacyDocs = docs.filter { $0.lowercasedExtension == "doc" }
            for format in ["docx", "rtf", "html", "txt"]
            where !legacyDocs.isEmpty && !legacyDocs.contains(where: { $0.lowercasedExtension == format }) {
                primary.append(MenuAction(
                    id: "convert-doc-textutil-\(format)",
                    title: "转为 \(format.uppercased())",
                    systemImage: "doc.badge.arrowup",
                    accent: .brown,
                    files: legacyDocs,
                    perform: { onRun(.convertDocTextUtil(format), legacyDocs) }
                ))
            }
        }

        // 归档:任何选择都能压 zip;归档文件能解压
        if !archives.isEmpty {
            primary.append(MenuAction(
                id: "extract-archive", title: "解压", systemImage: "archivebox.open.fill",
                accent: .mint, files: archives,
                perform: { onRun(ActionCatalog.extractArchive(archives), archives) }
            ))
        }
        primary.append(MenuAction(
            id: "create-zip", title: "压缩为ZIP", systemImage: "doc.zipper",
            accent: .mint, files: files, perform: { onRun(.createZip, files) }
        ))

        // 扇区上限:主轮盘最多 9 项,溢出移入工具轮盘
        while primary.count > 8 {
            tools.insert(primary.removeLast(), at: 0)
        }
        if !tools.isEmpty {
            primary.append(MenuAction(
                id: "open-tools", title: "工具…", systemImage: "wrench.and.screwdriver.fill",
                accent: .gray, files: files, perform: { onTools(files) }
            ))
        }
        return primary
    }

    // MARK: 工具轮盘

    /// 依据文件类型给出工具轮盘动作(与主轮盘的"工具…"配套)。
    static func toolActions(for files: [URL],
                            onRun: @escaping (ActionKind, [URL]) -> Void) -> [MenuAction] {
        var tools: [MenuAction] = []
        let images = files.filter(isImage)
        let videos = files.filter(isVideo)
        let pdfs = files.filter(isPDF)

        if !images.isEmpty {
            tools.append(contentsOf: [
                MenuAction(id: "tool-rotate-image-cw", title: "顺时针90°", systemImage: "rotate.right.fill",
                           accent: .orange, files: images, perform: { onRun(.rotateImage(90), images) }),
                MenuAction(id: "tool-rotate-image-ccw", title: "逆时针90°", systemImage: "rotate.left.fill",
                           accent: .orange, files: images, perform: { onRun(.rotateImage(-90), images) }),
                MenuAction(id: "tool-flip-image-h", title: "水平翻转", systemImage: "arrow.left.and.right.righttriangle.left.righttriangle.right.fill",
                           accent: .orange, files: images, perform: { onRun(.flipImage("horizontal"), images) }),
                MenuAction(id: "tool-flip-image-v", title: "垂直翻转", systemImage: "arrow.up.and.down.righttriangle.left.fill.righttriangle.right.fill",
                           accent: .orange, files: images, perform: { onRun(.flipImage("vertical"), images) }),
                MenuAction(id: "tool-scale-image-1920", title: "长边1920", systemImage: "arrow.down.right.and.arrow.up.left",
                           accent: .orange, files: images, perform: { onRun(.scaleImageLongest(1920), images) }),
                MenuAction(id: "tool-scale-image-50", title: "缩放50%", systemImage: "minus.magnifyingglass",
                           accent: .orange, files: images, perform: { onRun(.scaleImagePercent(50), images) }),
                MenuAction(id: "tool-grayscale-image", title: "灰度", systemImage: "circle.lefthalf.filled",
                           accent: .gray, files: images, perform: { onRun(.grayscaleImage, images) }),
            ])
            if images.count >= 2 {
                tools.append(MenuAction(
                    id: "tool-collage-images", title: "拼贴", systemImage: "square.grid.2x2.fill",
                    accent: .orange, files: images, perform: { onRun(.collageImages, images) }
                ))
            }
        }
        if !pdfs.isEmpty {
            tools.append(contentsOf: [
                MenuAction(id: "tool-rotate-pdf-cw", title: "顺时针90°", systemImage: "rotate.right.fill",
                           accent: .red, files: pdfs, perform: { onRun(.rotatePDF(90), pdfs) }),
                MenuAction(id: "tool-rotate-pdf-ccw", title: "逆时针90°", systemImage: "rotate.left.fill",
                           accent: .red, files: pdfs, perform: { onRun(.rotatePDF(-90), pdfs) }),
            ])
        }
        if FFmpegEngine.detect() != nil, !videos.isEmpty {
            tools.append(contentsOf: [
                MenuAction(id: "tool-speed-video-05", title: "变速0.5×", systemImage: "gauge.with.dots.needle.bottom.0percent",
                           accent: .pink, files: videos, perform: { onRun(.speedVideo(0.5), videos) }),
                MenuAction(id: "tool-speed-video-15", title: "变速1.5×", systemImage: "gauge.with.dots.needle.33percent",
                           accent: .pink, files: videos, perform: { onRun(.speedVideo(1.5), videos) }),
                MenuAction(id: "tool-speed-video-2", title: "变速2×", systemImage: "gauge.with.dots.needle.67percent",
                           accent: .pink, files: videos, perform: { onRun(.speedVideo(2), videos) }),
                MenuAction(id: "tool-extract-frame", title: "抽帧PNG", systemImage: "camera.viewfinder",
                           accent: .pink, files: videos, perform: { onRun(.extractVideoFrame, videos) }),
            ])
        }
        return tools
    }
}

// MARK: - 解压动作桥接

extension ActionCatalog {
    /// extractArchive 是唯一"按扩展名分派"的动作(zip vs tar),故单独建模。
    static func extractArchive(_ files: [URL]) -> ActionKind {
        let url = files.first ?? URL(fileURLWithPath: "/")
        return url.lowercasedExtension == "zip" ? .extractZip : .extractTar
    }
}
