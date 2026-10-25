import Foundation

/// What one class list import did to one class.
struct RosterSummary: Hashable {
    var name: String
    var prefix: Int
    var count: Int
    var added: Int
    var inactive: Int
}

struct RosterError: LocalizedError, Equatable {
    let message: String
    var errorDescription: String? { message }
}

/// Class lists merged into the classes and students, on plain arrays (the caller saves). Port of reference/roster.py.
///
/// - classes match by name among the current ones; a new class gets the lowest free prefix 1-9 (prefixes of archived
///   classes are free again: a new year archives them, archiveAll / archiveClass);
/// - students match by national ID when given, else by normalised name within the class; a new student gets prefix +
///   the next free 2-digit serial in that class: the 3-digit gradalId is fixed for good;
/// - every student's `order` is refreshed from the list; students no longer listed become inactive.
enum Roster {
    /// Without harakat, dagger alef, tatweel and spaces; أ إ آ ٱ -> ا, ة -> ه, ى -> ي.
    static func normalise(_ name: String) -> String {
        var out = ""
        for scalar in name.unicodeScalars {
            let v = scalar.value
            if (v >= 0x064B && v <= 0x0652) || v == 0x0670 || v == 0x0640 { continue }
            if scalar.properties.isWhitespace { continue }
            switch v {
            case 0x0623, 0x0625, 0x0622, 0x0671: out.unicodeScalars.append("\u{0627}")
            case 0x0629: out.unicodeScalars.append("\u{0647}")
            case 0x0649: out.unicodeScalars.append("\u{064A}")
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out
    }

    /// Without tatweel, single spaces, trimmed.
    static func cleanName(_ name: String) -> String {
        name.replacingOccurrences(of: "\u{0640}", with: "")
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    private static func isCurrent(_ c: SchoolClass) -> Bool { !c.deleted && c.archived == nil }
    private static func isCurrent(_ s: Student) -> Bool { !s.deleted && s.archived == nil }

    /// Applies one class list import. Returns a summary per class.
    static func merge(_ imported: [ImportedClass], classes: inout [SchoolClass], students: inout [Student]) throws -> [RosterSummary] {
        var summary: [RosterSummary] = []
        for entry in imported {
            let cname = cleanName(entry.name)
            var people: [(name: String, nid: String)] = []
            for item in entry.students {
                let name = cleanName(item.name)
                let nid = item.nationalId.trimmingCharacters(in: .whitespacesAndNewlines)
                if !name.isEmpty { people.append((name, nid)) }
            }
            if cname.isEmpty { continue }

            let key = normalise(cname)
            let classIndex: Int
            if let found = classes.firstIndex(where: { isCurrent($0) && normalise($0.name) == key }) {
                classIndex = found
            } else {
                let used = Set(classes.filter { $0.archived == nil }.map(\.prefix))
                guard let prefix = (1...9).first(where: { !used.contains($0) }) else {
                    throw RosterError(message: "لا رقم متاح لفصل جديد: الفصول تسعة على الأكثر")
                }
                classes.append(SchoolClass(name: cname, prefix: prefix))
                classIndex = classes.count - 1
            }
            let cls = classes[classIndex]
            let prefix = cls.prefix
            let prefixDigit = String(prefix)

            var serials = Set<Int>()
            for s in students where s.archived == nil {
                let g = s.gradalId
                guard g.count == 3, g.unicodeScalars.allSatisfy({ $0.value >= 48 && $0.value <= 57 }),
                      g.hasPrefix(prefixDigit), let n = Int(g.dropFirst()) else { continue }
                serials.insert(n)
            }

            var unmatched = students.indices.filter { isCurrent(students[$0]) && students[$0].classIds.contains(cls.id) }
            var added = 0
            for (offset, person) in people.enumerated() {
                let order = offset + 1
                let nameKey = normalise(person.name)
                var hit: Int?
                if !person.nid.isEmpty {
                    hit = unmatched.firstIndex { students[$0].nationalId == person.nid }
                }
                if hit == nil {
                    hit = unmatched.firstIndex { normalise(students[$0].name) == nameKey }
                }
                if let h = hit {
                    let i = unmatched.remove(at: h)
                    students[i].order = order
                    students[i].active = true
                    if !person.nid.isEmpty { students[i].nationalId = person.nid }
                    students[i].name = person.name   // the list's spelling wins
                } else {
                    guard let serial = (1...99).first(where: { !serials.contains($0) }) else {
                        throw RosterError(message: "الفصل \(cname) تجاوز 99 طالبًا")
                    }
                    serials.insert(serial)
                    let gradalId = prefixDigit + (serial < 10 ? "0" : "") + String(serial)
                    students.append(Student(classId: cls.id, name: person.name, gradalId: gradalId,
                                            nationalId: person.nid.isEmpty ? nil : person.nid, order: order))
                    added += 1
                }
            }
            var gone = 0
            for i in unmatched where students[i].active {
                students[i].active = false
                gone += 1
            }
            summary.append(RosterSummary(name: cname, prefix: prefix, count: people.count, added: added, inactive: gone))
        }
        return summary
    }

    /// One student added by hand to a class (created when new), at the end of its list; nobody else changes.
    @discardableResult
    static func addStudent(name rawName: String, className rawClass: String, classes: inout [SchoolClass],
                           students: inout [Student]) throws -> Student {
        let name = cleanName(rawName)
        let cname = cleanName(rawClass)
        if name.isEmpty { throw RosterError(message: "اكتب اسم الطالب") }
        if cname.isEmpty { throw RosterError(message: "اختر الفصل أو اكتب اسمه") }
        let key = normalise(cname)
        if classes.firstIndex(where: { isCurrent($0) && normalise($0.name) == key }) == nil {
            _ = try merge([ImportedClass(name: cname, students: [])], classes: &classes, students: &students)
        }
        guard let cls = classes.first(where: { isCurrent($0) && normalise($0.name) == key }) else {
            throw RosterError(message: "الفصل غير موجود")
        }
        let mine = students.filter { isCurrent($0) && $0.classIds.contains(cls.id) }
        if let same = mine.first(where: { normalise($0.name) == normalise(name) }) {
            throw RosterError(message: "\(same.name) موجود في الفصل برقم \(same.gradalId)")
        }
        let digit = String(cls.prefix)
        let used = Set(students.filter { $0.archived == nil && $0.gradalId.count == 3 && $0.gradalId.hasPrefix(digit) }
            .compactMap { Int($0.gradalId.dropFirst()) })
        guard let serial = (1...99).first(where: { !used.contains($0) }) else {
            throw RosterError(message: "الفصل \(cls.name) تجاوز 99 طالبًا")
        }
        let student = Student(classId: cls.id, name: name, gradalId: digit + (serial < 10 ? "0" : "") + String(serial),
                              nationalId: nil, order: (mine.map(\.order).max() ?? 0) + 1)
        students.append(student)
        return student
    }

    /// «2025-2026 — 2026-09-15»: the school year being closed and the day. Up to September (a new year starting)
    /// that is the year just ended; from October (a new semester) the running one. Gregorian, ASCII digits.
    static func yearLabel(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone.current
        let parts = calendar.dateComponents([.year, .month], from: date)
        let year = parts.year ?? 2000
        let start = (parts.month ?? 1) <= 9 ? year - 1 : year
        return "\(start)-\(start + 1) — \(DayFormat.string(from: date))"
    }

    private static func label(_ raw: String) -> String {
        let t = String(raw.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60))
        return t.isEmpty ? yearLabel(Date()) : t
    }

    /// Archives the given classes and every current student whose classes are all archived now.
    private static func archive(_ indices: [Int], label: String, classes: inout [SchoolClass], students: inout [Student]) {
        var ids = Set<String>()
        for i in indices {
            classes[i].archived = label
            ids.insert(classes[i].id)
        }
        for c in classes where !c.deleted && c.archived != nil { ids.insert(c.id) }
        for i in students.indices where isCurrent(students[i]) {
            let mine = Set(students[i].classIds)
            if !mine.isEmpty && mine.isSubset(of: ids) {
                students[i].archivedActive = students[i].active
                students[i].archived = label
                students[i].active = false
            }
        }
    }

    /// A new school year or semester: every current class and its students leave the current lists (never
    /// deleted: old quizzes, scans and record sheets keep their names). Prefixes and serials are free again.
    static func archiveAll(label: String, classes: inout [SchoolClass], students: inout [Student]) {
        let indices = classes.indices.filter { isCurrent(classes[$0]) }
        archive(indices, label: Self.label(label), classes: &classes, students: &students)
    }

    /// One class no longer taught («احذف الفصل»): archived like a year, its students with it.
    static func archiveClass(_ id: String, label: String, classes: inout [SchoolClass], students: inout [Student]) throws {
        guard let i = classes.firstIndex(where: { isCurrent($0) && $0.id == id }) else {
            throw RosterError(message: "الفصل غير موجود")
        }
        archive([i], label: Self.label(label), classes: &classes, students: &students)
    }
}
