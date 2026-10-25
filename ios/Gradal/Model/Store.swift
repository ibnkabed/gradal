import Foundation
import SwiftUI

/// A paper whose barcode code matches no quiz yet; attached when the quiz arrives.
struct OrphanScan: Codable, Identifiable, Hashable {
    var id: String
    var quizCode: Int
    var gradalId: String
    var version: Int
    var answers: [String]        // read with the layout's maxQuestions, trimmed on attach
    var scannedAt: String
    var hasImage: Bool
}

/// What the scanner needs to read a quiz's answers; bubbles nil = the PC has not prepared its sheet.
struct ScanGrid {
    let questionCount: Int
    let bubbles: [[[Double]]]?
}

struct OrphanGroup: Identifiable {
    let code: Int
    let count: Int
    var id: Int { code }
}

/// Everything the phone keeps, in one JSON file. Pending ids wait for the next sync.
struct StoreFile: Codable {
    var classes: [SchoolClass] = []
    var students: [Student] = []
    var quizzes: [Quiz] = []
    var scans: [Scan] = []
    var orphans: [OrphanScan] = []
    var pendingQuizIds: [String] = []
    var pendingScanIds: [String] = []
    /// Classes and students the last full snapshot no longer listed: archived on the PC. Kept to
    /// name old scans, hidden everywhere else; never synced back.
    var missingIds: [String] = []

    enum CodingKeys: String, CodingKey {
        case classes, students, quizzes, scans, orphans, pendingQuizIds, pendingScanIds, missingIds
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        classes = (try? c.decodeIfPresent([SchoolClass].self, forKey: .classes)) ?? []
        students = (try? c.decodeIfPresent([Student].self, forKey: .students)) ?? []
        quizzes = (try? c.decodeIfPresent([Quiz].self, forKey: .quizzes)) ?? []
        scans = (try? c.decodeIfPresent([Scan].self, forKey: .scans)) ?? []
        orphans = (try? c.decodeIfPresent([OrphanScan].self, forKey: .orphans)) ?? []
        pendingQuizIds = (try? c.decodeIfPresent([String].self, forKey: .pendingQuizIds)) ?? []
        pendingScanIds = (try? c.decodeIfPresent([String].self, forKey: .pendingScanIds)) ?? []
        missingIds = (try? c.decodeIfPresent([String].self, forKey: .missingIds)) ?? []
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

/// Local store: Application Support/Gradal/store.json + scans/<id>.jpg.
@MainActor
final class Store: ObservableObject {
    @Published private(set) var db: StoreFile
    /// The quiz on screen, so sync pulls its scans.
    @Published var openQuizId: String?
    /// Called after every local change that needs syncing.
    var onLocalChange: (@MainActor () -> Void)?

    private let folder: URL
    private let imagesFolder: URL

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Gradal", isDirectory: true)
        let images = base.appendingPathComponent("scans", isDirectory: true)
        try? FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
        folder = base
        imagesFolder = images
        if let data = try? Data(contentsOf: base.appendingPathComponent("store.json")),
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

    private func changed() {
        save()
        onLocalChange?()
    }

    func imageURL(_ scanId: String) -> URL {
        imagesFolder.appendingPathComponent("\(scanId).jpg")
    }

    // MARK: - Reading

    var activeQuizzes: [Quiz] {
        db.quizzes.filter { !$0.deleted }.sorted { a, b in
            a.date != b.date ? a.date > b.date : a.name < b.name
        }
    }

    func isArchived(_ c: SchoolClass) -> Bool {
        c.archived != nil || db.missingIds.contains(c.id)
    }

    func isArchived(_ s: Student) -> Bool {
        s.archived != nil || db.missingIds.contains(s.id)
    }

    private static func classOrder(_ a: SchoolClass, _ b: SchoolClass) -> Bool {
        let pa = a.prefix ?? Int.max, pb = b.prefix ?? Int.max
        return pa != pb ? pa < pb : a.name < b.name
    }

    /// Current classes in order (by prefix, then name); archived ones are left out.
    var activeClasses: [SchoolClass] {
        let missing = Set(db.missingIds)
        return db.classes.filter { !$0.deleted && $0.archived == nil && !missing.contains($0.id) }
            .sorted(by: Self.classOrder)
    }

