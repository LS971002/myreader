import SwiftUI
import UIKit

struct ReaderView: View {
    @StateObject private var model: ReaderModel
    @EnvironmentObject private var store: Store
    @EnvironmentObject private var theme: ThemeManager
    @Environment(\.dismiss) private var dismiss

    @State private var showMenu = false
    @State private var showCatalog = false
    @State private var showSettings = false
    @State private var showSourceSwitch = false
    /// 文本选择模式：开启后正文换成可长按选字的 UITextView。
    @State private var selecting = false
    @State private var toast: String?

    init(book: Book, store: Store) {
        _model = StateObject(wrappedValue: ReaderModel(store: store, book: book))
    }

    private var settings: AppSettings { store.settings }

    var body: some View {
        GeometryReader { geo in
            let horizontal: CGFloat = 20
            let bottomInset: CGFloat = settings.showBatteryAndTime ? 34 : 24
            let contentSize = CGSize(
                width: geo.size.width - horizontal * 2,
                height: geo.size.height - bottomInset - 30
            )
            ZStack {
                theme.current.background.ignoresSafeArea()

                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    pageContent(size: contentSize)
                        .frame(width: contentSize.width, height: contentSize.height, alignment: .topLeading)
                        .clipped()
                        // 菜单出现时正文缩放居中：完整可见，不被上下菜单遮挡
                        .scaleEffect(menuScale(geo: geo), anchor: .center)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, horizontal)
                .padding(.bottom, bottomInset)
                .padding(.top, 8)

                if settings.showBatteryAndTime && !selecting {
                    statusBar
                }

                if model.loading {
                    ProgressView()
                        .tint(theme.current.text)
                }

                if let message = model.errorMessage, !model.loading {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .padding(10)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
                        .padding(.horizontal, 30)
                }

                if selecting {
                    selectionBar
                }

                if let toast {
                    VStack {
                        Spacer()
                        Text(toast)
                            .font(.footnote)
                            .padding(.horizontal, 14).padding(.vertical, 8)
                            .background(.ultraThinMaterial, in: Capsule())
                            .padding(.bottom, 90)
                            .transition(.opacity)
                    }
                    .allowsHitTesting(false)
                }

                if showMenu && !selecting {
                    menuOverlay
                        .transition(.opacity)
                }
            }
            .onAppear {
                model.updateLayout(size: contentSize)
                model.onAppear()
            }
            .onChange(of: geo.size) { _ in
                model.updateLayout(size: contentSize)
            }
            .onChange(of: settings.fontSize) { _ in model.reloadPagination() }
            .onChange(of: settings.lineSpacing) { _ in model.reloadPagination() }
            .onChange(of: settings.fontName) { _ in model.reloadPagination() }
            .statusBar(hidden: !settings.showStatusBar && settings.fullScreen)
        }
        .navigationBarHidden(true)
        .sheet(isPresented: $showCatalog) {
            CatalogSheet(model: model)
                .environmentObject(store)
                .environmentObject(theme)
        }
        .sheet(isPresented: $showSettings) {
            ReaderSettingsPanel(model: model)
                .environmentObject(store)
                .environmentObject(theme)
        }
        .sheet(isPresented: $showSourceSwitch) {
            SourceSwitchSheet(model: model)
                .environmentObject(store)
        }
    }

    // MARK: - 正文

    @ViewBuilder
    private func pageContent(size: CGSize) -> some View {
        if selecting {
            // 选择模式：正文渲染为可选 UITextView（长按/双击选字，系统菜单可拷贝）。
            // 上下滚动模式下给整章文本并允许滚动，分页模式只给当前页。
            let scrollMode = settings.pageTurn == .scroll
            SelectablePageCanvas(
                text: scrollMode ? model.pages.joined(separator: "\n") : currentPageText,
                settings: settings,
                theme: theme.current,
                scrollable: scrollMode
            )
        } else if settings.pageTurn == .scroll {
            ScrollView(.vertical, showsIndicators: false) {
                PageCanvas(text: model.pages.joined(separator: "\n"),
                           settings: settings,
                           theme: theme.current)
                    .frame(width: nil)
            }
            .onTapGesture { withAnimation { showMenu.toggle() } }
        } else {
            // 分页：交给 UIScrollView(isPagingEnabled) 原生分页。
            // SwiftUI 侧不再有 DragGesture / offset / transition，拖动时
            // 不触发任何 body 重算，翻页由 UIKit 直接提交 CALayer 位移。
            PagedPagesView(
                pages: model.pages,
                index: model.pageIndex,
                settings: settings,
                theme: theme.current,
                pageSize: size,
                tapToTurn: settings.tapToTurn,
                onIndexChange: { model.setPage($0) },
                onOverflow: { forward in
                    guard !model.loading else { return }
                    if forward { model.goNextChapter() } else { model.goPreviousChapter() }
                },
                onCenterTap: { withAnimation { showMenu.toggle() } }
            )
        }
    }

    /// 菜单可见时的正文缩放比例（让出上下菜单区，内容完整可见）。
    private func menuScale(geo: GeometryProxy) -> CGFloat {
        guard showMenu else { return 1 }
        let menuTop: CGFloat = 56      // 顶部菜单条
        let menuBottom: CGFloat = 86   // 底部按钮条
        let available = geo.size.height - menuTop - menuBottom
        return max(0.5, min(1, available / geo.size.height))
    }

    private var currentPageText: String {
        model.pages.indices.contains(model.pageIndex) ? model.pages[model.pageIndex] : ""
    }

    // MARK: - 状态栏

    private var statusBar: some View {
        VStack {
            HStack {
                Text(model.currentChapterTitle)
                    .font(.system(size: 11))
                    .lineLimit(1)
                Spacer()
                Text(model.progressText)
                    .font(.system(size: 11))
            }
            .foregroundStyle(theme.current.secondary)
            .padding(.horizontal, 20)
            .padding(.top, 4)
            Spacer()
            HStack {
                Text("第 \(model.book.currentChapter + 1)/\(model.book.chapters.count) 章")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.current.secondary)
                Spacer()
                BatteryView(color: theme.current.secondary)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 6)
        }
    }

    // MARK: - 选摘（选择 / 复制）

    private var selectionBar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("长按选字后可拷贝")
                    .font(.caption2)
                    .foregroundStyle(theme.current.secondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Button("复制本页") { copyToPasteboard(currentPageText, label: "本页") }
                    .font(.caption)
                Button("复制本章") { copyToPasteboard(model.pages.joined(separator: "\n"), label: "本章") }
                    .font(.caption)
                Button {
                    withAnimation { selecting = false }
                } label: {
                    Text("完成").font(.caption.weight(.semibold))
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.regularMaterial)
            Spacer()
        }
        .foregroundStyle(Color.primary)
    }

    private func copyToPasteboard(_ text: String, label: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            AppLog.warn("READER", "复制\(label)失败：内容为空")
            return
        }
        UIPasteboard.general.string = trimmed
        AppLog.info("READER", "已复制\(label)：\(trimmed.count)字")
        withAnimation { toast = "已复制\(label)（\(trimmed.count)字）" }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_400_000_000)
            withAnimation { toast = nil }
        }
    }

    // MARK: - 菜单

    private var menuOverlay: some View {
        VStack(spacing: 0) {
            HStack {
                Button {
                    model.commitProgress()
                    store.flush()
                    dismiss()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 18, weight: .medium))
                }
                Spacer()
                VStack(spacing: 2) {
                    Text(model.book.name).font(.subheadline).lineLimit(1)
                    Text(model.currentChapterTitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Button {
                    showCatalog = true
                } label: {
                    Image(systemName: "list.bullet")
                        .font(.system(size: 17, weight: .medium))
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(.regularMaterial)

            Spacer()

            HStack(spacing: 0) {
                // 菜单"上一章"定位到上一章开头（对齐源APP；末页语义仅用于翻页越界连续回退）
                menuButton("上一章", "chevron.up") { model.jump(to: max(0, model.book.currentChapter - 1)) }
                menuButton("目录", "list.triangle") { showCatalog = true }
                menuButton("朗读", "waveform") { SpeechCenter.shared.begin(model: model) }
                // 选摘：进入文本选择模式，可长按选字 / 复制本页与本章
                menuButton("选摘", "textformat.alt") {
                    withAnimation {
                        showMenu = false
                        selecting = true
                    }
                }
                // 换源（在线书可用）
                menuButton(model.book.origin == .online ? "换源" : "设置", "arrow.triangle.2.circlepath") {
                    if model.book.origin == .online {
                        showSourceSwitch = true
                    } else {
                        showSettings = true
                    }
                }
                menuButton("下一章", "chevron.down") { model.goNextChapter() }
            }
            .padding(.vertical, 10)
            .background(.regularMaterial)
        }
        .foregroundStyle(Color.primary)
        .ignoresSafeArea(edges: .bottom)
    }

    private func menuButton(_ title: String, _ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 20))
                Text(title).font(.caption2)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

}

