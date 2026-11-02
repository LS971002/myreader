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

// MARK: - 朗读中心（全局单例：复刻源APP JxdTTSManager 分段调度 + JxdLocalTTS 参数映射）

/// 整章分段朗读 + 滑动窗口缓存 + APP内常驻后台：
/// - 向前预合成 3 段（AVSpeech 队列逐段补位），向后保留已播 10 段供上一曲回退
/// - 语速/音调/音色实时从当前段重启；暂停/恢复为真暂停（.word）
/// - 独占音频接入系统 NowPlaying（锁屏/控制中心/耳机线控可遥控）
/// - 章尾自动接续下一章（剩余 ≤3 段时后台预取，无缝续读）；全书读完自动停止
/// - 全局单例：切后台/锁屏继续朗读；换书自动杀旧开新；退出朗读定位回阅读页
final class SpeechCenter: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    static let shared = SpeechCenter()

    // MARK: 状态（UI 绑定）
    @Published var presented = false        // 全屏朗读页显示
    @Published var speaking = false         // 有朗读任务（播放中或暂停中）
    @Published var paused = false
    @Published var currentSegment = 0
    @Published var totalSegments = 0
    @Published var currentChapter = 0
    @Published var finishedNotice: String?
    /// 当前段内正在朗读的字范围（NSRange，willSpeakRange 回调）。
    @Published var highlightRange: NSRange?

    // MARK: 参数（调节后实时应用）
    var rate: Float = 0.5
    var pitch: Float = 1.0
    var voiceIdentifier: String = ""
    var mixAudio = false
    var autoNext = true
    var segmentChars = 500

    private let synthesizer = AVSpeechSynthesizer()
    /// 段落数组（@Published：TTSPage 正文渲染跟随换章刷新）。
    @Published private(set) var segments: [String] = []
    private var playedStack: [Int] = []          // 已播段历史（最多10，上一曲回退窗口）
    private var utteranceIndex: [ObjectIdentifier: Int] = [:]
    private var chapterLoading = false
    /// 远程命令与各自 target token（removeTarget 是命令对象的方法）。
    private var remoteCommands: [(command: MPRemoteCommand, token: Any)] = []

    /// 拉章文本的来源（ReaderModel.chapterText 带磁盘/网络缓存）。
    /// strong 引用：朗读期间保持该书阅读模型存活（后台续章预取依赖它）。
    private(set) var model: ReaderModel?
    var currentBookID: UUID? { model?.bookID }

    private override init() {
        super.init()
        synthesizer.delegate = self
        applyAudioSession()
        setupRemoteCommands()
    }

    // MARK: - 打开朗读（阅读页菜单入口）

    /// 同书 → 续播仅显示页面；异书 → 杀旧开新。
    func begin(model: ReaderModel) {
        syncSettings(from: model.store)
        if let current = self.model, current.bookID == model.bookID, speaking {
            presented = true
            restartFromCurrent()   // 设置可能已变化，从当前段以新参数重启
            return
        }
        stopAll()
        self.model = model
        presented = true
        start(chapter: model.book.currentChapter)
    }

    /// 从 Store 同步朗读参数。
    func syncSettings(from store: Store) {
        rate = store.settings.ttsRate
        pitch = store.settings.ttsPitch
        voiceIdentifier = store.settings.ttsVoice
        mixAudio = store.settings.ttsMixAudio
        autoNext = store.settings.ttsAutoNext
        segmentChars = store.settings.ttsSegmentChars
    }

    /// 最小化：回阅读界面，后台继续朗读。
    func minimize() {
        presented = false
    }

    /// 手动退出朗读：定位回当前段所在页 + 停止。
    func exitAndLocate() {
        if let model, segments.indices.contains(currentSegment) {
            let snippet = String(segments[currentSegment].prefix(24))
            model.revealPage(chapter: currentChapter, snippet: snippet)
        }
        stopAll()
        presented = false
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
        highlightRange = nil
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

    /// 分段字数变化 → 重切当前章，从当前朗读内容处继续（锚点=当前段首句前缀）。
    func resegment(chunk: Int) {
        segmentChars = max(100, chunk)
        guard let model, !segments.isEmpty else { return }
        let anchor = segments.indices.contains(currentSegment)
            ? String(segments[currentSegment].prefix(20)) : nil
        Task { [weak self] in
            let text = await model.chapterText(self?.currentChapter ?? 0)
            guard let self, !text.isEmpty else { return }
            let newSegments = Self.splitSegments(text, chunk: max(100, self.segmentChars))
            self.segments = newSegments
            self.totalSegments = newSegments.count
            if let anchor, let idx = newSegments.firstIndex(where: { $0.contains(anchor) }) {
                self.playSegment(idx)
            } else {
                self.playSegment(min(self.currentSegment, max(0, newSegments.count - 1)))
            }
        }
    }

    func stopAll() {
        synthesizer.stopSpeaking(at: .immediate)
        utteranceIndex.removeAll()
        speaking = false
        paused = false
        highlightRange = nil
        segments = []
        totalSegments = 0
        currentSegment = 0
        playedStack.removeAll()
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

    /// 正在朗读的字范围（源APP notifyPlayRange: 同款——阅读界面高亮跟随）。
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                           willSpeakRangeOfSpeechString characterRange: NSRange,
                           utterance: AVSpeechUtterance) {
        guard utteranceIndex[ObjectIdentifier(utterance)] != nil else { return }
        highlightRange = characterRange
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        guard let idx = utteranceIndex[ObjectIdentifier(utterance)] else { return }
        currentSegment = idx
        highlightRange = nil
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
        func bind(_ command: MPRemoteCommand, handler: @escaping () -> Void) {
            // addTarget 返回 Any（非Optional）
            let token = command.addTarget { _ in
                DispatchQueue.main.async { handler() }
                return .success
            }
            remoteCommands.append((command, token))
        }
        bind(center.playCommand) { [weak self] in self?.resume() }
        bind(center.pauseCommand) { [weak self] in self?.pause() }
        bind(center.nextTrackCommand) { [weak self] in self?.next() }
        bind(center.previousTrackCommand) { [weak self] in self?.prev() }
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
        info[MPMediaItemPropertyPlaybackDuration] = Double(max(totalSegments, 1))
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = Double(currentSegment)
        info[MPNowPlayingInfoPropertyPlaybackRate] = paused ? 0.0 : 1.0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
}

// MARK: - 全屏朗读页（参照源APP：正文显示 + 朗读高亮跟随 + 控制台悬浮）

struct TTSPage: View {
    @ObservedObject private var center = SpeechCenter.shared
    @EnvironmentObject private var store: Store
    @EnvironmentObject private var theme: ThemeManager
    @State private var autoScroll = true

    var body: some View {
        VStack(spacing: 0) {
            // 顶部：返回(最小化) + 书名/章节 + 退出朗读
            HStack(spacing: 12) {
                Button {
                    center.minimize()
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 17, weight: .medium))
                }
                VStack(spacing: 2) {
                    Text(center.model?.book.name ?? "朗读")
                        .font(.subheadline).lineLimit(1)
                    Text(chapterTitle)
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                .frame(maxWidth: .infinity)
                if let notice = center.finishedNotice {
                    Text(notice).font(.caption2).foregroundStyle(.orange).lineLimit(1)
                }
                Button {
                    center.exitAndLocate()
                } label: {
                    Text("退出朗读")
                        .font(.footnote.weight(.medium))
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(Color.accentColor.opacity(0.14), in: Capsule())
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.regularMaterial)

            // 正文（当前章全文，段落高亮跟随）
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(0..<max(center.segments.count, 1), id: \.self) { idx in
                            segmentText(idx)
                                .id(idx)
                                .padding(.horizontal, 4)
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 20)
                }
                .onAppear {
                    // 打开时定位到正在朗读的段
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        proxy.scrollTo(center.currentSegment, anchor: .center)
                    }
                }
                .onChange(of: center.currentSegment) { newValue in
                    guard autoScroll, presented else { return }
                    withAnimation(.easeInOut(duration: 0.35)) {
                        proxy.scrollTo(newValue, anchor: .center)
                    }
                }
            }

            // 底部控制台
            controlPanel
                .background(.regularMaterial)
        }
        .background(theme.current.background.ignoresSafeArea())
        .preferredColorScheme(store.settings.followSystemDark ? nil : .light)
        .onAppear {
            center.syncSettings(from: store)
            center.applyAudioSession()
        }
    }

    private var presented: Bool { center.presented }

    private var chapterTitle: String {
        guard let chapters = center.model?.book.chapters,
              chapters.indices.contains(center.currentChapter) else { return "" }
        return chapters[center.currentChapter].title
    }

    /// 单段渲染：当前段底色 + 正在朗读的字范围着色。
    @ViewBuilder
    private func segmentText(_ idx: Int) -> some View {
        let isCurrent = idx == center.currentSegment && center.speaking
        Group {
            if isCurrent {
                highlightedSegment
            } else {
                Text(center.segments.indices.contains(idx) ? center.segments[idx] : "")
                    .font(.system(size: 17))
                    .foregroundStyle(theme.current.text)
                    .lineSpacing(6)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isCurrent ? Color.accentColor.opacity(0.10) : Color.clear)
        )
    }

    /// 当前段：highlightRange 内的字高亮着色。
    /// 注意：Text 拼接结果上 .foregroundStyle 会命中 Text 专属重载(iOS17+)，
    /// 颜色一律用 .foregroundColor(iOS13+) 放在子段上。
    @ViewBuilder
    private var highlightedSegment: some View {
        let text = center.segments.indices.contains(center.currentSegment)
            ? center.segments[center.currentSegment] : ""
        if let range = center.highlightRange,
           range.location < text.count,
           let swiftLower = text.index(text.startIndex, offsetBy: range.location,
                                        limitedBy: text.endIndex),
           let swiftUpper = text.index(swiftLower, offsetBy: range.length,
                                        limitedBy: text.endIndex) {
            (Text(String(text[text.startIndex..<swiftLower]))
                .foregroundColor(theme.current.text)
            + Text(String(text[swiftLower..<swiftUpper]))
                .foregroundColor(Color.accentColor)
                .fontWeight(.medium)
            + Text(String(text[swiftUpper...]))
                .foregroundColor(theme.current.text))
            .font(.system(size: 17))
            .lineSpacing(6)
        } else {
            Text(text)
                .font(.system(size: 17))
                .foregroundColor(theme.current.text)
                .lineSpacing(6)
        }
    }

    private var controlPanel: some View {
        VStack(spacing: 12) {
            Text("第 \(center.currentSegment + 1)/\(center.totalSegments) 段 · 第 \(center.currentChapter + 1)/\(totalChapters) 章")
                .font(.caption).foregroundStyle(.secondary)

            HStack(spacing: 40) {
                Button {
                    center.prev()
                } label: {
                    Image(systemName: "backward.end.fill").font(.title2)
                }
                .disabled(!center.speaking)

                Button {
                    center.togglePlayPause()
                } label: {
                    Image(systemName: center.speaking && !center.paused
                          ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 48))
                }

                Button {
                    center.next()
                } label: {
                    Image(systemName: "forward.end.fill").font(.title2)
                }
                .disabled(!center.speaking)
            }
            .foregroundStyle(Color.accentColor)

            HStack(spacing: 24) {
                // 语速（独立滑块，拖动结束实时生效）
                VStack(alignment: .leading, spacing: 4) {
                    Text("语速，百分之\(Int(store.settings.ttsRatePercent))")
                        .font(.caption2).foregroundStyle(.secondary)
                    Slider(value: $store.settings.ttsRatePercent, in: 0...100, step: 1,
                           onEditingChanged: { editing in
                        if !editing {
                            center.rate = store.settings.ttsRate
                            center.restartFromCurrent()
                        }
                    })
                }
                // 音调（独立滑块，拖动结束实时生效）
                VStack(alignment: .leading, spacing: 4) {
                    Text("音调，百分之\(Int(store.settings.ttsPitchPercent))")
                        .font(.caption2).foregroundStyle(.secondary)
                    Slider(value: $store.settings.ttsPitchPercent, in: 0...100, step: 1,
                           onEditingChanged: { editing in
                        if !editing {
                            center.pitch = store.settings.ttsPitch
                            center.restartFromCurrent()
                        }
                    })
                }
            }

            HStack {
                Toggle("混合音频", isOn: Binding(
                    get: { store.settings.ttsMixAudio },
                    set: { v in
                        store.updateSettings { $0.ttsMixAudio = v }
                        center.mixAudio = v
                        center.applyAudioSession()
                    }
                ))
                .font(.caption)
                Toggle("自动接续", isOn: Binding(
                    get: { store.settings.ttsAutoNext },
                    set: { v in
                        store.updateSettings { $0.ttsAutoNext = v }
                        center.autoNext = v
                    }
                ))
                .font(.caption)
            }

            // 一次朗读内容块的字数配置（对齐源APP「本地听书分段字符数」）
            Stepper("分段字数：\(store.settings.ttsSegmentChars)",
                    value: Binding(
                        get: { store.settings.ttsSegmentChars },
                        set: { v in
                            store.updateSettings { $0.ttsSegmentChars = v }
                            center.resegment(chunk: v)
                        }
                    ), in: 100...2000, step: 100)
                .font(.caption)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var totalChapters: Int {
        center.model?.book.chapters.count ?? 0
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