    /// Current students (not deleted, not archived).
    var activeStudents: [Student] {
        let missing = Set(db.missingIds)
        return db.students.filter { !$0.deleted && $0.archived == nil && !missing.contains($0.id) }
    }

    private static func listOrder(_ a: Student, _ b: Student) -> Bool {
        let oa = a.order ?? Int.max, ob = b.order ?? Int.max
        return oa != ob ? oa < ob : a.name < b.name
    }

    /// Students of a class in the computer's list order.
    func students(inClass classId: String, includeInactive: Bool = true) -> [Student] {
        activeStudents
            .filter { $0.classIds.contains(classId) && (includeInactive || $0.active) }
            .sorted(by: Self.listOrder)
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

    var pendingCount: Int { db.pendingQuizIds.count + db.pendingScanIds.count }

    /// Unknown-quiz papers grouped by code.
    var orphanGroups: [OrphanGroup] {
        var counts: [Int: Int] = [:]
        for o in db.orphans { counts[o.quizCode, default: 0] += 1 }
        return counts.keys.sorted().map { OrphanGroup(code: $0, count: counts[$0] ?? 0) }
    }

    /// First among the students of the quiz's classes (archived or not), then among current students,
    /// so a new year's «101» never hits last year's «101».
    func studentFor(gradalId: String, preferring classIds: [String]) -> Student? {
        guard !gradalId.isEmpty, !gradalId.contains("?") else { return nil }
        let inQuiz = db.students.filter {
            !$0.deleted && $0.gradalId == gradalId && !Set($0.classIds).isDisjoint(with: classIds)
        }
        if let s = inQuiz.first(where: { !isArchived($0) && $0.active })
            ?? inQuiz.first(where: { !isArchived($0) })
            ?? inQuiz.first(where: { $0.archivedActive ?? $0.active })
            ?? inQuiz.first {
            return s
        }
        let current = activeStudents.filter { $0.gradalId == gradalId }
        return current.first { $0.active } ?? current.first
    }

    /// The scan's student: assigned, or resolved by gradalId.
    func resolvedStudent(_ scan: Scan, quiz: Quiz) -> Student? {
        student(scan.studentId) ?? studentFor(gradalId: scan.gradalId, preferring: quiz.classIds)
    }

    func displayName(_ scan: Scan, quiz: Quiz) -> String {
        if let s = resolvedStudent(scan, quiz: quiz) { return s.name }
        return unknownName(scan.gradalId)
    }

    private func unknownName(_ gradalId: String) -> String {
        let digits = gradalId.replacingOccurrences(of: "?", with: "")
        return digits.isEmpty ? "بلا رقم" : "رقم غير معروف \(gradalId)"
    }

    func scans(for quizId: String) -> [Scan] {
        db.scans.filter { $0.quizId == quizId && !$0.deleted }.sorted { $0.scannedAt > $1.scannedAt }
    }

    /// The newest non-deleted scan per student counts; unknown IDs count per read ID.
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
        Grading.grade(quiz, answers: scan.answers, version: scan.version)
    }

    func card(for scan: Scan, quiz: Quiz) -> ResultCard {
        let g = grade(scan, quiz: quiz)
        return ResultCard(quizName: quiz.name,
                          name: displayName(scan, quiz: quiz),
                          known: resolvedStudent(scan, quiz: quiz) != nil,
                          score: "\(fmt(g.earned)) من \(fmt(g.possible))",
                          percent: Int(percentOf(g.earned, g.possible).rounded()))
    }

    // MARK: - Local changes

    private func markScanPending(_ id: String) {
        if !db.pendingScanIds.contains(id) { db.pendingScanIds.append(id) }
    }

    private func makeScan(id: String, quiz: Quiz, gradalId: String, version: Int, answers raw: [String],
                          scannedAt: String, hasImage: Bool) -> Scan {
        var answers = Array(raw.prefix(quiz.questionCount))
        while answers.count < quiz.questionCount { answers.append("") }
        let g = Grading.grade(quiz, answers: answers, version: version)
        return Scan(id: id, quizId: quiz.id,
                    studentId: studentFor(gradalId: gradalId, preferring: quiz.classIds)?.id,
                    gradalId: gradalId, version: version, answers: answers,
                    earned: g.earned, possible: g.possible, scannedAt: scannedAt,
                    deviceId: DeviceIdentity.id, edited: false, hasImage: hasImage,
                    updatedAt: Stamp.now(), deleted: false)
    }

