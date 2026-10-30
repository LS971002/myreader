import Foundation

/// 用一套书源规则完成「搜索 → 目录 → 正文」的完整流程。
final class BookSourceEngine {
    let source: BookSource

    init(_ source: BookSource) {
        self.source = source
    }

    // MARK: - 搜索

    func search(_ keyword: String, page: Int = 1) async throws -> [SearchResult] {
        let url = Self.expand(source.searchURL, keyword: keyword, page: page, base: source.baseURL)
        let page0 = try await Fetcher.fetch(url, charset: source.charset)
        let engine = page0.engine

        var items: [HTMLNode] = []
        if !source.searchList.isEmpty {
            items = engine.nodes(source.searchList, in: page0.dom)
        }
        let listScope = items.isEmpty ? [page0.dom] : items

        var results: [SearchResult] = []
        var seen = Set<String>()
        for item in listScope.prefix(60) {
            let link = pick(source.searchLink, engine, item, page0)
            let title = pick(source.searchTitle, engine, item, page0)
            guard !title.isEmpty else { continue }
            let key = title + "|" + link
            if !seen.insert(key).inserted { continue }
            results.append(SearchResult(
                sourceID: source.id,
                sourceName: source.name,
                title: title,
                author: pick(source.searchAuthor, engine, item, page0),
                link: link.isEmpty ? source.baseURL : Self.abs(link, base: source.baseURL),
                cover: Self.abs(pick(source.searchCover, engine, item, page0), base: source.baseURL),
                intro: pick(source.searchIntro, engine, item, page0),
                latest: pick(source.searchLatest, engine, item, page0)
            ))
        }
        return results
    }

    // MARK: - 目录

    struct Directory {
        var intro: String = ""
        var cover: String = ""
        var author: String = ""
        var chapters: [Chapter] = []
    }

    func directory(detailURL: String) async throws -> Directory {
        var result = Directory()
        let detail = try await Fetcher.fetch(detailURL, charset: source.charset)
        let engine = detail.engine

        if !source.introRule.isEmpty {
            result.intro = engine.value(source.introRule, in: detail.dom)
        }
        if !source.coverRule.isEmpty {
            result.cover = Self.abs(engine.value(source.coverRule, in: detail.dom), base: source.baseURL)
        }

        // 目录可能在详情页，也可能需要单独打开一个目录页
        var directoryPage = detail
        var chapterNodes = source.dirURL.isEmpty
            ? engine.nodes(source.dirList, in: detail.dom)
            : []

        if !source.dirURL.isEmpty {
            let dirURL = Self.abs(source.dirURL, base: source.baseURL)
            if dirURL != detailURL, let page = try? await Fetcher.fetch(dirURL, charset: source.charset) {
                directoryPage = page
                chapterNodes = page.engine.nodes(source.dirList, in: page.dom)
            }
        }

        var chapters: [Chapter] = []
        var index = 0
        for node in chapterNodes {
            let title = pick(source.dirTitle, directoryPage.engine, node, directoryPage)
            let link = pick(source.dirLink, directoryPage.engine, node, directoryPage)
            guard !title.isEmpty else { continue }
            chapters.append(Chapter(
                index: index,
                title: title,
                url: link.isEmpty ? "" : Self.abs(link, base: source.baseURL)
            ))
            index += 1
        }

        // 翻页抓目录
        var nextURL = source.dirNext.isEmpty ? "" :
            pick(source.dirNext, directoryPage.engine, directoryPage.dom, directoryPage)
        var pageCount = 0
        while !nextURL.isEmpty, pageCount < 20 {
            pageCount += 1
            let next = Self.abs(nextURL, base: source.baseURL)
            guard let page = try? await Fetcher.fetch(next, charset: source.charset) else { break }
            let nodes = page.engine.nodes(source.dirList, in: page.dom)
            if nodes.isEmpty { break }
            for node in nodes {
                let title = pick(source.dirTitle, page.engine, node, page)
                let link = pick(source.dirLink, page.engine, node, page)
                guard !title.isEmpty else { continue }
                chapters.append(Chapter(
                    index: index,
                    title: title,
                    url: link.isEmpty ? "" : Self.abs(link, base: source.baseURL)
                ))
                index += 1
            }
            nextURL = pick(source.dirNext, page.engine, page.dom, page)
            if nextURL.isEmpty { break }
        }

        result.chapters = chapters
        return result
    }

    // MARK: - 正文

    func content(of chapter: Chapter) async throws -> String {
        guard !chapter.url.isEmpty else { return "" }
        var text = ""
        var nextURL = chapter.url
        var pageCount = 0

        while !nextURL.isEmpty, pageCount < 12 {
            pageCount += 1
            let page = try await Fetcher.fetch(nextURL, charset: source.charset)
            let engine = page.engine
            if source.contentRule.isEmpty {
                text += RuleEngine.htmlToText(page.dom.textContent)
            } else {
                let parts = engine.list(source.contentRule, in: page.dom)
                text += parts.joined(separator: "\n")
            }
            if source.contentNext.isEmpty { break }
            let next = pick(source.contentNext, engine, page.dom, page)
            if next.isEmpty { break }
            nextURL = Self.abs(next, base: source.baseURL)
        }
        return Self.clean(text)
    }

    // MARK: - 工具

    private func pick(_ rule: String, _ engine: RuleEngine, _ node: HTMLNode, _ page: Page) -> String {
        guard !rule.isEmpty else { return "" }
        return engine.value(rule, in: node, doc: page.dom)
    }

    static func abs(_ link: String, base: String) -> String {
        let v = link.trimmingCharacters(in: .whitespacesAndNewlines)
        if v.isEmpty { return "" }
        if v.hasPrefix("http://") || v.hasPrefix("https://") { return v }
        if v.hasPrefix("//") { return "https:" + v }
        guard let baseURL = URL(string: base) else { return v }
        if v.hasPrefix("/") {
            var comps = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
            comps?.path = v
            comps?.query = nil
            return comps?.url?.absoluteString ?? v
        }
        return URL(string: v, relativeTo: baseURL)?.absoluteString ?? v
    }

    /// 展开 `{{key}}` / `@kw` / `{{page}}` 等占位符
    static func expand(_ template: String, keyword: String, page: Int, base: String) -> String {
        let encoded = keyword.addingPercentEncoding(
            withAllowedCharacters: CharacterSet(charactersIn:
                "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        ) ?? keyword
        var url = template
        for token in ["{{key}}", "{{keyword}}", "@kw", "{key}", "%s"] {
            url = url.replacingOccurrences(of: token, with: encoded)
        }
        for token in ["{{page}}", "{page}", "%d"] {
            url = url.replacingOccurrences(of: token, with: "\(page)")
        }
        return abs(url, base: base)
    }

    /// 正文清洗：去掉多余空行、广告尾巴、全角空格等。
    static func clean(_ raw: String) -> String {
        var lines: [String] = []
        for line in raw.components(separatedBy: "\n") {
            var text = line.trimmingCharacters(in: .whitespaces)
            text = text.replacingOccurrences(of: "\u{3000}", with: " ")
            text = text.replacingOccurrences(of: "\u{00A0}", with: " ")
            if text.isEmpty { continue }
            if text.contains("请记住本书首发域名") { continue }
            if text.contains("最新章节") && text.count < 40 { continue }
            lines.append(text)
        }
        return lines.joined(separator: "\n")
    }
}
