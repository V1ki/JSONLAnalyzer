import Foundation
import CryptoKit

enum AnalysisError: LocalizedError {
    case fileMissing(String)
    case zstdNotFound
    case decompressFailed(status: Int32, detail: String)

    var errorDescription: String? {
        switch self {
        case .fileMissing(let p):
            return "文件不存在或无法读取：\(p)"
        case .zstdNotFound:
            return "未找到 zstd 命令。请先安装（例如 brew install zstd），再打开 .zstd 文件。"
        case .decompressFailed(let status, let detail):
            let suffix = detail.isEmpty ? "" : "：\(detail)"
            return "zstd 解压失败（退出码 \(status)）\(suffix)"
        }
    }
}

/// 一个可分析的 JSONL 文件。
/// - `.zstd` 文件会先解压到缓存目录（按 路径+大小+mtime 哈希命名，内容不变则复用），
///   之后所有读取都作用于解压后的文件。
/// - 普通文件直接读取原路径。
struct JsonlFile {
    /// 原始文件（可能是 .zstd）
    let url: URL
    /// 实际按行读取的文件（解压后的缓存文件，或原文件）
    let dataURL: URL
    let originalSize: Int64
    let dataSize: Int64
    let isCompressed: Bool

    static func isCompressedURL(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return ext == "zstd" || ext == "zst"
    }

