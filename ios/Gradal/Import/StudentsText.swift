import Foundation

/// Class lists read from text: a PDF printed by Noor (its text layer), or the JSON an AI provider returns after
/// reading the PDF itself. Foundation only, so OMRCheck tests it.
enum StudentsText {
    /// Words of report headers and labels, never part of a student's name.
    static let notName = ["الفصل", "الصف", "المدرسة", "وزارة", "التعليم", "تقرير", "الطلاب", "الطالب", "اسم", "رقم",
                          "الهوية", "المملكة", "إدارة", "ادارة", "مكتب", "الصفحة", "صفحة", "العام", "الدراسي",
                          "الشعبة", "المقرر", "المادة", "المعلم", "التاريخ", "الجنسية", "المرحلة", "سعودي", "سعودية"]

    /// Class lines in Noor's reports: «الفصل: 1», «الصف: الأول المتوسط - 1», «أول متوسط 1»…
    static func classLine(in line: String) -> String? {
        for label in ["الفصل", "الشعبة", "الصف"] {
            guard let r = line.range(of: label) else { continue }
            var rest = String(line[r.upperBound...])
            rest = rest.trimmingCharacters(in: CharacterSet(charactersIn: " :：-–/\t"))
            rest = StudentsImport.collapse(StudentsImport.asciiDigits(rest))
            if !rest.isEmpty && rest.count <= 40 { return rest }
        }
        return nil
    }

    /// A line that holds one student's name: three to six Arabic words, no Latin letters, no label words.
    static func name(in line: String) -> (name: String, nationalId: String)? {
        let digits = StudentsImport.asciiDigits(line)
        var nid = ""
        for token in digits.split(whereSeparator: { !$0.isNumber }) where token.count == 10 {
            if token.hasPrefix("1") || token.hasPrefix("2") { nid = String(token); break }
        }
        var words: [String] = []
        for w in line.split(whereSeparator: { $0.isWhitespace || "|،,.:-–()".contains($0) }) {
            let word = String(w)
            if word.unicodeScalars.allSatisfy({ ($0.value >= 0x0621 && $0.value <= 0x064A) || $0.value == 0x0640
                || ($0.value >= 0x064B && $0.value <= 0x0652) }) {
                words.append(word)
            } else if word.unicodeScalars.contains(where: { ($0.value >= 65 && $0.value <= 90) || ($0.value >= 97 && $0.value <= 122) }) {
                return nil
            }
        }
        guard (3...6).contains(words.count) else { return nil }
        if words.contains(where: { w in notName.contains { w.contains($0) } }) { return nil }
        return (Roster.cleanName(words.joined(separator: " ")), nid)
    }

    /// The text of a class-list PDF -> classes. Class lines start a new class; without any, everyone goes to
    /// `className`.
    static func fromText(_ text: String, className: String) throws -> [ImportedClass] {
        var order: [String] = []
        var classes: [String: [ImportedStudent]] = [:]
        var current = StudentsImport.collapse(className)
        var seen = Set<String>()
        for raw in text.components(separatedBy: .newlines) {
            let line = StudentsImport.collapse(raw)
            if line.isEmpty { continue }
            if let c = classLine(in: line) {
                current = c
                continue
            }
            guard let person = name(in: line) else { continue }
            if current.isEmpty { throw StudentsImportError(message: "اكتب اسم الفصل، فالملف لا يذكره") }
            let key = current + "|" + Roster.normalise(person.name)
            if !seen.insert(key).inserted { continue }
            if classes[current] == nil {
                order.append(current)
                classes[current] = []
            }
            classes[current]!.append(ImportedStudent(name: person.name, nationalId: person.nationalId))
        }
        if order.isEmpty { throw StudentsImportError(message: "لم أجد أسماء طلاب في الملف") }
        return order.map { ImportedClass(name: $0, students: classes[$0] ?? []) }
    }

    /// The prompt for an AI provider that reads the PDF (or its text).
    static let prompt = """
    This is a list of school students exported from Noor (the Saudi school system), possibly several classes. \
    Return JSON only: {"classes":[{"name":"<class as written, e.g. أول متوسط 1>","students":[{"name":"<full name in Arabic \
    exactly as written>","nationalId":"<10-digit ID if shown, else empty>"}]}]} in the list's order. Do not invent or \
    translate names; skip headers, teachers and totals.
    """

    /// The provider's JSON -> classes; `className` for a class without a name.
    static func fromJSON(_ object: [String: Any], className: String) throws -> [ImportedClass] {
        var out: [ImportedClass] = []
        for entry in object["classes"] as? [[String: Any]] ?? [] {
            var name = StudentsImport.collapse(StudentsImport.asciiDigits(entry["name"] as? String ?? ""))
            if name.isEmpty { name = StudentsImport.collapse(className) }
            if name.isEmpty { throw StudentsImportError(message: "اكتب اسم الفصل، فالملف لا يذكره") }
            var students: [ImportedStudent] = []
            for s in entry["students"] as? [[String: Any]] ?? [] {
                let n = Roster.cleanName(s["name"] as? String ?? "")
                let nid = StudentsImport.asciiDigits(s["nationalId"] as? String ?? "")
                if !n.isEmpty { students.append(ImportedStudent(name: n, nationalId: StudentsImport.isNationalId(nid) ? nid : "")) }
            }
            if !students.isEmpty { out.append(ImportedClass(name: name, students: students)) }
        }
        if out.isEmpty { throw StudentsImportError(message: "لم أجد أسماء طلاب في الملف") }
        return out
    }
}
