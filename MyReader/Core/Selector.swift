import Foundation

/// CSS 选择器子集 + XPath 常用子集（自动转换）。
/// 支持：`div.list li a`、`#id`、`.cls`、`[attr]`、`[attr=v]`、`[attr*=v]`、
/// `:first`、`:last`、`:eq(n)`、`:nth-child(n)`、子代 `>`、多选择器 `,`
/// XPath：`//div[@class="x"]/ul/li[2]/a/text()`
struct Selector {
    enum AttrMatch {
        case exists
        case equals(String)
        case contains(String)
        case prefix(String)
        case suffix(String)
    }

    struct Compound {
        var tag: String? = nil
        var id: String? = nil
        var classes: [String] = []
        var attrs: [(String, AttrMatch)] = []
        var firstOnly = false
        var lastOnly = false
        var eq: Int? = nil
        var nthChild: Int? = nil
    }

    struct Step {
        var combinator: Character = " "
        var compound: Compound
    }

    /// 逗号分隔的多组选择器，任意一组命中即算命中。
    var groups: [[Step]] = []

    static func parse(_ raw: String) -> Selector {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return Selector(groups: []) }
        if trimmed.hasPrefix("//") || trimmed.hasPrefix("./") {
            return parseXPath(trimmed)
        }
        let parts = splitTopLevel(trimmed, separator: ",")
        var selector = Selector(groups: [])
        selector.groups = parts.map { parseSteps($0) }.filter { !$0.isEmpty }
        if selector.groups.isEmpty {
            selector.groups = [[Step(compound: Compound(tag: nil))]]
        }
        return selector
    }

    // MARK: - 匹配

    func select(_ root: HTMLNode) -> [HTMLNode] {
        let all = root.elements()
        var result: [HTMLNode] = []
        var seen = Set<ObjectIdentifier>()
        for group in groups {
            guard group.last != nil else { continue }
            for node in all where node !== root {
                guard matchesChain(node: node, steps: group, index: group.count - 1) else { continue }
                if seen.insert(ObjectIdentifier(node)).inserted {
                    result.append(node)
                }
            }
        }
        // 保持文档顺序
        let order = Dictionary(uniqueKeysWithValues: all.enumerated().map { (ObjectIdentifier($0.element), $0.offset) })
        return result.sorted { (order[ObjectIdentifier($0)] ?? 0) < (order[ObjectIdentifier($1)] ?? 0) }
    }

    private func matchesChain(node: HTMLNode, steps: [Step], index: Int) -> Bool {
        guard index >= 0 else { return true }
        let step = steps[index]
        guard matches(node: node, compound: step.compound) else { return false }
        if index == 0 { return true }

        if step.combinator == ">" {
            guard let parent = node.parent else { return false }
            return matchesChain(node: parent, steps: steps, index: index - 1)
        } else {
            var current = node.parent
            while let parent = current {
                if matchesChain(node: parent, steps: steps, index: index - 1) { return true }
                current = parent.parent
            }
            return false
        }
    }

    private func matches(node: HTMLNode, compound: Compound) -> Bool {
        if node.isText { return false }
        if let tag = compound.tag, tag != "*", node.tag != tag.lowercased() { return false }
        if let id = compound.id, node.idValue != id { return false }
        for cls in compound.classes where !node.classList.contains(cls) { return false }
        for (name, match) in compound.attrs {
            let value = node.attr(name) ?? ""
            switch match {
            case .exists: break
            case .equals(let v): if value != v { return false }
            case .contains(let v): if !value.contains(v) { return false }
            case .prefix(let v): if !value.hasPrefix(v) { return false }
            case .suffix(let v): if !value.hasSuffix(v) { return false }
            }
        }
        if compound.firstOnly || compound.lastOnly || compound.eq != nil || compound.nthChild != nil {
            guard let parent = node.parent else { return false }
            let siblings = parent.children.filter { !$0.isText && $0.tag == node.tag }
            guard let position = siblings.firstIndex(where: { $0 === node }) else { return false }
            if compound.firstOnly, position != 0 { return false }
            if compound.lastOnly, position != siblings.count - 1 { return false }
            if let eq = compound.eq, position != eq { return false }
            if let nth = compound.nthChild, position != nth - 1 { return false }
        }
        return true
    }

    // MARK: - 解析 CSS

    private static func parseSteps(_ raw: String) -> [Step] {
        var steps: [Step] = []
        let chars = Array(raw)
        var i = 0
        var current = ""
        var nextCombinator: Character = " "

        func flush() {
            let text = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty, let compound = parseCompound(text) {
                steps.append(Step(combinator: nextCombinator, compound: compound))
                nextCombinator = " "
            }
            current = ""
        }

        while i < chars.count {
            let c = chars[i]
            if c == ">" {
                flush()
                nextCombinator = ">"
                i += 1
                continue
            }
            if c == " " || c == "\t" || c == "\n" || c == "\r" {
                flush()
                i += 1
                continue
            }
            current.append(c)
            i += 1
        }
        flush()
        return steps
    }

    private static func parseCompound(_ text: String) -> Compound? {
        var compound = Compound()
        let chars = Array(text)
        var i = 0
        var tag = ""
        while i < chars.count && !"#.[:".contains(chars[i]) {
            tag.append(chars[i]); i += 1
        }
        if !tag.isEmpty { compound.tag = tag.lowercased() }

        while i < chars.count {
            let c = chars[i]
            if c == "#" {
                i += 1
                var id = ""
                while i < chars.count && !"#.[:".contains(chars[i]) { id.append(chars[i]); i += 1 }
                compound.id = id
            } else if c == "." {
                i += 1
                var cls = ""
                while i < chars.count && !"#.[:".contains(chars[i]) { cls.append(chars[i]); i += 1 }
                if !cls.isEmpty { compound.classes.append(cls) }
            } else if c == "[" {
                i += 1
                var body = ""
                while i < chars.count && chars[i] != "]" { body.append(chars[i]); i += 1 }
                if i < chars.count { i += 1 }
                if let (name, match) = parseAttr(body) {
                    compound.attrs.append((name, match))
                }
            } else if c == ":" {
                i += 1
                var name = ""
                while i < chars.count && (chars[i].isLetter || chars[i] == "-") { name.append(chars[i]); i += 1 }
                var arg = ""
                if i < chars.count && chars[i] == "(" {
                    i += 1
                    while i < chars.count && chars[i] != ")" { arg.append(chars[i]); i += 1 }
                    if i < chars.count { i += 1 }
                }
                switch name.lowercased() {
                case "first", "first-child", "first-of-type": compound.firstOnly = true
                case "last", "last-child", "last-of-type": compound.lastOnly = true
                case "eq": compound.eq = Int(arg)
                case "nth-child", "nth-of-type": compound.nthChild = Int(arg)
                default: break
                }
            } else {
                i += 1
            }
        }
        return compound
    }

    private static func parseAttr(_ body: String) -> (String, AttrMatch)? {
        let trimmed = body.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let operators = ["*=", "^=", "$=", "="]
        for op in operators {
            if let range = trimmed.range(of: op) {
                let name = String(trimmed[trimmed.startIndex..<range.lowerBound])
                    .trimmingCharacters(in: .whitespaces).lowercased()
                var value = String(trimmed[range.upperBound...])
                    .trimmingCharacters(in: .whitespaces)
                value = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                switch op {
                case "*=": return (name, .contains(value))
                case "^=": return (name, .prefix(value))
                case "$=": return (name, .suffix(value))
                default: return (name, .equals(value))
                }
            }
        }
        return (trimmed.lowercased(), .exists)
    }

    // MARK: - XPath 子集

    static func parseXPath(_ raw: String) -> Selector {
        var text = raw.trimmingCharacters(in: .whitespaces)
        if text.hasSuffix("/text()") { text = String(text.dropLast(7)) }
        text = text.replacingOccurrences(of: "//", with: "/")
        if text.hasPrefix("/") { text = String(text.dropFirst()) }

        var steps: [Step] = []
        for piece in splitTopLevel(text, separator: "/") {
            let p = piece.trimmingCharacters(in: .whitespaces)
            if p.isEmpty || p == "." || p.hasPrefix("@") { continue }
            var compound = Compound()
            var head = p
            // [2] 位置
            if let bracket = p.range(of: "[", options: .backwards), p.hasSuffix("]") {
                let inside = String(p[bracket.upperBound..<p.index(before: p.endIndex)])
                if let n = Int(inside) {
                    compound.nthChild = n
                } else if inside.contains("@") {
                    let body = inside.replacingOccurrences(of: "@", with: "")
                    if let (name, match) = parseAttr(body) { compound.attrs.append((name, match)) }
                }
                head = String(p[p.startIndex..<bracket.lowerBound])
            }
            let name = head.trimmingCharacters(in: .whitespaces)
            if !name.isEmpty && name != "*" { compound.tag = name.lowercased() }
            if compound.tag == nil && compound.attrs.isEmpty && compound.nthChild == nil { continue }
            steps.append(Step(combinator: steps.isEmpty ? " " : ">", compound: compound))
        }
        return Selector(groups: steps.isEmpty ? [] : [steps])
    }

    static func splitTopLevel(_ text: String, separator: Character) -> [String] {
        var parts: [String] = []
        var current = ""
        var depth = 0
        var quote: Character? = nil
        for c in text {
            if let q = quote {
                current.append(c)
                if c == q { quote = nil }
                continue
            }
            if c == "\"" || c == "'" { quote = c; current.append(c); continue }
            if c == "[" || c == "(" { depth += 1 }
            if c == "]" || c == ")" { depth = max(0, depth - 1) }
            if c == separator && depth == 0 {
                parts.append(current); current = ""
            } else {
                current.append(c)
            }
        }
        if !current.isEmpty { parts.append(current) }
        return parts
    }
}
