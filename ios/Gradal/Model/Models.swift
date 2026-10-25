import Foundation

/// Gradal's records (docs/DATA.md). Everything lives on the phone; decoders are lenient about missing keys so
/// older saved data and backups still load.

struct SchoolClass: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var prefix: Int               // 1-9, the first digit of its students' IDs (unique among non-archived classes)
    var archived: String?         // label of the school year it was closed in
    var deleted: Bool = false

    enum CodingKeys: String, CodingKey { case id, name, prefix, archived, deleted }

    init(id: String = UUID().uuidString.lowercased(), name: String, prefix: Int) {
        self.id = id
        self.name = name
        self.prefix = prefix
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        prefix = try c.decodeIfPresent(Int.self, forKey: .prefix) ?? 0
        archived = try c.decodeIfPresent(String.self, forKey: .archived)
        deleted = try c.decodeIfPresent(Bool.self, forKey: .deleted) ?? false
    }
}

struct Student: Codable, Identifiable, Hashable {
    var id: String
    var classIds: [String]
    var name: String
    var gradalId: String          // exactly 3 digits: class prefix + 2-digit serial, fixed for good
    var nationalId: String?       // from Noor's export; matches re-imports, never printed
    var order: Int                // position in the imported class list
    var active: Bool
    var archived: String?
    var archivedActive: Bool?     // whether he was active when archived (stays on the old record sheet)
    var deleted: Bool = false

    enum CodingKeys: String, CodingKey {
        case id, classIds, name, gradalId, nationalId, order, active, archived, archivedActive, deleted
    }

    init(id: String = UUID().uuidString.lowercased(), classId: String, name: String, gradalId: String,
         nationalId: String?, order: Int) {
        self.id = id
        self.classIds = [classId]
        self.name = name
        self.gradalId = gradalId
        self.nationalId = nationalId
        self.order = order
        self.active = true
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        classIds = try c.decodeIfPresent([String].self, forKey: .classIds) ?? []
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        gradalId = try c.decodeIfPresent(String.self, forKey: .gradalId) ?? ""
        nationalId = try c.decodeIfPresent(String.self, forKey: .nationalId)
        order = try c.decodeIfPresent(Int.self, forKey: .order) ?? 9999
        active = try c.decodeIfPresent(Bool.self, forKey: .active) ?? true
        archived = try c.decodeIfPresent(String.self, forKey: .archived)
        archivedActive = try c.decodeIfPresent(Bool.self, forKey: .archivedActive)
        deleted = try c.decodeIfPresent(Bool.self, forKey: .deleted) ?? false
    }
}

struct QuizSection: Codable, Hashable {
    var name: String
    var from: Int                 // 1-based, inclusive
    var to: Int
}

/// The quiz's own header lines (the school's lines are in Settings).
struct QuizHeader: Codable, Hashable {
    var subject: String = ""
    var title: String = ""
    var grade: String = ""
    var extra: String = ""

    var lines: [String] { [subject, title, grade, extra].map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
}

/// One framed box of questions on the answer sheet (Sheet/SheetGeometry.swift computes it).
struct SheetBox: Codable, Hashable {
    var title: String
    var from: Int
    var to: Int
    var x0: Double
    var y0: Double
    var x1: Double
    var y1: Double
    var titleY1: Double
    var numberX: Double
    var numberAnchorStart: Bool   // true: the number's left edge is at numberX (Arabic); false: its right edge
}

struct SheetColumn: Codable, Hashable {
    var x0: Double
    var x1: Double
    var boxes: [SheetBox]
}

/// Where a quiz's questions sit on its answer sheet, in millimetres on A4. The scanner reads
/// questionBubbles[question][choice]; choice 0 is A (أ), whatever its place on the paper.
struct QuizSheet: Codable, Hashable {
    var version: Int
    var pitch: Double
    var rtl: Bool
    var questionBubbles: [[[Double]]]
    var columns: [SheetColumn]
}

struct Quiz: Codable, Identifiable, Hashable {
    var id: String
    var code: Int                 // 1000-9999, printed in the barcode
    var name: String
    var date: String              // yyyy-MM-dd
    var classIds: [String]
    var language: String          // "ar" or "en"
    var questionCount: Int
    var sheet: QuizSheet?         // computed whenever the quiz is saved
    var key: [String]             // accepted letters per question ("B", "AC"); "" = not counted
    var points: [Double]
    var sections: [QuizSection]
    var header: QuizHeader
    var paperId: String?          // the questions written in Gradal, if any
    var deleted: Bool = false

    enum CodingKeys: String, CodingKey {
        case id, code, name, date, classIds, language, questionCount, sheet, key, points, sections, header, paperId, deleted
    }

