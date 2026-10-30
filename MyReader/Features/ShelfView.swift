import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct ShelfView: View {
    @EnvironmentObject private var store: Store
    @EnvironmentObject private var theme: ThemeManager

    @State private var showImporter = false
    @State private var showGroups = false
    @State private var selectedGroup: UUID? = nil
    @State private var importError: String?
    @State private var searchText = ""
    @State private var detailBook: Book?

    private var books: [Book] {
        var list = store.books
        if let group = selectedGroup {
            list = list.filter { $0.groupID == group }
        }
        if !searchText.isEmpty {
            list = list.filter {
                $0.name.localizedCaseInsensitiveContains(searchText)
                    || $0.author.localizedCaseInsensitiveContains(searchText)
            }
        }
        return list.sorted {
            if $0.stick != $1.stick { return $0.stick }
            return $0.lastReadAt > $1.lastReadAt
        }
    }

    var body: some View {
        NavigationView {
            ZStack {
                if books.isEmpty {
                    emptyState
                } else {
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 18)], spacing: 22) {
                            ForEach(books) { book in
                                NavigationLink(destination: ReaderView(book: book, store: store)
                                    .environmentObject(store)
                                    .environmentObject(theme)) {
                                    BookCell(book: book)
                                }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    Button {
                                        store.toggleStick(book)
                                    } label: {
                                        Label(book.stick ? "取消置顶" : "置顶",
                                              systemImage: book.stick ? "pin.slash" : "pin")
                                    }
                                    Button {
                                        detailBook = book
                                    } label: {
                                        Label("书籍详情", systemImage: "info.circle")
                                    }
                                    Menu("移动到分组") {
                                        Button("未分组") { store.moveBook(book, toGroup: nil) }
                                        ForEach(store.groups) { group in
                                            Button(group.name) { store.moveBook(book, toGroup: group.id) }
                                        }
                                    }
                                    Button(role: .destructive) {
                                        store.removeBook(book)
                                    } label: {
                                        Label("删除", systemImage: "trash")
                                    }
                                }
                            }
                        }
                        .padding(18)
                    }
                }
            }
            .navigationTitle("书架")
            .toolbar {
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    Menu {
                        Button {
                            selectedGroup = nil
                        } label: {
                            Label("全部", systemImage: selectedGroup == nil ? "checkmark" : "books.vertical")
                        }
                        ForEach(store.groups) { group in
                            Button {
                                selectedGroup = group.id
                            } label: {
                                Label(group.name, systemImage: selectedGroup == group.id ? "checkmark" : "folder")
                            }
                        }
                    } label: {
                        Image(systemName: "line.3.horizontal.decrease.circle")
                    }

                    Button {
                        showImporter = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .searchable(text: $searchText, prompt: "搜索书架")
            .fileImporter(
                isPresented: $showImporter,
                allowedContentTypes: [.item, .plainText, .epub],
                allowsMultipleSelection: true
            ) { result in
                handleImport(result)
            }
            .alert("导入失败", isPresented: Binding(
                get: { importError != nil },
                set: { if !$0 { importError = nil } }
            )) {
                Button("好", role: .cancel) { importError = nil }
            } message: {
                Text(importError ?? "")
            }
            .sheet(item: $detailBook) { book in
                BookDetailSheet(book: book)
                    .environmentObject(store)
                    .environmentObject(theme)
            }
        }
        .navigationViewStyle(.stack)
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "books.vertical")
                .font(.system(size: 52))
                .foregroundStyle(.secondary)
            Text("书架还是空的").font(.headline)
            Text("从「发现」里搜索并加入书籍，\n或者点右上角 + 导入本地 TXT / EPUB。")
                .font(.footnote)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button {
                showImporter = true
            } label: {
                Text("导入本地书籍").padding(.horizontal, 18).padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(30)
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            for url in urls {
                do {
                    let ext = url.pathExtension.lowercased()
                    if ext == "json" {
                        try Importer.importBookSources(from: url)
                    } else {
                        let book = try Importer.importBook(from: url)
                        store.addBook(book)
                        if !book.coverURL.isEmpty {
                            BookActions.downloadCover(book: book, store: store)
                        }
                    }
                } catch {
                    importError = error.localizedDescription
                }
            }
        case .failure(let error):
            importError = error.localizedDescription
        }
    }
}

