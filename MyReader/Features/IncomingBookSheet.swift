import SwiftUI

/// 「用其他应用打开」后的导入确认界面：
/// - 书名 / 作者编辑
/// - TXT：切分规则（智能 / 自定义正则 / 按字数）可切换并重新切分
/// - 章节数预览 → 确认加入书架
struct IncomingBookSheet: View {
    @EnvironmentObject private var store: Store
    @Environment(\.dismiss) private var dismiss

    @State private var draft: Book
    private let isTXT: Bool

    @State private var modeIndex = 0
    @State private var regexText = "^\\s*第[0-9零一二三四五六七八九十百千万]+[章节卷回].{0,30}$"
    @State private var countPer = 5000
    @State private var reparsing = false

    init(draft: Book) {
        _draft = State(initialValue: draft)
        let ext = draft.localFile.map { Paths.absolute($0).pathExtension.lowercased() } ?? "txt"
        isTXT = (ext != "epub")
    }

    private var currentMode: Importer.SplitMode {
        switch modeIndex {
        case 1: return .regex(regexText)
        case 2: return .count(countPer)
        default: return .smart
        }
    }

    var body: some View {
        NavigationView {
            Form {
                Section("书籍信息") {
                    TextField("书名", text: $draft.name)
                    TextField("作者（可留空）", text: $draft.author)
                    HStack {
                        Text("来源")
                        Spacer()
                        Text(draft.localFile.map { Paths.absolute($0).lastPathComponent } ?? "本地文件")
                            .font(.caption).foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                if isTXT {
                    Section {
                        Picker("切分规则", selection: $modeIndex) {
                            Text("智能识别").tag(0)
                            Text("自定义正则").tag(1)
                            Text("按字数").tag(2)
                        }
                        .pickerStyle(.segmented)

                        if modeIndex == 1 {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("章节标题正则").font(.caption).foregroundStyle(.secondary)
                                TextField("例如：^\\s*第[0-9零一二三四五六七八九十百千万]+[章节卷回].{0,30}$",
                                          text: $regexText)
                                    .font(.system(size: 12, design: .monospaced))
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                                Text("匹配到的行作为章节标题，两标题之间为一章。切不出章节时自动回退智能识别。")
                                    .font(.caption2).foregroundStyle(.tertiary)
                            }
                        }

                        if modeIndex == 2 {
                            Stepper("每章约 \(countPer) 字", value: $countPer,
                                    in: 1000...20000, step: 1000)
                        }

                        HStack {
                            Button {
                                applyRule()
                            } label: {
                                if reparsing {
                                    HStack { ProgressView().padding(.trailing, 4); Text("正在切分…") }
                                } else {
                                    Label("重新切分", systemImage: "arrow.triangle.2.circlepath")
                                }
                            }
                            .disabled(reparsing)
                            Spacer()
                            VStack(alignment: .trailing, spacing: 2) {
                                Text("共 \(draft.chapters.count) 章")
                                    .font(.subheadline.monospacedDigit())
                                Text("约 \(totalWords) 字")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    } header: {
                        Text("章节切分")
                    } footer: {
                        Text("智能识别支持：第X章/节/卷/回/集/部/篇、序章、楔子、番外等。")
                            .font(.caption2)
                    }
                } else {
                    Section("章节") {
                        HStack {
                            Text("共 \(draft.chapters.count) 章")
                            Spacer()
                            Text("约 \(totalWords) 字")
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                // 章节预览
                if !draft.chapters.isEmpty {
                    Section("章节预览") {
                        ForEach(prefixChapters) { chapter in
                            HStack {
                                Text(chapter.title)
                                    .font(.caption)
                                    .lineLimit(1)
                                Spacer()
                                Text("\(chapter.wordCount)字")
                                    .font(.caption2).foregroundStyle(.tertiary)
                            }
                            .foregroundStyle(.secondary)
                        }
                        if draft.chapters.count > 8 {
                            Text("…其余 \(draft.chapters.count - 8) 章")
                                .font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                }

                Section {
                    Button {
                        commit()
                    } label: {
                        Text("加入书架")
                            .frame(maxWidth: .infinity)
                            .font(.body.weight(.semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(draft.name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .navigationTitle("导入书籍")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("取消") {
                        discardDraft()
                    }
                }
            }
        }
        .navigationViewStyle(.stack)
    }

    private var prefixChapters: [Chapter] {
        Array(draft.chapters.prefix(8))
    }

    private var totalWords: Int {
        draft.chapters.reduce(0) { $0 + $1.wordCount }
    }

    private func applyRule() {
        guard isTXT else { return }
        reparsing = true
        let mode = currentMode
        let source = draft
        Task.detached(priority: .userInitiated) {
            let reparsed = Importer.reparse(draft: source, mode: mode)
            await MainActor.run {
                // 保留用户已编辑的书名/作者
                var updated = reparsed
                updated.name = draft.name
                updated.author = draft.author
                draft = updated
                store.incomingSplitMode = mode
                reparsing = false
            }
        }
    }

    private func commit() {
        var final = draft
        final.name = draft.name.trimmingCharacters(in: .whitespaces)
        final.author = draft.author.trimmingCharacters(in: .whitespaces)
        let book = Importer.commitBook(final, mode: isTXT ? currentMode : .smart)
        store.incomingDraft = nil
        store.importNotice = "已加入书架：《\(book.name)》\(book.chapters.count) 章"
        dismiss()
    }

    private func discardDraft() {
        // 清理已暂存的原文件副本
        if let rel = draft.localFile {
            let url = Paths.absolute(rel)
            let dir = Paths.imported
            if url.deletingLastPathComponent().path == dir.path {
                try? FileManager.default.removeItem(at: url)
            }
        }
        store.incomingDraft = nil
        dismiss()
    }
}