    init(id: String = UUID().uuidString.lowercased(), code: Int, name: String, date: String, classIds: [String],
         language: String, key: [String], sections: [QuizSection], header: QuizHeader, paperId: String? = nil) {
        self.id = id
        self.code = code
        self.name = name
        self.date = date
        self.classIds = classIds
        self.language = language
        self.questionCount = key.count
        self.key = key
        self.points = Array(repeating: 1, count: key.count)
        self.sections = sections
        self.header = header
        self.paperId = paperId
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        code = try c.decodeIfPresent(Int.self, forKey: .code) ?? 0
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        date = try c.decodeIfPresent(String.self, forKey: .date) ?? ""
        classIds = try c.decodeIfPresent([String].self, forKey: .classIds) ?? []
        language = try c.decodeIfPresent(String.self, forKey: .language) ?? "ar"
        key = try c.decodeIfPresent([String].self, forKey: .key) ?? []
        questionCount = try c.decodeIfPresent(Int.self, forKey: .questionCount) ?? key.count
        sheet = try? c.decodeIfPresent(QuizSheet.self, forKey: .sheet)
        points = try c.decodeIfPresent([Double].self, forKey: .points) ?? []
        sections = try c.decodeIfPresent([QuizSection].self, forKey: .sections) ?? []
        header = try c.decodeIfPresent(QuizHeader.self, forKey: .header) ?? QuizHeader()
        paperId = try c.decodeIfPresent(String.self, forKey: .paperId)
        deleted = try c.decodeIfPresent(Bool.self, forKey: .deleted) ?? false
    }

    var isArabic: Bool { language == "ar" }

    /// True when the sheet covers every question, so papers can be printed and read.
    var sheetReady: Bool {
        guard let sheet else { return false }
        return sheet.questionBubbles.count >= questionCount && questionCount > 0
    }

    func point(_ i: Int) -> Double { i < points.count ? points[i] : 1 }
}

struct Scan: Codable, Identifiable, Hashable {
    var id: String
    var quizId: String
    var studentId: String?
    var gradalId: String
    var answers: [String]         // "" blank, "BD" more than one (never earns)
    var earned: Double
    var possible: Double
    var scannedAt: String
    var edited: Bool
    var hasImage: Bool
    var deleted: Bool = false

    enum CodingKeys: String, CodingKey {
        case id, quizId, studentId, gradalId, answers, earned, possible, scannedAt, edited, hasImage, deleted
    }

    init(id: String = UUID().uuidString.lowercased(), quizId: String, studentId: String?, gradalId: String,
         answers: [String], earned: Double, possible: Double, scannedAt: String, hasImage: Bool) {
        self.id = id
        self.quizId = quizId
        self.studentId = studentId
        self.gradalId = gradalId
        self.answers = answers
        self.earned = earned
        self.possible = possible
        self.scannedAt = scannedAt
        self.edited = false
        self.hasImage = hasImage
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        quizId = try c.decodeIfPresent(String.self, forKey: .quizId) ?? ""
        studentId = try c.decodeIfPresent(String.self, forKey: .studentId)
        gradalId = try c.decodeIfPresent(String.self, forKey: .gradalId) ?? ""
        answers = try c.decodeIfPresent([String].self, forKey: .answers) ?? []
        earned = try c.decodeIfPresent(Double.self, forKey: .earned) ?? 0
        possible = try c.decodeIfPresent(Double.self, forKey: .possible) ?? 0
        scannedAt = try c.decodeIfPresent(String.self, forKey: .scannedAt) ?? ""
        edited = try c.decodeIfPresent(Bool.self, forKey: .edited) ?? false
        hasImage = try c.decodeIfPresent(Bool.self, forKey: .hasImage) ?? false
        deleted = try c.decodeIfPresent(Bool.self, forKey: .deleted) ?? false
    }
}

/// A question written by the AI or by the teacher. answer: the right option's index (0-3); for true/false
/// 0 = true (صح, A) and 1 = false (خطأ, B).
struct Question: Codable, Hashable, Identifiable {
    enum Kind: String, Codable { case mcq, tf }
    var id: String = UUID().uuidString.lowercased()
    var kind: Kind
    var text: String
    var options: [String]         // four for mcq, empty for tf
    var answer: Int
    var section: Int?             // index in the request's sections (nil in drafts made before sections)

    enum CodingKeys: String, CodingKey { case id, kind, text, options, answer, section }

    init(kind: Kind, text: String, options: [String], answer: Int, section: Int? = nil) {
        self.kind = kind
        self.text = text
        self.options = options
        self.answer = answer
        self.section = section
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString.lowercased()
        kind = try c.decodeIfPresent(Kind.self, forKey: .kind) ?? .mcq
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        options = try c.decodeIfPresent([String].self, forKey: .options) ?? []
        answer = try c.decodeIfPresent(Int.self, forKey: .answer) ?? 0
        section = try c.decodeIfPresent(Int.self, forKey: .section)
    }

