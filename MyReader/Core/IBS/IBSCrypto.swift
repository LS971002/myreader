import Foundation
import CommonCrypto
import CryptoKit

/// 爱阅书香 .ibs 书源文件解密：
/// 第一层 WinZip AES-256（AE-2）加密 ZIP → configs.json
/// 第二层 AES-128-ECB（全零 key）→ authorId-password → MD5 hex 前 16 字符为 key
///         AES-128-ECB 解密 _encodeConfigs → 书源 JSON 明文
enum IBSCrypto {
    enum IBSError: LocalizedError {
        case notZip
        case noConfigEntry
        case aesInfoMissing
        case passwordCheckFailed
        case hmacFailed
        case badJSON
        case missingFields
        case decryptFailed

        var errorDescription: String? {
            switch self {
            case .notZip: return "不是有效的 .ibs 文件（缺少 ZIP 结构）"
            case .noConfigEntry: return "ibs 包里找不到 configs.json"
            case .aesInfoMissing: return "ibs 包缺少 WinZip AES 信息"
            case .passwordCheckFailed: return "ibs 密码校验失败"
            case .hmacFailed: return "ibs 完整性校验失败"
            case .badJSON: return "ibs 内部数据解析失败"
            case .missingFields: return "ibs 缺少 _passwordConfigs/_encodeConfigs"
            case .decryptFailed: return "ibs 解密失败"
            }
        }
    }

    // MARK: - 完整链路

    /// .ibs 文件 Data → 解密后的书源 JSON 字符串。
    static func decryptFile(_ data: Data) throws -> String {
        let configs = try extractConfigs(from: data)
        return try decryptConfigs(configs)
    }

    // MARK: - 第一层：WinZip AES ZIP

    /// 爱阅内置 ZIP 密码（逆向还原：MD5(基础串 + 字符表取9字符) + 后缀）。
    static func zipPassword() -> String {
        let charset = "0123456789abcdefghijklmnopqrstuvwxyz"
            + "ABCDEFGHIJKLMNOPQRSTUVWXYZ~!@#$%^&*()_+[]{}|;':\",./<>?"
        let base = "iFreeTime-Jxd_Dowing2018-2019-03-29 09:36"
        // 索引 = 1 + i*(i+1), i = 0..8 → "137dlvHV_"
        var suffix = ""
        for i in 0..<9 {
            let index = 1 + i * (i + 1)
            let chars = Array(charset)
            guard index < chars.count else { break }
            suffix.append(chars[index])
        }
        let material = (base + suffix).data(using: .utf8)!
        let digest = md5(material)
        return digest + "*&#@!"
    }

    /// 解压 .ibs，返回 configs.json 的字节内容。
    static func extractConfigs(from data: Data) throws -> Data {
        let bytes = [UInt8](data)
        guard let entry = findConfigEntry(bytes) else { throw IBSError.noConfigEntry }
        return try readAESFile(bytes, entry: entry, password: zipPassword())
    }

    private struct ZipEntry {
        var name: String
        var method: UInt16          // 99 = WinZip AES
        var compressedSize: Int
        var localOffset: Int
        var realMethod: UInt16      // extra field 0x9901 中的真实压缩方法
        var aesStrength: UInt8      // 1=128 2=192 3=256
    }

    /// 扫 central directory，找 configs.json（或唯一条目）。
    private static func findConfigEntry(_ bytes: [UInt8]) -> ZipEntry? {
        guard let eocd = findEOCD(bytes) else { return nil }
        let count = Int(readU16(bytes, eocd + 10))
        var offset = Int(readU32(bytes, eocd + 16))
        var candidates: [ZipEntry] = []
        var fallback: ZipEntry?

        for _ in 0..<count {
            guard offset + 46 <= bytes.count, readU32(bytes, offset) == 0x02014b50 else { break }
            let method = readU16(bytes, offset + 10)
            let compressed = Int(readU32(bytes, offset + 20))
            let nameLen = Int(readU16(bytes, offset + 28))
            let extraLen = Int(readU16(bytes, offset + 30))
            let commentLen = Int(readU16(bytes, offset + 32))
            let localOffset = Int(readU32(bytes, offset + 42))
            let nameStart = offset + 46
            guard nameStart + nameLen <= bytes.count else { break }
            let name = String(decoding: bytes[nameStart..<(nameStart + nameLen)], as: UTF8.self)

            // 解析 central extra 里的 WinZip AES 头
            var realMethod: UInt16 = method
            var strength: UInt8 = 3
            var extraStart = nameStart + nameLen
            let extraEnd = extraStart + extraLen
            while extraStart + 4 <= extraEnd && extraStart + 4 <= bytes.count {
                let fieldID = readU16(bytes, extraStart)
                let fieldSize = Int(readU16(bytes, extraStart + 2))
                if fieldID == 0x9901, fieldSize >= 7, extraStart + 4 + fieldSize <= bytes.count {
                    strength = bytes[extraStart + 8]      // version(2) vendor(2) 之后
                    realMethod = readU16(bytes, extraStart + 9)
                }
                extraStart += 4 + fieldSize
            }

            let entry = ZipEntry(name: name, method: method, compressedSize: compressed,
                                 localOffset: localOffset, realMethod: realMethod, aesStrength: strength)
            if name == "configs.json" { candidates.append(entry) }
            if fallback == nil { fallback = entry }
            offset = nameStart + nameLen + extraLen + commentLen
        }
        return candidates.first ?? fallback
    }

