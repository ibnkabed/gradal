import CryptoKit
import Foundation
import SwiftUI

/// What the scanner needs to read a quiz's answers.
struct ScanGrid {
    let questionCount: Int
    let bubbles: [[[Double]]]?
}

/// Everything Gradal keeps, in one JSON file (docs/DATA.md).
struct StoreFile: Codable {
    var classes: [SchoolClass] = []
    var students: [Student] = []
    var quizzes: [Quiz] = []
    var scans: [Scan] = []
    var papers: [Paper] = []
    var books: [Book] = []
    var settings = Settings()

    enum CodingKeys: String, CodingKey { case classes, students, quizzes, scans, papers, books, settings }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        classes = (try? c.decodeIfPresent([SchoolClass].self, forKey: .classes)) ?? []
        students = (try? c.decodeIfPresent([Student].self, forKey: .students)) ?? []
        quizzes = (try? c.decodeIfPresent([Quiz].self, forKey: .quizzes)) ?? []
        scans = (try? c.decodeIfPresent([Scan].self, forKey: .scans)) ?? []
        papers = (try? c.decodeIfPresent([Paper].self, forKey: .papers)) ?? []
        books = (try? c.decodeIfPresent([Book].self, forKey: .books)) ?? []
        settings = (try? c.decodeIfPresent(Settings.self, forKey: .settings)) ?? Settings()
    }
}

/// What the scanner shows after a paper is accepted.
struct ResultCard: Equatable {
    let quizName: String
    let name: String
    let known: Bool
    let score: String
    let percent: Int?        // nil when the quiz is unknown
}

/// One printable paper of a quiz.
struct PrintItem: Identifiable, Hashable {
    enum Kind: Hashable { case paper, model, key, students(String), blank }
    let kind: Kind
    let title: String
    var id: String {
        switch kind {
        case .paper: return "paper"
        case .model: return "model"
        case .key: return "key"
        case .students(let c): return "class-" + c
        case .blank: return "blank"
        }
    }
}

struct StoreError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Local store: Application Support/Gradal/ store.json, books/<id>.pdf, scans/<id>.jpg, prints/<quizId>/ (cache).
@MainActor
final class Store: ObservableObject {
    @Published private(set) var db: StoreFile

    let folder: URL
    private var imagesFolder: URL { folder.appendingPathComponent("scans", isDirectory: true) }
    private var booksFolder: URL { folder.appendingPathComponent("books", isDirectory: true) }
    private var printsFolder: URL { folder.appendingPathComponent("prints", isDirectory: true) }

