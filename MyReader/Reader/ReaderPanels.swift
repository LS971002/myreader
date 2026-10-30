import SwiftUI
import AVFoundation

// MARK: - 目录

struct CatalogSheet: View {
    @ObservedObject var model: ReaderModel
    @EnvironmentObject private var store: Store
    @EnvironmentObject private var theme: ThemeManager
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var ascending = true

    private var chapters: [Chapter] {
        let all = model.book.chapters
        let filtered = query.isEmpty
            ? all
            : all.filter { $0.title.localizedCaseInsensitiveContains(query) }
        return ascending ? filtered : filtered.reversed()
    }

    var body: some View {
        NavigationView {
            List {
                ForEach(chapters) { chapter in
                    Button {
                        model.jump(to: chapter.index)
                        dismiss()
                    } label: {
                        HStack {
                            Text(chapter.title)
                                .font(.subheadline)
                                .foregroundStyle(chapter.index == model.book.currentChapter ? Color.accentColor : Color.primary)
                                .lineLimit(1)
                            Spacer()
                            if chapter.cached {
                                Image(systemName: "arrow.down.circle.fill")
                                    .font(.caption2)
                                    .foregroundStyle(.green.opacity(0.7))
                            }
                        }
                    }
                }
            }
            .searchable(text: $query, prompt: "搜索章节")
            .navigationTitle("目录（\(model.book.chapters.count)）")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(ascending ? "正序" : "倒序") { ascending.toggle() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("关闭") { dismiss() }
                }
            }
        }
    }
}

// MARK: - 阅读设置

struct ReaderSettingsPanel: View {
    @ObservedObject var model: ReaderModel
    @EnvironmentObject private var store: Store
    @EnvironmentObject private var theme: ThemeManager
    @Environment(\.dismiss) private var dismiss
    @State private var tab = 0

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                Picker("", selection: $tab) {
                    Text("排版").tag(0)
                    Text("主题").tag(1)
                    Text("翻页").tag(2)
                    Text("其他").tag(3)
                }
                .pickerStyle(.segmented)
                .padding()

                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        if tab == 0 { typographyTab }
                        if tab == 1 { themeTab }
                        if tab == 2 { pageTurnTab }
                        if tab == 3 { otherTab }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 40)
                }
            }
            .navigationTitle("阅读设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var typographyTab: some View {
        VStack(alignment: .leading, spacing: 18) {
            sliderRow("字号", value: Binding(
                get: { store.settings.fontSize },
                set: { v in store.updateSettings { $0.fontSize = v } }
            ), range: 12...34, step: 1, format: "%.0f")

            sliderRow("行距", value: Binding(
                get: { store.settings.lineSpacing },
                set: { v in store.updateSettings { $0.lineSpacing = v } }
            ), range: 0...24, step: 1, format: "%.0f")

            sliderRow("段距", value: Binding(
                get: { store.settings.paragraphSpacing },
                set: { v in store.updateSettings { $0.paragraphSpacing = v } }
            ), range: 0...30, step: 1, format: "%.0f")

            Toggle("首行缩进", isOn: Binding(
                get: { store.settings.indentFirstLine },
                set: { v in store.updateSettings { $0.indentFirstLine = v } }
            ))
            Toggle("加粗", isOn: Binding(
                get: { store.settings.bold },
                set: { v in store.updateSettings { $0.bold = v } }
            ))

            VStack(alignment: .leading, spacing: 8) {
                Text("字体").font(.footnote).foregroundStyle(.secondary)
                Picker("字体", selection: Binding(
                    get: { store.settings.fontName },
                    set: { v in store.updateSettings { $0.fontName = v } }
                )) {
                    Text("系统").tag("")
                    Text("宋体").tag("Songti SC")
                    Text("楷体").tag("Kaiti SC")
                    Text("黑体").tag("Heiti SC")
                    Text("圆体").tag("Yuanti SC")
                }
                .pickerStyle(.menu)
            }
        }
    }

    private var themeTab: some View {
        VStack(alignment: .leading, spacing: 18) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 74), spacing: 12)], spacing: 12) {
                ForEach(ThemeCatalog.all) { item in
                    Button {
                        theme.apply(themeID: item.id)
                    } label: {
                        VStack(spacing: 6) {
                            RoundedRectangle(cornerRadius: 10)
                                .fill(item.background)
                                .frame(height: 56)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10)
                                        .stroke(store.settings.themeID == item.id ? Color.accentColor : Color.gray.opacity(0.25),
                                                lineWidth: store.settings.themeID == item.id ? 2 : 1)
                                )
                                .overlay(
                                    Text("文").font(.system(size: 18))
                                        .foregroundStyle(item.text)
                                )
                            Text(item.name).font(.caption2)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }

            Toggle("跟随系统深色模式", isOn: Binding(
                get: { store.settings.followSystemDark },
                set: { v in store.updateSettings { $0.followSystemDark = v } }
            ))
        }
    }

    private var pageTurnTab: some View {
        VStack(alignment: .leading, spacing: 18) {
            Picker("翻页方式", selection: Binding(
                get: { store.settings.pageTurn },
                set: { v in
                    store.updateSettings { $0.pageTurn = v }
                    model.reloadPagination()
                }
            )) {
                ForEach(PageTurnStyle.allCases) { style in
                    Text(style.title).tag(style)
                }
            }
            .pickerStyle(.inline)

            Toggle("点击翻页", isOn: Binding(
                get: { store.settings.tapToTurn },
                set: { v in store.updateSettings { $0.tapToTurn = v } }
            ))

            Stepper("预加载章节：\(store.settings.preloadCount)",
                    value: Binding(
                        get: { store.settings.preloadCount },
                        set: { v in store.updateSettings { $0.preloadCount = v } }
                    ), in: 0...30)
        }
    }

    private var otherTab: some View {
        VStack(alignment: .leading, spacing: 18) {
            Toggle("显示时间与电量", isOn: Binding(
                get: { store.settings.showBatteryAndTime },
                set: { v in store.updateSettings { $0.showBatteryAndTime = v } }
            ))
            Toggle("全屏阅读", isOn: Binding(
                get: { store.settings.fullScreen },
                set: { v in store.updateSettings { $0.fullScreen = v } }
            ))
            Toggle("显示状态栏", isOn: Binding(
                get: { store.settings.showStatusBar },
                set: { v in store.updateSettings { $0.showStatusBar = v } }
            ))
            Toggle("自动缓存后续章节", isOn: Binding(
                get: { store.settings.autoCacheNext },
                set: { v in store.updateSettings { $0.autoCacheNext = v } }
            ))

            Button(role: .destructive) {
                model.clearCache()
            } label: {
                Text("清理本书缓存")
            }
        }
    }

    private func sliderRow(_ title: String, value: Binding<Double>,
                           range: ClosedRange<Double>, step: Double, format: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.footnote).foregroundStyle(.secondary)
                Spacer()
                Text(String(format: format, value.wrappedValue))
                    .font(.footnote.monospacedDigit())
            }
            Slider(value: value, in: range, step: step)
        }
    }
}

