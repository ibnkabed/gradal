import Foundation

/// Records exactly as in shared/PROTOCOL.md. Decoders are lenient about missing optional keys.
protocol SyncRecord {
    var id: String { get }
    var updatedAt: String { get }
}

struct SchoolClass: Codable, Identifiable, Hashable, SyncRecord {
    var id: String
    var name: String
    var prefix: Int?
    var archived: String?         // label of the year / semester it was closed in
    var updatedAt: String
    var deleted: Bool

    enum CodingKeys: String, CodingKey {
        case id, name, prefix, archived, updatedAt, deleted
    }
}

extension SchoolClass {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        prefix = try c.decodeIfPresent(Int.self, forKey: .prefix)
        archived = try c.decodeIfPresent(String.self, forKey: .archived)
        updatedAt = try c.decodeIfPresent(String.self, forKey: .updatedAt) ?? ""
        deleted = try c.decodeIfPresent(Bool.self, forKey: .deleted) ?? false
    }
}

struct Student: Codable, Identifiable, Hashable, SyncRecord {
    var id: String
    var classIds: [String]
    var name: String
    var gradalId: String
    var externalId: String?
    var order: Int?
    var active: Bool
    var archived: String?
    var archivedActive: Bool?     // whether he was active when archived (stays on the old record sheet)
    var updatedAt: String
    var deleted: Bool

    enum CodingKeys: String, CodingKey {
        case id, classIds, name, gradalId, externalId, order, active, archived, archivedActive, updatedAt, deleted
    }
}

extension Student {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        classIds = try c.decodeIfPresent([String].self, forKey: .classIds) ?? []
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        gradalId = try c.decodeIfPresent(String.self, forKey: .gradalId) ?? ""
        externalId = try c.decodeIfPresent(String.self, forKey: .externalId)
        order = try c.decodeIfPresent(Int.self, forKey: .order)
        active = try c.decodeIfPresent(Bool.self, forKey: .active) ?? true
        archived = try c.decodeIfPresent(String.self, forKey: .archived)
        archivedActive = try c.decodeIfPresent(Bool.self, forKey: .archivedActive)
        updatedAt = try c.decodeIfPresent(String.self, forKey: .updatedAt) ?? ""
        deleted = try c.decodeIfPresent(Bool.self, forKey: .deleted) ?? false
    }
}

struct QuizSection: Codable, Hashable {
    var name: String
    var en: String?          // English title of its box on the sheet (optional)
    var from: Int
    var to: Int
}

/// Where the quiz's questions sit on its answer sheet (layout v3). Computed by the PC
/// (pc/sheet_layout.py) and read-only on the phone.
struct QuizSheet: Codable, Hashable {
    var version: Int
    var pitch: Double?
    var questionBubbles: [[[Double]]]   // [question][choice] -> [x, y] in mm
    var columns: JSONValue?             // passed through untouched

    enum CodingKeys: String, CodingKey {
        case version, pitch, questionBubbles, columns
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 0
        pitch = try c.decodeIfPresent(Double.self, forKey: .pitch)
        questionBubbles = try c.decodeIfPresent([[[Double]]].self, forKey: .questionBubbles) ?? []
        columns = try c.decodeIfPresent(JSONValue.self, forKey: .columns)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version)
        try c.encodeIfPresent(pitch, forKey: .pitch)
        try c.encode(questionBubbles, forKey: .questionBubbles)
        try c.encodeIfPresent(columns, forKey: .columns)
    }
}

