import Foundation

/// Reads the first worksheet of an .xlsx as rows of text: shared strings (rich text runs joined), inline
/// strings, numbers (whole numbers without ".0"), booleans. Each cell sits at the column its reference names
/// (`r="C5"`), with empty cells and rows filled in. Element names are matched without their namespace prefix,
/// so files from Excel, Numbers, Noor's export and XLSXWriter all read the same.
enum XLSXReader {
    enum ReadError: LocalizedError {
        case noSheet
        case badXML(String)

        var errorDescription: String? {
            switch self {
            case .noSheet: return "لا توجد ورقة في ملف Excel"
            case .badXML(let part): return "تعذّرت قراءة \(part) في ملف Excel"
            }
        }
    }

    static func rows(_ data: Data) throws -> [[String]] {
        let zip = try ZipReader(data)
        let shared = try sharedStrings(zip)
        let sheetPath = try firstSheetPath(zip)
        let handler = SheetHandler(shared: shared)
        try parse(try zip.data(sheetPath), handler, part: sheetPath)
        return handler.rows
    }

    // MARK: - Parts

    /// The first <sheet> of xl/workbook.xml through xl/_rels/workbook.xml.rels; else xl/worksheets/sheet1.xml,
    /// else the first worksheet part in the archive.
    static func firstSheetPath(_ zip: ZipReader) throws -> String {
        if zip.contains("xl/workbook.xml"), zip.contains("xl/_rels/workbook.xml.rels") {
            let wb = WorkbookHandler()
            let rels = RelsHandler()
            if (try? parse(try zip.data("xl/workbook.xml"), wb, part: "workbook")) != nil,
               (try? parse(try zip.data("xl/_rels/workbook.xml.rels"), rels, part: "rels")) != nil,
               let rid = wb.firstSheetRelId,
               let target = rels.targets[rid] {
                let path = resolve(target, base: "xl")
                if zip.contains(path) { return path }
            }
        }
        if zip.contains("xl/worksheets/sheet1.xml") { return "xl/worksheets/sheet1.xml" }
        if let any = zip.names.first(where: { $0.hasPrefix("xl/worksheets/") && $0.hasSuffix(".xml") }) {
            return any
        }
        throw ReadError.noSheet
    }

    /// A relationship target relative to `base` ("worksheets/sheet1.xml"), or absolute ("/xl/worksheets/sheet1.xml").
    static func resolve(_ target: String, base: String) -> String {
        var parts: [String] = target.hasPrefix("/") ? [] : base.split(separator: "/").map(String.init)
        for piece in target.split(separator: "/") {
            if piece == "." { continue }
            if piece == ".." { if !parts.isEmpty { parts.removeLast() }; continue }
            parts.append(String(piece))
        }
        return parts.joined(separator: "/")
    }

    static func sharedStrings(_ zip: ZipReader) throws -> [String] {
        var path = "xl/sharedStrings.xml"
        if !zip.contains(path), zip.contains("xl/_rels/workbook.xml.rels") {
            let rels = RelsHandler()
            if (try? parse(try zip.data("xl/_rels/workbook.xml.rels"), rels, part: "rels")) != nil,
               let target = rels.sharedStringsTarget {
                path = resolve(target, base: "xl")
            }
        }
        guard zip.contains(path) else { return [] }
        let handler = SharedStringsHandler()
        try parse(try zip.data(path), handler, part: "sharedStrings")
        return handler.strings
    }

    private static func parse(_ data: Data, _ delegate: XMLParserDelegate, part: String) throws {
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = false
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        guard parser.parse() else { throw ReadError.badXML(part) }
    }

    /// "x:sheetData" -> "sheetData".
    static func local(_ name: String) -> String {
        if let i = name.lastIndex(of: ":") { return String(name[name.index(after: i)...]) }
        return name
    }

    /// "C5" -> (column 2, row 5); row is nil when the reference has no digits.
    static func reference(_ ref: String) -> (column: Int, row: Int?)? {
        var column = 0
        var digits = ""
        for scalar in ref.unicodeScalars {
            let v = scalar.value
            if v >= 65 && v <= 90 {
                column = column * 26 + Int(v - 64)
            } else if v >= 97 && v <= 122 {
                column = column * 26 + Int(v - 96)
            } else if v >= 48 && v <= 57 {
                digits.unicodeScalars.append(scalar)
            } else if v == 36 {   // "$"
                continue
            } else {
                return nil
            }
        }
        guard column > 0 else { return nil }
        return (column - 1, Int(digits))
    }