// MARK: - 原生分页正文（UIScrollView）

/// 用 UIScrollView(isPagingEnabled) 承载页面：拖动由 UIKit 直接提交图层位移，
/// 期间 SwiftUI 不参与计算 —— 连续滑动翻页不再掉帧。
/// 只在「当前页 ±1」保留 UILabel（切页时预渲染下一张），翻页过程零重建。
struct PagedPagesView: UIViewRepresentable {
    let pages: [String]
    let index: Int
    let settings: AppSettings
    let theme: ReaderTheme
    let pageSize: CGSize
    let tapToTurn: Bool
    let onIndexChange: (Int) -> Void
    /// 越过首/末页：true = 向后（下一章），false = 向前（上一章）
    let onOverflow: (Bool) -> Void
    let onCenterTap: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UIScrollView {
        let scrollView = UIScrollView()
        scrollView.isPagingEnabled = true
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.alwaysBounceHorizontal = true
        scrollView.bounces = true
        scrollView.backgroundColor = .clear
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.delegate = context.coordinator

        let tap = UITapGestureRecognizer(target: context.coordinator,
                                         action: #selector(Coordinator.handleTap(_:)))
        tap.delegate = context.coordinator
        scrollView.addGestureRecognizer(tap)

        context.coordinator.attach(scrollView)
        return scrollView
    }

    func updateUIView(_ scrollView: UIScrollView, context: Context) {
        context.coordinator.update(with: self, scrollView: scrollView)
    }

    // MARK: 协调器

    final class Coordinator: NSObject, UIScrollViewDelegate, UIGestureRecognizerDelegate {
        private var parent: PagedPagesView
        private weak var scrollView: UIScrollView?
        private var labels: [Int: UILabel] = [:]
        /// 每页已渲染的排版 key：内容不变就不重新给 UILabel 赋 attributedText
        private var labelKeys: [Int: String] = [:]
        private var signature = ""
        private var currentIndex = 0
        private var overflowFired = false
        private var isProgrammatic = false

        init(_ parent: PagedPagesView) {
            self.parent = parent
        }

        func attach(_ scrollView: UIScrollView) {
            self.scrollView = scrollView
            reload(scrollView)
        }

        func update(with parent: PagedPagesView, scrollView: UIScrollView) {
            self.parent = parent
            self.scrollView = scrollView

            let sig = signature(for: parent)
            if sig != signature {
                signature = sig
                reload(scrollView)
                return
            }
            if currentIndex != parent.index {
                currentIndex = min(max(0, parent.index), max(0, parent.pages.count - 1))
                layoutWindow()
                setOffset(to: currentIndex, animated: false)
            }
        }

        /// 页面内容 / 排版参数 / 尺寸变化都要重建。
        private func signature(for parent: PagedPagesView) -> String {
            let contentHash = parent.pages.reduce(0) { $0 &+ $1.hashValue }
            return "\(parent.pages.count)|\(contentHash)|\(Int(parent.pageSize.width))x\(Int(parent.pageSize.height))"
                + "|\(parent.settings.fontSize)|\(parent.settings.lineSpacing)"
                + "|\(parent.settings.paragraphSpacing)|\(parent.settings.fontName)"
                + "|\(parent.settings.bold)|\(parent.settings.indentFirstLine)"
                + "|\(parent.theme.text.description)"
        }

        private func reload(_ scrollView: UIScrollView) {
            overflowFired = false
            currentIndex = min(max(0, parent.index), max(0, parent.pages.count - 1))
            let width = max(1, parent.pageSize.width)
            let height = max(1, parent.pageSize.height)

            // 清掉不在窗口内的页
            let window = validWindow()
            for (page, label) in labels where !window.contains(page) {
                label.removeFromSuperview()
                labels[page] = nil
                labelKeys[page] = nil
            }
            scrollView.contentSize = CGSize(width: width * CGFloat(max(parent.pages.count, 1)),
                                            height: height)
            layoutWindow()
            setOffset(to: currentIndex, animated: false)
        }

        private func validWindow() -> Set<Int> {
            var result = Set<Int>()
            for offset in -1...1 {
                let page = currentIndex + offset
                if parent.pages.indices.contains(page) { result.insert(page) }
            }
            return result
        }

        /// 只保留 当前页 / 上一页 / 下一页 三张 UILabel。
        private func layoutWindow() {
            let width = max(1, parent.pageSize.width)
            let height = max(1, parent.pageSize.height)
            let window = validWindow()
            for (page, label) in labels where !window.contains(page) {
                label.removeFromSuperview()
                labels[page] = nil
                labelKeys[page] = nil
            }
            for page in window {
                let label = labels[page] ?? makeLabel()
                labels[page] = label
                label.frame = CGRect(x: CGFloat(page) * width, y: 0, width: width, height: height)

                let text = parent.pages[page]
                let key = "\(text.hashValue)|\(text.count)|\(parent.settings.fontSize)"
                    + "|\(parent.settings.lineSpacing)|\(parent.settings.paragraphSpacing)"
                    + "|\(parent.settings.fontName)|\(parent.settings.bold)"
                    + "|\(parent.settings.indentFirstLine)|\(parent.theme.text.description)"
                guard labelKeys[page] != key else { continue }
                labelKeys[page] = key
                label.attributedText = Typography.attributedCached(
                    text, settings: parent.settings, color: UIColor(parent.theme.text), title: nil)
            }
        }

        private func makeLabel() -> UILabel {
            let label = UILabel()
            label.numberOfLines = 0
            label.lineBreakMode = .byWordWrapping
            label.backgroundColor = .clear
            label.isUserInteractionEnabled = false
            scrollView?.addSubview(label)
            return label
        }

        private func setOffset(to page: Int, animated: Bool) {
            guard let scrollView else { return }
            let width = max(1, parent.pageSize.width)
            isProgrammatic = true
            scrollView.setContentOffset(CGPoint(x: CGFloat(page) * width, y: 0), animated: animated)
            if !animated { isProgrammatic = false }
        }

        // MARK: UIScrollViewDelegate

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            guard !isProgrammatic, !overflowFired, !parent.pages.isEmpty else { return }
            let x = scrollView.contentOffset.x
            let maxX = max(0, scrollView.contentSize.width - scrollView.bounds.width)
            if x < -60 {
                overflowFired = true
                parent.onOverflow(false)
            } else if x > maxX + 60 {
                overflowFired = true
                parent.onOverflow(true)
            }
        }

        func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
            isProgrammatic = false
            overflowFired = false
            commit(scrollView)
        }