    /// 读取并解密一个 WinZip AES 条目。
    private static func readAESFile(_ bytes: [UInt8], entry: ZipEntry, password: String) throws -> Data {
        let base = entry.localOffset
        guard base + 30 <= bytes.count, readU32(bytes, base) == 0x04034b50 else {
            throw IBSError.notZip
        }
        guard entry.method == 99 else {
            // 非 AES zip：按 stored / deflate 直接读
            let nameLen = Int(readU16(bytes, base + 26))
            let extraLen = Int(readU16(bytes, base + 28))
            let start = base + 30 + nameLen + extraLen
            let end = min(start + entry.compressedSize, bytes.count)
            guard start < end else { throw IBSError.decryptFailed }
            let payload = Data(bytes[start..<end])
            if entry.realMethod == 0 || entry.method == 0 { return payload }
            return ZipReader.inflate(payload, expected: entry.compressedSize)
                ?? Data()  // 解压失败给空
        }

        // WinZip AES 规范：salt 长度与 key 长度是独立数值
        //   strength 1 = AES-128: salt 8B,  key 16B
        //   strength 2 = AES-192: salt 12B, key 24B
        //   strength 3 = AES-256: salt 16B, key 32B（派生 2*32+2 = 66B）
        let keyLength: Int
        let saltLength: Int
        switch entry.aesStrength {
        case 1: keyLength = 16; saltLength = 8
        case 2: keyLength = 24; saltLength = 12
        default: keyLength = 32; saltLength = 16
        }

        // local header 后：extra（同样含 0x9901）→ salt → pwcheck → 密文 → HMAC
        let nameLen = Int(readU16(bytes, base + 26))
        let extraLen = Int(readU16(bytes, base + 28))
        let dataStart = base + 30 + nameLen + extraLen
        guard dataStart + saltLength + 2 + 10 <= bytes.count else { throw IBSError.aesInfoMissing }

        let salt = Data(bytes[dataStart..<(dataStart + saltLength)])
        let pwCheck = Data(bytes[(dataStart + saltLength)..<(dataStart + saltLength + 2)])
        let cipherLength = entry.compressedSize - saltLength - 2 - 10
        guard cipherLength > 0 else { throw IBSError.decryptFailed }
        let cipherEnd = min(dataStart + saltLength + 2 + cipherLength, bytes.count)
        let ciphertext = Data(bytes[(dataStart + saltLength + 2)..<cipherEnd])
        let hmacStored = Data(bytes[cipherEnd..<min(cipherEnd + 10, bytes.count)])

        // PBKDF2-HMAC-SHA1 ×1000 → keyLen + 2B pwcheck + macKeyLen
        let derivedLength = keyLength * 2 + 2
        var derived = Data(count: derivedLength)
        let pwData = password.data(using: .utf8) ?? Data()
        let result = derived.withUnsafeMutableBytes { derivedPtr -> Int32 in
            pwData.withUnsafeBytes { pwPtr -> Int32 in
                salt.withUnsafeBytes { saltPtr -> Int32 in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        pwPtr.bindMemory(to: UInt8.self).baseAddress, pwData.count,
                        saltPtr.bindMemory(to: UInt8.self).baseAddress, salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), 1000,
                        derivedPtr.bindMemory(to: UInt8.self).baseAddress, derivedLength)
                }
            }
        }
        guard result == kCCSuccess else { throw IBSError.decryptFailed }

        // 密码校验：派生末 2 字节
        guard derived.suffix(2) == pwCheck else { throw IBSError.passwordCheckFailed }

        // AES-CTR（WinZip：16 字节 little-endian 计数器，从 1 开始）
        let key = derived.prefix(keyLength)
        let plain = ctrCrypt(key: Data(key), data: ciphertext)

        // HMAC-SHA1-80 校验
        let hmacKey = derived.dropFirst(keyLength).prefix(keyLength)
        let mac = hmacSHA1(key: Data(hmacKey), data: ciphertext)
        if mac.prefix(10) != hmacStored { throw IBSError.hmacFailed }

        // 真实压缩方法
        if entry.realMethod == 0 { return plain }
        if entry.realMethod == 8 {
            return ZipReader.inflate(plain, expected: entry.compressedSize) ?? plain
        }
        return plain
    }

    /// 手写 AES-CTR（little-endian 计数器，初值 1）。
    private static func ctrCrypt(key: Data, data: Data) -> Data {
        guard !data.isEmpty else { return data }
        let dataBytes = [UInt8](data)
        var out = Data(capacity: dataBytes.count)
        var counterLow: UInt64 = 1
        var counterHigh: UInt64 = 0

        var offset = 0
        while offset < dataBytes.count {
            // LE 128-bit counter
            var iv = [UInt8](repeating: 0, count: 16)
            withUnsafeBytes(of: counterLow.littleEndian) { ptr in
                for i in 0..<8 { iv[i] = ptr[i] }
            }
            withUnsafeBytes(of: counterHigh.littleEndian) { ptr in
                for i in 0..<8 { iv[8 + i] = ptr[i] }
            }

            let keystream = aesECBSingleBlock(key: key, block: iv)
            let blockEnd = min(offset + 16, dataBytes.count)
            for i in offset..<blockEnd {
                out.append(dataBytes[i] ^ keystream[i - offset])
            }

            // counter + 1（128 位进位）
            let (l1, carry) = counterLow.addingReportingOverflow(1)
            counterLow = l1
            if carry { counterHigh += 1 }
            offset += 16
        }
        return out
    }

    /// 单块 AES-ECB 加密（16 字节进 16 字节出）。
    private static func aesECBSingleBlock(key: Data, block: [UInt8]) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: 16)
        var moved = 0
        // exclusivity: 长度在闭包外提取，避免写访问闭包内读 out.count
        let outCapacity = out.count
        let keyLength = key.count
        let blockLength = block.count
        let status = key.withUnsafeBytes { keyPtr -> CCCryptorStatus in
            block.withUnsafeBytes { blockPtr -> CCCryptorStatus in
                out.withUnsafeMutableBytes { outPtr -> CCCryptorStatus in
                    CCCrypt(
                        CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES),
                        CCOptions(kCCOptionECBMode),
                        keyPtr.baseAddress, keyLength, nil,
                        blockPtr.baseAddress, blockLength,
                        outPtr.baseAddress, outCapacity, &moved)
                }
            }
        }
        _ = status
        return out
    }

    private static func hmacSHA1(key: Data, data: Data) -> Data {
        var mac = [UInt8](repeating: 0, count: 20)
        key.withUnsafeBytes { keyPtr in
            data.withUnsafeBytes { dataPtr in
                CCHmac(CCHmacAlgorithm(kCCHmacAlgSHA1),
                       keyPtr.baseAddress, key.count,
                       dataPtr.baseAddress, data.count, &mac)
            }
        }
        return Data(mac)
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

    private static func readU16(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
        guard offset + 1 < bytes.count else { return 0 }
        return UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
    }

    private static func readU32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        guard offset + 3 < bytes.count else { return 0 }
        return UInt32(bytes[offset]) | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16) | (UInt32(bytes[offset + 3]) << 24)
    }

    // MARK: - 第二层：AES-128-ECB 双层解密

    /// configs.json → 书源 JSON 明文字符串。
    static func decryptConfigs(_ configsData: Data) throws -> String {
        guard let object = (try? JSONSerialization.jsonObject(with: configsData)) as? [[String: Any]],
              let item = object.first,
              let passwordB64 = item["_passwordConfigs"] as? String,
              let encodeB64 = item["_encodeConfigs"] as? String,
              let passwordBytes = Data(base64Encoded: passwordB64),
              let encodeBytes = Data(base64Encoded: encodeB64) else {
            throw IBSError.missingFields
        }

        // 第一层：全零 key（原 App getCString maxLength=33 溢出 bug 的精确复刻）
        let real = unpad(aesECBDecrypt(passwordBytes, key: Data(repeating: 0, count: 16)))
        guard let realString = String(data: real, encoding: .utf8) else { throw IBSError.decryptFailed }

        // 第二层：key = MD5(realString) 小写 hex 前 16 字符（ASCII）
        let md5hex = md5(realString.data(using: .utf8) ?? real)
        let key2 = String(md5hex.prefix(16)).data(using: .ascii) ?? Data()
        let plain = unpad(aesECBDecrypt(encodeBytes, key: key2))
        guard let json = String(data: plain, encoding: .utf8), json.hasPrefix("{") else {
            throw IBSError.decryptFailed
        }
        return json
    }

    static func aesECBDecrypt(_ data: Data, key: Data) -> Data {
        guard data.count > 0, data.count % 16 == 0 else { return Data() }
        var out = Data(count: data.count)
        var moved = 0
        // exclusivity: 长度在闭包外提取，避免写访问闭包内读 out.count
        let outCapacity = out.count
        let keyLength = key.count
        let dataLength = data.count
        let status = key.withUnsafeBytes { keyPtr -> CCCryptorStatus in
            data.withUnsafeBytes { dataPtr -> CCCryptorStatus in
                out.withUnsafeMutableBytes { outPtr -> CCCryptorStatus in
                    CCCrypt(
                        CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES),
                        CCOptions(kCCOptionECBMode),
                        keyPtr.baseAddress, keyLength, nil,
                        dataPtr.baseAddress, dataLength,
                        outPtr.baseAddress, outCapacity, &moved)
                }
            }
        }
        return status == kCCSuccess ? out : Data()
    }

    static func unpad(_ data: Data) -> Data {
        guard let last = data.last, last >= 1, last <= 16, Int(last) <= data.count else { return data }
        return data.dropLast(Int(last))
    }

    static func md5(_ data: Data) -> String {
        Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
