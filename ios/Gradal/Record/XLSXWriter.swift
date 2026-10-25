import Foundation

/// Minimal .xlsx writer: inline strings, numbers, formulas, bold header row, column widths,
/// right-to-left sheet view. Pure Foundation so the macOS OMRCheck tool can exercise it.
enum XLSXCell {
    case empty
    case number(Double)
    case text(String)
    case formula(String)     // without the leading "="
}

struct XLSXSheet {
    var name: String
    var rightToLeft: Bool
    var columnWidths: [Double]   // index 0 = column A
    var defaultWidth: Double
    var rows: [[XLSXCell]]
    var boldFirstRow: Bool
}

enum XLSXWriter {
    static func columnName(_ index: Int) -> String {
        // 0 -> A, 25 -> Z, 26 -> AA
        var n = index + 1
        var s = ""
        while n > 0 {
            let r = (n - 1) % 26
            s = String(UnicodeScalar(UInt8(65 + r))) + s
            n = (n - 1) / 26
        }
        return s
    }

    static func escape(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for scalar in s.unicodeScalars {
            switch scalar {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            default:
                // Control characters other than tab/newline are not allowed in XML 1.0.
                if scalar.value < 0x20 && scalar != "\t" && scalar != "\n" && scalar != "\r" { continue }
                out.unicodeScalars.append(scalar)
            }
        }
        return out
    }

    static func number(_ v: Double) -> String {
        if v == v.rounded(), abs(v) < 1e15 { return String(Int64(v)) }
        return String(v)
    }

    /// Excel sheet names: at most 31 characters, none of : \ / ? * [ ], unique.
    static func sheetNames(_ wanted: [String]) -> [String] {
        var used = Set<String>()
        var out: [String] = []
        for (i, raw) in wanted.enumerated() {
            var name = String(raw.filter { !":\\/?*[]".contains($0) })
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if name.isEmpty { name = "Sheet\(i + 1)" }
            name = String(name.prefix(31))
            var candidate = name
            var k = 2
            while used.contains(candidate.lowercased()) {
                let suffix = " (\(k))"
                candidate = String(name.prefix(31 - suffix.count)) + suffix
                k += 1
            }
            used.insert(candidate.lowercased())
            out.append(candidate)
        }
        return out
    }

    static func sheetXML(_ sheet: XLSXSheet) -> String {
        var x = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"
        x += "<worksheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\" "
        x += "xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\">"
        x += "<sheetViews><sheetView workbookViewId=\"0\"\(sheet.rightToLeft ? " rightToLeft=\"1\"" : "")/></sheetViews>"
        x += "<sheetFormatPr defaultRowHeight=\"15\" defaultColWidth=\"\(number(sheet.defaultWidth))\"/>"
        let columns = max(sheet.columnWidths.count, sheet.rows.map(\.count).max() ?? 0)
        if columns > 0 {
            x += "<cols>"
            for c in 0..<columns {
                let w = c < sheet.columnWidths.count ? sheet.columnWidths[c] : sheet.defaultWidth
                x += "<col min=\"\(c + 1)\" max=\"\(c + 1)\" width=\"\(number(w))\" customWidth=\"1\"/>"
            }
            x += "</cols>"
        }
        x += "<sheetData>"
        for (r, row) in sheet.rows.enumerated() {
            let rowNumber = r + 1
            x += "<row r=\"\(rowNumber)\">"
            let style = (sheet.boldFirstRow && r == 0) ? " s=\"1\"" : ""
            for (c, cell) in row.enumerated() {
                let ref = columnName(c) + String(rowNumber)
                switch cell {
                case .empty:
                    continue
                case .number(let v):
                    x += "<c r=\"\(ref)\"\(style)><v>\(number(v))</v></c>"
                case .text(let s):
                    x += "<c r=\"\(ref)\"\(style) t=\"inlineStr\"><is><t xml:space=\"preserve\">\(escape(s))</t></is></c>"
                case .formula(let f):
                    x += "<c r=\"\(ref)\"\(style)><f>\(escape(f))</f></c>"
                }
            }
            x += "</row>"
        }
        x += "</sheetData></worksheet>"
        return x
    }

    static func workbook(_ input: [XLSXSheet]) -> Data {
        let names = sheetNames(input.map(\.name))
        let sheets = zip(input, names).map { pair -> XLSXSheet in
            var s = pair.0
            s.name = pair.1
            return s
        }
        let head = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"
        var archive = ZipWriter()

        var types = head + "<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\">"
        types += "<Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/>"
        types += "<Default Extension=\"xml\" ContentType=\"application/xml\"/>"
        types += "<Override PartName=\"/xl/workbook.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml\"/>"
        types += "<Override PartName=\"/xl/styles.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml\"/>"
        for i in sheets.indices {
            types += "<Override PartName=\"/xl/worksheets/sheet\(i + 1).xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml\"/>"
        }
        types += "</Types>"
        archive.add("[Content_Types].xml", text: types)

        var rels = head + "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">"
        rels += "<Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument\" Target=\"xl/workbook.xml\"/>"
        rels += "</Relationships>"
        archive.add("_rels/.rels", text: rels)

        var wb = head + "<workbook xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\" "
        wb += "xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\">"
        wb += "<bookViews><workbookView/></bookViews><sheets>"
        for (i, s) in sheets.enumerated() {
            wb += "<sheet name=\"\(escape(s.name))\" sheetId=\"\(i + 1)\" r:id=\"rId\(i + 1)\"/>"
        }
        wb += "</sheets><calcPr calcId=\"191029\" fullCalcOnLoad=\"1\"/></workbook>"
        archive.add("xl/workbook.xml", text: wb)

        var wbRels = head + "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">"
        for i in sheets.indices {
            wbRels += "<Relationship Id=\"rId\(i + 1)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet\" Target=\"worksheets/sheet\(i + 1).xml\"/>"
        }
        wbRels += "<Relationship Id=\"rId\(sheets.count + 1)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles\" Target=\"styles.xml\"/>"
        wbRels += "</Relationships>"
        archive.add("xl/_rels/workbook.xml.rels", text: wbRels)

        var styles = head + "<styleSheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\">"
        styles += "<fonts count=\"2\"><font><sz val=\"11\"/><name val=\"Calibri\"/><family val=\"2\"/></font>"
        styles += "<font><b/><sz val=\"11\"/><name val=\"Calibri\"/><family val=\"2\"/></font></fonts>"
        styles += "<fills count=\"2\"><fill><patternFill patternType=\"none\"/></fill><fill><patternFill patternType=\"gray125\"/></fill></fills>"
        styles += "<borders count=\"1\"><border><left/><right/><top/><bottom/><diagonal/></border></borders>"
        styles += "<cellStyleXfs count=\"1\"><xf numFmtId=\"0\" fontId=\"0\" fillId=\"0\" borderId=\"0\"/></cellStyleXfs>"
        styles += "<cellXfs count=\"2\"><xf numFmtId=\"0\" fontId=\"0\" fillId=\"0\" borderId=\"0\" xfId=\"0\"/>"
        styles += "<xf numFmtId=\"0\" fontId=\"1\" fillId=\"0\" borderId=\"0\" xfId=\"0\" applyFont=\"1\"/></cellXfs>"
        styles += "<cellStyles count=\"1\"><cellStyle name=\"Normal\" xfId=\"0\" builtinId=\"0\"/></cellStyles>"
        styles += "</styleSheet>"
        archive.add("xl/styles.xml", text: styles)

        for (i, s) in sheets.enumerated() {
            archive.add("xl/worksheets/sheet\(i + 1).xml", text: sheetXML(s))
        }
        return archive.finish()
    }
}
