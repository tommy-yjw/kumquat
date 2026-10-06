import AppKit
import PDFKit
import UniformTypeIdentifiers

// MARK: - 金桔自建测试执行器(CLT 无 XCTest;编译全部源码(除 app 入口)+ 本入口直接断言)
// 运行:./run-tests.sh;退出码非 0 = 有失败。

enum Check {
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
}

func testOutputNamer(_ directory: URL) {
    let source = directory.appendingPathComponent("photo.png")
    Check.that(OutputNamer.uniqueOutput(for: source, suffix: nil, fileExtension: "jpg")
        .lastPathComponent == "photo.jpg", "命名:格式转换 = 原名.新扩展名")
    Check.that(OutputNamer.uniqueOutput(for: source, suffix: "压缩", fileExtension: "jpg")
        .lastPathComponent == "photo 压缩.jpg", "命名:动作 = 原名 动作.扩展名")

    try? Data("x".utf8).write(to: directory.appendingPathComponent("photo.jpg"))
    Check.that(OutputNamer.uniqueOutput(for: source, suffix: nil, fileExtension: "jpg")
        .lastPathComponent == "photo 2.jpg", "命名:重名追加计数")
    try? FileManager.default.removeItem(at: directory.appendingPathComponent("photo.jpg"))
}

func testClassification() {
    func url(_ name: String) -> URL { URL(fileURLWithPath: "/tmp/\(name)") }
    Check.that(ActionCatalog.isImage(url("a.jpg")), "分类:jpg 是图片")
    Check.that(ActionCatalog.isImage(url("a.JPEG")), "分类:大写扩展名")
    Check.that(ActionCatalog.isPDF(url("a.pdf")), "分类:pdf")
    Check.that(ActionCatalog.isVideo(url("a.mov")), "分类:mov")
    Check.that(ActionCatalog.isAudio(url("a.m4a")), "分类:m4a")
    Check.that(!ActionCatalog.isImage(url("a.docx")), "分类:docx 非图片")
    Check.that(OfficeEngine.isOfficeDocument(url("report.docx")), "分类:docx 是 Office")
    Check.that(OfficeEngine.isOfficeDocument(url("报表.xlsx")), "分类:中文名 xlsx")
    Check.that(OfficeEngine.isOfficeDocument(url("deck.pptx")), "分类:pptx")
    Check.that(!OfficeEngine.isOfficeDocument(url("notes.md")), "分类:md 非 Office")
    Check.that(!OfficeEngine.isOfficeDocument(url("virus.exe")), "分类:exe 拒绝")
    Check.that(ActionCatalog.isArchiveExtract(url("bundle.zip")), "分类:zip 可解压")
    Check.that(ActionCatalog.isArchiveExtract(url("bundle.tar")), "分类:tar 可解压")
    Check.that(ActionCatalog.isArchiveExtract(url("bundle.tgz")), "分类:tgz 可解压")
    Check.that(!ActionCatalog.isArchiveExtract(url("bundle.rar")), "分类:rar 拒绝")
}

func testCatalog() {
    func url(_ name: String) -> URL { URL(fileURLWithPath: "/tmp/\(name)") }

    let singleImage = ActionCatalog.actions(
        for: [url("photo.png")],
        onRun: { _, _ in }, onTools: { _ in }, onEdit: { _ in }, onSizePanel: { _ in }
    )
    let ids = singleImage.map(\.id)
    Check.that(ids.contains("edit-image"), "目录:单图有编辑入口")
    Check.that(ids.contains("compress-image"), "目录:压缩")
    Check.that(ids.contains("strip-exif"), "目录:去EXIF")
    Check.that(ids.contains("create-zip"), "目录:压缩为ZIP")
    Check.that(ids.contains("open-tools"), "目录:工具轮盘入口")
    Check.that(!ids.contains("convert-image-png"), "目录:源已是png不重复出现")
    Check.that(ids.contains("convert-image-jpg"), "目录:转JPG")
    Check.that(singleImage.count <= 9, "目录:主轮盘扇区上限 9")

    let multipleImages = ActionCatalog.actions(
        for: [url("a.png"), url("b.png"), url("c.png")],
        onRun: { _, _ in }, onTools: { _ in }, onEdit: { _ in }, onSizePanel: { _ in }
    )
    Check.that(!multipleImages.map(\.id).contains("edit-image"), "目录:多图无单图编辑入口")

    let singlePDF = ActionCatalog.actions(
        for: [url("a.pdf")],
        onRun: { _, _ in }, onTools: { _ in }, onEdit: { _ in }, onSizePanel: { _ in }
    )
    Check.that(!singlePDF.map(\.id).contains("merge-pdf"), "目录:单PDF无合并")
    let doublePDF = ActionCatalog.actions(
        for: [url("a.pdf"), url("b.pdf")],
        onRun: { _, _ in }, onTools: { _ in }, onEdit: { _ in }, onSizePanel: { _ in }
    )
    Check.that(doublePDF.map(\.id).contains("merge-pdf"), "目录:双PDF有合并")

    if FFmpegEngine.detect() == nil {
        let video = ActionCatalog.actions(
            for: [url("clip.mov")],
            onRun: { _, _ in }, onTools: { _ in }, onEdit: { _ in }, onSizePanel: { _ in }
        )
        Check.that(!video.map(\.id).contains("convert-video-mp4"), "目录:无ffmpeg时视频动作隐藏")
    }
}

