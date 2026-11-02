import Foundation
import Compression

/// 极简 ZIP 读取器（只支持 stored / deflate，够读 EPUB 用）。
struct ZipReader {
    struct Entry {
        let name: String
        let method: UInt16
        let compressedSize: Int
        let uncompressedSize: Int
        let localOffset: Int
    }

    private let data: Data
    private(set) var entries: [String: Entry] = [:]

    init(data: Data) throws {
        self.data = data
        let bytes = [UInt8](data)
        guard let eocd = ZipReader.findEOCD(bytes) else { throw Importer.ImportError.read }

        let count = Int(readU16(bytes, eocd + 10))
        var offset = Int(readU32(bytes, eocd + 16))

        for _ in 0..<count {
            guard offset + 46 <= bytes.count, readU32(bytes, offset) == 0x02014b50 else { break }
            let method = readU16(bytes, offset + 10)
            let compressed = Int(readU32(bytes, offset + 20))
            let uncompressed = Int(readU32(bytes, offset + 24))
            let nameLen = Int(readU16(bytes, offset + 28))
            let extraLen = Int(readU16(bytes, offset + 30))
            let commentLen = Int(readU16(bytes, offset + 32))
            let localOffset = Int(readU32(bytes, offset + 42))
            let nameStart = offset + 46
            guard nameStart + nameLen <= bytes.count else { break }
            let name = String(decoding: bytes[nameStart..<(nameStart + nameLen)], as: UTF8.self)
            entries[name] = Entry(name: name, method: method, compressedSize: compressed,
                                  uncompressedSize: uncompressed, localOffset: localOffset)
            offset = nameStart + nameLen + extraLen + commentLen
        }
    }

    func read(_ name: String) -> Data? {
        guard let entry = entries[name] else { return nil }
        let bytes = [UInt8](data)
        let base = entry.localOffset
        guard base + 30 <= bytes.count, readU32(bytes, base) == 0x04034b50 else { return nil }
        let nameLen = Int(readU16(bytes, base + 26))
        let extraLen = Int(readU16(bytes, base + 28))
        let start = base + 30 + nameLen + extraLen
        guard start <= bytes.count else { return nil }
        let end = min(start + entry.compressedSize, bytes.count)
        let payload = Data(bytes[start..<end])
        if entry.method == 0 { return payload }
        return ZipReader.inflate(payload, expected: entry.uncompressedSize)
    }

    static func inflate(_ data: Data, expected: Int) -> Data? {
        guard !data.isEmpty else { return Data() }
        let capacity = max(expected, data.count * 6, 64 * 1024)
        var output = Data(count: capacity)
        let written = output.withUnsafeMutableBytes { outPointer -> Int in
            guard let outBase = outPointer.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return data.withUnsafeBytes { inPointer -> Int in
                guard let inBase = inPointer.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_decode_buffer(outBase, capacity, inBase, data.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard written > 0 else { return nil }
        return output.prefix(written)
    }

    private static func findEOCD(_ bytes: [UInt8]) -> Int? {
        guard bytes.count > 22 else { return nil }
        let lowerBound = max(0, bytes.count - 66_000)
        var i = bytes.count - 22
        while i >= lowerBound {
            if bytes[i] == 0x50, bytes[i + 1] == 0x4b, bytes[i + 2] == 0x05, bytes[i + 3] == 0x06 {
                return i
            }
            i -= 1
        }
        return nil
    }

    private func readU16(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
        guard offset + 1 < bytes.count else { return 0 }
        return UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
    }

    private func readU32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        guard offset + 3 < bytes.count else { return 0 }
        return UInt32(bytes[offset])
            | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16)
            | (UInt32(bytes[offset + 3]) << 24)
    }
}

/// 解析 EPUB 的 spine 顺序与正文。
struct EPUBArchive {
    struct Chapter {
        let title: String
        let content: String
        let bookTitle: String
        let author: String
    }

    private let zip: ZipReader

    init(data: Data) throws {
        zip = try ZipReader(data: data)
    }

    func chapters() throws -> [Chapter] {
        // 1. container.xml 找 OPF
        guard let containerData = zip.read("META-INF/container.xml"),
              let container = String(data: containerData, encoding: .utf8) else {
            throw Importer.ImportError.read
        }
        let containerDom = HTMLParser.parse(container)
        guard let rootfile = containerDom.elements().first(where: { $0.tag == "rootfile" }),
              let opfPath = rootfile.attr("full-path"),
              let opfData = zip.read(opfPath),
              let opf = String(data: opfData, encoding: .utf8) else {
            throw Importer.ImportError.read
        }

        let opfDom = HTMLParser.parse(opf)
        let all = opfDom.elements()
        let bookTitle = all.first { $0.tag == "dc:title" }?.textContent
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let author = all.first { $0.tag == "dc:creator" }?.textContent
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        // 2. manifest: id -> href
        var manifest: [String: String] = [:]
        for item in all where item.tag == "item" {
            if let id = item.attr("id"), let href = item.attr("href") {
                manifest[id] = href
            }
        }

        // 3. spine 顺序
        var hrefs: [String] = []
        for ref in all where ref.tag == "itemref" {
            if let idref = ref.attr("idref"), let href = manifest[idref] {
                hrefs.append(href)
            }
        }
        if hrefs.isEmpty {
            hrefs = manifest.values.filter { $0.hasSuffix(".xhtml") || $0.hasSuffix(".html") || $0.hasSuffix(".htm") }
                .sorted()
        }

        let baseDir = (opfPath as NSString).deletingLastPathComponent

        var result: [Chapter] = []
        for (index, href) in hrefs.enumerated() {
            let path = resolve(href, base: baseDir)
            guard let fileData = zip.read(path),
                  let html = String(data: fileData, encoding: .utf8) ?? String(data: fileData, encoding: .isoLatin1)
            else { continue }

            let dom = HTMLParser.parse(html)
            let nodes = dom.elements()
            let heading = nodes.first { ["h1", "h2", "h3", "title"].contains($0.tag) }?
                .textContent.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let body = nodes.first { $0.tag == "body" }

            var content = HTMLParser.htmlToText(body?.textContent ?? dom.textContent)
            if !heading.isEmpty {
                content = content.replacingOccurrences(of: heading, with: "", options: [], range: content.startIndex..<content.endIndex)
            }
            let title = heading.isEmpty ? "第 \(index + 1) 节" : heading
            guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            result.append(Chapter(title: title, content: content, bookTitle: bookTitle, author: author))
        }
        return result
    }

    private func resolve(_ href: String, base: String) -> String {
        let decoded = href.removingPercentEncoding ?? href
        if base.isEmpty { return decoded }
        return (base as NSString).appendingPathComponent(decoded)
    }
}
