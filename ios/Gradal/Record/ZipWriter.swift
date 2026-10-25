import Foundation

/// Minimal ZIP archive writer: STORE only (no compression), enough for an .xlsx.
struct ZipWriter {
    private struct Entry {
        let name: [UInt8]
        let crc: UInt32
        let size: UInt32
        let offset: UInt32
    }

    private var data = Data()
    private var entries: [Entry] = []

    private static let crcTable: [UInt32] = (0..<256).map { n -> UInt32 in
        var c = UInt32(n)
        for _ in 0..<8 {
            c = (c & 1) != 0 ? (0xEDB8_8320 ^ (c >> 1)) : (c >> 1)
        }
        return c
    }

    static func crc32(_ bytes: [UInt8]) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for b in bytes {
            c = crcTable[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8)
        }
        return c ^ 0xFFFF_FFFF
    }

    private static func le16(_ v: UInt16) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8)] }

    private static func le32(_ v: UInt32) -> [UInt8] {
        [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8(v >> 24)]
    }

    // 2026-01-01 00:00 in DOS format; the date does not matter to Excel.
    private static let dosTime: UInt16 = 0
    private static let dosDate: UInt16 = UInt16(((2026 - 1980) << 9) | (1 << 5) | 1)

    mutating func add(_ path: String, _ content: Data) {
        let name = Array(path.utf8)
        let bytes = [UInt8](content)
        let crc = Self.crc32(bytes)
        let offset = UInt32(data.count)
        var header: [UInt8] = []
        header += Self.le32(0x0403_4B50)
        header += Self.le16(20)            // version needed
        header += Self.le16(0x0800)        // UTF-8 names
        header += Self.le16(0)             // STORE
        header += Self.le16(Self.dosTime)
        header += Self.le16(Self.dosDate)
        header += Self.le32(crc)
        header += Self.le32(UInt32(bytes.count))
        header += Self.le32(UInt32(bytes.count))
        header += Self.le16(UInt16(name.count))
        header += Self.le16(0)             // extra
        data.append(contentsOf: header)
        data.append(contentsOf: name)
        data.append(contentsOf: bytes)
        entries.append(Entry(name: name, crc: crc, size: UInt32(bytes.count), offset: offset))
    }

    mutating func add(_ path: String, text: String) {
        add(path, Data(text.utf8))
    }

    func finish() -> Data {
        var out = data
        let centralStart = UInt32(out.count)
        for e in entries {
            var c: [UInt8] = []
            c += Self.le32(0x0201_4B50)
            c += Self.le16(20)             // version made by
            c += Self.le16(20)             // version needed
            c += Self.le16(0x0800)
            c += Self.le16(0)
            c += Self.le16(Self.dosTime)
            c += Self.le16(Self.dosDate)
            c += Self.le32(e.crc)
            c += Self.le32(e.size)
            c += Self.le32(e.size)
            c += Self.le16(UInt16(e.name.count))
            c += Self.le16(0)              // extra
            c += Self.le16(0)              // comment
            c += Self.le16(0)              // disk
            c += Self.le16(0)              // internal attrs
            c += Self.le32(0)              // external attrs
            c += Self.le32(e.offset)
            out.append(contentsOf: c)
            out.append(contentsOf: e.name)
        }
        let centralSize = UInt32(out.count) - centralStart
        var end: [UInt8] = []
        end += Self.le32(0x0605_4B50)
        end += Self.le16(0)
        end += Self.le16(0)
        end += Self.le16(UInt16(entries.count))
        end += Self.le16(UInt16(entries.count))
        end += Self.le32(centralSize)
        end += Self.le32(centralStart)
        end += Self.le16(0)
        out.append(contentsOf: end)
        return out
    }
}
