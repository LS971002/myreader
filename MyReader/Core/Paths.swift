import Foundation

/// 统一的沙盒路径管理。所有数据都在 Documents/MyReader 下，
/// 开启文件共享后可以直接用「文件」App 或 iTunes 拖取备份。
enum Paths {
    static var root: URL {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("MyReader", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static var booksJSON: URL { root.appendingPathComponent("books.json") }
    static var sourcesJSON: URL { root.appendingPathComponent("sources.json") }
    static var groupsJSON: URL { root.appendingPathComponent("groups.json") }
    static var bookmarksJSON: URL { root.appendingPathComponent("bookmarks.json") }
    static var settingsJSON: URL { root.appendingPathComponent("settings.json") }

    static var covers: URL { ensure(root.appendingPathComponent("Covers", isDirectory: true)) }
    static var chapterDir: URL { ensure(root.appendingPathComponent("Chapters", isDirectory: true)) }
    static var imported: URL { ensure(root.appendingPathComponent("Imported", isDirectory: true)) }

    static func ensure(_ url: URL) -> URL {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func chapterFile(bookID: UUID, index: Int) -> URL {
        chapterDir
            .appendingPathComponent(bookID.uuidString, isDirectory: true)
            .appendingPathComponent("\(index).txt")
    }

    static func writeChapter(_ text: String, bookID: UUID, index: Int) {
        let file = chapterFile(bookID: bookID, index: index)
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? text.write(to: file, atomically: true, encoding: .utf8)
    }

    static func readChapter(bookID: UUID, index: Int) -> String? {
        try? String(contentsOf: chapterFile(bookID: bookID, index: index), encoding: .utf8)
    }

    static func removeChapters(bookID: UUID) {
        try? FileManager.default.removeItem(
            at: chapterDir.appendingPathComponent(bookID.uuidString, isDirectory: true))
    }

    static func relative(_ url: URL) -> String {
        url.path.replacingOccurrences(of: root.path + "/", with: "")
    }

    static func absolute(_ relative: String) -> URL {
        root.appendingPathComponent(relative)
    }
}
