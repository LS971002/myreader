import Foundation
import JavaScriptCore

/// IBS 规则执行器：按前缀分发，支持组合规则（contents[i] 引用前序结果）。
///
/// 前缀（逆向文档 01 模块 4.1 节）：
///   @dyn:  动态脚本（DynEngine）
///   @def:  JavaScript（组合中作为代码文本传递，contents[0]）
///   @ex: / 无前缀  XPath 选择器（ExSelector）
///   @str:  字符串拼接（self = 输入）
///   @regex: 正则（pattern @=>template，无 @=> 为提取）
///   @json: JSON 路径
final class RuleRunner {
    let ctx: DynContext

    init(ctx: DynContext) {
        self.ctx = ctx
    }

    // MARK: 组合规则

    /// 依次执行组合规则；每条结果的输入是前一条的输出，并累积到 ctx.contents。
    /// - Parameters:
    ///   - value: 规则（单条或数组）
    ///   - input: 首条规则的输入（响应 HTML / 上层传入值）
    ///   - dom: 首条输入对应的 DOM（响应已解析则传入，避免重复 parse）
    func run(_ value: RuleValue, input: String, dom: HTMLNode? = nil) -> String? {
        let rules = value.rules
        guard !rules.isEmpty else { return nil }
        var current = input
        ctx.contents.removeAll()

        for (index, rule) in rules.enumerated() {
            let firstDom = (index == 0) ? dom : nil
            let result = runSingle(rule, input: current, dom: firstDom) ?? ""
            ctx.contents.append(result)
            current = result
        }
        return current.isEmpty ? nil : current
    }

    // MARK: 单条规则

    func runSingle(_ rule: String, input: String, dom: HTMLNode?) -> String? {
        let trimmed = rule.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // @dyn: —— self.respContent 由 IBSEngine 维护；隐式变量 content = 输入
        if trimmed.hasPrefix("@dyn:") {
            let script = String(trimmed.dropFirst(5))
            let engine = DynEngine(ctx: ctx)
            ctx.vars["content"] = .str(input)
            let value = engine.execute(script)
            return value.isNull ? nil : value.stringValue
        }

        // @def: —— 组合场景返回代码文本（contents[0] 供 @dyn: evaluateScript）
        if trimmed.hasPrefix("@def:") {
            return String(trimmed.dropFirst(5))
        }

        // @str: 字符串拼接（"literal"+self）
        if trimmed.hasPrefix("@str:") {
            return evalStrExpr(String(trimmed.dropFirst(5)), input: input)
        }

        // @regex: pattern @=>template（可空 = 删除匹配）；无 @=> 为提取
        if trimmed.hasPrefix("@regex:") {
            let body = String(trimmed.dropFirst(7))
            let value = DynEngine.executeRegex(input, rule: body)
            return value.isNull ? nil : value.stringValue
        }

        // @json: 路径
        if trimmed.hasPrefix("@json:") {
            let path = String(trimmed.dropFirst(6))
            let values = JSONRule.path(path, in: input)
            return values.first
        }

        // @ex: / 无前缀 —— XPath 选择器
        var selectorText = trimmed
        if trimmed.hasPrefix("@ex:") {
            selectorText = String(trimmed.dropFirst(4))
        } else if trimmed.hasPrefix("@xpath:") {
            selectorText = String(trimmed.dropFirst(7))
        }
        if trimmed.hasPrefix("@ex:") || trimmed.hasPrefix("@xpath:") || looksLikeSelector(selectorText) {
            let selector = ExSelector.parse(selectorText)
            let scope: HTMLNode
            if let dom {
                scope = dom
            } else if let parsed = parseDOM(input) {
                scope = parsed
            } else {
                return nil
            }
            let value = selector.value(from: scope)
            return value?.isEmpty == true ? nil : value
        }

        // 兜底：纯文本（type 0）直接返回
        return trimmed
    }

