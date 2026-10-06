import Foundation

// MARK: - 归档引擎(zip 用系统 ditto,tar 用系统 tar,零外部依赖)

enum ArchiveEngine {
    static let dittoPath = "/usr/bin/ditto"
    static let tarPath = "/usr/bin/tar"

    /// 压缩为 zip。ditto -c 只收一个来源(实测 "Can't archive multiple sources"):
    /// 单文件直接压;多来源先复制进暂存目录,再压目录内容(items 在压缩包根目录)。
    static func createZip(inputs: [URL], output: URL, cancel: CancelToken? = nil) async throws {
        let fileManager = FileManager.default
        if inputs.count == 1 {
            try await ProcessRunner.run(executablePath: dittoPath,
                                        arguments: ["-c", "-k", "--sequesterRsrc",
                                                    inputs[0].path, output.path],
                                        timeout: 1800, cancel: cancel)
            return
        }
        let staging = fileManager.temporaryDirectory
            .appendingPathComponent("kumquat-zip-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: staging) }
        for input in inputs {
            let destination = staging.appendingPathComponent(input.lastPathComponent)
            try? fileManager.removeItem(at: destination)
            try fileManager.copyItem(at: input, to: destination) // APFS 上是克隆语义
        }
        try await ProcessRunner.run(executablePath: dittoPath,
                                    arguments: ["-c", "-k", "--sequesterRsrc",
                                                staging.path, output.path],
                                    timeout: 1800, cancel: cancel)
    }

    /// 解压 zip 到独立目录(ditto -x -k)。
    static func extractZip(input: URL, outputDirectory: URL) async throws {
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        try await ProcessRunner.run(executablePath: dittoPath,
                                    arguments: ["-x", "-k", input.path, outputDirectory.path],
                                    timeout: 1800)
    }

    /// 解压 tar / tar.gz / tgz(bsdtar -xf 自动识别压缩)。
    static func extractTar(input: URL, outputDirectory: URL) async throws {
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        try await ProcessRunner.run(executablePath: tarPath,
                                    arguments: ["-xf", input.path, "-C", outputDirectory.path],
                                    timeout: 1800)
    }

    /// 解压目标目录:"原名 解压",重名追加 " 2"" 3"…。x.tar.gz 正确去双扩展名。
    static func uniqueExtractionDirectory(for archive: URL) -> URL {
        let directory = archive.deletingLastPathComponent()
        var stem = archive.deletingPathExtension().lastPathComponent
        if stem.lowercased().hasSuffix(".tar") { stem = String(stem.dropLast(4)) }
        var candidate = directory.appendingPathComponent("\(stem) 解压", isDirectory: true)
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(stem) 解压 \(counter)", isDirectory: true)
            counter += 1
        }
        return candidate
    }
}
