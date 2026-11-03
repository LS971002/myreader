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

    struct StepResult {
        var text: String = ""
        var headers: [String: String] = [:]
        var finalURL: String = ""
        var parser: [String: ParserField] = [:]   // 最深层 parser（字段提取）
        var frames: [ParentFrame] = []            // 最深层视角的父链
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

        // 最深层 parser：_list + bookName / author / desc + _BookFields.dirURL
        guard let listRules = fieldRules(step.parser, "_list"), let listRule = listRules.first else {
            return []
        }
        let runner = RuleRunner(ctx: makeContext(step: step))

        // 双模式列表：@json: 路径 → JSON 数组项；否则 HTML DOM 选择器
        // 字段规则求值输入：JSON 模式 = (项JSON文本, nil)；DOM 模式 = (节点文本, 节点对象)
        var entries: [(input: String, node: HTMLNode?)] = []
        if listRule.hasPrefix("@json:") {
            let path = String(listRule.dropFirst(6))
            entries = JSONRule.objectArray(path, in: step.text).compactMap { item in
                guard let data = try? JSONSerialization.data(withJSONObject: item),
                      let text = String(data: data, encoding: .utf8) else { return nil }
                return (text, nil)
            }
        } else {
            let dom = HTMLParser.parse(step.text)
            entries = ExSelector.parse(listRule).select(from: dom).map { ($0.textContent, $0) }
        }
        guard !entries.isEmpty else {
            AppLog.warn("SEARCH", "〔\(source.name)〕列表为空（_list: \(listRule.prefix(60))）"
                        + " 响应\(step.text.count)字 末尾: \(step.text.suffix(120).replacingOccurrences(of: "\n", with: " "))")
            return []
        }
        AppLog.info("SEARCH", "〔\(source.name)〕列表项 \(entries.count) 个（\(listRule.hasPrefix("@json:") ? "JSON" : "DOM")模式）")

        var results: [SearchResult] = []
        var seen = Set<String>()

        for entry in entries.prefix(80) {
            let title = runFieldOn(runner, parser: step.parser, name: "bookName",
                                   input: entry.input, node: entry.node) ?? ""
            guard !title.isEmpty else { continue }
            let key = title + "|" + (fieldRules(step.parser, "dirURL")?.first ?? "")
            if !seen.insert(key).inserted { continue }

            let dirURL = runFieldOn(runner, parser: step.parser, name: "dirURL",
                                    input: entry.input, node: entry.node) ?? ""
            if dirURL.isEmpty {
                AppLog.warn("SEARCH", "〔\(source.name)〕《\(title.prefix(16))》dirURL为空(规则: \(fieldRules(step.parser, "dirURL")?.first?.prefix(50) ?? "-"))，link兜底为搜索URL")
            }
            let link = dirURL.isEmpty ? step.finalURL
                : HTTPClient.absolute(dirURL, base: step.finalURL.isEmpty ? source.homeURL : step.finalURL)
            let author = runFieldOn(runner, parser: step.parser, name: "author",
                                    input: entry.input, node: entry.node) ?? ""
            // helpId 提取（七猫形态：_BookFields.helpId → 正文组合规则 source.helpId）
            let helpId = runFieldOn(runner, parser: step.parser, name: "helpId",
                                    input: entry.input, node: entry.node) ?? ""
            if helpId.isEmpty == false && self.helpId.isEmpty {
                self.helpId = helpId
                AppLog.debug("SEARCH", "〔\(source.name)〕helpId提取：\(helpId.prefix(20))")
            }

            results.append(SearchResult(
                sourceID: source.id,
                sourceName: source.name,
                title: title,
                author: author,
                helpId: helpId,
                link: link,
                cover: HTTPClient.absolute(
                    runFieldOn(runner, parser: step.parser, name: "coverUrl", input: entry.input, node: entry.node) ?? "",
                    base: source.homeURL),
                intro: runFieldOn(runner, parser: step.parser, name: "desc", input: entry.input, node: entry.node) ?? "",
                latest: runFieldOn(runner, parser: step.parser, name: "lastChapterTitle", input: entry.input, node: entry.node) ?? "",
                matchKind: Self.classify(title: title, author: author, keyword: trimmed)
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
        let runner = RuleRunner(ctx: makeContext(step: step))
        let dom = HTMLParser.parse(step.text)
        let intro = runFieldOn(runner, parser: step.parser, name: "desc",
                               input: dom.textContent, node: dom) ?? ""
        let cover = HTTPClient.absolute(
            runFieldOn(runner, parser: step.parser, name: "coverUrl",
                       input: dom.textContent, node: dom) ?? "",
            base: source.homeURL)
        return (intro, cover)
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
        let maxPages = max(node.maxPageCount, 1)

        for pageIndex in 0..<min(maxPages, 40) {
            let step = try await runNode(node, overrideURL: overrideURL, keyword: nil,
                                         pageIndex: pageIndex,
                                         parentFrames: [], sourceRef: sourceRef)
            guard let listRules = fieldRules(step.parser, "_list"), let listRule = listRules.first else {
                AppLog.warn("DIR", "〔\(source.name)〕无_list规则（parser键: \(step.parser.keys.sorted().prefix(6).joined(separator: ","))）")
                break
            }
            let runner = RuleRunner(ctx: makeContext(step: step, sourceRef: sourceRef))

            // 双模式列表（与 search 一致）：@json: 路径 → JSON 数组项；否则 HTML DOM 选择器
            var entries: [(input: String, node: HTMLNode?)] = []
            if listRule.hasPrefix("@json:") {
                let path = String(listRule.dropFirst(6))
                entries = JSONRule.objectArray(path, in: step.text).compactMap { item in
                    guard let data = try? JSONSerialization.data(withJSONObject: item),
                          let text = String(data: data, encoding: .utf8) else { return nil }
                    return (text, nil)
                }
            } else {
                let dom = HTMLParser.parse(step.text)
                entries = ExSelector.parse(listRule).select(from: dom).map { ($0.textContent, $0) }
            }
            AppLog.info("DIR", "〔\(source.name)〕第\(pageIndex + 1)页列表项 \(entries.count) 个（\(listRule.hasPrefix("@json:") ? "JSON" : "DOM")模式）")
            if entries.isEmpty { break }

            for entry in entries {
                let title = runFieldOn(runner, parser: step.parser, name: "title",
                                       input: entry.input, node: entry.node) ?? ""
                let url = runFieldOn(runner, parser: step.parser, name: "url",
                                     input: entry.input, node: entry.node) ?? ""
                guard !title.isEmpty, !url.isEmpty else { continue }
                if !seenTitles.insert(title).inserted { continue }
                chapters.append(Chapter(
                    index: chapters.count,
                    title: title,
                    url: HTTPClient.absolute(url, base: step.finalURL.isEmpty ? source.homeURL : step.finalURL)))
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
        AppLog.info("DIR", "〔\(source.name)〕目录完成：\(chapters.count) 章")
        return chapters
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

        // 最深层 parser 的 content 字段（组合规则：@def: JS + @dyn: 提取 + @ex: 取文本）
        if let contentRules = fieldRules(step.parser, "content") {
            let runner = RuleRunner(ctx: makeContext(step: step, sourceRef: sourceRef))
            let dom = HTMLParser.parse(step.text)
            var text = runner.run(RuleValue.combo(contentRules), input: step.text, dom: dom)
            // 智能兜底：@def: 携带 CryptoJS 的源（七猫形态）在 JS 解密链未生效时
            // （结果为 nil / 空 / 仍是 Base64 密文）→ 走原生 AES-128-CBC 解密。
            // 密文直接取响应里的 data.content，不依赖 JS 执行是否成功。
            if let defScript = contentRules.first(where: { $0.contains("@def:") && $0.contains("CryptoJS") }) {
                let produced = text ?? ""
                if produced.isEmpty || Self.looksLikeBase64Cipher(produced) {
                    let cipher = JSONRule.path("data.content", in: step.text).first ?? produced
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
        } else {
            AppLog.warn("CONTENT", "〔\(source.name)〕最深层parser无content字段（键: \(step.parser.keys.sorted().prefix(8).joined(separator: ","))）")
        }
        // 兜底：_range
        if let rangeRules = fieldRules(step.parser, "_range") {
            let runner = RuleRunner(ctx: makeContext(step: step, sourceRef: sourceRef))
            let dom = HTMLParser.parse(step.text)
            let text = runner.run(RuleValue.combo(rangeRules), input: step.text, dom: dom)
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

        let frame = ParentFrame(currentRequestUrl: finalURL, respContent: text)
        let frames = [frame] + parentFrames

        // 5. middleHandle 递归（子层脚本 self.parent.* 由 parentChain 承载）
        if let middle = node.middleHandle {
            return try await runNode(middle, overrideURL: nil, keyword: keyword, pageIndex: pageIndex,
                                     parentFrames: frames, sourceRef: sourceRef)
        }

        // 6. 本层即最深层
        return StepResult(text: text, headers: headers, finalURL: finalURL,
                          parser: node.parser, frames: frames)
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
