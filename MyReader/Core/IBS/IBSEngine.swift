import Foundation

/// IBS 书源引擎：搜索 → 详情 → 目录 → 正文 四大流程。
/// 复刻爱阅 JxdNetDataProcess 执行模型：
///   节点(url 求值 → 请求 → parser 执行副作用 → middleHandle 递归)
///   rule 变量（RuleStore）跨节点 / 跨流程共享（cookie 状态依赖此机制）。
final class IBSEngine {
    let source: IBSBookSource
    private let store = RuleStore()

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
            AppLog.warn("SEARCH", "〔\(source.name)〕列表为空 (_list规则: \(listRule.prefix(60)))")
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
            let link = dirURL.isEmpty ? step.finalURL
                : HTTPClient.absolute(dirURL, base: step.finalURL.isEmpty ? source.homeURL : step.finalURL)
            let author = runFieldOn(runner, parser: step.parser, name: "author",
                                    input: entry.input, node: entry.node) ?? ""

            results.append(SearchResult(
                sourceID: source.id,
                sourceName: source.name,
                title: title,
                author: author,
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
        guard let node = source.sourceDetail else { return [] }
        var sourceRef = DynSourceRef(configName: source.name)
        sourceRef.dirURL = link
        sourceRef.detailURL = link

        var chapters: [Chapter] = []
        var overrideURL: String? = nil
        var seenTitles = Set<String>()
        let maxPages = max(node.maxPageCount, 1)

        for pageIndex in 0..<min(maxPages, 40) {
            let step = try await runNode(node, overrideURL: overrideURL, keyword: nil,
                                         pageIndex: pageIndex,
                                         parentFrames: [], sourceRef: sourceRef)
            guard let listRules = fieldRules(step.parser, "_list"), let listRule = listRules.first else {
                break
            }
            let dom = HTMLParser.parse(step.text)
            let items = ExSelector.parse(listRule).select(from: dom)
            if items.isEmpty { break }

            let runner = RuleRunner(ctx: makeContext(step: step))
            for item in items {
                let title = runFieldOn(runner, parser: step.parser, name: "title",
                                       input: item.textContent, node: item) ?? ""
                let url = runFieldOn(runner, parser: step.parser, name: "url",
                                     input: item.textContent, node: item) ?? ""
                guard !title.isEmpty, !url.isEmpty else { continue }
                if !seenTitles.insert(title).inserted { continue }
                chapters.append(Chapter(
                    index: chapters.count,
                    title: title,
                    url: HTTPClient.absolute(url, base: step.finalURL.isEmpty ? source.homeURL : step.finalURL)))
            }

            // 下一页（nextPageUrl 脚本读取 helpId 存入的 next0 / next1）
            if let nextRule = node.nextPageUrl?.first, !nextRule.isEmpty {
                let ctx = makeContext(step: step)
                let next: String?
                if nextRule.hasPrefix("@dyn:") {
                    next = DynEngine(ctx: ctx).executeString(String(nextRule.dropFirst(5)))
                } else {
                    next = nextRule
                }
                if let next, !next.isEmpty {
                    overrideURL = HTTPClient.absolute(next, base: step.finalURL)
                } else {
                    break
                }
            } else {
                break
            }
        }
        return chapters
    }

    // MARK: - 正文

    func content(chapter: Chapter) async throws -> String {
        guard let node = source.chapterDetail else { return "" }
        var sourceRef = DynSourceRef(configName: source.name)
        sourceRef.chapterURL = chapter.url

        let step = try await runNode(node, overrideURL: nil, keyword: nil, pageIndex: nil,
                                     parentFrames: [], sourceRef: sourceRef)

        // 最深层 parser 的 content 字段（组合规则：@def: JS + @dyn: 提取 + @ex: 取文本）
        if let contentRules = fieldRules(step.parser, "content") {
            let runner = RuleRunner(ctx: makeContext(step: step))
            let dom = HTMLParser.parse(step.text)
            let text = runner.run(RuleValue.combo(contentRules), input: step.text, dom: dom)
            if let text, !text.isEmpty { return Self.cleanContent(text) }
        }
        // 兜底：_range
        if let rangeRules = fieldRules(step.parser, "_range") {
            let runner = RuleRunner(ctx: makeContext(step: step))
            let dom = HTMLParser.parse(step.text)
            let text = runner.run(RuleValue.combo(rangeRules), input: step.text, dom: dom)
            if let text, !text.isEmpty { return Self.cleanContent(text) }
        }
        // 最终兜底：整页转文本
        return Self.cleanContent(HTMLParser.htmlToText(step.text))
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
        for (_, field) in node.parser {
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

    private func makeContext(step: StepResult) -> DynContext {
        let ctx = DynContext(store: store)
        ctx.respContent = step.text
        ctx.responseHeaders = step.headers
        ctx.parentChain = step.frames
        ctx.source = DynSourceRef(configName: source.name)
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

    // MARK: - 工具

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