/// Any JSON value, kept as is (quiz header lines are edited on the PC only).
indirect enum JSONValue: Codable, Hashable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
        } else if let v = try? c.decode(Bool.self) {
            self = .bool(v)
        } else if let v = try? c.decode(Double.self) {
            self = .number(v)
        } else if let v = try? c.decode(String.self) {
            self = .string(v)
        } else if let v = try? c.decode([JSONValue].self) {
            self = .array(v)
        } else {
            self = .object(try c.decode([String: JSONValue].self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }
}

struct Quiz: Codable, Identifiable, Hashable, SyncRecord {
    var id: String
    var code: Int                 // 1000-9999, printed in the barcode
    var name: String
    var date: String              // yyyy-MM-dd
    var classIds: [String]
    var questionCount: Int
    var pages: [Int]?             // questions on each page of the question paper (optional)
    var sheet: QuizSheet?         // computed by the PC; dropped locally when it goes stale
    var keys: [[String]]          // one key in practice; [version][question] accepted letters, "" = dropped
    var points: [Double]
    var sections: [QuizSection]
    var header: JSONValue?        // PC-only, passed through untouched
    var language: String?         // "ar" or "en" (absent = "en"); only how A–D are shown
    var updatedAt: String
    var deleted: Bool

    enum CodingKeys: String, CodingKey {
        case id, code, name, date, classIds, questionCount, pages, sheet, keys, points, sections, header
        case language, updatedAt, deleted
    }

    /// True when the PC's sheet covers every question, so papers can be read.
    var sheetReady: Bool {
        guard let sheet else { return false }
        return sheet.questionBubbles.count >= questionCount && questionCount > 0
    }

    var isArabic: Bool { language == "ar" }

    func point(_ i: Int) -> Double { i < points.count ? points[i] : 1 }
}

extension Quiz {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        code = try c.decodeIfPresent(Int.self, forKey: .code) ?? 0
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        date = try c.decodeIfPresent(String.self, forKey: .date) ?? ""
        classIds = try c.decodeIfPresent([String].self, forKey: .classIds) ?? []
        keys = try c.decodeIfPresent([[String]].self, forKey: .keys) ?? [[]]
        let count = try c.decodeIfPresent(Int.self, forKey: .questionCount)
        questionCount = count ?? (keys.first?.count ?? 0)
        pages = try c.decodeIfPresent([Int].self, forKey: .pages)
        sheet = try? c.decodeIfPresent(QuizSheet.self, forKey: .sheet)
        points = try c.decodeIfPresent([Double].self, forKey: .points) ?? []
        sections = try c.decodeIfPresent([QuizSection].self, forKey: .sections) ?? []
        header = try c.decodeIfPresent(JSONValue.self, forKey: .header)
        language = try? c.decodeIfPresent(String.self, forKey: .language)
        updatedAt = try c.decodeIfPresent(String.self, forKey: .updatedAt) ?? ""
        deleted = try c.decodeIfPresent(Bool.self, forKey: .deleted) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(code, forKey: .code)
        try c.encode(name, forKey: .name)
        try c.encode(date, forKey: .date)
        try c.encode(classIds, forKey: .classIds)
        try c.encode(questionCount, forKey: .questionCount)
        try c.encodeIfPresent(pages, forKey: .pages)
        try c.encodeIfPresent(sheet, forKey: .sheet)
        try c.encode(keys, forKey: .keys)
        try c.encode(points, forKey: .points)
        try c.encode(sections, forKey: .sections)
        try c.encodeIfPresent(header, forKey: .header)
        try c.encodeIfPresent(language, forKey: .language)
        try c.encode(updatedAt, forKey: .updatedAt)
        try c.encode(deleted, forKey: .deleted)
    }
}

struct Scan: Codable, Identifiable, Hashable, SyncRecord {
    var id: String
    var quizId: String
    var studentId: String?
    var gradalId: String
    var version: Int
    var answers: [String]
    var earned: Double
    var possible: Double
    var scannedAt: String
    var deviceId: String
    var edited: Bool
    var hasImage: Bool
    var updatedAt: String
    var deleted: Bool

    enum CodingKeys: String, CodingKey {
        case id, quizId, studentId, gradalId, version, answers, earned, possible
        case scannedAt, deviceId, edited, hasImage, updatedAt, deleted
    }
}

