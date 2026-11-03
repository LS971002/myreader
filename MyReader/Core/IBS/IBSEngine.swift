import Foundation
import CommonCrypto

/// IBS 书源引擎：搜索 → 详情 → 目录 → 正文 四大流程。
/// 复刻爱阅 JxdNetDataProcess 执行模型：
///   节点(url 求值 → 请求 → parser 执行副作用 → middleHandle 递归)
///   rule 变量（RuleStore）跨节点 / 跨流程共享（cookie 状态依赖此机制）。
final class IBSEngine {
    let source: IBSBookSource
    private let store = RuleStore()
    /// 书籍级辅助id（七猫形态：搜索 _BookFields.helpId 提取 →
    /// 目录/正文组合规则 `bid=source.helpId` 使用；跨引擎实例由 Book.helpId 传递）。
    var helpId = ""

    enum EngineError: LocalizedError {
        case noSearchNode
        case emptyKeyword

        var errorDescription: String? {
            switch self {
            case .noSearchNode: return "书源缺少搜索规则"
            case .emptyKeyword: return "搜索词为空"
            }
        }
    }

    init(source: IBSBookSource) {
        self.source = source
    }

    // MARK: - 步骤结果

    /// 单层执行快照：爱阅里一个 JxdNetDataProcess 实例 = 一次请求 + 一套 parser。
    struct StepLayer {
        var text: String = ""
        var headers: [String: String] = [:]
        var finalURL: String = ""
        var parser: [String: ParserField] = [:]
        /// 本层视角的父链（含本层自身），按层求值时充当 self.parent。
        var frames: [ParentFrame] = []
    }

    struct StepResult {
        var text: String = ""
        var headers: [String: String] = [:]
        var finalURL: String = ""
        var parser: [String: ParserField] = [:]   // 最深层 parser（单值字段默认取这里）
        /// 全层快照：index 0 = 最深层，末尾 = 最外层。
        /// 逆向依据（JxdNetDataProcess，0x10003a624 `parseContent` 反汇编）：
        ///   本层 `parseCurrentContent` 先执行 → 若 `mCurMiddleProcess` 存在
        ///   → `[子进程 parseContent]` → `+MergeJson:toResult:` 把子层结果合并进本层。
        /// `MergeJson` → `+AddObject:withKey:toResult:`（0x100035254）合并规则：
        ///   `+IsEmptyValue:`（0x10003499c：nil/NSNull/空串/空数组/元素全空的容器）为真 → 跳过；
        ///   键不存在 → 写入；两字典 → 递归；两数组 → 追加；标量冲突 → 转为数组 [旧, 新]。
        /// 即多层 parser 是「逐层解析 + 合并，空值不覆盖父层」，而不是二选一回退。
        var layers: [StepLayer] = []
        var frames: [ParentFrame] = []            // 最深层视角的父链
    }

    /// 列表项：记录它来自哪一层，字段求值必须用该层的响应 DOM / 文本。
    private struct ListEntry {
        let input: String
        let node: HTMLNode?
        let layerIndex: Int
    }

    /// 单层解析视图：本层响应 + 本层 parser + 已解析 DOM + 规则执行器。
    private struct LayerView {
        let layer: StepLayer
        let runner: RuleRunner
        let dom: HTMLNode?
    }

    // MARK: - 搜索

    func search(keyword: String) async throws -> [SearchResult] {
        AppLog.info("SEARCH", "〔\(source.name)〕开始搜索「\(keyword)」")
        guard let node0 = source.searchBook else {
            AppLog.warn("SEARCH", "〔\(source.name)〕无searchBook节点")
            throw EngineError.noSearchNode
        }
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw EngineError.emptyKeyword }

        // XDKEYWORD 注入：占位词 → 搜索词（深度替换节点树中的规则串）
        let node = injectKeyword(node0, placeholder: keywordPlaceholder(node0), keyword: trimmed)

        let sourceRef = DynSourceRef(configName: source.name)
        let step = try await runNode(node, overrideURL: nil, keyword: trimmed, pageIndex: 0,
                                     parentFrames: [], sourceRef: sourceRef)

        // 逐层解析 + 合并（爱阅 parseContent → MergeJson）：外层到深层依次解析，
        // 空列表按 IsEmptyValue 语义跳过、不覆盖已有结果，非空则追加。
        var views: [LayerView] = []
        var entries: [ListEntry] = []
        var firstListRule = ""

        for layer in step.layers.reversed() {
            let scoped = scopedLayerContent(layer)
            let dom = scoped.dom
            let runner = RuleRunner(ctx: makeContext(layer: layer))
            let layerIndex = views.count
            views.append(LayerView(layer: layer, runner: runner, dom: dom))

            guard let rule = fieldRules(layer.parser, "_list")?.first else { continue }
            if firstListRule.isEmpty { firstListRule = rule }
            let candidate = parseListEntries(rule, text: scoped.text, dom: dom, source: source.name)
            guard !candidate.isEmpty else {
                AppLog.debug("SEARCH", "〔\(source.name)〕第\(layerIndex + 1)层_list为空，跳过合并（\(rule.prefix(46))）")
                continue
            }
            AppLog.debug("SEARCH", "〔\(source.name)〕第\(layerIndex + 1)层_list命中\(candidate.count)项（\(rule.prefix(46))）")
            entries.append(contentsOf: candidate.map {
                ListEntry(input: $0.input, node: $0.node, layerIndex: layerIndex)
            })
        }
        guard !entries.isEmpty else {
            AppLog.warn("SEARCH", "〔\(source.name)〕列表为空（_list: \(firstListRule.prefix(60))）"
                        + " 层数\(views.count) 响应\(step.text.count)字 末尾: \(step.text.suffix(120).replacingOccurrences(of: "\n", with: " "))")
            return []
        }
        AppLog.info("SEARCH", "〔\(source.name)〕列表项 \(entries.count) 个（\(firstListRule.hasPrefix("@json:") ? "JSON" : "DOM")模式）")

        var results: [SearchResult] = []
        var seen = Set<String>()