    /// 列表项字段规则：在节点子树内执行。
    func runOnNode(_ rule: String, node: HTMLNode) -> String? {
        let trimmed = rule.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.hasPrefix("@dyn:") {
            let script = String(trimmed.dropFirst(5))
            ctx.vars["content"] = .str(node.textContent)
            let engine = DynEngine(ctx: ctx)
            let value = engine.execute(script)
            return value.isNull ? nil : value.stringValue
        }
        if trimmed.hasPrefix("@str:") {
            return evalStrExpr(String(trimmed.dropFirst(5)), input: node.textContent)
        }
        if trimmed.hasPrefix("@regex:") {
            let body = String(trimmed.dropFirst(7))
            let value = DynEngine.executeRegex(node.textContent, rule: body)
            return value.isNull ? nil : value.stringValue
        }

        var selectorText = trimmed
        if trimmed.hasPrefix("@ex:") { selectorText = String(trimmed.dropFirst(4)) }
        else if trimmed.hasPrefix("@xpath:") { selectorText = String(trimmed.dropFirst(7)) }

        let selector = ExSelector.parse(selectorText)
        let value = selector.value(from: node)
        return value?.isEmpty == true ? nil : value
    }

    // MARK: @str: 表达式

    /// `"literal"+self` 形式的拼接（self = 输入）。
    private func evalStrExpr(_ expr: String, input: String) -> String? {
        var out = ""
        var rest = expr.trimmingCharacters(in: .whitespacesAndNewlines)
        while !rest.isEmpty {
            if rest.hasPrefix("\"") {
                guard let close = rest.dropFirst().firstIndex(of: "\"") else {
                    out += String(rest.dropFirst())
                    return out.isEmpty ? nil : out
                }
                out += String(rest[rest.index(after: rest.startIndex)...close])
                rest = String(rest[rest.index(after: close)...])
            } else {
                let piece: String
                if let plus = rest.firstIndex(of: "+") {
                    piece = String(rest[rest.startIndex..<plus])
                    rest = String(rest[rest.index(after: plus)...])
                } else {
                    piece = rest
                    rest = ""
                }
                let atom = piece.trimmingCharacters(in: .whitespaces)
                if atom == "self" { out += input }
                else if atom.isEmpty { continue }
                else if let v = ctx.vars[atom] { out += v.stringValue }
                else { out += atom }
            }
            if rest.hasPrefix("+") { rest = String(rest.dropFirst()) }
        }
        return out.isEmpty ? nil : out
    }

    // MARK: 工具

    private func parseDOM(_ html: String) -> HTMLNode? {
        guard !html.isEmpty else { return nil }
        return HTMLParser.parse(html)
    }

    /// 判断是否为选择器形态（含 [ 或以 @ 开头的段）。
    private func looksLikeSelector(_ text: String) -> Bool {
        text.contains("[") || text.contains(".") || text.contains("@")
    }
}

// MARK: - JSON 路径（自旧引擎迁移）

enum JSONRule {
    /// `data.books[0].title`、`a.b[*].c`
    static func path(_ path: String, in text: String) -> [String] {
        guard
            let data = text.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data)
        else { return [] }

        var cleaned = path.trimmingCharacters(in: .whitespaces)
        if cleaned.hasPrefix("$") { cleaned = String(cleaned.dropFirst()) }
        if cleaned.hasPrefix(".") { cleaned = String(cleaned.dropFirst()) }

        var keys: [String] = []
        var current = ""
        for c in cleaned {
            if c == "." { keys.append(current); current = "" }
            else if c == "[" { if !current.isEmpty { keys.append(current); current = "" } }
            else if c == "]" { if !current.isEmpty { keys.append(current); current = "" } }
            else { current.append(c) }
        }
        if !current.isEmpty { keys.append(current) }

        var currentValues: [Any] = [object]
        for key in keys {
            var next: [Any] = []
            if key == "*" {
                for value in currentValues {
                    if let array = value as? [Any] { next.append(contentsOf: array) }
                    else if let dict = value as? [String: Any] { next.append(contentsOf: dict.values) }
                }
            } else if let index = Int(key) {
                for value in currentValues {
                    if let array = value as? [Any], array.indices.contains(index) {
                        next.append(array[index])
                    }
                }
            } else {
                for value in currentValues {
                    if let dict = value as? [String: Any], let v = dict[key] {
                        next.append(v)
                    }
                }
            }
            currentValues = next
            if currentValues.isEmpty { return [] }
        }

        return currentValues.compactMap { value -> String? in
            switch value {
            case let s as String: return s
            case let n as NSNumber: return n.stringValue
            default: return nil
            }
        }
    }
}