        func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
            isProgrammatic = false
            overflowFired = false
            commit(scrollView)
        }

        func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
            if !decelerate {
                overflowFired = false
                commit(scrollView)
            }
        }

        private func commit(_ scrollView: UIScrollView) {
            let width = max(1, parent.pageSize.width)
            let page = Int(round(scrollView.contentOffset.x / width))
            let clamped = min(max(0, page), max(0, parent.pages.count - 1))
            guard clamped != currentIndex else { return }
            currentIndex = clamped
            layoutWindow()
            parent.onIndexChange(clamped)
        }

        // MARK: 点击

        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard let scrollView else { return }
            let width = max(1, parent.pageSize.width)
            let x = gesture.location(in: scrollView).x - scrollView.contentOffset.x

            guard parent.tapToTurn else {
                parent.onCenterTap()
                return
            }
            if x < width / 3 {
                if currentIndex <= 0 { parent.onOverflow(false) } else { turn(to: currentIndex - 1) }
            } else if x > width * 2 / 3 {
                if currentIndex >= parent.pages.count - 1 { parent.onOverflow(true) } else { turn(to: currentIndex + 1) }
            } else {
                parent.onCenterTap()
            }
        }

        private func turn(to page: Int) {
            currentIndex = page
            layoutWindow()
            setOffset(to: page, animated: true)
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true
        }
    }
}

