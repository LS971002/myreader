import SwiftUI
import AVFoundation
import MediaPlayer

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
        return ascending ? filtered : Array(filtered.reversed())
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
        .compatibleDetents(.mediumSheet)
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

// MARK: - 朗读引擎（复刻源APP JxdTTSManager 分段调度 + JxdLocalTTS 参数映射）

/// 整章分段朗读 + 滑动窗口缓存：
/// - 向前预合成 3 段（AVSpeech 队列逐段补位），向后保留已播 10 段供上一曲回退
/// - 语速/音调/音色实时从当前段重启；暂停/恢复为真暂停（.word）
/// - 独占音频接入系统 NowPlaying（锁屏/控制中心/耳机线控可遥控）
/// - 章尾自动接续下一章（剩余 ≤3 段时后台预取，无缝续读）；全书读完自动停止
final class SpeechManager: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    // MARK: 状态（UI 绑定）
    @Published var speaking = false        // 有朗读任务（播放中或暂停中）
    @Published var paused = false
    @Published var currentSegment = 0
    @Published var totalSegments = 0
    @Published var currentChapter = 0
    @Published var segmentPreview = ""
    @Published var finishedNotice: String?

    // MARK: 参数（调节后实时应用）
    var rate: Float = 0.5
    var pitch: Float = 1.0
    var voiceIdentifier: String = ""
    var mixAudio = false
    var autoNext = true
    var segmentChars = 500

    private let synthesizer = AVSpeechSynthesizer()
    private var segments: [String] = []
    private var playedStack: [Int] = []          // 已播段历史（最多10，上一曲回退窗口）
    private var utteranceIndex: [ObjectIdentifier: Int] = [:]
    private var chapterLoading = false
    private var remoteTokens: [Any?] = []

    /// 拉章文本的来源（ReaderModel.chapterText 带磁盘/网络缓存）。
    weak var model: ReaderModel?

    override init() {
        super.init()
        synthesizer.delegate = self
        applyAudioSession()
        setupRemoteCommands()
    }

    deinit {
        for token in remoteTokens {
            if let token { MPRemoteCommandCenter.shared().removeTarget(token) }
        }
    }

    // MARK: - 音频会话（独占 / 混合 实时切换）

    func applyAudioSession() {
        let session = AVAudioSession.sharedInstance()
        let options: AVAudioSession.CategoryOptions = mixAudio ? [.mixWithOthers] : []
        try? session.setCategory(.playback, mode: .spokenAudio, options: options)
        try? session.setActive(true)
    }

    // MARK: - 启动

    func start(chapter: Int) {
        Task { await startChapter(chapter) }
    }

    func startChapter(_ chapter: Int, fromEnd: Bool = false) async {
        guard let model, !chapterLoading else { return }
        chapterLoading = true
        defer { chapterLoading = false }
        let text = await model.chapterText(chapter)
        guard !text.isEmpty else {
            finishedNotice = "第 \(chapter + 1) 章没有内容，朗读停止"
            stopAll()
            return
        }
        currentChapter = chapter
        segments = Self.splitSegments(text, chunk: max(100, segmentChars))
        totalSegments = segments.count
        playedStack.removeAll()
        finishedNotice = nil
        playSegment(fromEnd ? segments.count - 1 : 0)
    }

    // MARK: - 分段播放（窗口预合成3段）

    private func playSegment(_ index: Int) {
        guard segments.indices.contains(index) else { return }
        synthesizer.stopSpeaking(at: .immediate)
        utteranceIndex.removeAll()
        for k in index...min(index + 2, segments.count - 1) {
            enqueue(k)
        }
        speaking = true
        paused = false
    }

    private func enqueue(_ index: Int) {
        guard segments.indices.contains(index) else { return }
        let utterance = makeUtterance(segments[index])
        utteranceIndex[ObjectIdentifier(utterance)] = index
        synthesizer.speak(utterance)
    }

    private func makeUtterance(_ text: String) -> AVSpeechUtterance {
        let u = AVSpeechUtterance(string: text)
        u.rate = max(AVSpeechUtteranceMinimumSpeechRate,
                     min(AVSpeechUtteranceMaximumSpeechRate, rate))
        u.pitchMultiplier = max(0.5, min(1.5, pitch))
        u.volume = 1.0     // 源APP写死常量1.0
        if !voiceIdentifier.isEmpty, let voice = AVSpeechSynthesisVoice(identifier: voiceIdentifier) {
            u.voice = voice
        } else {
            u.voice = AVSpeechSynthesisVoice(language: "zh-CN")
        }
        return u
    }

    // MARK: - 控制

    func pause() {
        guard speaking, !paused else { return }
        synthesizer.pauseSpeaking(at: .word)
        paused = true
        updateNowPlaying()
    }

    func resume() {
        guard speaking, paused else { return }
        synthesizer.continueSpeaking()
        paused = false
        updateNowPlaying()
    }

    func togglePlayPause() {
        if speaking && !paused {
            pause()
        } else if paused {
            resume()
        } else {
            start(chapter: currentChapter)
        }
    }

    /// 下一曲：当前段+1；章末则接下一章（向下无限探索直到全书读完）。
    func next() {
        if currentSegment + 1 < totalSegments {
            playSegment(currentSegment + 1)
        } else {
            goNeighborChapter(forward: true)
        }
    }

    /// 上一曲：回退已播段（窗口10段）；用尽则回上一章末段。
    func prev() {
        if let last = playedStack.popLast() {
            playSegment(last)
        } else if currentSegment > 0 {
            playSegment(currentSegment - 1)
        } else {
            goNeighborChapter(forward: false)
        }
    }

    private func goNeighborChapter(forward: Bool) {
        guard let model else { return }
        let target = forward ? currentChapter + 1 : currentChapter - 1
        guard model.book.chapters.indices.contains(target) else {
            if forward { finishedNotice = "全书已读完" }
            stopAll()
            return
        }
        Task { await startChapter(target, fromEnd: !forward) }
    }

    /// 参数（语速/音调/音色）变化 → 从当前段实时重启。
    func restartFromCurrent() {
        guard speaking else { return }
        playSegment(currentSegment)
    }

    func stopAll() {
        synthesizer.stopSpeaking(at: .immediate)
        utteranceIndex.removeAll()
        speaking = false
        paused = false
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    // MARK: - 切分（按句边界聚合，对齐源APP「本地听书分段字符数」）

    static func splitSegments(_ text: String, chunk: Int) -> [String] {
        var sentences: [String] = []
        var current = ""
        for ch in text {
            current.append(ch)
            if "。！？!?\n；;".contains(ch) {
                sentences.append(current)
                current = ""
            }
        }
        if !current.isEmpty { sentences.append(current) }

        var segments: [String] = []
        var buffer = ""
        for sentence in sentences {
            let piece = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !piece.isEmpty else { continue }
            if !buffer.isEmpty && buffer.count + piece.count > chunk {
                segments.append(buffer)
                buffer = piece
            } else {
                buffer += piece
            }
        }
        if !buffer.isEmpty { segments.append(buffer) }
        return segments.isEmpty ? [text] : segments
    }

    // MARK: - AVSpeechSynthesizerDelegate（回调在主线程）

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        guard let idx = utteranceIndex[ObjectIdentifier(utterance)] else { return }
        currentSegment = idx
        if segments.indices.contains(idx) {
            segmentPreview = String(segments[idx].prefix(80))
        }
        updateNowPlaying()
        prefetchNextChapterIfNeeded(currentIdx: idx)
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        guard let idx = utteranceIndex.removeValue(forKey: ObjectIdentifier(utterance)) else { return }
        // 记录已播段（上一曲回退窗口，最多10）
        playedStack.append(idx)
        if playedStack.count > 10 { playedStack.removeFirst() }

        // 滑动窗口：完成一段补一段（维持3段预合成）
        let refill = idx + 3
        if refill < segments.count {
            enqueue(refill)
        } else if idx + 1 >= segments.count {
            handleChapterFinished()
        }
        updateNowPlaying()
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        utteranceIndex.removeValue(forKey: ObjectIdentifier(utterance))
    }

    private func handleChapterFinished() {
        guard let model else { stopAll(); return }
        let nextChapter = currentChapter + 1
        guard model.book.chapters.indices.contains(nextChapter) else {
            finishedNotice = "全书已读完"
            stopAll()
            return
        }
        guard autoNext else {
            stopAll()
            return
        }
        Task { await startChapter(nextChapter) }
    }

    /// 边界自动缓存：本章剩 ≤3 段时后台拉取下一章（写入磁盘缓存）。
    private func prefetchNextChapterIfNeeded(currentIdx: Int) {
        guard autoNext, let model,
              currentIdx >= totalSegments - 3,
              model.book.chapters.indices.contains(currentChapter + 1) else { return }
        let nextChapter = currentChapter + 1
        Task { [weak model] in
            _ = await model?.chapterText(nextChapter)
        }
    }

    // MARK: - 系统遥控（独占音频时锁屏/下拉控制中心/耳机线控可用）

    private func setupRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        remoteTokens.append(center.playCommand.addTarget { [weak self] _ in
            DispatchQueue.main.async { self?.resume() }
            return .success
        })
        remoteTokens.append(center.pauseCommand.addTarget { [weak self] _ in
            DispatchQueue.main.async { self?.pause() }
            return .success
        })
        remoteTokens.append(center.nextTrackCommand.addTarget { [weak self] _ in
            DispatchQueue.main.async { self?.next() }
            return .success
        })
        remoteTokens.append(center.previousTrackCommand.addTarget { [weak self] _ in
            DispatchQueue.main.async { self?.prev() }
            return .success
        })
    }

    private func updateNowPlaying() {
        guard speaking else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        let bookName = model?.book.name ?? ""
        let chapterTitle: String
        if let chapters = model?.book.chapters, chapters.indices.contains(currentChapter) {
            chapterTitle = chapters[currentChapter].title
        } else {
            chapterTitle = ""
        }
        var info: [String: Any] = [:]
        info[MPMediaItemPropertyTitle] = chapterTitle.isEmpty ? bookName : chapterTitle
        info[MPMediaItemPropertyArtist] = bookName
        info[MPMediaItemPropertyAlbumTitle] = "听书"
        info[MPNowPlayingInfoPropertyPlaybackDuration] = Double(max(totalSegments, 1))
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = Double(currentSegment)
        info[MPNowPlayingInfoPropertyPlaybackRate] = paused ? 0.0 : 1.0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
}