func testArchiveNaming() {
    Check.that(ArchiveEngine.uniqueExtractionDirectory(for: URL(fileURLWithPath: "/tmp/x/bundle.zip"))
        .lastPathComponent == "bundle 解压", "解压命名:zip")
    Check.that(ArchiveEngine.uniqueExtractionDirectory(for: URL(fileURLWithPath: "/tmp/x/bundle.tar.gz"))
        .lastPathComponent == "bundle 解压", "解压命名:tar.gz 去双扩展名")
}

func makePDF(directory: URL, name: String) throws -> URL {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let path = directory.appendingPathComponent(name)
    var box = CGRect(x: 0, y: 0, width: 400, height: 300)
    guard let consumer = CGDataConsumer(url: path as CFURL) else {
        throw NSError(domain: "Kumquat.Tests", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "无法创建 CGDataConsumer"])
    }
    guard let context = CGContext(consumer: consumer, mediaBox: &box, nil) else {
        throw NSError(domain: "Kumquat.Tests", code: 2,
                      userInfo: [NSLocalizedDescriptionKey: "无法创建 CGContext"])
    }
    context.beginPDFPage(nil)
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    context.fill(box)
    context.setStrokeColor(CGColor(gray: 0, alpha: 1))
    context.stroke(CGRect(x: 20, y: 20, width: 360, height: 260), width: 3)
    context.endPDFPage()
    context.closePDF()
    return path
}

func testPDFTools(_ directory: URL) throws {
    let a = try makePDF(directory: directory, name: "a.pdf")
    let b = try makePDF(directory: directory, name: "b.pdf")

    let merged = directory.appendingPathComponent("merged.pdf")
    try PDFToolsEngine.merge(inputs: [a, b], output: merged)
    Check.that(PDFDocument(url: merged)?.pageCount == 2, "PDF:合并页数")

    var lastPage = 0
    let pages = try PDFToolsEngine.split(input: merged) { index in
        lastPage = index
        return directory.appendingPathComponent("page-\(index).pdf")
    }
    Check.that(pages.count == 2, "PDF:拆分页数")
    Check.that(lastPage == 2, "PDF:拆分页码递增")
    Check.that(pages.allSatisfy { PDFDocument(url: $0)?.pageCount == 1 }, "PDF:拆分单页")

    let rotated = directory.appendingPathComponent("rot.pdf")
    try PDFToolsEngine.rotate(input: a, output: rotated, degrees: 90)
    Check.that(PDFDocument(url: rotated)?.page(at: 0)?.rotation == 90, "PDF:旋转90°")

    let pngs = try PDFToolsEngine.renderPNGs(input: a) { index in
        directory.appendingPathComponent("p\(index).png")
    }
    Check.that(pngs.count == 1
        && FileManager.default.fileExists(atPath: pngs[0].path), "PDF:导出PNG")

    let compressed = directory.appendingPathComponent("small.pdf")
    try PDFToolsEngine.compress(input: merged, output: compressed)
    let compressedSize = (try? FileManager.default.attributesOfItem(atPath: compressed.path)[.size] as? Int) ?? 0
    Check.that(compressedSize > 0, "PDF:位图化压缩产出")
}

// MARK: - 入口(测试主体整体在 MainActor 上跑:AppKit 友好,exit 干净)

func stage(_ name: String) {
    FileHandle.standardError.write(Data("▶️ \(name)\n".utf8))
}

@MainActor
func runAllTests() async {
    let testRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("kumquat-tests-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: testRoot, withIntermediateDirectories: true)
    for subdirectory in ["pdf"] {
        try? FileManager.default.createDirectory(at: testRoot.appendingPathComponent(subdirectory),
                                                 withIntermediateDirectories: true)
    }

    do {
    stage("OutputNamer")
    testOutputNamer(testRoot)
    stage("Classification")
    testClassification()
    stage("Catalog")
    testCatalog()
    stage("ArchiveNaming")
    testArchiveNaming()
    stage("PDFTools")
    try testPDFTools(testRoot.appendingPathComponent("pdf"))
    } catch {
        Check.failed.append("测试执行异常:\(error.localizedDescription)")
        FileHandle.standardError.write(Data("💥 测试执行异常:\(error)\n".utf8))
    }

    FileHandle.standardError.write(Data("—— 测试结果:通过 \(Check.passed),失败 \(Check.failed.count) ——\n".utf8))
    if !Check.failed.isEmpty {
        exit(1)
    }
    try? FileManager.default.removeItem(at: testRoot)
    exit(0)
}

// top-level 入口:先在主 actor 上跑完全部测试
await runAllTests()
