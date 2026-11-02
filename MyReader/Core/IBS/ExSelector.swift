import Foundation

/// 爱阅 @ex: / 无前缀 XPath 规则选择器。
///
/// 语法（真实 IBS 书源样例归纳）：
/// ```
/// div[@class=container search-card]     标签 + 属性包含匹配
/// a[@href=book][0]                      属性包含 + 结果索引
/// ul[@class=chapter-list].li            子级
/// a.@text                               取文本
/// a[@text=下页][0].@href                文本包含 + 取属性
/// script[@text=initTxt].@text           脚本内容包含
/// a[@href=book][0].@href#\.html @=>/list.html   取值后 regex 替换
/// ```
/// 属性 / 文本匹配一律「包含」语义；段间以 `.` 分隔；末段 `@attr` 取值。
struct ExSelector {
    struct Segment {
        var tag: String?
        var attrName: String?      // "@text" 特殊：匹配 textContent
        var attrValue: String?
        var index: Int? = nil
    }

    var segments: [Segment] = []
    /// 末段取值属性：@text / @allText / @ownText / @html / @href…
    var valueAttr: String? = nil
    /// 取值后缀：`#pattern @=>template`
    var replacePattern: String? = nil
    var replaceTemplate: String = ""

    // MARK: - 解析

    static func parse(_ raw: String) -> ExSelector {
        var selector = ExSelector()
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return selector }

        // 取值后缀（#pattern @=>template）
        var body = trimmed
        if let hash = body.firstIndex(of: "#") {
            let tail = String(body[hash...].dropFirst())
            // 只有形如 pattern @=>template 的才当后缀（含 " @=>"）
            if let range = tail.range(of: " @=>") {
                selector.replacePattern = String(tail[tail.startIndex..<range.lowerBound])
                selector.replaceTemplate = String(tail[range.upperBound...])
                body = String(body[body.startIndex..<hash])
            }
        }

        let parts = body.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "." })
            .map(String.init)
            .filter { !$0.isEmpty }

        for (i, part) in parts.enumerated() {
            let isLast = i == parts.count - 1
            if part.hasPrefix("@") {
                selector.valueAttr = part
                continue
            }
            selector.segments.append(parseSegment(part, allowValueAttr: isLast))
        }
        return selector
    }

    private static func parseSegment(_ part: String, allowValueAttr: Bool) -> Segment {
        var segment = Segment()
        var rest = part

        // 标签
        if let bracket = rest.firstIndex(of: "[") {
            segment.tag = String(rest[rest.startIndex..<bracket]).lowercased()
            if segment.tag?.isEmpty == true { segment.tag = nil }
            rest = String(rest[bracket...])
        } else {
            segment.tag = rest.lowercased()
            rest = ""
        }

        // [@attr=value] / [index]
        while rest.hasPrefix("[") {
            guard let close = rest.firstIndex(of: "]") else { break }
            let inner = String(rest[rest.index(after: rest.startIndex)..<close])
            rest = String(rest[rest.index(after: close)...])

            if let eq = inner.firstIndex(of: "="), inner.hasPrefix("@") {
                segment.attrName = String(inner[inner.startIndex..<eq])   // 含 @
                segment.attrValue = String(inner[inner.index(after: eq)...])
            } else if let n = Int(inner) {
                segment.index = n
            }
        }
        _ = allowValueAttr
        return segment
    }

    // MARK: - 查询

    /// 返回匹配节点集合（无取值段时）。
    func select(from root: HTMLNode) -> [HTMLNode] {
        guard !segments.isEmpty else { return [root] }
        var current: [HTMLNode] = [root]

        for (i, segment) in segments.enumerated() {
            let isFirst = i == 0
            var matched: [HTMLNode] = []
            for scope in current {
                let candidates: [HTMLNode] =
                    isFirst ? scope.elements() : scope.children.filter { !$0.isText }
                for node in candidates where matches(node, segment: segment) {
                    if !matched.contains(where: { $0 === node }) {
                        matched.append(node)
                    }
                }
            }
            if let index = segment.index {
                matched = matched.indices.contains(index) ? [matched[index]] : []
            }
            current = matched
            if current.isEmpty { return [] }
        }
        return current
    }

    /// 取单值：第一个匹配节点的属性 / 文本（含 regex 后缀）。
    func value(from root: HTMLNode) -> String? {
        // 无取值属性：返回拼接文本
        guard let attr = valueAttr else {
            let nodes = select(from: root)
            return nodes.first?.textContent.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let nodes = select(from: root)
        guard let node = nodes.first else { return nil }
        var result: String?
        switch attr {
        case "@text":
            result = node.textContent.trimmingCharacters(in: .whitespacesAndNewlines)
        case "@allText":
            result = node.textContent
        case "@ownText":
            result = node.ownText.trimmingCharacters(in: .whitespacesAndNewlines)
        case "@html":
            result = node.outerHTML()
        default:
            let name = String(attr.dropFirst())   // @href → href
            result = node.attr(name)
        }
        guard var value = result, !value.isEmpty else { return nil }
        if let pattern = replacePattern {
            value = ExSelector.regexReplace(value, pattern: pattern, template: replaceTemplate)
        }
        return value
    }

    private func matches(_ node: HTMLNode, segment: Segment) -> Bool {
        if node.isText { return false }
        if let tag = segment.tag, tag != "*", node.tag != tag { return false }
        if let attrName = segment.attrName, let wanted = segment.attrValue {
            if attrName == "@text" {
                let text = node.textContent.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.contains(wanted) { return false }
            } else {
                let name = String(attrName.dropFirst())
                guard let value = node.attr(name), value.contains(wanted) else { return false }
            }
        }
        return true
    }

    // MARK: - regex 后缀

    static func regexReplace(_ content: String, pattern: String, template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return content }
        let ns = content as NSString
        return regex.stringByReplacingMatches(
            in: content, range: NSRange(location: 0, length: ns.length),
            withTemplate: template)
    }
}