// MARK: - 朗读面板

struct TTSBar: View {
    @ObservedObject var model: ReaderModel
    @EnvironmentObject private var store: Store
    @EnvironmentObject private var theme: ThemeManager
    @Environment(\.dismiss) private var dismiss
    @StateObject private var manager = SpeechManager()

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Text("朗读").font(.headline)
                Spacer()
                if let notice = manager.finishedNotice {
                    Text(notice).font(.caption2).foregroundStyle(.orange)
                }
                Button("关闭") {
                    manager.stopAll()
                    dismiss()
                }
            }

            Text(manager.segmentPreview.isEmpty ? "准备中…" : manager.segmentPreview)
                .font(.footnote)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))

            Text("第 \(manager.currentSegment + 1)/\(manager.totalSegments) 段 · 第 \(manager.currentChapter + 1)/\(model.book.chapters.count) 章")
                .font(.caption).foregroundStyle(.secondary)

            HStack(spacing: 34) {
                Button {
                    manager.prev()
                } label: {
                    Image(systemName: "backward.end.fill").font(.title2)
                }
                .disabled(!manager.speaking)

                Button {
                    manager.togglePlayPause()
                } label: {
                    Image(systemName: manager.speaking && !manager.paused
                          ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 46))
                }

                Button {
                    manager.next()
                } label: {
                    Image(systemName: "forward.end.fill").font(.title2)
                }
                .disabled(!manager.speaking)
            }
            .foregroundStyle(Color.accentColor)

            // 语速（独立滑块，拖动结束实时生效）
            VStack(alignment: .leading, spacing: 4) {
                Text("语速，百分之\(Int(store.settings.ttsRatePercent))")
                    .font(.footnote).foregroundStyle(.secondary)
                Slider(value: $store.settings.ttsRatePercent, in: 0...100, step: 1,
                       onEditingChanged: { editing in
                    if !editing {
                        manager.rate = store.settings.ttsRate
                        manager.restartFromCurrent()
                    }
                })
            }

            // 音调（独立滑块，拖动结束实时生效）
            VStack(alignment: .leading, spacing: 4) {
                Text("音调，百分之\(Int(store.settings.ttsPitchPercent))")
                    .font(.footnote).foregroundStyle(.secondary)
                Slider(value: $store.settings.ttsPitchPercent, in: 0...100, step: 1,
                       onEditingChanged: { editing in
                    if !editing {
                        manager.pitch = store.settings.ttsPitch
                        manager.restartFromCurrent()
                    }
                })
            }

            Toggle("混合音频（不打断其他App声音）", isOn: Binding(
                get: { store.settings.ttsMixAudio },
                set: { v in
                    store.updateSettings { $0.ttsMixAudio = v }
                    manager.mixAudio = v
                    manager.applyAudioSession()
                }
            ))
            Toggle("读完自动接续下一章", isOn: Binding(
                get: { store.settings.ttsAutoNext },
                set: { v in
                    store.updateSettings { $0.ttsAutoNext = v }
                    manager.autoNext = v
                }
            ))
        }
        .padding(20)
        .compatibleDetents(.bar)
        .onAppear {
            manager.model = model
            manager.rate = store.settings.ttsRate
            manager.pitch = store.settings.ttsPitch
            manager.voiceIdentifier = store.settings.ttsVoice
            manager.mixAudio = store.settings.ttsMixAudio
            manager.autoNext = store.settings.ttsAutoNext
            manager.segmentChars = store.settings.ttsSegmentChars
            manager.applyAudioSession()
            if !manager.speaking {
                manager.start(chapter: model.book.currentChapter)
            }
        }
        .onDisappear {
            manager.stopAll()
        }
    }
}

// MARK: - iOS 15 兼容的 sheet 高度

enum CompatibleDetent {
    case mediumSheet
    case bar
}

extension View {
    /// `.presentationDetents` 是 iOS 16+，iOS 15 上退化为默认高度。
    @ViewBuilder
    func compatibleDetents(_ style: CompatibleDetent) -> some View {
        if #available(iOS 16.0, *) {
            switch style {
            case .mediumSheet:
                self.presentationDetents([.medium, .large])
            case .bar:
                self.presentationDetents([.height(380)])
            }
        } else {
            self
        }
    }
}
