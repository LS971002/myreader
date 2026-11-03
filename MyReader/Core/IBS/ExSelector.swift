import Foundation

/// 爱阅 `@ex:` / 无前缀 选择器。
///
/// 语义对齐逆向产物 `Reverse/rea/01_书源模块.md`（JxdRuleInfo executeCombi +
/// JxdXpathEx / JxdAnalyzeHtml）与真实书源归纳：
/// ```
/// div[@class=container search-card]      标签 + 属性「包含」匹配
/// div[@class==bookbox]                  属性「精确」匹配（==）
/// article[@id=main]..div[@class==item]  `..` = 递归后代，`.` = 直接子级
/// div[@class=author][1]                 第 2 个匹配（0 起）
/// article[@id=main]..div[0~33]          取前 34 个
/// a.@text / img.@data-original          末段 @attr 取值
/// a[@text=下页][@and href=_].@href       复合条件（@and 追加）
/// a.@href#\.html @=>/list.html          取值后 regex 替换
/// ```
struct ExSelector {
    struct Condition {
        var name: String      // "@id" / "@class" / "@text" / "href"
        var value: String
        var exact: Bool       // `==` 精确，`=` 包含
    }

    struct Segment {
        var tag: String?
        var conditions: [Condition] = []
        var index: Int? = nil
        /// `[0~33]` → 保留前 34 个（33 为闭区间上界）。
        var limit: Int? = nil
        /// true = `..`（递归后代），false = `.`（直接子级）。
        var descendant: Bool = false
    }

    var segments: [Segment] = []
    /// 末段取值属性：@text / @allText / @ownText / @html / @href…
    var valueAttr: String? = nil
    /// XPath 步骤（`@xpath:``//dt[...]/following-sibling::a`` 形态）。
    var xpathSteps: [XPathStep]? = nil
    /// 取值后缀：`#pattern @=>template`
    var replacePattern: String? = nil
    var replaceTemplate: String = ""

    // MARK: - 解析

    static func parse(_ raw: String) -> ExSelector {
        var selector = ExSelector()
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return selector }

        // XPath 形态（真实书源：`//dt[contains(text(),"全部章节")]/following-sibling::a`）
        if let steps = XPathStep.parse(trimmed) {
            selector.xpathSteps = steps
            return selector
        }

        // 取值后缀（#pattern @=>template）
        var body = trimmed
        if let hash = body.firstIndex(of: "#") {
            let tail = String(body[hash...].dropFirst())
            if let range = tail.range(of: " @=>") {
                selector.replacePattern = String(tail[tail.startIndex..<range.lowerBound])
                selector.replaceTemplate = String(tail[range.upperBound...])
                body = String(body[body.startIndex..<hash])
            }
        }

        // 段分隔：`.` 子级 / `..` 后代（首段按后代处理）
        var parts: [(text: String, descendant: Bool)] = []
        var current = ""
        var descendantFlag = true
        var index = body.startIndex
        while index < body.endIndex {
            let ch = body[index]
            if ch == "." {
                let next = body.index(after: index)
                var isDouble = false
                var advance = next
                if next < body.endIndex, body[next] == "." {
                    isDouble = true
                    advance = body.index(after: next)
                }
                if !current.isEmpty {
                    parts.append((current, descendantFlag))
                    current = ""
                }
                descendantFlag = isDouble
                index = advance
                continue
            }
            current.append(ch)
            index = body.index(after: index)
        }
        if !current.isEmpty { parts.append((current, descendantFlag)) }

