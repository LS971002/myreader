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
        guard let node0 = source.searchBook else { throw EngineError.noSearchNode }
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw EngineError.emptyKeyword }

        // XDKEYWORD 注入：占位词 → 搜索词（深度替换节点树中的规则串）
        let node = injectKeyword(node0, placeholder: keywordPlaceholder(node0), keyword: trimmed)

        let sourceRef = DynSourceRef(configName: source.name)
        let step = try await runNode(node, overrideURL: nil, keyword: trimmed,
                                     parentFrames: [], sourceRef: sourceRef)

        // 最深层 parser：_list + bookName / author / desc + _BookFields.dirURL
        guard let listRules = fieldRules(step.parser, "_list"), let listRule = listRules.first else {
            return []
        }
        let dom = HTMLParser.parse(step.text)
        let items = ExSelector.parse(listRule).select(from: dom)
        guard !items.isEmpty else { return [] }

        let runner = RuleRunner(ctx: makeContext(step: step))
        var results: [SearchResult] = []
        var seen = Set<String>()

        for item in items.prefix(80) {
            let title = runField(runner, parser: step.parser, name: "bookName",
                                 node: item, dom: step.text) ?? ""
            guard !title.isEmpty else { continue }
            let key = title + "|" + (fieldRules(step.parser, "dirURL")?.first ?? "")
            if !seen.insert(key).inserted { continue }

            let dirURL = runField(runner, parser: step.parser, name: "dirURL",
                                  node: item, dom: step.text) ?? ""
            let link = dirURL.isEmpty ? step.finalURL
                : HTTPClient.absolute(dirURL, base: step.finalURL.isEmpty ? source.homeURL : step.finalURL)

            results.append(SearchResult(
                sourceID: source.id,
                sourceName: source.name,
                title: title,
                author: runField(runner, parser: step.parser, name: "author", node: item, dom: step.text) ?? "",
                link: link,
                cover: HTTPClient.absolute(
                    runField(runner, parser: step.parser, name: "coverUrl", node: item, dom: step.text) ?? "",
                    base: source.homeURL),
                intro: runField(runner, parser: step.parser, name: "desc", node: item, dom: step.text) ?? "",
                latest: runField(runner, parser: step.parser, name: "lastChapterTitle", node: item, dom: step.text) ?? "",
                matchKind: Self.classify(title: title, author: runField(runner, parser: step.parser, name: "author", node: item, dom: step.text) ?? "", keyword: trimmed)
            ))
        }
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
        let step = try await runNode(node, overrideURL: link, keyword: nil,
                                     parentFrames: [], sourceRef: sourceRef)
        let runner = RuleRunner(ctx: makeContext(step: step))
        let dom = HTMLParser.parse(step.text)
        let intro = runField(runner, parser: step.parser, name: "desc", node: dom, dom: step.text) ?? ""
        let cover = HTTPClient.absolute(
            runField(runner, parser: step.parser, name: "coverUrl", node: dom, dom: step.text) ?? "",
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

        for _ in 0..<min(maxPages, 40) {
            let step = try await runNode(node, overrideURL: overrideURL, keyword: nil,
                                         parentFrames: [], sourceRef: sourceRef)
            guard let listRules = fieldRules(step.parser, "_list"), let listRule = listRules.first else {
                break
            }
            let dom = HTMLParser.parse(step.text)
            let items = ExSelector.parse(listRule).select(from: dom)
            if items.isEmpty { break }

            let runner = RuleRunner(ctx: makeContext(step: step))
            for item in items {
                let title = runField(runner, parser: step.parser, name: "title",
                                     node: item, dom: step.text) ?? ""
                let url = runField(runner, parser: step.parser, name: "url",
                                   node: item, dom: step.text) ?? ""
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

        let step = try await runNode(node, overrideURL: nil, keyword: nil,
                                     parentFrames: [], sourceRef: sourceRef)

        // 最深层 parser 的 content 字段（组合规则：@def: JS + @dyn: 提取 + @ex: 取文本）
        if let contentRules = fieldRules(step.parser, "content") {
            let runner = RuleRunner(ctx: makeContext(step: step))
            let dom = HTMLParser.parse(step.text)
            let text = runner.run(RuleValue.combo(contentRules), input: step.text, dom: dom)
            if let text, !text.isEmpty { return cleanContent(text) }
        }
        // 兜底：_range
        if let rangeRules = fieldRules(step.parser, "_range") {
            let runner = RuleRunner(ctx: makeContext(step: step))
            let dom = HTMLParser.parse(step.text)
            let text = runner.run(RuleValue.combo(rangeRules), input: step.text, dom: dom)
            if let text, !text.isEmpty { return cleanContent(text) }
        }
        // 最终兜底：整页转文本
        return cleanContent(HTMLParser.htmlToText(step.text))
    }

    // MARK: - 节点执行（核心）

    private func runNode(_ node: RuleNode,
                         overrideURL: String?,
                         keyword: String?,
                         parentFrames: [ParentFrame],
                         sourceRef: DynSourceRef) async throws -> StepResult {
        // 1. URL 求值
        let ctx = DynContext(store: store)
        ctx.parentChain = parentFrames
        ctx.source = sourceRef
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
            } else {
                urlStr = applyParams(urlRule, params: node.params, keyword: keyword)
            }
        } else {
            urlStr = nil
        }

        // 2. 短路（nil / data: URL → 空响应继续走 parser + middleHandle）
        var text = ""
        var headers: [String: String] = [:]
        var finalURL = urlStr ?? ""

        if let url = urlStr, !url.isEmpty {
            if url.hasPrefix("data:") {
                text = decodeDataURL(url)
                headers = [:]
            } else {
                // 3. 请求（含重试）
                let method = node.forGetMethod ? "GET" : "POST"
                let params = applyParamsDict(node.params, keyword: keyword)
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
                                url: url, headers: mergedHeaders, js: nil)
                            resp = HTTPClient.Response(finalURL: url, text: html, headers: [:])
                        } else {
                            resp = try await HTTPClient.shared.request(
                                url: url, method: method, params: params,
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
                    finalURL = resp.finalURL
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
            return try await runNode(middle, overrideURL: nil, keyword: keyword,
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
    private func runField(_ runner: RuleRunner, parser: [String: ParserField],
                          name: String, node: HTMLNode, dom: String) -> String? {
        guard let rules = fieldRules(parser, name) else { return nil }
        return runner.run(RuleValue.combo(rules), input: node.textContent, dom: node)
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

    private func applyParams(_ url: String, params: [String: String], keyword: String?) -> String {
        var result = url
        if let keyword {
            result = result.replacingOccurrences(of: "%@", with: keyword)
        }
        return result
    }

    private func applyParamsDict(_ params: [String: String], keyword: String?) -> [String: String] {
        guard let keyword else { return params }
        var result = params
        for (k, v) in params where v.contains("%@") {
            result[k] = v.replacingOccurrences(of: "%@", with: keyword)
        }
        return result
    }

    /// XDKEYWORD 占位词（节点 extraKeys 中 ^-^XDKEYWORD 开头的值）。
    private func keywordPlaceholder(_ node: RuleNode) -> String? {
        for (key, value) in node.extraKeys where key.contains("XDKEYWORD") {
            return value.isEmpty ? nil : value
        }
        return nil
    }

    /// 深度替换节点树规则串中的占位词。
    private func injectKeyword(_ node: RuleNode, placeholder: String?, keyword: String) -> RuleNode {
        guard let placeholder, !placeholder.isEmpty, placeholder != keyword else { return node }
        var copy = node
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