    /// Saves an accepted paper of a known quiz; nil (nothing saved) when the quiz is not here.
    func addScan(read: SheetRead, jpeg: Data?) -> ResultCard? {
        guard let quiz = quiz(code: read.quizCode) else { return nil }
        let id = UUID().uuidString.lowercased()
        var hasImage = false
        if let jpeg {
            hasImage = (try? jpeg.write(to: imageURL(id), options: .atomic)) != nil
        }
        let scan = makeScan(id: id, quiz: quiz, gradalId: read.studentId, version: read.version,
                            answers: read.answers, scannedAt: Stamp.now(), hasImage: hasImage)
        db.scans.append(scan)
        markScanPending(id)
        changed()
        return card(for: scan, quiz: quiz)
    }

    /// Papers scanned by older builds before their quiz arrived become ordinary scans (pending sync).
    private func attachOrphans() {
        guard !db.orphans.isEmpty else { return }
        var left: [OrphanScan] = []
        var attached = 0
        for o in db.orphans {
            guard let quiz = quiz(code: o.quizCode) else {
                left.append(o)
                continue
            }
            let scan = makeScan(id: o.id, quiz: quiz, gradalId: o.gradalId, version: o.version,
                                answers: o.answers, scannedAt: o.scannedAt, hasImage: o.hasImage)
            db.scans.append(scan)
            markScanPending(scan.id)
            attached += 1
        }
        if attached > 0 { db.orphans = left }
    }

    func deleteOrphans(code: Int) {
        for o in db.orphans where o.quizCode == code {
            try? FileManager.default.removeItem(at: imageURL(o.id))
        }
        db.orphans.removeAll { $0.quizCode == code }
        save()
    }

    /// Teacher edits (answers, version, student). Re-grades and marks the scan pending.
    func updateScan(_ scan: Scan) {
        guard let i = db.scans.firstIndex(where: { $0.id == scan.id }) else { return }
        var s = scan
        if let quiz = quiz(s.quizId) {
            let g = Grading.grade(quiz, answers: s.answers, version: s.version)
            s.earned = g.earned
            s.possible = g.possible
        }
        s.edited = true
        s.updatedAt = Stamp.after(db.scans[i].updatedAt)
        db.scans[i] = s
        markScanPending(s.id)
        changed()
    }

    func deleteScan(_ id: String) {
        guard let i = db.scans.firstIndex(where: { $0.id == id }) else { return }
        db.scans[i].deleted = true
        db.scans[i].updatedAt = Stamp.after(db.scans[i].updatedAt)
        try? FileManager.default.removeItem(at: imageURL(id))
        markScanPending(id)
        changed()
    }

    // MARK: - Record sheet