    static var dataFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Gradal", isDirectory: true)
    }

    init() {
        folder = Self.dataFolder
        db = StoreFile()
        load()
    }

    private func load() {
        for dir in [folder, imagesFolder, booksFolder, printsFolder] {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        if let data = try? Data(contentsOf: folder.appendingPathComponent("store.json")),
           let file = try? JSONDecoder().decode(StoreFile.self, from: data) {
            db = file
        } else {
            db = StoreFile()
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(db) else { return }
        try? data.write(to: folder.appendingPathComponent("store.json"), options: .atomic)
    }

    func imageURL(_ scanId: String) -> URL {
        imagesFolder.appendingPathComponent("\(scanId).jpg")
    }

    func bookURL(_ id: String) -> URL {
        booksFolder.appendingPathComponent("\(id).pdf")
    }

    // MARK: - Reading

    var activeQuizzes: [Quiz] {
        db.quizzes.filter { !$0.deleted }.sorted { a, b in
            a.date != b.date ? a.date > b.date : a.name < b.name
        }
    }

    var drafts: [Paper] {
        db.papers.filter { $0.quizId == nil }.sorted { $0.createdAt > $1.createdAt }
    }

    func paper(_ id: String?) -> Paper? {
        guard let id else { return nil }
        return db.papers.first { $0.id == id }
    }

    /// Current classes (not archived) by prefix, then name.
    var activeClasses: [SchoolClass] {
        db.classes.filter { !$0.deleted && $0.archived == nil }
            .sorted { $0.prefix != $1.prefix ? $0.prefix < $1.prefix : $0.name < $1.name }
    }

    var activeStudents: [Student] {
        db.students.filter { !$0.deleted && $0.archived == nil }
    }

    private static func listOrder(_ a: Student, _ b: Student) -> Bool {
        a.order != b.order ? a.order < b.order : a.name < b.name
    }

    /// Active students of a class in list order. An archived class keeps those who were active when archived.
    func students(inClass classId: String) -> [Student] {
        let archived = db.classes.first { $0.id == classId }?.archived != nil
        return db.students
            .filter { s in
                guard !s.deleted, s.classIds.contains(classId) else { return false }
                return archived ? (s.archivedActive ?? false) : (s.archived == nil && s.active)
            }
            .sorted(by: Self.listOrder)
    }

    func className(_ id: String) -> String {
        db.classes.first { $0.id == id }?.name ?? ""
    }

    /// The quiz's classes first, then everyone else (active students only).
    func studentsFor(_ quiz: Quiz) -> [Student] {
        let all = activeStudents.filter(\.active).sorted { $0.name < $1.name }
        let inQuiz = all.filter { !Set($0.classIds).isDisjoint(with: quiz.classIds) }
        let others = all.filter { Set($0.classIds).isDisjoint(with: quiz.classIds) }
        return inQuiz + others
    }

    func quiz(_ id: String) -> Quiz? {
        db.quizzes.first { $0.id == id && !$0.deleted }
    }

    func quiz(code: Int) -> Quiz? {
        db.quizzes.first { $0.code == code && !$0.deleted }
    }

    func scan(_ id: String) -> Scan? {
        db.scans.first { $0.id == id && !$0.deleted }
    }

    func student(_ id: String?) -> Student? {
        guard let id else { return nil }
        return db.students.first { $0.id == id && !$0.deleted }
    }

    /// First among the students of the quiz's classes (archived or not), then among current students,
    /// so a new year's «101» never hits last year's «101».
    func studentFor(gradalId: String, preferring classIds: [String]) -> Student? {
        guard !gradalId.isEmpty, !gradalId.contains("?") else { return nil }
        let inQuiz = db.students.filter {
            !$0.deleted && $0.gradalId == gradalId && !Set($0.classIds).isDisjoint(with: classIds)
        }
        if let s = inQuiz.first(where: { $0.archived == nil && $0.active })
            ?? inQuiz.first(where: { $0.archived == nil })
            ?? inQuiz.first(where: { $0.archivedActive ?? $0.active })
            ?? inQuiz.first {
            return s
        }
        let current = activeStudents.filter { $0.gradalId == gradalId }
        return current.first { $0.active } ?? current.first
    }

    func resolvedStudent(_ scan: Scan, quiz: Quiz) -> Student? {
        student(scan.studentId) ?? studentFor(gradalId: scan.gradalId, preferring: quiz.classIds)
    }

    func displayName(_ scan: Scan, quiz: Quiz) -> String {
        if let s = resolvedStudent(scan, quiz: quiz) { return s.name }
        let digits = scan.gradalId.replacingOccurrences(of: "?", with: "")
        return digits.isEmpty ? "بلا رقم" : "رقم غير معروف \(scan.gradalId)"
    }

    func scans(for quizId: String) -> [Scan] {
        db.scans.filter { $0.quizId == quizId && !$0.deleted }.sorted { $0.scannedAt > $1.scannedAt }
    }

    /// The newest scan per student counts; unknown IDs count per read ID.
    func countedScans(_ quiz: Quiz) -> [Scan] {
        var seen = Set<String>()
        var out: [Scan] = []
        for scan in scans(for: quiz.id) {
            let key: String
            if let s = resolvedStudent(scan, quiz: quiz) {
                key = "s:" + s.id
            } else if !scan.gradalId.isEmpty && !scan.gradalId.contains("?") {
                key = "g:" + scan.gradalId
            } else {
                key = "x:" + scan.id
            }
            if seen.insert(key).inserted { out.append(scan) }
        }
        return out
    }

    func grade(_ scan: Scan, quiz: Quiz) -> (earned: Double, possible: Double) {
        Grading.grade(quiz, answers: scan.answers)
    }

    func card(for scan: Scan, quiz: Quiz) -> ResultCard {
        let g = grade(scan, quiz: quiz)
        return ResultCard(quizName: quiz.name, name: displayName(scan, quiz: quiz),
                          known: resolvedStudent(scan, quiz: quiz) != nil,
                          score: "\(fmt(g.earned)) من \(fmt(g.possible))",
                          percent: Int(percentOf(g.earned, g.possible).rounded()))
    }

    var scanGrids: [Int: ScanGrid] {
        var out: [Int: ScanGrid] = [:]
        for q in db.quizzes where !q.deleted {
            out[q.code] = ScanGrid(questionCount: q.questionCount, bubbles: q.sheetReady ? q.sheet?.questionBubbles : nil)
        }
        return out
    }

    // MARK: - Quizzes

    private func freeCode() -> Int {
        let used = Set(db.quizzes.map(\.code))
        let free = (1000...9999).filter { !used.contains($0) }
        return free.randomElement() ?? 1000
    }

    /// Inserts or replaces a quiz: code, sheet geometry, re-grading of its scans, fresh printouts.
    @discardableResult
    func saveQuiz(_ input: Quiz) throws -> Quiz {
        guard let layout = LayoutStore.shared else { throw StoreError(message: "ملف شكل الورقة مفقود من التطبيق") }
        var quiz = input
        quiz.name = quiz.name.trimmingCharacters(in: .whitespaces)
        if quiz.name.isEmpty { throw StoreError(message: "اكتب اسم الاختبار") }
        quiz.questionCount = quiz.key.count
        while quiz.points.count < quiz.questionCount { quiz.points.append(1) }
        quiz.points = Array(quiz.points.prefix(quiz.questionCount))
        if quiz.code == 0 { quiz.code = freeCode() }
        quiz.sheet = try SheetGeometry.compute(questionCount: quiz.questionCount, sections: quiz.sections,
                                               rtl: quiz.isArabic, layout: layout)
        if let i = db.quizzes.firstIndex(where: { $0.id == quiz.id }) {
            db.quizzes[i] = quiz
        } else {
            db.quizzes.append(quiz)
        }
        for i in db.scans.indices where db.scans[i].quizId == quiz.id {
            let g = Grading.grade(quiz, answers: db.scans[i].answers)
            db.scans[i].earned = g.earned
            db.scans[i].possible = g.possible
        }
        clearPrints(quiz.id)
        save()
        return quiz
    }

    /// A quiz with a key the teacher typed (a test prepared elsewhere).
    @discardableResult
    func saveManualQuiz(id: String?, name: String, subject: String, language: String, classIds: [String],
                        key: [String]) throws -> Quiz {
        var quiz = id.flatMap { self.quiz($0) }
            ?? Quiz(code: 0, name: name, date: DayFormat.today(), classIds: classIds, language: language,
                    key: key, sections: [], header: QuizHeader())
        quiz.name = name
        quiz.language = language
        quiz.classIds = classIds
        quiz.key = key
        quiz.header.subject = subject
        quiz.header.title = name
        quiz.header.extra = teacherLine(language)
        return try saveQuiz(quiz)
    }

    func deleteQuiz(_ id: String) {
        guard let i = db.quizzes.firstIndex(where: { $0.id == id }) else { return }
        db.quizzes[i].deleted = true
        db.papers.removeAll { $0.quizId == id }
        clearPrints(id)
        save()
    }

    private func teacherLine(_ language: String) -> String {
        let t = db.settings.teacher.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return "" }
        return (language == "ar" ? "المعلم: " : "Teacher: ") + t
    }

    // MARK: - Papers (questions written in Gradal)

    func saveDraft(_ paper: Paper) {
        if let i = db.papers.firstIndex(where: { $0.id == paper.id }) {
            db.papers[i] = paper
        } else {
            db.papers.append(paper)
        }
        save()
    }

    func deleteDraft(_ id: String) {
        db.papers.removeAll { $0.id == id && $0.quizId == nil }
        save()
    }

    /// The paper becomes (or updates) its quiz: MCQ first, then true/false, a section for each kind.
    @discardableResult
    func approve(_ input: Paper) throws -> Quiz {
        var paper = input
        for (n, q) in paper.questions.enumerated() {
            let blank = q.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let badOptions = q.kind == .mcq && (q.options.count != 4
                || q.options.contains { $0.trimmingCharacters(in: .whitespaces).isEmpty })
            if blank || badOptions {
                throw StoreError(message: "السؤال \(n + 1) ناقص: نص السؤال وأربعة بدائل")
            }
        }
        paper.questions = paper.questions.filter { $0.kind == .mcq } + paper.questions.filter { $0.kind == .tf }
        let count = paper.questions.count
        guard count >= SheetGeometry.minQuestions, count <= SheetGeometry.maxQuestions else {
            throw StoreError(message: "عدد الأسئلة من \(SheetGeometry.minQuestions) إلى \(SheetGeometry.maxQuestions)")
        }
        let req = paper.request
        let names = ExamMaker.sectionNames[req.language] ?? [:]
        var sections: [QuizSection] = []
        var start = 1
        for kind in [Question.Kind.mcq, .tf] {
            let n = paper.questions.filter { $0.kind == kind }.count
            if n > 0 {
                sections.append(QuizSection(name: names[kind] ?? "", from: start, to: start + n - 1))
                start += n
            }
        }
        let key = paper.questions.map(\.letter)
        let header = QuizHeader(subject: req.subject, title: req.name, grade: req.grade, extra: teacherLine(req.language))
        var quiz = self.quiz(paper.quizId ?? "")
            ?? Quiz(code: 0, name: req.name, date: DayFormat.today(), classIds: req.classIds, language: req.language,
                    key: key, sections: sections, header: header, paperId: paper.id)
        quiz.name = req.name
        quiz.classIds = req.classIds
        quiz.language = req.language
        quiz.key = key
        quiz.points = Array(repeating: 1, count: key.count)
        quiz.sections = sections
        quiz.header = header
        quiz.paperId = paper.id
        let saved = try saveQuiz(quiz)
        paper.quizId = saved.id
        saveDraft(paper)
        return saved
    }

    // MARK: - Books

    /// Copies a PDF the teacher picked into the app (the same file twice is kept once).
    func addBook(from url: URL) throws -> Book {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: url)
        guard data.starts(with: Array("%PDF-".utf8)) else { throw StoreError(message: "الملف ليس PDF") }
        let id = SHA256.hash(data: data).prefix(8).map { String(format: "%02x", $0) }.joined()
        if let existing = db.books.first(where: { $0.id == id }) { return existing }
        try data.write(to: bookURL(id), options: .atomic)
        let pages = BookText.pageCount(bookURL(id))
        guard pages > 0 else {
            try? FileManager.default.removeItem(at: bookURL(id))
            throw StoreError(message: "تعذّر فتح ملف PDF")
        }
        let name = url.deletingPathExtension().lastPathComponent
        let book = Book(id: id, name: name, pages: pages, size: data.count, addedAt: Stamp.now())
        db.books.append(book)
        save()
        return book
    }

    func deleteBook(_ id: String) {
        db.books.removeAll { $0.id == id }
        try? FileManager.default.removeItem(at: bookURL(id))
        save()
    }

    // MARK: - Students

    func importStudents(_ data: Data, filename: String, className: String) throws -> [RosterSummary] {
        try applyRoster(StudentsImport.read(data, filename: filename, className: className))
    }

    func pasteStudents(_ text: String, className: String) throws -> [RosterSummary] {
        try applyRoster(StudentsImport.pasted(text, className: className))
    }

    private func applyRoster(_ imported: [ImportedClass]) throws -> [RosterSummary] {
        var classes = db.classes, students = db.students
        let summary = try Roster.merge(imported, classes: &classes, students: &students)
        db.classes = classes
        db.students = students
        relinkUnknown()
        clearAllPrints()
        save()
        return summary
    }

    func archiveClass(_ id: String) throws {
        var classes = db.classes, students = db.students
        try Roster.archiveClass(id, label: Roster.yearLabel(Date()), classes: &classes, students: &students)
        db.classes = classes
        db.students = students
        save()
    }

    func startNewYear() {
        var classes = db.classes, students = db.students
        Roster.archiveAll(label: Roster.yearLabel(Date()), classes: &classes, students: &students)
        db.classes = classes
        db.students = students
        save()
    }

    /// Scans of unknown IDs get their student once the class list has them.
    private func relinkUnknown() {
        for i in db.scans.indices where db.scans[i].studentId == nil {
            guard let quiz = quiz(db.scans[i].quizId) else { continue }
            db.scans[i].studentId = studentFor(gradalId: db.scans[i].gradalId, preferring: quiz.classIds)?.id
        }
    }

    // MARK: - Settings

    func updateSettings(_ settings: Settings) {
        db.settings = settings
        clearAllPrints()
        save()
    }

    // MARK: - Scans

    /// Saves an accepted paper; nil (nothing saved) when its quiz is not on this phone.
    func addScan(read: SheetRead, jpeg: Data?) -> ResultCard? {
        guard let quiz = quiz(code: read.quizCode) else { return nil }
        let id = UUID().uuidString.lowercased()
        var hasImage = false
        if let jpeg {
            hasImage = (try? jpeg.write(to: imageURL(id), options: .atomic)) != nil
        }
        var answers = Array(read.answers.prefix(quiz.questionCount))
        while answers.count < quiz.questionCount { answers.append("") }
        let g = Grading.grade(quiz, answers: answers)
        let scan = Scan(id: id, quizId: quiz.id,
                        studentId: studentFor(gradalId: read.studentId, preferring: quiz.classIds)?.id,
                        gradalId: read.studentId, answers: answers, earned: g.earned, possible: g.possible,
                        scannedAt: Stamp.now(), hasImage: hasImage)
        db.scans.append(scan)
        save()
        return card(for: scan, quiz: quiz)
    }

    /// Teacher edits (answers, student). Re-grades.
    func updateScan(_ scan: Scan) {
        guard let i = db.scans.firstIndex(where: { $0.id == scan.id }) else { return }
        var s = scan
        if let quiz = quiz(s.quizId) {
            let g = Grading.grade(quiz, answers: s.answers)
            s.earned = g.earned
            s.possible = g.possible
        }
        s.edited = true
        db.scans[i] = s
        save()
    }

    func deleteScan(_ id: String) {
        guard let i = db.scans.firstIndex(where: { $0.id == id }) else { return }
        db.scans[i].deleted = true
        try? FileManager.default.removeItem(at: imageURL(id))
        save()
    }

    // MARK: - Printing

    /// The papers of a quiz, in print order.
    func printItems(_ quiz: Quiz) -> [PrintItem] {
        var items: [PrintItem] = []
        if paper(quiz.paperId) != nil {
            items.append(PrintItem(kind: .paper, title: "ورقة الأسئلة"))
            items.append(PrintItem(kind: .model, title: "نموذج الإجابة"))
        }
        items.append(PrintItem(kind: .key, title: "ورقة الإجابة — المفتاح"))
        for cid in quiz.classIds {
            let n = students(inClass: cid).count
            if n > 0 {
                items.append(PrintItem(kind: .students(cid), title: "أوراق الإجابة — \(className(cid)) (\(studentsWord(n)))"))
            }
        }
        items.append(PrintItem(kind: .blank, title: "ورقة إجابة فارغة"))
        return items
    }

    private func studentsWord(_ n: Int) -> String {
        n == 1 ? "طالب واحد" : n == 2 ? "طالبان" : (3...10).contains(n) ? "\(n) طلاب" : "\(n) طالبًا"
    }

    /// The PDF of one paper, made on first use and kept until the quiz, its class list or the settings change.
    func printFile(_ item: PrintItem, quiz: Quiz) async throws -> URL {
        let dir = printsFolder.appendingPathComponent(quiz.id, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let safe = String(quiz.name.filter { !"/\\:?*\"<>|".contains($0) }).trimmingCharacters(in: .whitespaces)
        let url = dir.appendingPathComponent("\(safe.isEmpty ? "Gradal" : safe) - \(item.title.replacingOccurrences(of: "/", with: "-")).pdf")
        if FileManager.default.fileExists(atPath: url.path) { return url }
        guard let layout = LayoutStore.shared else { throw StoreError(message: "ملف شكل الورقة مفقود من التطبيق") }
        let data: Data
        switch item.kind {
        case .paper, .model:
            guard let paper = paper(quiz.paperId) else { throw StoreError(message: "لا أسئلة محفوظة لهذا الاختبار") }
            data = try await PaperPDF.make(quiz: quiz, paper: paper, settings: db.settings, mark: item.kind == .model)
        case .key:
            data = AnswerSheetPDF.make(quiz: quiz, people: [], settings: db.settings, layout: layout, key: true)
        case .students(let cid):
            let people = students(inClass: cid).map { SheetPerson(studentName: $0.name, gradalId: $0.gradalId, className: className(cid)) }
            data = AnswerSheetPDF.make(quiz: quiz, people: people, settings: db.settings, layout: layout, key: false)
        case .blank:
            data = AnswerSheetPDF.make(quiz: quiz, people: [], settings: db.settings, layout: layout, key: false)
        }
        try data.write(to: url, options: .atomic)
        return url
    }

    private func clearPrints(_ quizId: String) {
        try? FileManager.default.removeItem(at: printsFolder.appendingPathComponent(quizId, isDirectory: true))
    }

    private func clearAllPrints() {
        try? FileManager.default.removeItem(at: printsFolder)
        try? FileManager.default.createDirectory(at: printsFolder, withIntermediateDirectories: true)
    }

    // MARK: - Record sheet

    /// The record sheet (.xlsx) for a quiz, written to a temporary file for the share sheet.
    func recordFile(_ quiz: Quiz) throws -> URL {
        let counted = countedScans(quiz)
        var byStudent: [String: Scan] = [:]
        for scan in counted {
            if let s = resolvedStudent(scan, quiz: quiz), byStudent[s.id] == nil { byStudent[s.id] = scan }
        }
        let quizClasses = quiz.classIds.compactMap { id in db.classes.first { $0.id == id && !$0.deleted } }
        var classes: [RecordClass] = quizClasses.map { cls in
            let rows = students(inClass: cls.id).map { st -> RecordStudent in
                RecordStudent(gradalId: st.gradalId, name: st.name,
                              points: byStudent[st.id].map { Grading.perQuestion(quiz, answers: $0.answers) })
            }
            return RecordClass(name: cls.name, students: rows)
        }
        if classes.isEmpty {
            let rows = counted.compactMap { scan -> RecordStudent? in
                guard let st = self.resolvedStudent(scan, quiz: quiz) else { return nil }
                return RecordStudent(gradalId: st.gradalId, name: st.name,
                                     points: Grading.perQuestion(quiz, answers: scan.answers))
            }
            classes = [RecordClass(name: quiz.name.isEmpty ? "السجل" : quiz.name, students: rows)]
        }
        let sections = quiz.sections.map { RecordSection(name: $0.name, from: $0.from, to: $0.to) }
        let data = RecordSheet.workbook(classes, questionCount: quiz.questionCount, sections: sections)
        let safe = String(quiz.name.filter { !"/\\:?*\"<>|".contains($0) }).trimmingCharacters(in: .whitespaces)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("records", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(safe.isEmpty ? "Record" : safe) (\(quiz.code)).xlsx")
        try data.write(to: url, options: .atomic)
        return url
    }

    // MARK: - Backup

    func exportBackup() throws -> URL {
        save()
        return try Backup.export(folder: folder)
    }

    func restoreBackup(_ url: URL) throws {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        try Backup.restore(url, into: folder)
        load()
    }
}