    /// 准备文件：必要时解压。可能抛出 AnalysisError。
    static func prepare(_ url: URL) throws -> JsonlFile {
        let fm = FileManager.default
        let attrs = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard attrs?.isRegularFile == true else {
            throw AnalysisError.fileMissing(url.path)
        }
        let originalSize = Int64(attrs?.fileSize ?? 0)

        if !isCompressedURL(url) {
            return JsonlFile(url: url, dataURL: url, originalSize: originalSize,
                             dataSize: originalSize, isCompressed: false)
        }

        let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate?.timeIntervalSince1970 ?? 0
        let hash = SHA256.hash(data: Data("\(url.path)|\(originalSize)|\(Int64(mtime))".utf8))
            .prefix(12).map { String(format: "%02x", $0) }.joined()
        let cacheDir = FileManager.default.cachesDir
            .appendingPathComponent("JSONLAnalyzer", isDirectory: true)
        try? fm.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        let dest = cacheDir.appendingPathComponent("\(hash).jsonl")

        let needDecompress: Bool
        if let size = (try? dest.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size > 0 {
            needDecompress = false
        } else {
            needDecompress = true
        }
        if needDecompress {
            try decompress(src: url, to: dest)
        }
        let dataSize = Int64((try? dest.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        return JsonlFile(url: url, dataURL: dest, originalSize: originalSize,
                         dataSize: dataSize, isCompressed: true)
    }

    /// 在常见位置查找 zstd 二进制。
    static func locateZstd() -> URL? {
        let candidates = [
            "/opt/homebrew/bin/zstd", "/opt/local/bin/zstd",
            "/usr/local/bin/zstd", "/usr/bin/zstd",
        ]
        for c in candidates where FileManager.default.isExecutableFile(atPath: c) {
            return URL(fileURLWithPath: c)
        }
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        for dir in path.split(separator: ":") {
            let p = URL(fileURLWithPath: String(dir)).appendingPathComponent("zstd")
            if FileManager.default.isExecutableFile(atPath: p.path) { return p }
        }
        return nil
    }

    private static func decompress(src: URL, to dest: URL) throws {
        guard let zstd = locateZstd() else { throw AnalysisError.zstdNotFound }
        FileManager.default.createFile(atPath: dest.path, contents: nil)
        let outHandle = try FileHandle(forWritingTo: dest)
        defer { try? outHandle.close() }

        let p = Process()
        p.executableURL = zstd
        p.arguments = ["-dc", src.path]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        try p.run()

        let reader = pipe.fileHandleForReading
        while true {
            let chunk = reader.availableData
            if chunk.isEmpty { break }
            try outHandle.write(contentsOf: chunk)
        }
        p.waitUntilExit()

        let stderrText = String(data: (p.standardError as? Pipe)?
            .fileHandleForReading.readDataToEndOfFile() ?? Data(), encoding: .utf8) ?? ""
        if p.terminationStatus != 0 {
            try? FileManager.default.removeItem(at: dest)
            throw AnalysisError.decompressFailed(status: p.terminationStatus,
                                                 detail: stderrText.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200).description)
        }
        let size = (try? dest.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        if size == 0 {
            try? FileManager.default.removeItem(at: dest)
            throw AnalysisError.decompressFailed(status: p.terminationStatus, detail: "解压结果为空")
        }
    }

    /// 打开流式行读取器（从头开始）。
    func openReader() -> LineReader? {
        LineReader(url: dataURL, totalBytes: dataSize)
    }

    /// 按字节偏移回读一行（用于详情视图，不把整个文件驻留内存）。
    func readLine(offset: UInt64, length: Int) -> Data? {
        guard let reader = RowReader(url: dataURL) else { return nil }
        return reader.read(offset: offset, length: length)
    }

    /// 打开按偏移回读的读取器。要连续回读很多行时用它复用同一个文件句柄，
    /// 不必每行都 open / close 一次（会话页逐行回读）。
    func openRowReader() -> RowReader? {
        RowReader(url: dataURL)
    }
}

/// 按字节偏移随机回读的读取器，持有并复用一个文件句柄。
/// 非线程安全：批量回读时在一个任务里串行使用。
final class RowReader {
    private let handle: FileHandle

    init?(url: URL) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        self.handle = handle
    }
    deinit { try? handle.close() }

    func read(offset: UInt64, length: Int) -> Data? {
        do {
            try handle.seek(toOffset: offset)
            return try handle.read(upToCount: length)
        } catch { return nil }
    }
}

/// 流式逐行读取器：返回每行的字节区间（不含换行符），供后续随机回读。
final class LineReader {
    private let handle: FileHandle
    private var buf: [UInt8] = []
    private var pos = 0                 // buf 中已消费位置
    private var baseOffset: UInt64 = 0  // buf[0] 对应的文件偏移
    let totalBytes: Int64
    private(set) var consumedBytes: Int64 = 0
    private static let chunkSize = 1 << 16

    init?(url: URL, totalBytes: Int64) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        self.handle = handle
        self.totalBytes = totalBytes
    }
    deinit { try? handle.close() }

    /// 返回下一行（不含换行符）与其起始偏移；文件结束时返回 nil。
    func nextLine() -> (line: ArraySlice<UInt8>, offset: UInt64)? {
        while true {
            if pos < buf.count, let nl = buf[pos...].firstIndex(of: 0x0A) {
                let start = baseOffset + UInt64(pos)
                let line = buf[pos..<nl]
                pos = nl + 1
                consumedBytes = Int64(baseOffset) + Int64(pos)
                return (line, start)
            }
            // 缓冲区里没有换行符：腾出空间，继续读。
            // 只有已消费部分过半才前移剩余数据（搬动量不超过腾出的空间）；
            // 否则直接追加——长行跨越很多块时，不必每读一块就整体搬动一次。
            if pos > 0, pos * 2 >= buf.count {
                buf.removeFirst(pos)
                baseOffset += UInt64(pos)
                consumedBytes = Int64(baseOffset)
                pos = 0
            }
            // 一次读取量随未成行的数据增长：长行只需对数次数的读取
            let want = max(Self.chunkSize, buf.count - pos)
            guard let chunk = try? handle.read(upToCount: want), !chunk.isEmpty else {
                if pos < buf.count {
                    // 文件末尾没有换行符的最后一行
                    let start = baseOffset + UInt64(pos)
                    let line = buf[pos...]
                    pos = buf.count
                    consumedBytes = Int64(baseOffset) + Int64(pos)
                    return (line, start)
                }
                return nil
            }
            buf.append(contentsOf: chunk)
        }
    }
}

private extension FileManager {
    var cachesDir: URL {
        urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? temporaryDirectory
    }
}
