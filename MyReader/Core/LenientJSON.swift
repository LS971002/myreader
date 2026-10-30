import Foundation

/// 宽松解码：缺失的字段自动用默认值补齐，多出来的字段忽略。
/// 这样旧版本数据、别人导出的书源 JSON 都能直接吃进来，不会因为少个字段整体失败。
enum LenientJSON {
    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    static func decode<T: Codable>(_ type: T.Type, from data: Data, default defaultValue: T) -> T? {
        guard
            let object = try? JSONSerialization.jsonObject(with: data),
            var dict = object as? [String: Any],
            let baseData = try? encoder.encode(defaultValue),
            let baseObject = try? JSONSerialization.jsonObject(with: baseData),
            let base = baseObject as? [String: Any]
        else { return nil }

        merge(base: base, into: &dict)
        guard let merged = try? JSONSerialization.data(withJSONObject: dict) else { return nil }
        return try? decoder.decode(T.self, from: merged)
    }

    static func decodeArray<T: Codable>(_ type: T.Type, from data: Data, elementDefault: T) -> [T]? {
        guard
            let object = try? JSONSerialization.jsonObject(with: data),
            let array = object as? [Any],
            let templateData = try? encoder.encode(elementDefault),
            let templateObject = try? JSONSerialization.jsonObject(with: templateData),
            let template = templateObject as? [String: Any]
        else { return nil }

        var result: [T] = []
        for item in array {
            guard var dict = item as? [String: Any] else { continue }
            var base = template
            merge(base: base, into: &dict)
            if let merged = try? JSONSerialization.data(withJSONObject: dict),
               let value = try? decoder.decode(T.self, from: merged) {
                result.append(value)
            }
            base.removeAll()
        }
        return result
    }

    /// 把 base 中缺失的键补到 target 上（嵌套字典递归，数组整体覆盖）。
    private static func merge(base: [String: Any], into target: inout [String: Any]) {
        for (key, baseValue) in base {
            if target[key] == nil || target[key] is NSNull {
                target[key] = baseValue
            } else if let baseDict = baseValue as? [String: Any],
                      var targetDict = target[key] as? [String: Any] {
                merge(base: baseDict, into: &targetDict)
                target[key] = targetDict
            }
        }
    }
}
