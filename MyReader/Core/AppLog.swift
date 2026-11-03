import Foundation
import UIKit
import Darwin

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
        installCrashHandlers()
    }

    // MARK: - 崩溃捕获（未捕异常 + 致命信号 → 崩溃日志文件，导出可见）

    private func installCrashHandlers() {
        NSSetUncaughtExceptionHandler { exception in
            let report = """
            ===== CRASH（未捕获异常）=====
            时间: \(Date())
            名称: \(exception.name.rawValue)
            原因: \(exception.reason ?? "-")
            堆栈:
            \(exception.callStackSymbols.joined(separator: "\n"))

            """
            AppLog.shared.writeCrashReport(report)
        }
        // SIGTRAP(5)：Swift 运行时的数组越界 / 强解包 nil / fatalError 都走 trap，
        // 之前没装 → 「搜索时闪退」这类崩溃一条日志都没有。
        // 预打开崩溃现场文件（handler 内不能 open / 分配内存）
        if myreaderCrashTraceFD < 0 {
            let url = dir.appendingPathComponent("crash-trace.log")
            myreaderCrashTraceFD = prepareCrashTraceFile(at: url)
        }
        let signals: [Int32] = [SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGFPE, SIGTRAP]
        for sig in signals {
            // 必须是 C 函数指针（不能捕获上下文）→ 使用文件级函数
            signal(sig, myreaderFatalSignalHandler)
        }
    }

    /// 崩溃报告写入（同步直写，不经队列——崩溃场景不能依赖异步）。
    /// 覆盖同一个文件，避免多次崩溃堆成一堆小文件找不到重点。
    func writeCrashReport(_ text: String) {
        let url = dir.appendingPathComponent("crash-latest.log")
        try? text.data(using: .utf8)?.write(to: url)
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

    /// 同步落盘版本：**排查崩溃时必须用它**。
    /// 普通 append 是 queue.async，进程被 trap 时队列里还没写的日志全部丢失，
    /// 所以崩溃现场永远是「最后一条日志之后什么都没有」。
    static func traceSync(_ tag: String, _ message: String) {
        shared.appendSync(.debug, tag, message)
    }

    private func appendSync(_ level: Level, _ tag: String, _ message: String) {
        let entry = Entry(time: Date(), level: level, tag: tag, message: message)
        queue.sync {
            buffer.append(entry)
            if buffer.count > maxBuffer {
                buffer.removeFirst(buffer.count - maxBuffer)
            }
            writeToFile(entry)
        }
    }

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
        // FileHandle(forUpdating:) 是 throws 且非 Optional 的初始化器：
        // try? 使其成为 Optional 供条件绑定
        if size > maxFileBytes, let handle = try? FileHandle(forUpdating: file) {
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
        // 注意：try? 包裹整个表达式，contentsOfDirectory 返回 [URL]（非optional），
        // 排序在解包后进行——勿在 try? 链内再叠 ?.
        let files = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let sorted = files.sorted { a, b in
            let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
            let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
            return da < db
        }
        for file in sorted where file.pathExtension == "log" {
            parts.append("===== \(file.deletingPathExtension().lastPathComponent) =====")
            if let text = try? String(contentsOf: file, encoding: .utf8) {
                parts.append(text)
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

// MARK: - 致命信号处理器

/// 崩溃现场文件描述符（handler 内只能用它写，不能 new 任何对象）。
/// 由 AppLog.installCrashHandlers() 预先 open，零捕获。
private var myreaderCrashTraceFD: Int32 = -1

/// 预打开崩溃现场文件，返回 fd（-1 表示失败）。
func prepareCrashTraceFile(at url: URL) -> Int32 {
    let path = url.path
    return open(path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
}

private func writeRaw(_ text: String, to fd: Int32) {
    guard fd >= 0 else { return }
    let bytes = Array(text.utf8)
    bytes.withUnsafeBufferPointer { buf in
        guard let base = buf.baseAddress else { return }
        _ = write(fd, base, buf.count)
    }
}

/// 信号处理器参数必须是 C 函数指针，不能捕获任何上下文（闭包捕获会编译失败），
/// 故定义为文件级函数；处理器内不可安全调用复杂 API，仅做精简记录，
/// 随后恢复默认处理并重新 raise，保证系统原有崩溃上报不被吞掉。
///
/// 关键：Swift 的数组越界 / 强解包 nil / fatalError 都是 brk → SIGTRAP，
/// 只记信号名等于没记。这里用 backtrace + backtrace_symbols_fd（均为
/// async-signal-safe）把**调用栈**直接写进预打开的 fd。
private func myreaderFatalSignalHandler(_ sig: Int32) {
    let name: String
    switch sig {
    case SIGABRT: name = "SIGABRT"
    case SIGSEGV: name = "SIGSEGV"
    case SIGBUS: name = "SIGBUS"
    case SIGILL: name = "SIGILL"
    case SIGFPE: name = "SIGFPE"
    case SIGTRAP: name = "SIGTRAP"
    default: name = "SIG\(sig)"
    }

    let fd = myreaderCrashTraceFD
    writeRaw("\n===== CRASH（信号 \(name) / thread=\(pthread_main_np() == 1 ? "main" : "background")）=====\n", to: fd)

    // 调用栈（async-signal-safe）
    var frames = [UnsafeMutableRawPointer?](repeating: nil, count: 96)
    let count = backtrace(&frames, Int32(frames.count))
    if count > 0 {
        writeRaw("--- backtrace（模块/地址/偏移）---\n", to: fd)
        backtrace_symbols_fd(&frames, count, fd)
        writeRaw("--- end backtrace ---\n", to: fd)
    }

    let report = """
    ===== CRASH（信号 \(name)）=====
    时间: \(Date())
    线程: \(pthread_main_np() == 1 ? "主线程" : "后台线程")
    调用栈已写入 crash-trace 文件（导出日志可见）

    """
    AppLog.shared.writeCrashReport(report)
    signal(sig, SIG_DFL)
    raise(sig)
}
