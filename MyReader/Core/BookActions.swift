import Foundation
import UIKit

enum BookActions {
    /// 把搜索结果变成书架里的一本书（含目录 + 封面）。
    static func add(result: SearchResult, store: Store) async throws -> Book {
        guard let source = store.sources.first(where: { $0.id == result.sourceID }) else {
            throw BookSourceEngineError.missingSource
        }
        var book = Book(name: result.title, origin: .online)
        book.author = result.author
        book.intro = result.intro
        book.coverURL = result.cover
        book.sourceID = source.id
        book.sourceName = source.name
        book.detailURL = result.link

        let directory = try await BookSourceEngine(source).directory(detailURL: result.link)
        book.chapters = directory.chapters
        if book.intro.isEmpty { book.intro = directory.intro }
        if book.coverURL.isEmpty { book.coverURL = directory.cover }

        store.addBook(book)
        if !book.coverURL.isEmpty {
            downloadCover(book: book, store: store)
        }
        return book
    }

    /// 异步下载封面并缓存到本地，之后离线也能显示。
    static func downloadCover(book: Book, store: Store) {
        guard !book.coverURL.isEmpty else { return }
        let bookID = book.id
        let urlString = book.coverURL
        Task.detached(priority: .utility) {
            guard let url = URL(string: urlString) else { return }
            var request = URLRequest(url: url)
            request.setValue(Fetcher.userAgent, forHTTPHeaderField: "User-Agent")
            guard let (data, _) = try? await URLSession.shared.data(for: request),
                  let image = UIImage(data: data) else { return }
            let file = Paths.covers.appendingPathComponent("\(bookID.uuidString).jpg")
            if let jpeg = image.jpegData(compressionQuality: 0.85) {
                try? jpeg.write(to: file)
            }
            await MainActor.run {
                guard var latest = store.book(id: bookID) else { return }
                latest.coverFile = Paths.relative(file)
                store.updateBook(latest)
            }
        }
    }

    /// 导出书籍为 TXT（备份 / 传阅自己的内容）。
    static func exportTXT(book: Book) -> URL? {
        var text = book.name + "\n" + book.author + "\n\n"
        for chapter in book.chapters {
            text += chapter.title + "\n\n"
            if let content = Paths.readChapter(bookID: book.id, index: chapter.index) {
                text += content + "\n\n"
            }
        }
        let file = Paths.root.appendingPathComponent("\(book.name).txt")
        try? text.write(to: file, atomically: true, encoding: .utf8)
        return file
    }
}

enum BookSourceEngineError: LocalizedError {
    case missingSource

    var errorDescription: String? {
        switch self {
        case .missingSource: return "书源已被删除"
        }
    }
}
