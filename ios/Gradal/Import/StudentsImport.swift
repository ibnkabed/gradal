import Foundation

/// Class lists from a file the teacher already has: Noor's Excel export of a class (xlsx, or the HTML table
/// Noor sometimes saves as .xls), a CSV, or names pasted one per line. Port of reference/students_import.py;
/// the result goes to Roster.merge.
///
/// The header row is found by its words, wherever it is: the name column («اسم الطالب», «الاسم», «Name»),
/// optionally the class («الفصل», «الشعبة») and the national ID («رقم الهوية», «السجل المدني»). Without a class
/// column every row goes to the class the teacher typed. Rows keep the file's order.

struct ImportedStudent: Hashable {
    var name: String
    var nationalId: String        // "" when the file has none
}

struct ImportedClass: Hashable {
    var name: String
    var students: [ImportedStudent]
}

/// A message for the teacher, in Arabic.
struct StudentsImportError: LocalizedError, Equatable {
    let message: String
    var errorDescription: String? { message }
}

enum StudentsImport {
    static let nameWords = ["اسم الطالب", "اسم الطالبة", "الاسم", "اسم", "name", "student"]
    static let classWords = ["الفصل", "الشعبة", "الصف", "class", "section"]
    static let idWords = ["رقم الهوية", "الهوية", "السجل المدني", "رقم الطالب", "national", "id"]

    static let legacyXLS = "هذا ملف Excel قديم (xls). افتحه في Excel أو Numbers واحفظه بصيغة xlsx ثم أعد المحاولة."
    static let unreadable = "تعذّرت قراءة الملف. احفظه من Excel بصيغة xlsx ثم أعد المحاولة."

    // MARK: - Entry points

    static func read(_ data: Data, filename: String, className: String) throws -> [ImportedClass] {
        let rows: [[String]]
        do {
            rows = try fileRows(data, filename: filename)
        } catch let e as StudentsImportError {
            throw e
        } catch {
            throw StudentsImportError(message: unreadable)
        }
        return try fromRows(rows, className: className)
    }

    static func pasted(_ text: String, className: String) throws -> [ImportedClass] {
        let strip = Set(" \t-•.0123456789٠١٢٣٤٥٦٧٨٩".unicodeScalars)
        let names = lines(text).map { line -> String in
            var scalars = Array(collapse(line).unicodeScalars)
            while let f = scalars.first, strip.contains(f) { scalars.removeFirst() }
            while let l = scalars.last, strip.contains(l) { scalars.removeLast() }
            var s = ""
            s.unicodeScalars.append(contentsOf: scalars)
            return s
        }.filter { !$0.isEmpty }
        if names.isEmpty { throw StudentsImportError(message: "الصق الأسماء، اسمًا في كل سطر") }
        let cname = className.trimmingCharacters(in: .whitespacesAndNewlines)
        if cname.isEmpty { throw StudentsImportError(message: "اكتب اسم الفصل") }
        return [ImportedClass(name: cname, students: names.map { ImportedStudent(name: $0, nationalId: "") })]
    }

    // MARK: - Rows from the file

    static func fileRows(_ data: Data, filename: String) throws -> [[String]] {
        let bytes = [UInt8](data.prefix(512))
        if bytes.count >= 2 && bytes[0] == 0x50 && bytes[1] == 0x4B {   // "PK": xlsx
            return try XLSXReader.rows(data).map { $0.map(cell) }
        }
        if bytes.count >= 8 && bytes[0..<8].elementsEqual([0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]) {
            throw StudentsImportError(message: legacyXLS)
        }
        guard let text = decode(data) else { throw StudentsImportError(message: "تعذّرت قراءة الملف") }

        var head = bytes[...]
        while let b = head.first, b == 0x20 || b == 0x09 || b == 0x0A || b == 0x0D || b == 0x0B || b == 0x0C {
            head = head.dropFirst()
        }
        let startsWithTag = head.first == 0x3C || head.starts(with: [0xEF, 0xBB, 0xBF, 0x3C])
        if startsWithTag || String(text.prefix(5000)).lowercased().contains("<table") {
            return htmlRows(text).map { $0.map(cell) }
        }
        let name = filename.lowercased()
        let delimiter = sniff(String(text.prefix(4000)))
        if let delimiter {
            return csvRows(text, delimiter: delimiter).map { $0.map(cell) }
        }
        if name.hasSuffix(".csv") {
            return csvRows(text, delimiter: ",").map { $0.map(cell) }
        }
        return lines(text).map { [cell($0)] }
    }