    /// The record sheet (.xlsx) for a quiz, written to a temporary file for the share sheet.
    func recordFile(_ quiz: Quiz) throws -> URL {
        let counted = countedScans(quiz)
        var byStudent: [String: Scan] = [:]
        for scan in counted {
            if let s = resolvedStudent(scan, quiz: quiz), byStudent[s.id] == nil { byStudent[s.id] = scan }
        }
        // The quiz's own classes even when archived; an archived class keeps the students who were
        // active in it when it was archived.
        let quizClasses = db.classes.filter { !$0.deleted && quiz.classIds.contains($0.id) }.sorted(by: Self.classOrder)
        var classes: [RecordClass] = quizClasses.map { cls in
            let members: [Student]
            if self.isArchived(cls) {
                members = self.db.students
                    .filter { !$0.deleted && $0.classIds.contains(cls.id) && ($0.archivedActive ?? $0.active) }
                    .sorted(by: Self.listOrder)
            } else {
                members = self.students(inClass: cls.id, includeInactive: false)
            }
            let rows = members.map { st -> RecordStudent in
                let points = byStudent[st.id].map {
                    Grading.perQuestion(quiz, answers: $0.answers, version: $0.version)
                }
                return RecordStudent(gradalId: st.gradalId, name: st.name, points: points)
            }
            return RecordClass(name: cls.name, students: rows)
        }
        if classes.isEmpty {
            // No classes on the quiz: one sheet with every graded student.
            let rows = counted.compactMap { scan -> RecordStudent? in
                guard let st = self.resolvedStudent(scan, quiz: quiz) else { return nil }
                return RecordStudent(gradalId: st.gradalId, name: st.name,
                                     points: Grading.perQuestion(quiz, answers: scan.answers, version: scan.version))
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

    // MARK: - Sync

    /// Quizzes are made on the computer only, so nothing on the phone adds to this; kept for the protocol.
    var pendingQuizzes: [Quiz] {
        db.pendingQuizIds.compactMap { id in db.quizzes.first { $0.id == id } }
    }

    /// Oldest first.
    var pendingScans: [Scan] {
        let ids = Set(db.pendingScanIds)
        return db.scans.filter { ids.contains($0.id) }.sorted { $0.scannedAt < $1.scannedAt }
    }

    /// Clears the pending flag only where the record was not changed again while it travelled.
    func markQuizzesSynced(_ sent: [Quiz]) {
        let quizzes = db.quizzes
        let done = Set(sent.filter { s in quizzes.first { $0.id == s.id }?.updatedAt == s.updatedAt }.map(\.id))
        db.pendingQuizIds.removeAll { done.contains($0) }
        save()
    }

    func markScansSynced(_ sent: [Scan]) {
        let scans = db.scans
        let done = Set(sent.filter { s in scans.first { $0.id == s.id }?.updatedAt == s.updatedAt }.map(\.id))
        db.pendingScanIds.removeAll { done.contains($0) }
        save()
    }

    private func merged<T: SyncRecord>(_ local: [T], _ incoming: [T]) -> (records: [T], replaced: Set<String>) {
        var result = local
        var index: [String: Int] = [:]
        for (i, r) in local.enumerated() where index[r.id] == nil { index[r.id] = i }
        var replaced = Set<String>()
        for r in incoming {
            if let i = index[r.id] {
                if Stamp.isNewer(r.updatedAt, than: result[i].updatedAt) {
                    result[i] = r
                    replaced.insert(r.id)
                }
            } else {
                index[r.id] = result.count
                result.append(r)
                replaced.insert(r.id)
            }
        }
        return (result, replaced)
    }

    func applySnapshot(_ snapshot: Snapshot) {
        db.classes = merged(db.classes, snapshot.classes).records
        db.students = merged(db.students, snapshot.students).records
        // A full snapshot leaves archived classes and students out: hide what it no longer lists.
        let listed = Set(snapshot.classes.map(\.id)).union(snapshot.students.map(\.id))
        db.missingIds = db.classes.filter { !$0.deleted && !listed.contains($0.id) }.map(\.id)
            + db.students.filter { !$0.deleted && !listed.contains($0.id) }.map(\.id)
        let q = merged(db.quizzes, snapshot.quizzes)
        db.quizzes = q.records
        db.pendingQuizIds.removeAll { q.replaced.contains($0) }
        attachOrphans()
        save()
    }

    func mergeScans(_ incoming: [Scan]) {
        let m = merged(db.scans, incoming)
        db.scans = m.records
        db.pendingScanIds.removeAll { m.replaced.contains($0) }
        for scan in db.scans where scan.deleted && m.replaced.contains(scan.id) {
            try? FileManager.default.removeItem(at: imageURL(scan.id))
        }
        save()
    }

    /// Quizzes whose scans sync pulls: the one on screen, else the three newest.
    func quizzesToRefresh() -> [String] {
        if let open = openQuizId, quiz(open) != nil { return [open] }
        return Array(activeQuizzes.prefix(3).map(\.id))
    }

    /// Code -> question positions, for the scanner thread.
    var scanGrids: [Int: ScanGrid] {
        var out: [Int: ScanGrid] = [:]
        for q in db.quizzes where !q.deleted {
            out[q.code] = ScanGrid(questionCount: q.questionCount,
                                   bubbles: q.sheetReady ? q.sheet?.questionBubbles : nil)
        }
        return out
    }
}
