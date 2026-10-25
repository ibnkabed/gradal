import Compression
import Foundation

/// Minimal ZIP archive reader: STORE and DEFLATE entries, UTF-8 names, no ZIP64, no encryption.
/// Enough for .xlsx files written by Excel, Numbers, Noor and XLSXWriter, and for Gradal's own backups.
struct ZipReader {
    enum ZipError: LocalizedError {
        case notZip
        case missing(String)
        case unsupported(String)
        case corrupt(String)

        var errorDescription: String? {
            switch self {
            case .notZip: return "الملف ليس أرشيف ZIP صالحًا"
            case .missing(let name): return "لا يوجد في الأرشيف: \(name)"
            case .unsupported(let name): return "صيغة غير مدعومة في الأرشيف: \(name)"
            case .corrupt(let name): return "الأرشيف تالف: \(name)"
            }
        }
    }

    private struct Entry {
        let name: String
        let flags: UInt16
        let method: UInt16
        let crc: UInt32
        let compressedSize: Int
        let size: Int
        let localOffset: Int
    }

    private let bytes: Data
    private let entries: [String: Entry]
    /// Entry names in the order of the central directory (directories end with "/").
    let names: [String]

    init(_ data: Data) throws {
        bytes = data
        let count = data.count
        guard count >= 22 else { throw ZipError.notZip }

        // End of central directory: the last 0x06054b50 within the final 64 KiB + 22 bytes.
        var eocd = -1
        var i = count - 22
        let lowest = max(0, count - 22 - 0xFFFF)
        while i >= lowest {
            if Self.u32(data, i) == 0x0605_4B50 { eocd = i; break }
            i -= 1
        }
        guard eocd >= 0 else { throw ZipError.notZip }
        let total = Int(Self.u16(data, eocd + 10))
        let centralSize = Int(Self.u32(data, eocd + 12))
        let centralOffset = Int(Self.u32(data, eocd + 16))
        guard centralOffset + centralSize <= count else { throw ZipError.notZip }

        var map: [String: Entry] = [:]
        var order: [String] = []
        var p = centralOffset
        for _ in 0..<total {
            guard p + 46 <= count, Self.u32(data, p) == 0x0201_4B50 else { throw ZipError.notZip }
            let flags = Self.u16(data, p + 8)
            let method = Self.u16(data, p + 10)
            let crc = Self.u32(data, p + 16)
            let csize = Int(Self.u32(data, p + 20))
            let usize = Int(Self.u32(data, p + 24))
            let nameLen = Int(Self.u16(data, p + 28))
            let extraLen = Int(Self.u16(data, p + 30))
            let commentLen = Int(Self.u16(data, p + 32))
            let offset = Int(Self.u32(data, p + 42))
            guard p + 46 + nameLen <= count else { throw ZipError.notZip }
            let start = data.startIndex + p + 46
            let raw = data.subdata(in: start..<(start + nameLen))
            let name = String(data: raw, encoding: .utf8) ?? String(decoding: raw, as: UTF8.self)
            if map[name] == nil { order.append(name) }
            map[name] = Entry(name: name, flags: flags, method: method, crc: crc,
                              compressedSize: csize, size: usize, localOffset: offset)
            p += 46 + nameLen + extraLen + commentLen
        }
        entries = map
        names = order
    }

    func contains(_ name: String) -> Bool { entries[name] != nil }

    /// The uncompressed content of one entry; the CRC is checked.
    func data(_ name: String) throws -> Data {
        guard let e = entries[name] else { throw ZipError.missing(name) }
        if e.flags & 0x0001 != 0 { throw ZipError.unsupported(name) }   // encrypted
        let h = e.localOffset
        guard h + 30 <= bytes.count, Self.u32(bytes, h) == 0x0403_4B50 else { throw ZipError.corrupt(name) }
        let nameLen = Int(Self.u16(bytes, h + 26))
        let extraLen = Int(Self.u16(bytes, h + 28))
        let begin = h + 30 + nameLen + extraLen
        guard begin + e.compressedSize <= bytes.count else { throw ZipError.corrupt(name) }
        let start = bytes.startIndex + begin
        let packed = bytes.subdata(in: start..<(start + e.compressedSize))

        let out: Data
        switch e.method {
        case 0:
            out = packed
        case 8:
            out = try Self.inflate(packed, expected: e.size, name: name)
        default:
            throw ZipError.unsupported(name)
        }
        guard out.count == e.size, ZipWriter.crc32([UInt8](out)) == e.crc else { throw ZipError.corrupt(name) }
        return out
    }

    /// Raw DEFLATE (RFC 1951) through Compression's COMPRESSION_ZLIB. The buffer starts a little larger than the
    /// size the directory gives, so a full buffer means the size was wrong; then it grows.
    private static func inflate(_ packed: Data, expected: Int, name: String) throws -> Data {
        if expected == 0 && packed.count <= 2 { return Data() }
        guard !packed.isEmpty else { throw ZipError.corrupt(name) }
        var capacity = max(expected, 64) + 64
        for _ in 0..<6 {
            var out = Data(count: capacity)
            let cap = capacity
            let written: Int = out.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) -> Int in
                packed.withUnsafeBytes { (src: UnsafeRawBufferPointer) -> Int in
                    guard let d = dst.bindMemory(to: UInt8.self).baseAddress,
                          let s = src.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                    return compression_decode_buffer(d, cap, s, src.count, nil, COMPRESSION_ZLIB)
                }
            }
            if written < cap {
                if written == 0 && expected > 0 { throw ZipError.corrupt(name) }
                out.count = written
                return out
            }
            capacity *= 4
        }
        throw ZipError.corrupt(name)
    }

    private static func u16(_ d: Data, _ at: Int) -> UInt16 {
        let i = d.startIndex + at
        return UInt16(d[i]) | (UInt16(d[i + 1]) << 8)
    }

    private static func u32(_ d: Data, _ at: Int) -> UInt32 {
        let i = d.startIndex + at
        return UInt32(d[i]) | (UInt32(d[i + 1]) << 8) | (UInt32(d[i + 2]) << 16) | (UInt32(d[i + 3]) << 24)
    }
}
