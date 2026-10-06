import Foundation

// MARK: - Office 引擎(LibreOffice 无头转换,docx/xlsx/pptx → PDF)

enum OfficeEngine {
    static let officeExtensions: Set<String> = ["doc", "docx", "xls", "xlsx", "ppt", "pptx", "odt"]

    static func isOfficeDocument(_ url: URL) -> Bool {
        officeExtensions.contains(url.lowercasedExtension)
    }

    /// 探测顺序:bundle 内 → Homebrew → /Applications/LibreOffice.app → /usr/local/bin → $PATH。
    static func detect() -> URL? {
        var candidates: [String] = []
        if let bundleDirectory = Bundle.main.executableURL?.deletingLastPathComponent().path {
            candidates.append(bundleDirectory + "/soffice")
        }
        candidates.append(contentsOf: [
            "/opt/homebrew/bin/soffice",
            "/Applications/LibreOffice.app/Contents/MacOS/soffice",
            "/usr/local/bin/soffice",
        ])
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            candidates.append(contentsOf: path.split(separator: ":").map { "\($0)/soffice" })
        }
        for candidate in candidates {
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return URL(fileURLWithPath: candidate)
            }
        }
        return nil
    }

    /// 无头转 PDF。LibreOffice 是单实例锁:并发/与用户手开的 LibreOffice 会互踢,
    /// 因此每次转换用独立 UserInstallation profile;输出先进临时目录,由调用方搬运命名。
    static func convertToPDF(executable: URL, input: URL, outputDirectory: URL,
                             cancel: CancelToken? = nil) async throws {
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let profile = FileManager.default.temporaryDirectory
            .appendingPathComponent("kumquat-lo-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: profile) }
        let arguments = [
            "--headless", "--norestore",
            "-env:UserInstallation=file://\(profile.path)",
            "--convert-to", "pdf",
            "--outdir", outputDirectory.path,
            input.path,
        ]
        try await ProcessRunner.run(executablePath: executable.path,
                                    arguments: arguments,
                                    timeout: 900, cancel: cancel)
        // soffice 失败时退出码也可能为 0(旧版行为):校验产物存在
        let expected = outputDirectory
            .appendingPathComponent(input.deletingPathExtension().lastPathComponent + ".pdf")
        guard FileManager.default.fileExists(atPath: expected.path) else {
            throw NSError(domain: "Kumquat.Office", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "LibreOffice 未产出 PDF(\(expected.lastPathComponent))"])
        }
    }

    /// 临时输出目录(转换结果先落这里,再由调用方搬到最终唯一名)。
    static func makeTempOutputDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("kumquat-out-\(UUID().uuidString)", isDirectory: true)
    }
}