// MARK: - 朗读

final class TTSController: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    @Published var speaking = false
    private let synthesizer = AVSpeechSynthesizer()
    var onFinish: (() -> Void)?

    override init() {
        super.init()
        synthesizer.delegate = self
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio,
                                                         options: [.duckOthers, .allowBluetooth])
        try? AVAudioSession.sharedInstance().setActive(true)
    }

    func speak(_ text: String, rate: Double, pitch: Double, voiceIdentifier: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        synthesizer.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = Float(max(0.1, min(0.9, rate)))
        utterance.pitchMultiplier = Float(max(0.5, min(2.0, pitch)))
        if !voiceIdentifier.isEmpty, let voice = AVSpeechSynthesisVoice(identifier: voiceIdentifier) {
            utterance.voice = voice
        } else {
            utterance.voice = AVSpeechSynthesisVoice(language: "zh-CN")
        }
        synthesizer.speak(utterance)
        speaking = true
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        speaking = false
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        speaking = false
        onFinish?()
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        speaking = false
    }
}

struct TTSBar: View {
    @ObservedObject var model: ReaderModel
    @EnvironmentObject private var store: Store
    @EnvironmentObject private var theme: ThemeManager
    @Environment(\.dismiss) private var dismiss
    @StateObject private var tts = TTSController()
    @State private var autoNext = true
    @State private var currentPage = 0

    var body: some View {
        VStack(spacing: 18) {
            HStack {
                Text("朗读").font(.headline)
                Spacer()
                Button("关闭") {
                    tts.stop()
                    dismiss()
                }
            }

            Text(model.pages.indices.contains(currentPage) ? model.pages[currentPage] : "")
                .font(.footnote)
                .lineLimit(4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))

            HStack(spacing: 30) {
                Button {
                    if currentPage > 0 { currentPage -= 1 }
                } label: {
                    Image(systemName: "backward.end.fill")
                }
                Button {
                    if tts.speaking {
                        tts.stop()
                    } else {
                        startReading()
                    }
                } label: {
                    Image(systemName: tts.speaking ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 46))
                }
                Button {
                    if model.pages.indices.contains(currentPage + 1) { currentPage += 1 }
                } label: {
                    Image(systemName: "forward.end.fill")
                }
            }
            .foregroundStyle(Color.accentColor)

            VStack(alignment: .leading, spacing: 4) {
                Text("语速 \(String(format: "%.2f", store.settings.ttsRate))")
                    .font(.caption).foregroundStyle(.secondary)
                Slider(value: Binding(
                    get: { store.settings.ttsRate },
                    set: { v in store.updateSettings { $0.ttsRate = v } }
                ), in: 0.1...0.9)
            }

            Toggle("读完自动翻页 / 下一章", isOn: $autoNext)
        }
        .padding(20)
        .presentationDetents([.height(380)])
        .onAppear {
            currentPage = model.pageIndex
            tts.onFinish = {
                guard autoNext else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    if model.pages.indices.contains(currentPage + 1) {
                        currentPage += 1
                    } else if model.book.chapters.indices.contains(model.book.currentChapter + 1) {
                        model.goNextChapter()
                        currentPage = 0
                    } else {
                        return
                    }
                    startReading()
                }
            }
        }
        .onDisappear { tts.stop() }
    }

    private func startReading() {
        guard model.pages.indices.contains(currentPage) else { return }
        tts.speak(model.pages[currentPage],
                  rate: store.settings.ttsRate,
                  pitch: store.settings.ttsPitch,
                  voiceIdentifier: store.settings.ttsVoice)
    }
}