        for (i, part) in parts.enumerated() {
            if part.text.hasPrefix("@") {
                selector.valueAttr = part.text
                continue
            }
            let isLast = i == parts.count - 1
            selector.segments.append(parseSegment(part.text,
                                                  descendant: part.descendant,
                                                  allowValueAttr: isLast))
        }
        return selector
    }

    private static func parseSegment(_ part: String, descendant: Bool,
                                     allowValueAttr: Bool) -> Segment {
        var segment = Segment()
        segment.descendant = descendant
        var rest = part

        if let bracket = rest.firstIndex(of: "[") {
            segment.tag = String(rest[rest.startIndex..<bracket]).lowercased()
            rest = String(rest[bracket...])
        } else {
            segment.tag = rest.lowercased()
            rest = ""
        }
        if segment.tag?.isEmpty == true { segment.tag = nil }

        while rest.hasPrefix("[") {
            guard let close = rest.firstIndex(of: "]") else { break }
            let inner = String(rest[rest.index(after: rest.startIndex)..<close])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            rest = String(rest[rest.index(after: close)...])
            if inner.isEmpty { continue }

            // 复合条件：`@and href=_` / `@and @class=x`
            if inner.hasPrefix("@and ") || inner.hasPrefix("@and") {
                let sub = inner.hasPrefix("@and ") ? String(inner.dropFirst(5)) : String(inner.dropFirst(4))
                for piece in sub.components(separatedBy: "@and") {
                    if let condition = parseCondition(piece) {
                        segment.conditions.append(condition)
                    }
                }
                continue
            }
            if let condition = parseCondition(inner) {
                segment.conditions.append(condition)
                continue
            }
            if inner.contains("~") {
                let pair = inner.components(separatedBy: "~")
                if pair.count == 2, let upper = Int(pair[1].trimmingCharacters(in: .whitespaces)) {
                    segment.limit = upper + 1
                }
                continue
            }
            if let n = Int(inner) {
                segment.index = n
            }
        }
        _ = allowValueAttr
        return segment
    }

    private static func parseCondition(_ raw: String) -> Condition? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        var exact = false
        if text.contains("==") {
            exact = true
            text = text.replacingOccurrences(of: "==", with: "=")
        }
        guard text.hasPrefix("@") else {
            // 非属性条件（contains(...) 等 XPath 函数）不支持，跳过而不是整体失败
            return nil
        }
        guard let eq = text.firstIndex(of: "=") else { return nil }
        let name = String(text[text.startIndex..<eq]).trimmingCharacters(in: .whitespaces)
        var value = String(text[text.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("\"") && value.hasSuffix("\"") && value.count >= 2 {
            value = String(value.dropFirst().dropLast())
        }
        guard !name.isEmpty else { return nil }
        return Condition(name: name, value: value, exact: exact)
    }

    // MARK: - 查询

    /// 返回匹配节点集合（无取值段时）。
    func select(from root: HTMLNode) -> [HTMLNode] {
        if let steps = xpathSteps {
            return XPathStep.evaluate(steps, from: root)
        }
        guard !segments.isEmpty else { return [root] }
        var current: [HTMLNode] = [root]

        for (i, segment) in segments.enumerated() {
            var matched: [HTMLNode] = []
            for scope in current {
                let candidates: [HTMLNode]
                if i == 0 || segment.descendant {
                    candidates = scope.elements().filter { $0 !== scope }
                } else {
                    candidates = scope.children.filter { !$0.isText }
                }
                for node in candidates where matches(node, segment: segment) {
                    if !matched.contains(where: { $0 === node }) {
                        matched.append(node)
                    }
                }
            }
            if let limit = segment.limit, matched.count > limit {
                matched = Array(matched.prefix(limit))
            }
            if let index = segment.index {
                matched = matched.indices.contains(index) ? [matched[index]] : []
            }
            current = matched
            if current.isEmpty { return [] }
        }
        return current
    }

    /// 取单值：第一个匹配节点的属性 / 多节点文本拼接（含 regex 后缀）。
    func value(from root: HTMLNode) -> String? {
        let nodes = select(from: root)
        guard !nodes.isEmpty else { return nil }

        var value: String
        if let attr = valueAttr {
            guard let node = nodes.first else { return nil }
            // 书源里属性名大小写混用（`@text` / `@allText` / `@alltext`），统一小写比较
            switch attr.lowercased() {
            case "@text", "@alltext", "@all_text":
                value = node.textContent
            case "@owntext":
                value = node.ownText
            case "@html", "@outerhtml":
                value = node.outerHTML()
            default:
                value = node.attr(String(attr.dropFirst())) ?? ""
            }
        } else {
            // 多节点：逐节点取文本按行拼接（JxdXpathEx 取所有命中节点的文本）
            value = nodes
                .map { $0.textContent.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
        }
        value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        if let pattern = replacePattern {
            value = ExSelector.regexReplace(value, pattern: pattern, template: replaceTemplate)
        }
        return value.isEmpty ? nil : value
    }

    private func matches(_ node: HTMLNode, segment: Segment) -> Bool {
        if node.isText { return false }
        if let tag = segment.tag, tag != "*", !tag.isEmpty, node.tag != tag { return false }
        for condition in segment.conditions {
            switch condition.name {
            case "@text", "@allText":
                let text = node.textContent.trimmingCharacters(in: .whitespacesAndNewlines)
                let matched = condition.exact
                    ? (text == condition.value) : text.contains(condition.value)
                if !matched { return false }
            case "@html":
                let html = node.outerHTML()
                let matched = condition.exact
                    ? (html == condition.value) : html.contains(condition.value)
                if !matched { return false }
            default:
                let name = condition.name.hasPrefix("@")
                    ? String(condition.name.dropFirst()) : condition.name
                let attrValue = node.attr(name) ?? ""
                let matched = condition.exact
                    ? (attrValue == condition.value) : attrValue.contains(condition.value)
                if !matched { return false }
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

// MARK: - 极简 XPath

/// 真实书源只用到的 XPath 子集：
/// `//tag[predicate]`、`/tag`、`/following-sibling::tag`，
/// 谓词支持 `contains(text(),"x")`、`@attr="v"`、`text()="v"`、`[n]`。
/// 依据：`Reverse/rea/01_书源模块.md`（JxdXpathEx / JxdXpathInfo，基于 ONOXML）。
/// 注意：必须是 struct —— enum 不能带存储属性（CI 报错 error: enums must not contain stored properties）。
struct XPathStep {
    enum Axis {
        case descendant
        case child
        case followingSibling
    }

    enum Predicate {
        case containsText(String)
        case textEquals(String)
        case attrEquals(String, String)
        case attrExists(String)
        case index(Int)
    }

    var axis: Axis
    var tag: String
    var predicate: Predicate?

    static func parse(_ raw: String) -> [XPathStep]? {
        guard raw.hasPrefix("/") || raw.contains("::") else { return nil }
        guard raw.hasPrefix("/") else { return nil }

        var steps: [XPathStep] = []
        var index = raw.startIndex

        while index < raw.endIndex {
            guard raw[index] == "/" else { return nil }
            var axis = Axis.child
            let next = raw.index(after: index)
            if next < raw.endIndex, raw[next] == "/" {
                axis = .descendant
                index = raw.index(after: next)
            } else {
                index = next
            }

            var name = ""
            while index < raw.endIndex {
                let ch = raw[index]
                if ch.isLetter || ch.isNumber || ch == "-" || ch == "_" || ch == "*" {
                    name.append(ch)
                    index = raw.index(after: index)
                } else {
                    break
                }
            }

            // axis::tag（following-sibling::a / descendant::a）
            if index < raw.endIndex, raw[index] == ":" {
                var cursor = raw.index(after: index)
                guard cursor < raw.endIndex, raw[cursor] == ":" else { return nil }
                cursor = raw.index(after: cursor)
                let axisName = name
                var realTag = ""
                while cursor < raw.endIndex, !"[/".contains(raw[cursor]) {
                    realTag.append(raw[cursor])
                    cursor = raw.index(after: cursor)
                }
                index = cursor
                switch axisName.lowercased() {
                case "following-sibling": axis = .followingSibling
                case "descendant": axis = .descendant
                case "child": axis = .child
                default: return nil
                }
                name = realTag.isEmpty ? "*" : realTag
            }

            var predicate: Predicate?
            if index < raw.endIndex, raw[index] == "[" {
                var depth = 0
                var inner = ""
                while index < raw.endIndex {
                    let ch = raw[index]
                    if ch == "[" {
                        depth += 1
                        if depth > 1 { inner.append(ch) }
                    } else if ch == "]" {
                        depth -= 1
                        if depth == 0 {
                            index = raw.index(after: index)
                            break
                        }
                        inner.append(ch)
                    } else {
                        inner.append(ch)
                    }
                    index = raw.index(after: index)
                }
                predicate = parsePredicate(inner)
            }

            steps.append(XPathStep(axis: axis, tag: name.lowercased(), predicate: predicate))
        }
        return steps.isEmpty ? nil : steps
    }

    private static func parsePredicate(_ raw: String) -> Predicate? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if let n = Int(text) { return .index(n) }
        if text.hasPrefix("contains("), let value = quotedValue(text) {
            return .containsText(value)
        }
        if text.hasPrefix("text()") {
            if let value = quotedValue(text) { return .textEquals(value) }
            return nil
        }
        if text.hasPrefix("@") {
            if let eq = text.firstIndex(of: "=") {
                let name = String(text[text.startIndex..<eq]).dropFirst()
                let value = String(text[text.index(after: eq)...])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                return .attrEquals(String(name), value)
            }
            return .attrExists(String(text.dropFirst()))
        }
        return nil
    }

    /// 取谓词里最后一个引号串（`contains(text(),"全部章节")` → 全部章节）。
    private static func quotedValue(_ text: String) -> String? {
        guard let first = text.firstIndex(of: "\"") ?? text.firstIndex(of: "'") else { return nil }
        let quote = text[first]
        let rest = text[text.index(after: first)...]
        guard let close = rest.firstIndex(of: quote) else { return nil }
        let value = String(rest[rest.startIndex..<close])
        return value.isEmpty ? nil : value
    }

    static func evaluate(_ steps: [XPathStep], from root: HTMLNode) -> [HTMLNode] {
        var current: [HTMLNode] = [root]
        for step in steps {
            var out: [HTMLNode] = []
            switch step.axis {
            case .descendant:
                for scope in current {
                    for node in scope.elements() where node !== scope {
                        if matches(node, step) { out.append(node) }
                    }
                }
            case .child:
                for scope in current {
                    for node in scope.children where !node.isText {
                        if matches(node, step) { out.append(node) }
                    }
                }
            case .followingSibling:
                for node in current {
                    guard let parent = node.parent,
                          let position = parent.children.firstIndex(where: { $0 === node }) else { continue }
                    let tail = parent.children[(position + 1)...]
                    for sibling in tail where !sibling.isText {
                        if matches(sibling, step) { out.append(sibling) }
                    }
                }
            }
            // 去重（保持顺序）
            var unique: [HTMLNode] = []
            for node in out where !unique.contains(where: { $0 === node }) {
                unique.append(node)
            }
            current = unique
            if current.isEmpty { return [] }
        }
        return current
    }

    private static func matches(_ node: HTMLNode, _ step: XPathStep) -> Bool {
        if step.tag != "*", node.tag != step.tag { return false }
        guard let predicate = step.predicate else { return true }
        switch predicate {
        case .containsText(let value):
            return node.textContent.contains(value)
        case .textEquals(let value):
            return node.textContent.trimmingCharacters(in: .whitespacesAndNewlines) == value
        case .attrEquals(let name, let value):
            return (node.attr(name) ?? "") == value
        case .attrExists(let name):
            return node.attr(name) != nil
        case .index(let n):
            return n == 0
        }
    }
}