// MARK: - 单元格

struct BookCell: View {
    let book: Book

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .bottomLeading) {
                CoverView(book: book)
                    .frame(height: 132)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .shadow(color: .black.opacity(0.12), radius: 4, y: 2)

                if book.stick {
                    Image(systemName: "pin.fill")
                        .font(.caption2)
                        .padding(4)
                        .background(.thinMaterial, in: Circle())
                        .padding(5)
                }
            }
            Text(book.name)
                .font(.caption)
                .lineLimit(1)
                .foregroundStyle(.primary)
            Text(book.readChapterTitle.isEmpty ? book.author : book.readChapterTitle)
                .font(.caption2)
                .lineLimit(1)
                .foregroundStyle(.secondary)
        }
    }
}

struct CoverView: View {
    let book: Book

    var body: some View {
        GeometryReader { geo in
            if let file = book.coverFile, let image = UIImage(contentsOfFile: Paths.absolute(file).path) {
                Image(uiImage: image).resizable().scaledToFill()
                    .frame(width: geo.size.width, height: geo.size.height)
                    .clipped()
            } else if let url = URL(string: book.coverURL), !book.coverURL.isEmpty {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill()
                    } else {
                        placeholder
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height)
                .clipped()
            } else {
                placeholder
            }
        }
    }

    private var placeholder: some View {
        ZStack {
            LinearGradient(colors: [Color(hex: 0x8FA98F), Color(hex: 0x4F6B57)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            Text(String(book.name.prefix(2)))
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.white.opacity(0.92))
        }
    }
}

// MARK: - 书籍详情

struct BookDetailSheet: View {
    @EnvironmentObject private var store: Store
    @EnvironmentObject private var theme: ThemeManager
    @Environment(\.dismiss) private var dismiss

    let book: Book
    @State private var busy = false
    @State private var message: String?

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .top, spacing: 14) {
                        CoverView(book: book)
                            .frame(width: 88, height: 122)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        VStack(alignment: .leading, spacing: 6) {
                            Text(book.name).font(.headline)
                            Text(book.author).font(.subheadline).foregroundStyle(.secondary)
                            Text("书源：\(book.sourceName.isEmpty ? "本地" : book.sourceName)")
                                .font(.caption).foregroundStyle(.secondary)
                            Text("共 \(book.chapters.count) 章")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }

                    if !book.intro.isEmpty {
                        Text(book.intro)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    if let message {
                        Text(message).font(.footnote).foregroundStyle(.orange)
                    }

                    VStack(spacing: 10) {
                        if book.origin == .online {
                            Button {
                                refreshDirectory()
                            } label: {
                                HStack {
                                    if busy { ProgressView().padding(.trailing, 4) }
                                    Text(busy ? "正在更新目录…" : "更新目录")
                                }
                                .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                        }

                        Button(role: .destructive) {
                            store.removeBook(book)
                            dismiss()
                        } label: {
                            Text("从书架删除").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .padding(20)
            }
            .navigationTitle("书籍详情")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("关闭") { dismiss() }
                }
            }
        }
    }

    private func refreshDirectory() {
        guard let sourceID = book.sourceID,
              let source = store.sources.first(where: { $0.id == sourceID }) else {
            message = "找不到对应书源，无法更新目录"
            return
        }
        busy = true
        Task {
            do {
                let directory = try await BookSourceEngine(source).directory(detailURL: book.detailURL)
                var updated = book
                if !directory.chapters.isEmpty {
                    updated.chapters = directory.chapters
                    updated.intro = directory.intro.isEmpty ? book.intro : directory.intro
                }
                if !directory.cover.isEmpty { updated.coverURL = directory.cover }
                store.updateBook(updated)
                message = "目录已更新，共 \(updated.chapters.count) 章"
            } catch {
                message = "更新失败：\(error.localizedDescription)"
            }
            busy = false
        }
    }
}