    /// Numbers as Python's openpyxl + str() would show them for whole numbers: "1023456789", not "1.023456789E9".
    static func number(_ raw: String) -> String {
        let t = raw.trimmingCharacters(in: .whitespaces)
        guard let v = Double(t) else { return t }
        if v == v.rounded(), abs(v) < 1e15 { return String(Int64(v)) }
        return t
    }

    // MARK: - XML handlers

    private final class WorkbookHandler: NSObject, XMLParserDelegate {
        var firstSheetRelId: String?

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
            guard firstSheetRelId == nil, XLSXReader.local(elementName) == "sheet" else { return }
            for (key, value) in attributeDict where key == "id" || key.hasSuffix(":id") {
                firstSheetRelId = value
                return
            }
        }
    }

    private final class RelsHandler: NSObject, XMLParserDelegate {
        var targets: [String: String] = [:]
        var sharedStringsTarget: String?

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
            guard XLSXReader.local(elementName) == "Relationship",
                  let id = attributeDict["Id"], let target = attributeDict["Target"] else { return }
            targets[id] = target
            if let type = attributeDict["Type"], type.hasSuffix("/sharedStrings") { sharedStringsTarget = target }
        }
    }

    /// <si><t>…</t></si> or <si><r><t>…</t></r>…</si>; phonetic runs (<rPh>) are left out.
    private final class SharedStringsHandler: NSObject, XMLParserDelegate {
        var strings: [String] = []
        private var current: String?
        private var inText = false
        private var phonetic = 0

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
            switch XLSXReader.local(elementName) {
            case "si": current = ""
            case "rPh": phonetic += 1
            case "t": inText = current != nil && phonetic == 0
            default: break
            }
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?) {
            switch XLSXReader.local(elementName) {
            case "si":
                strings.append(current ?? "")
                current = nil
            case "rPh": phonetic = max(0, phonetic - 1)
            case "t": inText = false
            default: break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if inText { current = (current ?? "") + string }
        }
    }

    private final class SheetHandler: NSObject, XMLParserDelegate {
        let shared: [String]
        var rows: [[String]] = []

        private var rowIndex = -1          // 0-based index of the open <row>
        private var nextColumn = 0
        private var cellColumn = 0
        private var cellType = ""
        private var inCell = false
        private var value = ""
        private var inline = ""
        private var inValue = false
        private var inInlineText = false
        private var phonetic = 0

        init(shared: [String]) { self.shared = shared }

        private func ensureRow(_ index: Int) {
            // Gaps of empty rows are filled, within reason.
            while rows.count <= index && rows.count < 1_048_576 { rows.append([]) }
        }

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
            switch XLSXReader.local(elementName) {
            case "row":
                if let r = attributeDict["r"], let n = Int(r), n >= 1 {
                    rowIndex = max(n - 1, rowIndex + 1)
                } else {
                    rowIndex += 1
                }
                nextColumn = 0
                ensureRow(rowIndex)
            case "c":
                inCell = true
                cellType = attributeDict["t"] ?? ""
                value = ""
                inline = ""
                cellColumn = nextColumn
                if let r = attributeDict["r"], let ref = XLSXReader.reference(r) {
                    cellColumn = ref.column
                    if rowIndex < 0, let row = ref.row, row >= 1 {   // a cell outside any <row>
                        rowIndex = row - 1
                        ensureRow(rowIndex)
                    }
                }
            case "v":
                if inCell { inValue = true }
            case "rPh":
                phonetic += 1
            case "t":
                if inCell && phonetic == 0 { inInlineText = true }
            default:
                break
            }
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?) {
            switch XLSXReader.local(elementName) {
            case "v": inValue = false
            case "t": inInlineText = false
            case "rPh": phonetic = max(0, phonetic - 1)
            case "c":
                inCell = false
                finishCell()
            default: break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if inValue { value += string } else if inInlineText { inline += string }
        }

        private func finishCell() {
            let text: String
            switch cellType {
            case "s":
                if let i = Int(value.trimmingCharacters(in: .whitespaces)), i >= 0, i < shared.count {
                    text = shared[i]
                } else {
                    text = ""
                }
            case "inlineStr":
                text = inline
            case "str", "e":
                text = value
            case "b":
                let b = value.trimmingCharacters(in: .whitespaces)
                text = b.isEmpty ? "" : (b == "1" ? "TRUE" : "FALSE")
            default:
                text = value.isEmpty ? inline : XLSXReader.number(value)
            }
            nextColumn = cellColumn + 1
            guard rowIndex >= 0, !text.isEmpty, cellColumn < 16_384 else { return }
            ensureRow(rowIndex)
            guard rowIndex < rows.count else { return }
            while rows[rowIndex].count <= cellColumn { rows[rowIndex].append("") }
            rows[rowIndex][cellColumn] = text
        }
    }
}
