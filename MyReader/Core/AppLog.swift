import Foundation
import UIKit

/// 全局诊断日志：环形缓冲（内存最近 N 条）+ 每日文件持久化 + 导出。
/// - 自动清理：启动时删除 7 天前的日志文件；单文件超 5MB 截断
/// - 手动清理：设置页「清空日志」
/// - 导出：合并内存缓冲与全部日志文件为一个 txt（系统分享面板）
final class AppLog {
    static let shared = AppLog()

    enum Level: String {
        case debug = "DEBUG", info = "INFO ", warn = "WARN ", error = "ERROR"
    }

    struct Entry: Identifiable, Equatable {
        let id = UUID()
        let time: Date
        let level: Level
        let tag: String
        let message: String
    }

    /// 内存环形缓冲（最近 2000 条，界面即时查看）。
    private(set) var buffer: [Entry] = []
    private let maxBuffer = 2000
    /// 日志文件目录（Documents/Logs）。
    private let dir: URL
    private let queue = DispatchQueue(label: "com.example.myreader.log")
    private let keepDays = 7
    private let maxFileBytes = 5 * 1024 * 1024
    /// 设备与版本头（导出文件首部，方便远程定位环境差异）。
    private var header: String = ""

    private init() {
        dir = Paths.root.appendingPathComponent("Logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        buildHeader()
        autoCleanOldFiles()
    }

    private func buildHeader() {
        let device = UIDevice.current
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        header = """
        MyReader 诊断日志
        版本: \(version) (\(build))
        设备: \(device.model) / iOS \(device.systemVersion)
        导出时间: \(Self.stamp(Date()))

        """
    }

    // MARK: - 记录

    static func debug(_ tag: String, _ message: String) { shared.append(.debug, tag, message) }
    static func info(_ tag: String, _ message: String) { shared.append(.info, tag, message) }
    static func warn(_ tag: String, _ message: String) { shared.append(.warn, tag, message) }
    static func error(_ tag: String, _ message: String) { shared.append(.error, tag, message) }

    private func append(_ level: Level, _ tag: String, _ message: String) {
        let entry = Entry(time: Date(), level: level, tag: tag, message: message)
        queue.async { [weak self] in
            guard let self else { return }
            self.buffer.append(entry)
            if self.buffer.count > self.maxBuffer {
                self.buffer.removeFirst(self.buffer.count - self.maxBuffer)
            }
            self.writeToFile(entry)
        }
    }

    private func fileName(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return "app-\(formatter.string(from: date)).log"
    }

    private func writeToFile(_ entry: Entry) {
        let url = dir.appendingPathComponent(fileName(for: entry.time))
        let line = "\(Self.stamp(entry.time)) [\(entry.level.rawValue)] [\(entry.tag)] \(entry.message)\n"
        if let data = line.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: url.path) == false {
                try? "".data(using: .utf8)?.write(to: url)
            }
            if let handle = FileHandle(forWritingAtPath: url.path) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            }
        }
    }

    private static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: date)
    }

    /// 查看器用：条目时间文本。
    static func stampText(_ entry: Entry) -> String {
        stamp(entry.time)
    }

    // MARK: - 自动清理

    /// 启动时：删除 keepDays 天前的文件；截断超大文件。
    private func autoCleanOldFiles() {
        queue.async { [weak self] in
            guard let self else { return }
            let cutoff = Calendar.current.date(byAdding: .day, value: -self.keepDays, to: Date()) ?? Date()
            if let files = try? FileManager.default.contentsOfDirectory(
                at: self.dir, includingPropertiesForKeys: [.contentModificationDateKey]) {
                for file in files where file.pathExtension == "log" {
                    let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey])
                        .contentModificationDate) ?? Date()
                    if modified < cutoff {
                        try? FileManager.default.removeItem(at: file)
                    } else {
                        self.truncateIfOversize(file)
                    }
                }
            }
        }
    }

    private func truncateIfOversize(_ file: URL) {
        let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int) ?? 0
        if size > maxFileBytes, let handle = FileHandle(forReadingAndUpdateAt: file.path) {
            // 保留尾部 2MB（最新内容）
            let keep = 2 * 1024 * 1024
            handle.seek(toFileOffset: UInt64(max(0, size - keep)))
            if let tail = try? handle.read(upToCount: keep) {
                try? handle.truncate(atOffset: 0)
                handle.seek(toFileOffset: 0)
                handle.write(tail)
            }
            try? handle.close()
        }
    }

    // MARK: - 手动清理 / 导出

    /// 清空全部日志（缓冲 + 文件）。返回清理的文件数。
    @discardableResult
    func clearAll() -> Int {
        queue.sync {
            buffer.removeAll()
        }
        var removed = 0
        if let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
            for file in files where file.pathExtension == "log" {
                try? FileManager.default.removeItem(at: file)
                removed += 1
            }
        }
        return removed
    }

    /// 合并导出：header + 全部日志文件（旧→新）+ 内存缓冲尾部。
    func exportText() -> String {
        var parts: [String] = [header]
        if let files = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey])?.sorted(by: { a, b in
            let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
            let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
            return da < db
        }) {
            for file in files where file.pathExtension == "log" {
                parts.append("===== \(file.deletingPathExtension().lastPathComponent) =====")
                if let text = try? String(contentsOf: file, encoding: .utf8) {
                    parts.append(text)
                }
            }
        }
        parts.append("===== 内存缓冲（最近 \(buffer.count) 条）=====")
        for e in buffer.suffix(500) {
            parts.append("\(Self.stamp(e.time)) [\(e.level.rawValue)] [\(e.tag)] \(e.message)")
        }
        return parts.joined(separator: "\n")
    }

    /// 导出为临时文件（分享面板用）。
    func exportFileURL() -> URL {
        let url = dir.appendingPathComponent("MyReader诊断日志.txt")
        let text = exportText()
        queue.sync { }
        try? text.data(using: .utf8)?.write(to: url)
        return url
    }

    /// 日志统计（设置页显示）。
    func stat() -> (entries: Int, files: Int, bytes: Int) {
        var files = 0, bytes = 0
        if let list = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]) {
            for file in list where file.pathExtension == "log" {
                files += 1
                bytes += (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            }
        }
        return (buffer.count, files, bytes)
    }
}