    /// The letter on the answer sheet.
    var letter: String { Grading.letters[min(max(answer, 0), 3)] }
}

/// One part of the paper as the teacher names it («السؤال الأول: اختر الإجابة الصحيحة»), its kind and how many.
struct PaperSection: Codable, Hashable, Identifiable {
    var id: String = UUID().uuidString.lowercased()
    var name: String
    var kind: Question.Kind
    var count: Int

    /// The two usual parts, in the paper's language.
    static func defaults(_ language: String) -> [PaperSection] {
        language == "ar"
            ? [PaperSection(name: "السؤال الأول: اختر الإجابة الصحيحة", kind: .mcq, count: 15),
               PaperSection(name: "السؤال الثاني: ضع علامة صح أو خطأ", kind: .tf, count: 5)]
            : [PaperSection(name: "Multiple Choice", kind: .mcq, count: 15),
               PaperSection(name: "True or False", kind: .tf, count: 5)]
    }
}

/// What the teacher asked the question writer for.
struct PaperRequest: Codable, Hashable {
    var name: String
    var subject: String
    var grade: String
    var language: String          // "ar" | "en"
    var classIds: [String]
    var bookId: String
    var pageFrom: Int
    var pageTo: Int
    var mcq: Int
    var tf: Int
    var notes: String
    var sections: [PaperSection]? = nil   // the paper's parts in order; nil = MCQ then true/false

    /// The parts in order (the two usual ones for requests made before sections).
    var parts: [PaperSection] {
        if let sections, !sections.isEmpty { return sections }
        let names = PaperSection.defaults(language)
        return [PaperSection(name: names[0].name, kind: .mcq, count: mcq),
                PaperSection(name: names[1].name, kind: .tf, count: tf)].filter { $0.count > 0 }
    }
}

/// The questions of a test written in Gradal: a draft until the teacher approves it, then the quiz's paper.
struct Paper: Codable, Identifiable, Hashable {
    var id: String = UUID().uuidString.lowercased()
    var createdAt: String
    var request: PaperRequest
    var questions: [Question]     // multiple choice first, then true/false
    var providers: [String]       // which AI providers wrote / reviewed it
    var quizId: String?           // set on approval
}

/// A textbook PDF the teacher added (Application Support/Gradal/books/<id>.pdf).
struct Book: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var pages: Int
    var size: Int
    var addedAt: String
}

struct Settings: Codable, Hashable {
    var schoolLines: [String] = ["المملكة العربية السعودية", "وزارة التعليم", "", ""]
    var schoolName: String = ""
    var teacher: String = ""
    var logoPNG: Data?
    var ministryLogo: Bool = true    // the Ministry of Education logo when no logo of the school's own is chosen

    enum CodingKeys: String, CodingKey { case schoolLines, schoolName, teacher, logoPNG, ministryLogo }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schoolLines = try c.decodeIfPresent([String].self, forKey: .schoolLines) ?? Settings().schoolLines
        schoolName = try c.decodeIfPresent(String.self, forKey: .schoolName) ?? ""
        teacher = try c.decodeIfPresent(String.self, forKey: .teacher) ?? ""
        logoPNG = try c.decodeIfPresent(Data.self, forKey: .logoPNG)
        ministryLogo = try c.decodeIfPresent(Bool.self, forKey: .ministryLogo) ?? true
    }

    /// The logo printed in the header: the school's own, else the ministry's (bundled), else none.
    var headerLogo: Data? {
        if let logoPNG, !logoPNG.isEmpty { return logoPNG }
        guard ministryLogo, let url = Bundle.main.url(forResource: "moe-logo", withExtension: "png") else { return nil }
        return try? Data(contentsOf: url)
    }

    var lines: [String] { schoolLines.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
}

/// ISO-8601 UTC timestamps, whole seconds (`2026-10-21T08:30:00Z`).
enum Stamp {
    static func string(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: date)
    }

    static func now() -> String { string(Date()) }

    static func date(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
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
    static func today() -> String { string(from: Date()) }
}

/// Bundled shared/sheet-layouts.json.
enum LayoutStore {
    static let shared: SheetLayouts? = {
        guard let url = Bundle.main.url(forResource: "sheet-layouts", withExtension: "json") else { return nil }
        return try? SheetLayouts.load(from: url)
    }()
}

func fmt(_ v: Double) -> String {
    if v == v.rounded(), abs(v) < 1e9 { return String(Int(v)) }
    return String(format: "%.1f", v)
}

func percentOf(_ earned: Double, _ possible: Double) -> Double {
    possible > 0 ? earned / possible * 100 : 0
}