extension Scan {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        quizId = try c.decodeIfPresent(String.self, forKey: .quizId) ?? ""
        studentId = try c.decodeIfPresent(String.self, forKey: .studentId)
        gradalId = try c.decodeIfPresent(String.self, forKey: .gradalId) ?? ""
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 0
        answers = try c.decodeIfPresent([String].self, forKey: .answers) ?? []
        earned = try c.decodeIfPresent(Double.self, forKey: .earned) ?? 0
        possible = try c.decodeIfPresent(Double.self, forKey: .possible) ?? 0
        scannedAt = try c.decodeIfPresent(String.self, forKey: .scannedAt) ?? ""
        deviceId = try c.decodeIfPresent(String.self, forKey: .deviceId) ?? ""
        edited = try c.decodeIfPresent(Bool.self, forKey: .edited) ?? false
        hasImage = try c.decodeIfPresent(Bool.self, forKey: .hasImage) ?? false
        updatedAt = try c.decodeIfPresent(String.self, forKey: .updatedAt) ?? ""
        deleted = try c.decodeIfPresent(Bool.self, forKey: .deleted) ?? false
    }

    /// studentId is written as null when absent, as PROTOCOL shows.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(quizId, forKey: .quizId)
        try c.encode(studentId, forKey: .studentId)
        try c.encode(gradalId, forKey: .gradalId)
        try c.encode(version, forKey: .version)
        try c.encode(answers, forKey: .answers)
        try c.encode(earned, forKey: .earned)
        try c.encode(possible, forKey: .possible)
        try c.encode(scannedAt, forKey: .scannedAt)
        try c.encode(deviceId, forKey: .deviceId)
        try c.encode(edited, forKey: .edited)
        try c.encode(hasImage, forKey: .hasImage)
        try c.encode(updatedAt, forKey: .updatedAt)
        try c.encode(deleted, forKey: .deleted)
    }
}

/// GET /m/snapshot
struct Snapshot: Decodable {
    var serverTime: String?
    var classes: [SchoolClass]
    var students: [Student]
    var quizzes: [Quiz]

    enum CodingKeys: String, CodingKey {
        case serverTime, classes, students, quizzes
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        serverTime = try c.decodeIfPresent(String.self, forKey: .serverTime)
        classes = try c.decodeIfPresent([SchoolClass].self, forKey: .classes) ?? []
        students = try c.decodeIfPresent([Student].self, forKey: .students) ?? []
        quizzes = try c.decodeIfPresent([Quiz].self, forKey: .quizzes) ?? []
    }
}

/// ISO-8601 UTC timestamps, whole seconds (`2026-10-21T08:30:00Z`).
enum Stamp {
    static func string(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: date)
    }

    static func now() -> String { string(Date()) }

    /// A stamp strictly newer than `previous`, so a quick second edit still wins the merge.
    static func after(_ previous: String) -> String {
        let current = Date()
        if let old = date(previous), old >= current.addingTimeInterval(-0.5) {
            return string(old.addingTimeInterval(1))
        }
        return string(current)
    }

    static func date(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }

    static func isNewer(_ a: String, than b: String) -> Bool {
        if let da = date(a), let db = date(b) { return da > db }
        return a > b
    }
}

enum DayFormat {
    static func formatter() -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.dateFormat = "yyyy-MM-dd"
        return f
    }

    static func string(from date: Date) -> String { formatter().string(from: date) }
    static func date(from string: String) -> Date? { formatter().date(from: string) }
}

/// Bundled shared/sheet-layouts.json.
enum LayoutStore {
    static let shared: SheetLayouts? = {
        guard let url = Bundle.main.url(forResource: "sheet-layouts", withExtension: "json") else { return nil }
        return try? SheetLayouts.load(from: url)
    }()

    static var maxQuestions: Int { shared?.maxQuestions ?? 100 }
}

func fmt(_ v: Double) -> String {
    if v == v.rounded(), abs(v) < 1e9 { return String(Int(v)) }
    return String(format: "%.1f", v)
}

func percentOf(_ earned: Double, _ possible: Double) -> Double {
    possible > 0 ? earned / possible * 100 : 0
}