/// 用 UILabel 渲染一页，保证与 CoreText 分页的行宽一致。
struct PageCanvas: UIViewRepresentable {
    let text: String
    let settings: AppSettings
    let theme: ReaderTheme

    /// 拖动翻页时 dragOffset 每帧变化都会重算 body，这里缓存上一次的排版 key，
    /// 文本/字体没变就跳过 NSAttributedString 重建（连翻卡顿的主要来源）。
    final class Coordinator {
        var key: String = ""
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UILabel {
        let label = UILabel()
        label.numberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        label.backgroundColor = .clear
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }

    func updateUIView(_ label: UILabel, context: Context) {
        let key = Self.cacheKey(text: text, settings: settings, theme: theme)
        guard key != context.coordinator.key else { return }
        context.coordinator.key = key
        label.attributedText = Typography.attributedCached(
            text,
            settings: settings,
            color: UIColor(theme.text),
            title: nil
        )
    }

    static func cacheKey(text: String, settings: AppSettings, theme: ReaderTheme) -> String {
        "\(text.count)|\(text.hashValue)|\(settings.fontSize)|\(settings.lineSpacing)"
            + "|\(settings.paragraphSpacing)|\(settings.fontName)|\(settings.bold)"
            + "|\(settings.indentFirstLine)|\(theme.text.description)"
    }
}

/// 可选中的正文页（选择模式）：排版与 PageCanvas 一致，底层换成 UITextView，
/// 以便长按/双击选字并调用系统「拷贝」菜单。
struct SelectablePageCanvas: UIViewRepresentable {
    let text: String
    let settings: AppSettings
    let theme: ReaderTheme
    /// 上下滚动模式：整章文本允许滚动；分页模式只显示当前页，不滚动。
    var scrollable: Bool = false

    final class Coordinator {
        var key: String = ""
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false
        view.isSelectable = true
        view.isScrollEnabled = scrollable
        view.backgroundColor = .clear
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.dataDetectorTypes = []
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        view.isScrollEnabled = scrollable
        let key = PageCanvas.cacheKey(text: text, settings: settings, theme: theme)
            + "|\(scrollable)"
        guard key != context.coordinator.key else { return }
        context.coordinator.key = key
        view.attributedText = Typography.attributedCached(
            text,
            settings: settings,
            color: UIColor(theme.text),
            title: nil
        )
    }
}

struct BatteryView: View {
    let color: Color
    @State private var level: Float = 0

    var body: some View {
        HStack(spacing: 6) {
            Text(timeString).font(.system(size: 11))
            Text("\(Int(level * 100))%").font(.system(size: 11))
        }
        .foregroundStyle(color)
        .onAppear {
            UIDevice.current.isBatteryMonitoringEnabled = true
            level = abs(UIDevice.current.batteryLevel)
        }
    }

    private var timeString: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: Date())
    }
}