        for (entryIndex, entry) in entries.prefix(80).enumerated() {
            let view = views[entry.layerIndex]
            let parser = view.layer.parser
            let baseURL = view.layer.finalURL.isEmpty ? source.homeURL : view.layer.finalURL

            // 逐项同步打点：崩溃发生在字段求值阶段时，日志最后一行就是出错项/字段
            AppLog.traceSync("SEARCH", "〔\(source.name)〕项\(entryIndex)/\(entries.count) 求书名")
            var title = runFieldOn(view.runner, parser: parser, name: "bookName",
                                   input: entry.input, node: entry.node) ?? ""
            // 书名清洗：真实书源偶尔把整段简介塞进 title（几十万字），
            // 会拖垮 UI 排版与聚合逻辑
            title = title.replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if title.count > 100 { title = String(title.prefix(100)) }
            guard !title.isEmpty else { continue }

            AppLog.traceSync("SEARCH", "〔\(source.name)〕项\(entryIndex) 书名=\(title.prefix(20)) 求dirURL")
            let dirURL = runFieldOn(view.runner, parser: parser, name: "dirURL",
                                    input: entry.input, node: entry.node) ?? ""
            if dirURL.isEmpty {
                AppLog.warn("SEARCH", "〔\(source.name)〕《\(title.prefix(16))》dirURL为空(规则: \(fieldRules(parser, "dirURL")?.first?.prefix(50) ?? "-"))，link兜底为搜索URL")
            }
            // 部分源的 href 形如 `javascript:sovote(123,'/book/x/')`，
            // 规则若没把前缀剥干净，拼出来的「URL」交给 URLComponents 赋值会抛异常。
            // 非 http(s) 结果一律回退到本层响应地址，保证 link 始终可请求。
            var resolvedLink = dirURL.isEmpty ? baseURL : HTTPClient.absolute(dirURL, base: baseURL)
            if !(resolvedLink.hasPrefix("http://") || resolvedLink.hasPrefix("https://")) {
                AppLog.warn("SEARCH", "〔\(source.name)〕《\(title.prefix(16))》链接非法，回退本层地址：\(resolvedLink.prefix(60))")
                resolvedLink = baseURL
            }
            let link = resolvedLink
            // 去重键用「书名 + 解析出的链接」：多层 parser 的 dirURL 规则串不同，
            // 用规则串做键会让同一本书在不同层各留一条。
            if !seen.insert(title + "|" + link).inserted { continue }
            AppLog.traceSync("SEARCH", "〔\(source.name)〕项\(entryIndex) dirURL=\(dirURL.prefix(48)) link=\(link.prefix(60)) 求作者")
            let author = runFieldOn(view.runner, parser: parser, name: "author",
                                    input: entry.input, node: entry.node) ?? ""
            // helpId 提取（七猫形态：_BookFields.helpId → 正文组合规则 source.helpId）
            let helpId = runFieldOn(view.runner, parser: parser, name: "helpId",
                                    input: entry.input, node: entry.node) ?? ""
            if helpId.isEmpty == false && self.helpId.isEmpty {
                self.helpId = helpId
                AppLog.debug("SEARCH", "〔\(source.name)〕helpId提取：\(helpId.prefix(20))")
            }

            // 简介/最新章节做长度上限：个别源会取到整页文本，UI 渲染与 Hashable
            // 计算会被拖到秒级（曾表现为「搜索时闪退」）
            AppLog.traceSync("SEARCH", "〔\(source.name)〕项\(entryIndex) 求简介/封面/最新章节")
            var intro = runFieldOn(view.runner, parser: parser, name: "desc", input: entry.input, node: entry.node) ?? ""
            if intro.count > 800 { intro = String(intro.prefix(800)) }
            var latest = runFieldOn(view.runner, parser: parser, name: "lastChapterTitle", input: entry.input, node: entry.node) ?? ""
            latest = latest.trimmingCharacters(in: .whitespacesAndNewlines)
            if latest.count > 120 { latest = String(latest.prefix(120)) }
            var authorText = author.trimmingCharacters(in: .whitespacesAndNewlines)
            if authorText.count > 60 { authorText = String(authorText.prefix(60)) }

            results.append(SearchResult(
                sourceID: source.id,
                sourceName: source.name,
                title: title,
                author: authorText,
                helpId: helpId,
                link: link,
                cover: HTTPClient.absolute(
                    runFieldOn(view.runner, parser: parser, name: "coverUrl", input: entry.input, node: entry.node) ?? "",
                    base: baseURL),
                intro: intro,
                latest: latest,
                matchKind: Self.classify(title: title, author: authorText, keyword: trimmed)
            ))
        }
        AppLog.info("SEARCH", "〔\(source.name)〕完成：\(results.count) 本书")
        return results
    }

    /// 搜索词匹配分类（排序权重用）。
    static func classify(title: String, author: String, keyword: String) -> SearchResult.MatchKind {
        if title == keyword { return .exactTitle }
        if title.localizedCaseInsensitiveContains(keyword) { return .fuzzyTitle }
        if !author.isEmpty && author.localizedCaseInsensitiveContains(keyword) { return .authorMatch }
        return .fuzzyTitle
    }

    // MARK: - 详情

    func detail(link: String) async throws -> (intro: String, cover: String) {
        guard let node = source.bookDetail,
              let urlRule = node.url?.first, !urlRule.isEmpty else {
            return ("", "")
        }
        var sourceRef = DynSourceRef(configName: source.name)
        sourceRef.detailURL = link
        let step = try await runNode(node, overrideURL: link, keyword: nil, pageIndex: nil,
                                     parentFrames: [], sourceRef: sourceRef)
        // 逐层取（外层 → 深层）：空值不覆盖，取第一个非空 desc / coverUrl
        var intro = ""
        var cover = ""
        for layer in step.layers.reversed() {
            let runner = RuleRunner(ctx: makeContext(layer: layer))
            let scoped = scopedLayerContent(layer)
            guard let dom = scoped.dom else { continue }
            if intro.isEmpty {
                intro = runFieldOn(runner, parser: layer.parser, name: "desc",
                                   input: dom.textContent, node: dom) ?? ""
            }
            if cover.isEmpty {
                cover = runFieldOn(runner, parser: layer.parser, name: "coverUrl",
                                   input: dom.textContent, node: dom) ?? ""
            }
        }
        return (intro, HTTPClient.absolute(cover, base: source.homeURL))
    }

    // MARK: - 目录

    func directory(link: String) async throws -> [Chapter] {
        guard let node = source.sourceDetail else {
            AppLog.warn("DIR", "〔\(source.name)〕无sourceDetail节点")
            return []
        }
        var sourceRef = DynSourceRef(configName: source.name)
        sourceRef.dirURL = link
        sourceRef.detailURL = link
        sourceRef.helpId = resolvedHelpId(fallbackURL: link)
        AppLog.debug("DIR", "〔\(source.name)〕helpId=\(sourceRef.helpId.isEmpty ? "空" : sourceRef.helpId.prefix(20))")

        var chapters: [Chapter] = []
        // 爱阅语义：sourceDetail.url 为空 = 直接请求目录链接（link）。
        // 首次请求以 link 为目标，后续翻页由 nextPageUrl 求值替换。
        var overrideURL: String? = link
        var seenTitles = Set<String>()
        var firstPageText = ""
        var firstPageBase = ""
        // 爱阅 maxPageCount = 0 表示「不设上限，由 nextPageUrl 求值空自终止」
        // （真实书源常见写法）。这里给 40 页硬上限，并加「连续 2 页无新增即停」
        // 防止 nextPageUrl 恒返回同一页造成重复请求。
        let declaredMax = node.maxPageCount
        let maxPages = declaredMax > 0 ? min(declaredMax, 40) : 40
        var pagesWithoutNew = 0

        for pageIndex in 0..<maxPages {
            let step = try await runNode(node, overrideURL: overrideURL, keyword: nil,
                                         pageIndex: pageIndex,
                                         parentFrames: [], sourceRef: sourceRef)
            // 逐层解析 + 合并（与 search 一致）：空列表按 IsEmptyValue 跳过，非空追加
            var views: [LayerView] = []
            var entries: [ListEntry] = []
            var firstListRule = ""
            for layer in step.layers.reversed() {
                let scoped = scopedLayerContent(layer, sourceRef: sourceRef)
                let dom = scoped.dom
                let runner = RuleRunner(ctx: makeContext(layer: layer, sourceRef: sourceRef))
                let layerIndex = views.count
                views.append(LayerView(layer: layer, runner: runner, dom: dom))
                guard let rule = fieldRules(layer.parser, "_list")?.first else { continue }
                if firstListRule.isEmpty { firstListRule = rule }
                let candidate = parseListEntries(rule, text: scoped.text, dom: dom, source: source.name)
                guard !candidate.isEmpty else {
                    AppLog.debug("DIR", "〔\(source.name)〕第\(layerIndex + 1)层_list为空，跳过合并")
                    continue
                }
                entries.append(contentsOf: candidate.map {
                    ListEntry(input: $0.input, node: $0.node, layerIndex: layerIndex)
                })
            }
            guard !firstListRule.isEmpty else {
                AppLog.warn("DIR", "〔\(source.name)〕无_list规则（最深层parser键: \(step.parser.keys.sorted().prefix(6).joined(separator: ","))）")
                break
            }
            AppLog.info("DIR", "〔\(source.name)〕第\(pageIndex + 1)页列表项 \(entries.count) 个（\(firstListRule.hasPrefix("@json:") ? "JSON" : "DOM")模式）"
                        + (entries.isEmpty ? " _list: \(firstListRule.prefix(90))" : ""))
            // 兜底取样用最外层响应：middleHandle 的中间页常是另一套模板（甚至空壳），
            // 真正含章节链接的是第一次请求的详情/目录页。
            firstPageText = firstPageText.isEmpty
                ? (step.layers.last?.text ?? step.text) : firstPageText
            let outermostURL = step.layers.last?.finalURL ?? step.finalURL
            firstPageBase = firstPageBase.isEmpty
                ? (outermostURL.isEmpty ? source.homeURL : outermostURL) : firstPageBase
            if entries.isEmpty { break }

            var emptyFieldSample = ""
            let addedBefore = chapters.count
            for entry in entries {
                let view = views[entry.layerIndex]
                let parser = view.layer.parser
                let base = view.layer.finalURL.isEmpty ? source.homeURL : view.layer.finalURL
                let title = runFieldOn(view.runner, parser: parser, name: "title",
                                       input: entry.input, node: entry.node) ?? ""
                let url = runFieldOn(view.runner, parser: parser, name: "url",
                                     input: entry.input, node: entry.node) ?? ""
                if emptyFieldSample.isEmpty && (title.isEmpty || url.isEmpty) {
                    let node = entry.node
                    emptyFieldSample = "首项 title=「\(title.prefix(20))」url=「\(url.prefix(40))」"
                        + " 节点=\(node.map { "<\($0.tag)> 文本:\($0.textContent.prefix(24))" } ?? "json")"
                }
                guard !title.isEmpty, !url.isEmpty else { continue }
                // 通用防御：目录容器常常连带站点导航（「首页」「排行榜」/ `href="#"`），
                // 混进来会被当成第 1 章，换源进度对齐直接错位
                // （日志(13)：「第一章 灭门！」→「第1章 首页」）。
                guard Self.looksLikeChapterItem(title: title, url: url, base: base) else { continue }
                let absolute = HTTPClient.absolute(url, base: base)
                // 去重键 = 标题 + URL：真实站点存在同名章节
                // （101Minc 目录里「第333章 战争开始（求订阅！）」等 14 组标题重复，
                //   但指向不同 URL、内容不同）。只按标题去重会丢 15 章（690→675）。
                if !seenTitles.insert(title + "|" + absolute).inserted { continue }
                chapters.append(Chapter(
                    index: chapters.count,
                    title: title,
                    url: absolute))
            }
            if !emptyFieldSample.isEmpty {
                AppLog.warn("DIR", "〔\(source.name)〕列表项字段缺失 \(emptyFieldSample)")
            }
            // maxPageCount 未声明（0）时靠 nextPageUrl 自终止；若连续 2 页
            // 没有任何新增章节，判定翻页规则已失效（多为恒返回同一页），停止。
            let added = chapters.count - addedBefore
            pagesWithoutNew = added == 0 ? pagesWithoutNew + 1 : 0
            if pagesWithoutNew >= 2 {
                AppLog.debug("DIR", "〔\(source.name)〕连续\(pagesWithoutNew)页无新增章节，停止翻页")
                break
            }

            // 下一页（nextPageUrl 脚本读取 helpId 存入的 next0 / next1）
            if let nextRule = node.nextPageUrl?.first, !nextRule.isEmpty {
                let ctx = makeContext(step: step, sourceRef: sourceRef)
                let next: String?
                if nextRule.hasPrefix("@dyn:") {
                    next = DynEngine(ctx: ctx).executeString(String(nextRule.dropFirst(5)))
                } else {
                    next = nextRule
                }
                if let next, !next.isEmpty {
                    AppLog.debug("DIR", "〔\(source.name)〕翻页: \(next.prefix(60))")
                    overrideURL = HTTPClient.absolute(next, base: step.finalURL)
                } else {
                    AppLog.debug("DIR", "〔\(source.name)〕翻页终止（nextPageUrl求值空）")
                    break
                }
            } else {
                break
            }
        }
        // 通用兜底：_list 规则没命中 / 命中了但字段取不到（真实书源常见：
        // `@xpath://dt[...]/following-sibling::a` 这类结构规则在不同站点变体下失效）。
        // 做法：直接扫描整页 <a>，按「与详情页同目录 + 章节链接形态」筛选并排序。
        if chapters.isEmpty && !firstPageText.isEmpty {
            let fallback = Self.fallbackChapterLinks(from: firstPageText,
                                                     baseURL: firstPageBase,
                                                     detailURL: link)
            if !fallback.isEmpty {
                AppLog.warn("DIR", "〔\(source.name)〕_list未命中，整页链接兜底：\(fallback.count) 章")
                chapters = fallback
            }
        }
        AppLog.info("DIR", "〔\(source.name)〕目录完成：\(chapters.count) 章")
        return chapters
    }

    /// 列表项是否像「章节」而非站点导航/工具栏。
    /// 不针对某个源：站点导航在任何书源的目录容器里都可能被规则连带选中，
    /// 表现为 url 为 `#`、指向站点根，或标题就是「首页」「排行榜」这类词。
    static func looksLikeChapterItem(title: String, url: String, base: String) -> Bool {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return false }
        let u = url.trimmingCharacters(in: .whitespacesAndNewlines)
        if u.isEmpty || u == "#" || u.lowercased().hasPrefix("javascript:")
            || u.lowercased().hasPrefix("void(") {
            return false
        }
        // 指向站点根（`/` 或 `https://host`）= 首页链接，不可能是章节
        let absolute = HTTPClient.absolute(u, base: base)
        if let path = URL(string: absolute)?.path, path.isEmpty || path == "/" {
            return false
        }
        let navigation: Set<String> = [
            "首页", "目录", "章节目录", "全部章节", "排行榜", "全部小说", "最新更新", "热门书",
            "完本", "完结", "书架", "我的书架", "加入书架", "开始阅读", "马上阅读", "立即阅读",
            "返回", "上一页", "下一页", "上一章", "下一章", "登录", "注册", "电脑版", "手机版",
            "查看更多", "展开", "收起", "书签"
        ]
        return !navigation.contains(t)
    }

    // MARK: - 目录整页兜底

    /// 从整页 HTML 里提取章节链接（书源规则失效时的通用兜底）。
    /// 判定：与详情页同目录前缀（`/book/160069/xxx.html`）或形如 `123456.html`，
    /// 标题含章节语义或至少 2 字，排除导航/翻页/推荐类链接，最后按「第N章」数字排序。
    static func fallbackChapterLinks(from text: String, baseURL: String,
                                     detailURL: String) -> [Chapter] {
        guard text.contains("<a"), !text.isEmpty else { return [] }
        let dom = HTMLParser.parse(text)
        let prefix = chapterPathPrefix(detailURL)
        let host = URL(string: detailURL)?.host ?? ""

        let navigation: Set<String> = [
            "上一页", "下一页", "上一章", "下一章", "目录", "章节目录", "首页", "返回",
            "加入书签", "添加书签", "推荐", "排行榜", "全部", "查看更多", "展开", "收起",
            "电脑版", "手机版", "书架", "登录", "注册",
            // 「开始阅读 / 马上阅读」这类按钮指向第 1 章，会把真正的第 1 章挤掉
            "开始阅读", "马上阅读", "立即阅读", "继续阅读", "在线阅读", "立即畅读",
            "加入书架", "投票推荐", "催更", "举报", "投推荐票", "下载APP"
        ]

        var items: [(title: String, url: String, order: Int?)] = []

        for node in dom.elements() where node.tag == "a" {
            guard let raw = node.attr("href")?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !raw.isEmpty,
                  !raw.hasPrefix("#"), !raw.hasPrefix("javascript"), !raw.hasPrefix("mailto") else { continue }
            let url = HTTPClient.absolute(raw, base: baseURL.isEmpty ? detailURL : baseURL)
            guard !url.isEmpty else { continue }
            // URL.host 是 Optional（iOS 16 起还有 host(percentEncoded:) 重载），必须显式解包
            if !host.isEmpty, let other = URL(string: url)?.host, !other.isEmpty, other != host {
                continue
            }

            var title = node.textContent
                .replacingOccurrences(of: "\u{3000}", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if title.isEmpty { continue }
            title = title.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
            guard title.count >= 2, title.count <= 60 else { continue }
            if navigation.contains(where: { title.hasPrefix($0) || title == $0 }) { continue }

            let path = URL(string: url)?.path ?? ""
            let sameFolder = !prefix.isEmpty && path.hasPrefix(prefix) && path != prefix
            let looksChapter = path.range(of: #"/\d{3,}\.html$"#, options: .regularExpression) != nil
                || path.range(of: #"(chapter|read)[-_]?\d+"#, options: .regularExpression) != nil
            // 严格：同目录 + 章节链接形态；详情地址无路径时才放宽（需带章节号）
            let strict = sameFolder && looksChapter
            let loose = prefix.isEmpty && looksChapter && chapterNumber(in: title) != nil
            guard strict || loose else { continue }

            items.append((title, url, chapterNumber(in: title)))
        }

        guard items.count >= 2 else { return [] }

        // 同一 URL 可能同时被「开始阅读」按钮和真实章节名指向 → 保留「带章节号」的那个
        var bestByURL: [String: (title: String, url: String, order: Int?)] = [:]
        var urlOrder: [String] = []
        for item in items {
            guard let existing = bestByURL[item.url] else {
                bestByURL[item.url] = item
                urlOrder.append(item.url)
                continue
            }
            if existing.order == nil && item.order != nil {
                bestByURL[item.url] = item
            } else if existing.order == item.order && item.title.count > existing.title.count {
                bestByURL[item.url] = item
            }
        }
        items = urlOrder.compactMap { bestByURL[$0] }

        // 「最新章节」区块会先出现后 12 章，按章节号重排才不会乱序；
        // 章节号覆盖率高时丢弃无编号项（导航按钮/广告位残留）。
        let numbered = items.filter { $0.order != nil }.count
        if numbered * 4 >= items.count * 3 {
            items = items.filter { $0.order != nil }
            items = items.enumerated()
                .sorted { a, b in
                    let x = a.element.order ?? Int.max
                    let y = b.element.order ?? Int.max
                    return x == y ? a.offset < b.offset : x < y
                }
                .map(\.element)
        }
        var deduped = Set<String>()
        var result: [Chapter] = []
        for item in items {
            guard deduped.insert(item.title).inserted else { continue }
            result.append(Chapter(index: result.count, title: item.title, url: item.url))
        }
        return result
    }

    /// 详情页所在目录（`http://x/book/160069/` → `/book/160069/`）。
    private static func chapterPathPrefix(_ detailURL: String) -> String {
        guard !detailURL.isEmpty, let url = URL(string: detailURL) else { return "" }
        var path = url.path
        if path.isEmpty { return "" }
        if !path.hasSuffix("/") {
            path = (path as NSString).deletingLastPathComponent
            if !path.hasSuffix("/") { path += "/" }
        }
        return path
    }

    /// 标题里的章节序号（第12章 / 第12节 / 12.）。
    static func chapterNumber(in title: String) -> Int? {
        if let range = title.range(of: #"第\s*(\d+)\s*[章节回]"#, options: .regularExpression) {
            let digits = String(title[range]).filter(\.isNumber)
            return Int(digits)
        }
        if let range = title.range(of: #"^\s*(\d+)[\.、]"#, options: .regularExpression) {
            return Int(String(title[range]).filter(\.isNumber))
        }
        return nil
    }

    // MARK: - 正文

    /// 上一次 content() 是否只拿到「整页兜底」产物（不可信，调用方不应写入章节缓存）。
    private(set) var lastContentUsedFallback = false

    /// - Parameter detailURL: 书籍详情/目录地址（helpId 为空时的兜底来源：`id=1784836`）。
    func content(chapter: Chapter, detailURL: String = "") async throws -> String {
        lastContentUsedFallback = false
        guard let node = source.chapterDetail else {
            AppLog.warn("CONTENT", "〔\(source.name)〕无chapterDetail节点，正文将为空")
            return ""
        }
        var sourceRef = DynSourceRef(configName: source.name)
        sourceRef.chapterURL = chapter.url
        sourceRef.detailURL = detailURL
        sourceRef.helpId = resolvedHelpId(fallbackURL: detailURL)
        if helpId.isEmpty && !sourceRef.helpId.isEmpty {
            helpId = sourceRef.helpId
            AppLog.warn("CONTENT", "〔\(source.name)〕helpId缺失，已从详情URL兜底解析：\(sourceRef.helpId)")
        }
        AppLog.debug("CONTENT", "〔\(source.name)〕helpId=\(sourceRef.helpId.isEmpty ? "空" : sourceRef.helpId.prefix(20)) 章节URL=\(chapter.url.prefix(80))")

        // 爱阅语义：chapterDetail.url 为空 = 直接请求章节URL（chapter.url）
        let step = try await runNode(node, overrideURL: chapter.url, keyword: nil, pageIndex: nil,
                                     parentFrames: [], sourceRef: sourceRef)
        AppLog.debug("CONTENT", "〔\(source.name)〕章节页响应 \(step.text.count) 字符：\(step.text.prefix(120))")

        // content 逐层尝试（外层 → 深层）：爱阅合并语义下 content 是标量，
        // 父层非空优先，父层为空（IsEmptyValue）才由子层补上。
        var hasContentRule = false
        for layer in step.layers.reversed() {
            guard let contentRules = fieldRules(layer.parser, "content") else { continue }
            hasContentRule = true
            let runner = RuleRunner(ctx: makeContext(layer: layer, sourceRef: sourceRef))
            // DOM 用 `_range` 裁剪后的范围（选择器类 content 规则常依赖它）；
            // 文本仍用整层响应（@json:/@def: 类规则需要完整 JSON）。
            let scoped = scopedLayerContent(layer, sourceRef: sourceRef)
            // 逐条规则打点：正文空结果时能直接看出是哪一步清空的
            // （规则数 / 每步字符数 / 起止值）。仅 DEBUG 级，正式包默认不落盘。
            var stage = layer.text
            // 复刻 RuleRunner.run 的 contents 累积：七猫 `@def:` 代码文本要靠
            // contents[0] 传给后续 `@dyn:` 的 evaluateScript，漏掉会直接坏掉。
            runner.ctx.contents.removeAll()
            for (ruleIndex, rule) in contentRules.enumerated() {
                let out = runner.runSingle(rule, input: stage,
                                           dom: ruleIndex == 0 ? scoped.dom : nil) ?? ""
                runner.ctx.contents.append(out)
                AppLog.debug("CONTENT", "〔\(source.name)〕content[\(ruleIndex)] "
                             + "\(stage.count)→\(out.count)字 规则:\(rule.prefix(44))")
                stage = out
            }
            var text: String? = stage.isEmpty ? nil : stage
            // 智能兜底：@def: 携带 CryptoJS 的源（七猫形态）在 JS 解密链未生效时
            // （结果为 nil / 空 / 仍是 Base64 密文）→ 走原生 AES-128-CBC 解密。
            // 密文直接取响应里的 data.content，不依赖 JS 执行是否成功。
            if let defScript = contentRules.first(where: { $0.contains("@def:") && $0.contains("CryptoJS") }) {
                let produced = text ?? ""
                if produced.isEmpty || Self.looksLikeBase64Cipher(produced) {
                    let cipher = JSONRule.path("data.content", in: layer.text).first ?? produced
                    if Self.looksLikeBase64Cipher(cipher) {
                        AppLog.warn("CONTENT", "〔\(source.name)〕JS解密链未生效（结果: \(produced.isEmpty ? "空" : "\(produced.count)字密文")），尝试原生AES兜底")
                        if let plain = Self.decryptQimaoStyle(cipherB64: cipher, script: defScript) {
                            text = plain
                            AppLog.info("CONTENT", "〔\(source.name)〕原生兜底解密成功：\(plain.count)字")
                        } else {
                            AppLog.error("CONTENT", "〔\(source.name)〕原生兜底解密失败（key/填充不匹配）")
                        }
                    }
                }
            }
            if let text, !text.isEmpty {
                let cleaned = Self.cleanContent(text)
                AppLog.info("CONTENT", "〔\(source.name)〕content规则命中：\(cleaned.count)字")
                return cleaned
            }
            AppLog.warn("CONTENT", "〔\(source.name)〕content规则空结果（规则: \(contentRules.first?.prefix(60) ?? "")）")
        }
        if !hasContentRule {
            AppLog.warn("CONTENT", "〔\(source.name)〕所有层均无content字段（最深层键: \(step.parser.keys.sorted().prefix(8).joined(separator: ","))）")
        }
        // 兜底：_range（同样逐层）
        for layer in step.layers.reversed() {
            guard let rangeRules = fieldRules(layer.parser, "_range") else { continue }
            let runner = RuleRunner(ctx: makeContext(layer: layer, sourceRef: sourceRef))
            let dom = HTMLParser.parse(layer.text)
            let text = runner.run(RuleValue.combo(rangeRules), input: layer.text, dom: dom)
            if let text, !text.isEmpty {
                let cleaned = Self.cleanContent(text)
                AppLog.info("CONTENT", "〔\(source.name)〕_range兜底命中：\(cleaned.count)字")
                return cleaned
            }
        }
        // 最终兜底：整页转文本（多为接口错误 JSON，标记为不可信，不写缓存）
        lastContentUsedFallback = true
        let fallback = Self.cleanContent(HTMLParser.htmlToText(step.text))
        AppLog.warn("CONTENT", "〔\(source.name)〕整页兜底：\(fallback.count)字（content规则未命中，结果不写缓存）")
        return fallback
    }

    // MARK: - 节点执行（核心）

    private func runNode(_ node: RuleNode,
                         overrideURL: String?,
                         keyword: String?,
                         pageIndex: Int?,
                         parentFrames: [ParentFrame],
                         sourceRef: DynSourceRef) async throws -> StepResult {
        // 1. URL 求值
        let ctx = DynContext(store: store)
        ctx.parentChain = parentFrames
        ctx.source = sourceRef
        if let pageIndex {
            ctx.vars["pageIndex"] = .num(Double(pageIndex))
        }
        if let keyword {
            ctx.vars["keyword"] = .str(keyword)
        }
        if let first = parentFrames.first {
            ctx.respContent = first.respContent
        }

        let urlStr: String?
        if let override = overrideURL, !override.isEmpty {
            urlStr = override
        } else if let urlRule = node.url?.first, !urlRule.isEmpty {
            if urlRule.hasPrefix("@dyn:") {
                let engine = DynEngine(ctx: ctx)
                urlStr = engine.executeString(String(urlRule.dropFirst(5)))
            } else if urlRule.hasPrefix("@get:{"), urlRule.hasSuffix("}") {
                // rule store 变量取值（00小说 MH url 形态：上层脚本 rule.put 存入）
                let key = String(urlRule.dropFirst(6).dropLast())
                let value = ctx.store.values[key]?.stringValue
                urlStr = (value == nil || value == "null") ? nil : value
            } else {
                urlStr = applyParams(urlRule, params: node.params, keyword: keyword)
            }
        } else {
            urlStr = nil
        }
        AppLog.debug("ENGINE", "节点url求值: \(urlStr ?? "nil")")

        // 2. 短路（nil / data: URL → 空响应继续走 parser + middleHandle）
        var text = ""
        var headers: [String: String] = [:]
        var finalURL = urlStr ?? ""

        // middleHandle 不写 url = 不重新请求，直接在父层响应上再套一套 parser。
        // 爱阅 JxdNetDataProcess 里子 process 的 url 为空即沿用当前响应内容。
        if (urlStr ?? "").isEmpty, let parent = parentFrames.first {
            text = parent.respContent
            headers = parent.headers
            finalURL = parent.currentRequestUrl
        }

        if let url = urlStr, !url.isEmpty {
            if url.hasPrefix("data:") {
                text = decodeDataURL(url)
                headers = [:]
            } else {
                // 相对路径绝对化（对齐爱阅：基于父请求URL，无父则书源主页）
                // 码字阅读等 @dyn: 源的 url 求值产物就是 "/search/" 这类相对路径
                let baseURL = parentFrames.first?.currentRequestUrl ?? source.homeURL
                let absoluteURL = HTTPClient.absolute(url, base: baseURL)

                // 3. 请求（含重试）
                let method = node.forGetMethod ? "GET" : "POST"
                let params = applyParamsDict(node.params, keyword: keyword, ctx: ctx)
                var staticHeaders = source.httpConfigs?.headers ?? [:]
                if let nodeHTTP = node.httpConfigs {
                    for (k, v) in nodeHTTP.headers { staticHeaders[k] = v }
                }
                let useCookies = node.httpConfigs?.useCookies
                    ?? source.httpConfigs?.useCookies ?? false

                let mergedHeaders = ctx.headers.merged(over: staticHeaders)
                var resp: HTTPClient.Response? = nil
                let tries = max(node.tryCount, 0) + 1
                for attempt in 0..<tries {
                    do {
                        if node.requestByWebView {
                            let html = try await WebViewFetcher.shared.fetch(
                                url: absoluteURL, headers: mergedHeaders, js: nil)
                            resp = HTTPClient.Response(finalURL: absoluteURL, text: html, headers: [:])
                        } else {
                            resp = try await HTTPClient.shared.request(
                                url: absoluteURL, method: method, params: params,
                                staticHeaders: staticHeaders,
                                dynamicHeaders: ctx.headers, useCookies: useCookies)
                        }
                        break
                    } catch {
                        if attempt == tries - 1 { throw error }
                        let space = node.trySpaceSecond > 0 ? node.trySpaceSecond : 0.5
                        try? await Task.sleep(nanoseconds: UInt64(space * 1_000_000_000))
                    }
                }
                if let resp {
                    text = resp.text
                    headers = resp.headers
                    finalURL = resp.finalURL.isEmpty ? absoluteURL : resp.finalURL
                } else {
                    finalURL = absoluteURL
                }
            }
        }

        // 4. 更新上下文 → 执行本层 parser（副作用：cookie / next0 等存 RuleStore）
        ctx.respContent = text
        ctx.responseHeaders = headers
        let runner = RuleRunner(ctx: ctx)
        let dom: HTMLNode? = text.isEmpty ? nil : HTMLParser.parse(text)
        for (key, field) in node.parser {
            // content/_range 是「取值」字段，由上层 content() 单独执行（那里带 detailURL/helpId）。
            // 这里跳过可避免七猫同一章跑两遍 CryptoJS 解密（每章省一次 JSContext）。
            if key == "content" || key == "_range" { continue }
            if case .rules(let rules) = field {
                _ = runner.run(RuleValue.combo(rules), input: text, dom: dom)
            }
        }

        let frame = ParentFrame(currentRequestUrl: finalURL, respContent: text, headers: headers)
        let frames = [frame] + parentFrames

        // 5. middleHandle 递归（子层脚本 self.parent.* 由 parentChain 承载）
        if let middle = node.middleHandle {
            var result = try await runNode(middle, overrideURL: nil, keyword: keyword, pageIndex: pageIndex,
                                           parentFrames: frames, sourceRef: sourceRef)
            // 本层追加到链尾（由深到浅），上层解析时按 MergeJson 语义逐层合并
            result.layers.append(StepLayer(text: text, headers: headers,
                                           finalURL: finalURL, parser: node.parser, frames: frames))
            return result
        }

        // 6. 本层即最深层
        let layer = StepLayer(text: text, headers: headers, finalURL: finalURL,
                              parser: node.parser, frames: frames)
        return StepResult(text: text, headers: headers, finalURL: finalURL,
                          parser: node.parser, layers: [layer], frames: frames)
    }

    // MARK: - 字段执行辅助

    /// 在 parser 字典中查找字段规则（顶层 → _SourceFields → _BookFields）。
    private func fieldRules(_ parser: [String: ParserField], _ name: String) -> [String]? {
        if let f = parser[name], !f.ruleStrings.isEmpty { return f.ruleStrings }
        for container in ["_SourceFields", "_BookFields"] {
            if let sub = parser[container], case .sub(let dict) = sub,
               let f = dict[name], !f.ruleStrings.isEmpty {
                return f.ruleStrings
            }
        }
        return nil
    }

    /// 应用 `_range` 解析作用域。
    /// 爱阅 parser 里 `_range` 是「先裁出片段，再在片段内跑 `_list`/字段选择器」：
    /// 真实源常见 `_range` 取 `div#allchapter` 的 HTML，`_list` 只写 `@ex:dd`，
    /// 若在整个页面上跑 `dd` 会命中书签区/推荐区等无关节点。
    /// 规则求值失败或产物为空时退回整页，不影响只用 `_range` 当正文兜底的源。
    private func scopedLayerContent(_ layer: StepLayer,
                                    sourceRef: DynSourceRef? = nil) -> (text: String, dom: HTMLNode?) {
        let baseDom = layer.text.isEmpty ? nil : HTMLParser.parse(layer.text)
        guard let baseDom, let rules = fieldRules(layer.parser, "_range") else {
            return (layer.text, baseDom)
        }
        let runner = RuleRunner(ctx: makeContext(layer: layer, sourceRef: sourceRef))
        guard let scoped = runner.run(RuleValue.combo(rules), input: layer.text, dom: baseDom),
              !scoped.isEmpty, scoped != layer.text else {
            return (layer.text, baseDom)
        }
        AppLog.debug("ENGINE", "〔\(source.name)〕_range范围生效：\(scoped.count)字")
        return (scoped, HTMLParser.parse(scoped))
    }

    /// 解析一层 `_list`（@json: 路径 → 数组项 JSON 文本；否则 DOM 选择器 → 节点）。
    private func parseListEntries(_ rule: String, text: String, dom: HTMLNode?,
                                  source name: String) -> [(input: String, node: HTMLNode?)] {
        if rule.hasPrefix("@json:") {
            let path = String(rule.dropFirst(6))
            return JSONRule.objectArray(path, in: text).compactMap { item -> (input: String, node: HTMLNode?)? in
                // 标量数组（`_list: @json:types` 形态）直接转文本：
                // JSONSerialization 不接受顶层片段，原实现会把这类项全丢掉。
                switch item {
                case let s as String: return (input: s, node: nil)
                case let n as NSNumber: return (input: n.stringValue, node: nil)
                default: break
                }
                guard let data = try? JSONSerialization.data(withJSONObject: item),
                      let json = String(data: data, encoding: .utf8) else { return nil }
                return (input: json, node: nil)
            }
        }
        guard let dom else { return [] }
        return ExSelector.parse(rule).select(from: dom).map {
            (input: $0.textContent, node: Optional($0))
        }
    }

    /// 在列表项上执行字段组合规则。
    /// - JSON 模式（node=nil）：input=项JSON文本，@json: 规则在其上求值
    /// - DOM 模式（node非nil）：选择器在节点子树内执行（与原 runField 行为一致）
    private func runFieldOn(_ runner: RuleRunner, parser: [String: ParserField],
                            name: String, input: String, node: HTMLNode?) -> String? {
        guard let rules = fieldRules(parser, name) else { return nil }
        return runner.run(RuleValue.combo(rules), input: input, dom: node)
    }

    /// 字段/组合规则执行上下文。
    /// ⚠️ 必须带上 sourceRef（尤其 helpId）：七猫正文 URL 由
    /// `@dyn: bid=source.helpId; ...` 组合规则拼出，若这里只新建
    /// `DynSourceRef(configName:)`，helpId 恒为空 → `id=` 空 → 服务端报错 →
    /// `@json:data.content` 取空 → 正文空白（日志实锤场景）。
    private func makeContext(step: StepResult, sourceRef: DynSourceRef? = nil) -> DynContext {
        let ctx = DynContext(store: store)
        ctx.respContent = step.text
        ctx.responseHeaders = step.headers
        ctx.parentChain = step.frames
        var ref = sourceRef ?? DynSourceRef(configName: source.name)
        if ref.configName.isEmpty { ref.configName = source.name }
        if ref.helpId.isEmpty { ref.helpId = helpId }
        ctx.source = ref
        return ctx
    }

    /// 按层构造上下文：响应文本 / 响应头 / 父链都取自该层，
    /// 避免「用外层规则解内层 HTML」时 self.contents、self.parent 串层。
    private func makeContext(layer: StepLayer, sourceRef: DynSourceRef? = nil) -> DynContext {
        let ctx = DynContext(store: store)
        ctx.respContent = layer.text
        ctx.responseHeaders = layer.headers
        ctx.parentChain = layer.frames
        var ref = sourceRef ?? DynSourceRef(configName: source.name)
        if ref.configName.isEmpty { ref.configName = source.name }
        if ref.helpId.isEmpty { ref.helpId = helpId }
        ctx.source = ref
        return ctx
    }

    // MARK: - params / keyword

    /// URL 中的 %@ → 搜索词（percent-encode：错层源 "/book/so/%@.html" 中文直接进URL会构造失败）。
    private func applyParams(_ url: String, params: [String: String], keyword: String?) -> String {
        var result = url
        if let keyword {
            let encoded = DynEngine.percentEncodeStatic(keyword)
            result = result.replacingOccurrences(of: "%@", with: encoded)
        }
        return result
    }

    /// params 值的完整求值（对齐爱阅 JxdNetConfigManager params 语义）：
    /// - `@dyn:...` → 动态脚本执行（ctx 已注入 keyword / pageIndex 变量）
    /// - `%@keyword` → 搜索词
    /// - `%@calc(expr)` → 表达式求值（如 calc(pageIndex + 1)）
    /// - `%@变量名` → DynContext 变量
    /// - 混合静态文本原样保留
    private func applyParamsDict(_ params: [String: String], keyword: String?,
                                 ctx: DynContext) -> [String: String] {
        guard !params.isEmpty else { return params }
        // 变量注入（脚本里的裸 keyword / pageIndex 引用）
        if let keyword {
            ctx.vars["keyword"] = .str(keyword)
        }
        let engine = DynEngine(ctx: ctx)
        var result = params
        for (k, v) in params {
            let trimmed = v.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("@dyn:") {
                if let s = engine.executeString(String(trimmed.dropFirst(5))) {
                    result[k] = s
                }
                continue
            }
            if v.contains("%@") {
                result[k] = resolveParamPlaceholders(v, engine: engine, keyword: keyword)
            }
        }
        return result
    }

    /// 扫描值中的 `%@名称` / `%@calc(expr)` / 裸 `%@` 占位符并替换为求值结果。
    /// 裸 `%@`（无标识符跟随）= 搜索词（猫眼API形态：keyword: "%@"）。
    private func resolveParamPlaceholders(_ value: String, engine: DynEngine, keyword: String?) -> String {
        var out = ""
        var i = value.startIndex
        while i < value.endIndex {
            // 找 %@ 前缀
            if value[i] == "%", value.index(after: i) < value.endIndex,
               value[value.index(after: i)] == "@" {
                var j = value.index(i, offsetBy: 2)
                // calc( 表达式占位
                if value[j...].hasPrefix("calc(") {
                    var depth = 0
                    let start = j
                    while j < value.endIndex {
                        if value[j] == "(" { depth += 1 }
                        if value[j] == ")" {
                            depth -= 1
                            if depth == 0 {
                                j = value.index(after: j)
                                break
                            }
                        }
                        j = value.index(after: j)
                    }
                    let exprText = String(value[start..<j])
                    if case .num(let n) = engine.evaluate(exprText) {
                        out += DynEngine.trimNumber(n)
                    } else if case .str(let s) = engine.evaluate(exprText) {
                        out += s
                    }
                    i = j
                    continue
                }
                // 标识符占位（keyword / 变量名）
                var name = ""
                while j < value.endIndex {
                    let c = value[j]
                    if c.isLetter || c.isNumber || c == "_" { name.append(c) }
                    else { break }
                    j = value.index(after: j)
                }
                if !name.isEmpty {
                    if name == "keyword", let keyword {
                        out += keyword
                    } else if case .num(let n)? = engine.ctx.vars[name] {
                        out += DynEngine.trimNumber(n)
                    } else if case .str(let s)? = engine.ctx.vars[name] {
                        out += s
                    }
                    i = j
                    continue
                }
                // 裸 %@ = 搜索词（值内直接替换）
                if let keyword {
                    out += keyword
                    i = j
                    continue
                }
            }
            out.append(value[i])
            i = value.index(after: i)
        }
        return out
    }

    /// XDKEYWORD 占位词（节点 extraKeys 中 ^-^XDKEYWORD 开头的值）。
    private func keywordPlaceholder(_ node: RuleNode) -> String? {
        for (key, value) in node.extraKeys where key.contains("XDKEYWORD") {
            return value.isEmpty ? nil : value
        }
        return nil
    }

    /// 深度替换节点树规则串中的占位词（RuleNode 为 class，先深拷贝隔离）。
    private func injectKeyword(_ node: RuleNode, placeholder: String?, keyword: String) -> RuleNode {
        guard let placeholder, !placeholder.isEmpty, placeholder != keyword else { return node }
        let copy = node.cloned()
        copy.url = replaceInRuleValue(node.url, placeholder: placeholder, keyword: keyword)
        copy.nextPageUrl = replaceInRuleValue(node.nextPageUrl, placeholder: placeholder, keyword: keyword)
        copy.parser = replaceInParser(node.parser, placeholder: placeholder, keyword: keyword)
        if let middle = node.middleHandle {
            copy.middleHandle = injectKeyword(middle, placeholder: placeholder, keyword: keyword)
        }
        return copy
    }

    private func replaceInRuleValue(_ value: RuleValue?, placeholder: String, keyword: String) -> RuleValue? {
        guard let value else { return nil }
        let rules = value.rules.map { $0.replacingOccurrences(of: placeholder, with: keyword) }
        return rules.count == 1 ? .text(rules[0]) : .combo(rules)
    }

    private func replaceInParser(_ parser: [String: ParserField], placeholder: String,
                                 keyword: String) -> [String: ParserField] {
        var result: [String: ParserField] = [:]
        for (key, field) in parser {
            switch field {
            case .rules(let rules):
                result[key] = .rules(rules.map { $0.replacingOccurrences(of: placeholder, with: keyword) })
            case .sub(let dict):
                result[key] = .sub(replaceInParser(dict, placeholder: placeholder, keyword: keyword))
            }
        }
        return result
    }

    // MARK: - helpId 兜底

    /// 取当前 helpId；为空时从兜底 URL 的查询参数里解析（旧书数据 helpId 缺失的兼容路径）。
    func resolvedHelpId(fallbackURL: String = "") -> String {
        if !helpId.isEmpty { return helpId }
        return Self.helpIdFromURL(fallbackURL)
    }

    /// 从 URL 查询串中提取书籍 id（`...chapter-list?id=1784836&sign=...` → "1784836"）。
    static func helpIdFromURL(_ url: String) -> String {
        guard !url.isEmpty, let mark = url.firstIndex(of: "?") else { return "" }
        let query = url[url.index(after: mark)...]
        for pair in query.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard kv.count == 2, kv[0].lowercased() == "id" else { continue }
            let value = String(kv[1]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { return value }
        }
        return ""
    }

    // MARK: - 工具

    /// 疑似接口错误 JSON 被当成正文（`{"code":...,"message":...}` 形态）。
    /// 旧版本把这类「整页兜底」结果写进了章节缓存，需要识别后丢弃重取。
    static func looksLikeAPIErrorPayload(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.hasPrefix("{"), t.count < 400, !t.contains("\n\n") else { return false }
        return t.contains("\"code\"") || t.contains("\"message\"") || t.contains("\"msg\"")
    }

    /// 疑似 Base64 密文（长度>100、纯Base64字符集、无中文）。
    static func looksLikeBase64Cipher(_ text: String) -> Bool {
        guard text.count > 100 else { return false }
        let b64Chars = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=\r\n ")
        return text.unicodeScalars.allSatisfy { b64Chars.contains($0) }
    }

    /// 七猫模式原生解密兜底：Base64解码 → 前16字节作IV → AES-128-CBC(PKCS7)。
    /// key 从 @def 脚本正则提取（`Utf8.parse("<16字符>")`）；提取失败返回 nil。
    static func decryptQimaoStyle(cipherB64: String, script: String) -> String? {
        // 从 @def: CryptoJS 脚本中提取 key: CryptoJS.enc.Utf8.parse("242ccb8230d709e1")
        guard let match = script.range(of: #"Utf8\.parse\("([0-9a-fA-F]{16})"\)"#,
                                       options: .regularExpression) else {
            AppLog.warn("CONTENT", "原生兜底：未从@def脚本提取到16位key")
            return nil
        }
        let keyStr = String(script[match]).replacingOccurrences(
            of: #"Utf8\.parse\(|\)|""#, with: "", options: .regularExpression)
        guard keyStr.count == 16,
              let cipherData = Data(base64Encoded: cipherB64.trimmingCharacters(in: .whitespacesAndNewlines)),
              cipherData.count > 16 else {
            AppLog.warn("CONTENT", "原生兜底：key长度或Base64数据不合法")
            return nil
        }
        let iv = cipherData.prefix(16)
        let ciphertext = cipherData.dropFirst(16)
        guard ciphertext.count % 16 == 0 else { return nil }

        var out = Data(count: ciphertext.count)
        var moved = 0
        let outCapacity = out.count
        let keyData = Data(keyStr.utf8)
        let status = keyData.withUnsafeBytes { keyPtr -> CCCryptorStatus in
            iv.withUnsafeBytes { ivPtr -> CCCryptorStatus in
                ciphertext.withUnsafeBytes { dataPtr -> CCCryptorStatus in
                    out.withUnsafeMutableBytes { outPtr -> CCCryptorStatus in
                        CCCrypt(
                            CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyPtr.baseAddress, keyData.count,
                            ivPtr.baseAddress,
                            dataPtr.baseAddress, ciphertext.count,
                            outPtr.baseAddress, outCapacity, &moved)
                    }
                }
            }
        }
        guard status == kCCSuccess, moved > 0 else { return nil }
        out.removeSubrange(moved..<out.count)
        return String(data: out, encoding: .utf8)
    }

    /// data:text/plain;base64,XXX → 解码文本（短路机制）。
    private func decodeDataURL(_ url: String) -> String {
        guard let comma = url.firstIndex(of: ",") else { return "" }
        let payload = String(url[url.index(after: comma)...])
        guard url.hasPrefix("data:text/plain;base64") || url.hasPrefix("data:;base64") else {
            return payload
        }
        guard let data = Data(base64Encoded: payload) else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// 正文清洗（HTML → 文本 + 去广告空行）。
    static func cleanContent(_ raw: String) -> String {
        var text = raw
        // 组合规则产物可能是 HTML 片段
        if text.contains("<") {
            text = HTMLParser.htmlToText(text)
        }
        var lines: [String] = []
        for line in text.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "\u{3000}", with: " ")
                .replacingOccurrences(of: "\u{00A0}", with: " ")
            if t.isEmpty { continue }
            if t.contains("请记住本书首发域名") { continue }
            lines.append(t)
        }
        return lines.joined(separator: "\n")
    }
}