    /// UTF-8 (with or without a BOM), UTF-16 with a BOM, else Windows Arabic (cp1256).
    static func decode(_ data: Data) -> String? {
        let bytes = [UInt8](data.prefix(3))
        if bytes.count >= 2 && ((bytes[0] == 0xFF && bytes[1] == 0xFE) || (bytes[0] == 0xFE && bytes[1] == 0xFF)) {
            if let s = String(data: data, encoding: .utf16) { return s }
        }
        if var s = String(data: data, encoding: .utf8) {
            if s.hasPrefix("\u{FEFF}") { s.removeFirst() }
            return s
        }
        let cp1256 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.windowsArabic.rawValue)))
        if let s = String(data: data, encoding: cp1256) { return s }
        return String(data: data, encoding: .utf16)
    }

    /// Lines as Python's str.splitlines() gives them ("\r\n" counts once).
    static func lines(_ text: String) -> [String] {
        var out: [String] = []
        var current = ""
        for ch in text {
            if ch.isNewline {
                out.append(current)
                current = ""
            } else {
                current.append(ch)
            }
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    /// Runs of white space become one space; the ends are trimmed.
    static func collapse(_ s: String) -> String {
        s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    static func cell(_ s: String) -> String { collapse(s) }

    /// ٠١٢٣٤٥٦٧٨٩ (and the Persian ۰-۹) -> 0-9.
    static func asciiDigits(_ s: String) -> String {
        var out = ""
        for scalar in s.unicodeScalars {
            let v = scalar.value
            if v >= 0x0660 && v <= 0x0669, let a = Unicode.Scalar(v - 0x0660 + 48) {
                out.unicodeScalars.append(a)
            } else if v >= 0x06F0 && v <= 0x06F9, let a = Unicode.Scalar(v - 0x06F0 + 48) {
                out.unicodeScalars.append(a)
            } else {
                out.unicodeScalars.append(scalar)
            }
        }
        return out
    }

    // MARK: HTML tables

    /// <tr> rows of <td>/<th> cells, with entities decoded; like Python's HTMLParser in reference/students_import.py
    /// (a new <tr> or cell drops one left open; text outside cells is ignored).
    static func htmlRows(_ html: String) -> [[String]] {
        let s = Array(html.unicodeScalars)
        var rows: [[String]] = []
        var row: [String]?
        var cell: String?
        var i = 0
        var text = ""

        func flushText() {
            if cell != nil, !text.isEmpty { cell! += decodeEntities(text) }
            text = ""
        }

        while i < s.count {
            if s[i] != "<" {
                text.unicodeScalars.append(s[i])
                i += 1
                continue
            }
            // A comment, or a declaration such as <!DOCTYPE …>.
            if i + 3 < s.count, s[i + 1] == "!", s[i + 2] == "-", s[i + 3] == "-" {
                flushText()
                var j = i + 4
                while j + 2 < s.count && !(s[j] == "-" && s[j + 1] == "-" && s[j + 2] == ">") { j += 1 }
                i = min(j + 3, s.count)
                continue
            }
            if i + 1 < s.count, s[i + 1] == "!" || s[i + 1] == "?" {   // <!DOCTYPE …>, <?xml …?>
                flushText()
                var j = i + 2
                while j < s.count && s[j] != ">" { j += 1 }
                i = j + 1
                continue
            }
            var j = i + 1
            var quote: Unicode.Scalar?
            while j < s.count {
                let c = s[j]
                if let q = quote {
                    if c == q { quote = nil }
                } else if c == "\"" || c == "'" {
                    quote = c
                } else if c == ">" {
                    break
                }
                j += 1
            }
            guard j < s.count else {   // "<" without ">": plain text
                text.unicodeScalars.append(contentsOf: s[i...])
                break
            }
            var tag = ""
            var k = i + 1
            let closing = k < j && s[k] == "/"
            if closing { k += 1 }
            while k < j, s[k].properties.isAlphabetic || (s[k].value >= 48 && s[k].value <= 57) {
                tag.unicodeScalars.append(s[k])
                k += 1
            }
            if tag.isEmpty {   // "< b" or "<>": text, as in HTML
                text.unicodeScalars.append(s[i])
                i += 1
                continue
            }
            flushText()
            tag = tag.lowercased()
            if !closing {
                if tag == "tr" {
                    row = []
                } else if (tag == "td" || tag == "th") && row != nil {
                    cell = ""
                } else if tag == "script" || tag == "style" {
                    // Their content is not text: skip to the closing tag.
                    let end = "</\(tag)"
                    let length = end.unicodeScalars.count
                    var m = j + 1
                    while m < s.count {
                        if m + length <= s.count {
                            var piece = ""
                            piece.unicodeScalars.append(contentsOf: s[m..<(m + length)])
                            if piece.lowercased() == end { break }
                        }
                        m += 1
                    }
                    j = m
                    while j < s.count && s[j] != ">" { j += 1 }
                }
            } else {
                if (tag == "td" || tag == "th"), let c = cell, row != nil {
                    row!.append(c)
                    cell = nil
                } else if tag == "tr", let r = row {
                    rows.append(r)
                    row = nil
                }
            }
            i = j + 1
        }
        flushText()
        return rows
    }

    /// &amp; &lt; &gt; &quot; &apos; &nbsp; &#NNN; &#xHH;. Unknown entities stay as written.
    static func decodeEntities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        let named: [String: String] = ["amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{00A0}"]
        let chars = Array(s.unicodeScalars)
        var out = ""
        var i = 0
        while i < chars.count {
            guard chars[i] == "&" else {
                out.unicodeScalars.append(chars[i])
                i += 1
                continue
            }
            var j = i + 1
            var body = ""
            while j < chars.count, j - i <= 12, chars[j] != ";", chars[j] != "&", !chars[j].properties.isWhitespace {
                body.unicodeScalars.append(chars[j])
                j += 1
            }
            var replacement: String?
            if body.hasPrefix("#") {
                let digits = body.dropFirst()
                var code: UInt32?
                if digits.hasPrefix("x") || digits.hasPrefix("X") {
                    code = UInt32(digits.dropFirst(), radix: 16)
                } else {
                    code = UInt32(digits)
                }
                if let code, let scalar = Unicode.Scalar(code) {
                    var r = ""
                    r.unicodeScalars.append(scalar)
                    replacement = r
                }
            } else {
                replacement = named[body.lowercased()]
            }
            if let replacement {
                out += replacement
                i = (j < chars.count && chars[j] == ";") ? j + 1 : j
            } else {
                out.unicodeScalars.append(chars[i])
                i += 1
            }
        }
        return out
    }

    // MARK: CSV

    /// The delimiter (tab, semicolon or comma) found on the most lines, outside quotes; nil when none is.
    static func sniff(_ sample: String) -> Character? {
        let sampleLines = lines(sample).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.prefix(30)
        var best: Character?
        var bestScore = (0, 0)
        for d: Character in [",", ";", "\t"] {
            var linesWith = 0
            var total = 0
            for line in sampleLines {
                var inQuotes = false
                var n = 0
                for ch in line {
                    if ch == "\"" { inQuotes.toggle() } else if ch == d && !inQuotes { n += 1 }
                }
                if n > 0 { linesWith += 1 }
                total += n
            }
            if linesWith > bestScore.0 || (linesWith == bestScore.0 && total > bestScore.1) {
                if linesWith > 0 {
                    best = d
                    bestScore = (linesWith, total)
                }
            }
        }
        return best
    }

    /// RFC 4180: quoted fields may hold the delimiter, newlines and doubled quotes.
    static func csvRows(_ text: String, delimiter: Character) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var afterQuote = false
        var any = false
        for ch in text {
            if inQuotes {
                if ch == "\"" {
                    inQuotes = false
                    afterQuote = true
                } else {
                    field.append(ch)
                }
                continue
            }
            if ch == "\"" {
                if afterQuote { field.append("\"") }   // "" inside a quoted field
                inQuotes = true
                afterQuote = false
                any = true
                continue
            }
            afterQuote = false
            if ch == delimiter {
                row.append(field)
                field = ""
                any = true
            } else if ch.isNewline {
                row.append(field)
                rows.append(row)
                row = []
                field = ""
                any = false
            } else {
                field.append(ch)
                any = true
            }
        }
        if any || !field.isEmpty || !row.isEmpty {
            row.append(field)
            rows.append(row)
        }
        return rows
    }

    // MARK: - Header and classes

    static func isNameHeader(_ cell: String) -> Bool {
        let t = collapse(cell.lowercased())
        if nameWords.contains(t) { return true }
        for p in ["اسم ال", "الاسم ", "student name", "name "] where t.hasPrefix(p) { return true }
        return t == "student name" || t == "full name"
    }

    static func find(_ header: [String], _ words: [String]) -> Int? {
        let low = header.map { $0.lowercased() }
        for w in words {
            for (i, h) in low.enumerated() where h == w || (w.unicodeScalars.count > 3 && h.contains(w)) {
                return i
            }
        }
        return nil
    }

    /// Letters (Latin or Arabic), two words or more, and no run of three digits.
    static func looksLikeName(_ s: String) -> Bool {
        var letter = false
        var run = 0
        var longRun = false
        for scalar in s.unicodeScalars {
            let v = scalar.value
            if (v >= 65 && v <= 90) || (v >= 97 && v <= 122) || (v >= 0x0600 && v <= 0x06FF) { letter = true }
            if scalar.properties.numericType == .decimal {
                run += 1
                if run >= 3 { longRun = true }
            } else {
                run = 0
            }
        }
        let words = s.split(whereSeparator: { $0.isWhitespace }).count
        return letter && words >= 2 && !longRun
    }

    static func isNationalId(_ s: String) -> Bool {
        let n = s.unicodeScalars.count
        return n >= 6 && n <= 12 && s.unicodeScalars.allSatisfy { $0.value >= 48 && $0.value <= 57 }
    }

    static func fromRows(_ input: [[String]], className: String) throws -> [ImportedClass] {
        let rows = input.filter { $0.contains { !$0.isEmpty } }
        var headerAt: Int?
        var nameCol = 0
        var classCol: Int?
        var idCol: Int?
        for (i, r) in rows.prefix(30).enumerated() {
            if let c = r.firstIndex(where: isNameHeader) {
                headerAt = i
                nameCol = c
                classCol = find(r, classWords)
                idCol = find(r, idWords)
                if idCol == nameCol { idCol = nil }
                break
            }
        }
        if headerAt == nil {
            // No header: the column that holds the most names.
            let width = rows.map(\.count).max() ?? 0
            let scores = (0..<width).map { c in rows.filter { c < $0.count && looksLikeName($0[c]) }.count }
            guard let top = scores.max(), top > 0, let col = scores.firstIndex(of: top) else {
                throw StudentsImportError(message: "لم أجد أسماء طلاب في الملف")
            }
            nameCol = col
            headerAt = -1
        }

        var order: [String] = []
        var classes: [String: [ImportedStudent]] = [:]
        for r in rows.dropFirst((headerAt ?? -1) + 1) {
            let name = nameCol < r.count ? r[nameCol] : ""
            if !looksLikeName(name) { continue }
            var cname = ""
            if let cc = classCol, cc < r.count { cname = r[cc] }
            if cname.isEmpty { cname = className }
            cname = collapse(asciiDigits(cname))
            if cname.isEmpty { throw StudentsImportError(message: "اكتب اسم الفصل، فالملف لا يذكره") }
            var nid = ""
            if let ic = idCol, ic < r.count { nid = asciiDigits(r[ic]) }
            if classes[cname] == nil {
                order.append(cname)
                classes[cname] = []
            }
            classes[cname]!.append(ImportedStudent(name: name, nationalId: isNationalId(nid) ? nid : ""))
        }
        if order.isEmpty { throw StudentsImportError(message: "لم أجد أسماء طلاب في الملف") }
        return order.map { ImportedClass(name: $0, students: classes[$0] ?? []) }
    }
}
