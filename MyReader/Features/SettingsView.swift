import SwiftUI
import UIKit
import AVFoundation

struct SettingsView: View {
    @EnvironmentObject private var store: Store
    @EnvironmentObject private var theme: ThemeManager

    @State private var showSourceList = false
    @State private var showFontPanel = false
    @State private var exported: URL?
    @State private var message: String?

    var body: some View {
        NavigationView {
            List {
                Section {
                    NavigationLink(destination: ThemeSettingsView()) {
                        Label("阅读主题与排版", systemImage: "textformat")
                    }
                    Button {
                        showFontPanel = true
                    } label: {
                        Label("朗读设置", systemImage: "waveform")
                    }
                } header: {
                    Text("阅读")
                }

                Section {
                    Button {
                        showSourceList = true
                    } label: {
                        HStack {
                            Label("书源管理", systemImage: "square.stack.3d.up")
                            Spacer()
                            Text("\(store.sources.count)").foregroundStyle(.secondary)
                        }
                    }

                    Button {
                        exportSources()
                    } label: {
                        Label("导出全部书源", systemImage: "square.and.arrow.up")
                    }

                    Button {
                        backupBooks()
                    } label: {
                        Label("导出书架书籍（TXT）", systemImage: "doc.text")
                    }
                } header: {
                    Text("书源与数据")
                }

                Section {
                    HStack {
                        Text("书籍数量")
                        Spacer()
                        Text("\(store.books.count)").foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("缓存目录")
                        Spacer()
                        Text(Paths.root.lastPathComponent).foregroundStyle(.secondary)
                    }
                    Button(role: .destructive) {
                        for book in store.books {
                            Paths.removeChapters(bookID: book.id)
                        }
                        message = "已清理全部章节缓存"
                    } label: {
                        Text("清理全部缓存")
                    }
                } header: {
                    Text("存储")
                }

                Section {
                    HStack {
                        Text("版本")
                        Spacer()
                        Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0")
                            .foregroundStyle(.secondary)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("关于这个 App").font(.subheadline)
                        Text("完全免费的本地阅读器：没有会员、没有激励、没有广告位，所有高级功能（主题、朗读、导出、多书源）全部常驻可用。启动直接进书架，不加载任何第三方 SDK。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                } header: {
                    Text("关于")
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("我的")
            .sheet(isPresented: $showSourceList) {
                BookSourceListView().environmentObject(store)
            }
            .sheet(isPresented: $showFontPanel) {
                TTSVoiceSettingsView().environmentObject(store)
            }
            .sheet(item: Binding(
                get: { exported.map { ExportItem(url: $0) } },
                set: { exported = $0?.url }
            )) { item in
                ShareSheet(items: [item.url])
            }
            .overlay(alignment: .bottom) {
                if let message {
                    Text(message)
                        .font(.footnote)
                        .padding(.horizontal, 14).padding(.vertical, 9)
                        .background(.thinMaterial, in: Capsule())
                        .padding(.bottom, 20)
                }
            }
        }
        .navigationViewStyle(.stack)
    }

    private func exportSources() {
        let texts = store.sourceRecords.map(\.rawJSON)
        guard !texts.isEmpty else { return }
        let json = "[" + texts.joined(separator: ",\n") + "]"
        let file = Paths.root.appendingPathComponent("书源导出.json")
        try? json.data(using: .utf8)?.write(to: file)
        exported = file
    }

    private func backupBooks() {
        guard let book = store.books.first else {
            message = "书架是空的"
            return
        }
        if let url = BookActions.exportTXT(book: book) {
            exported = url
        }
    }
}

struct ExportItem: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

// MARK: - 主题与排版

struct ThemeSettingsView: View {
    @EnvironmentObject private var store: Store
    @EnvironmentObject private var theme: ThemeManager

    var body: some View {
        Form {
            Section("主题") {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 78), spacing: 12)], spacing: 12) {
                    ForEach(ThemeCatalog.all) { item in
                        Button {
                            theme.apply(themeID: item.id)
                        } label: {
                            VStack(spacing: 6) {
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(item.background)
                                    .frame(height: 60)
                                    .overlay(RoundedRectangle(cornerRadius: 10)
                                        .stroke(store.settings.themeID == item.id ? Color.accentColor : Color.gray.opacity(0.2),
                                                lineWidth: store.settings.themeID == item.id ? 2 : 1))
                                    .overlay(Text("文").foregroundStyle(item.text))
                                Text(item.name).font(.caption2)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 6)
            }

            Section("排版") {
                VStack(alignment: .leading) {
                    Text("字号 \(Int(store.settings.fontSize))").font(.footnote)
                    Slider(value: Binding(
                        get: { store.settings.fontSize },
                        set: { v in store.updateSettings { $0.fontSize = v } }
                    ), in: 12...34, step: 1)
                }
                VStack(alignment: .leading) {
                    Text("行距 \(Int(store.settings.lineSpacing))").font(.footnote)
                    Slider(value: Binding(
                        get: { store.settings.lineSpacing },
                        set: { v in store.updateSettings { $0.lineSpacing = v } }
                    ), in: 0...24, step: 1)
                }
                Toggle("首行缩进", isOn: Binding(
                    get: { store.settings.indentFirstLine },
                    set: { v in store.updateSettings { $0.indentFirstLine = v } }
                ))
                Toggle("跟随系统深色模式", isOn: Binding(
                    get: { store.settings.followSystemDark },
                    set: { v in store.updateSettings { $0.followSystemDark = v } }
                ))
            }
        }
        .navigationTitle("主题与排版")
    }
}

// MARK: - 朗读设置（还原爱阅：语速恒等映射 0~100%，音调 percent → 0.5~1.5）

struct TTSVoiceSettingsView: View {
    @EnvironmentObject private var store: Store
    @Environment(\.dismiss) private var dismiss

    private var chineseVoices: [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix("zh") }
    }

    var body: some View {
        NavigationView {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("语速，百分之\(Int(store.settings.ttsRatePercent))").font(.footnote)
                        Slider(value: Binding(
                            get: { store.settings.ttsRatePercent },
                            set: { v in store.updateSettings { $0.ttsRatePercent = v } }
                        ), in: 0...100, step: 1)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("音调，百分之\(Int(store.settings.ttsPitchPercent))").font(.footnote)
                        Slider(value: Binding(
                            get: { store.settings.ttsPitchPercent },
                            set: { v in store.updateSettings { $0.ttsPitchPercent = v } }
                        ), in: 0...100, step: 1)
                    }
                } header: {
                    Text("语速 / 音调")
                } footer: {
                    Text("语速对应系统 0.0~1.0（默认 50）；音调实际可调 0.5~1.5（默认 75）。")
                        .font(.caption2)
                }
                Section("发音人") {
                    Picker("发音人", selection: Binding(
                        get: { store.settings.ttsVoice },
                        set: { v in store.updateSettings { $0.ttsVoice = v } }
                    )) {
                        Text("系统默认").tag("")
                        ForEach(chineseVoices, id: \.identifier) { voice in
                            Text("\(voice.name)（\(voice.language)）").tag(voice.identifier)
                        }
                    }
                }
            }
            .navigationTitle("朗读设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}
