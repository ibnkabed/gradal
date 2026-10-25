# Gradal (iPhone only) — design

Gradal is one iPhone app that does everything: a teacher adds a textbook PDF (Arabic or English, any
subject), the linked AI providers write the questions, the teacher reviews them, and the phone makes the
question paper, the answer model, the answer-key sheet and a personalised bubble answer sheet for each
student, prints them with AirPrint, scans the filled sheets with the camera, grades them and shares the
grade book (xlsx). No computer, no account, no server: data stays on the phone (backup to Files/iCloud).

Swift 5.10, iOS 17, SwiftUI, XcodeGen (`ios/project.yml`), built unsigned on GitHub Actions
(`.github/workflows/build-ipa.yml`). Python files in `reference/` are the reference each Swift part is a
port of; CI compares them where it can (`ios/OMRCheck`, a macOS command-line target that compiles the
Foundation-only Swift files).

## Shared types — `ios/Gradal/Model/Models.swift` (fixed; read it first)

`SchoolClass`, `Student`, `QuizSection`, `QuizHeader`, `SheetBox`, `SheetColumn`, `QuizSheet`, `Quiz`
(one `key: [String]`, `language` "ar"/"en", `header: QuizHeader`, `paperId`), `Scan`, `Question`
(`kind` .mcq/.tf, `options`, `answer` index; tf: 0 = true/صح = A, 1 = false/خطأ = B), `PaperRequest`,
`Paper`, `Book`, `Settings` (`schoolLines`, `teacher`, `logoPNG`), `Stamp`, `DayFormat`, `LayoutStore`.
`Grading` (`Model/Grading.swift`): grade, perQuestion, display letters (أ ب ج د for Arabic).
`SheetLayouts` (`OMR/SheetLayouts.swift`) decodes `shared/sheet-layouts.json`, including `print`.

## Modules and their APIs

All user-facing strings are Arabic. Errors thrown to the UI conform to `LocalizedError` with an Arabic
`errorDescription`. No module touches `Store` or SwiftUI views except where stated.

### A. Sheet and paper rendering — `ios/Gradal/Sheet/`, `ios/Gradal/Paper/`

```swift
enum SheetGeometry {                         // Foundation only (also compiled into OMRCheck)
    static let version = 4
    static let minQuestions = 5, maxQuestions = 60
    /// Port of reference/sheet_layout.py compute(): same constants, same numbers (rounded to 0.001).
    static func compute(questionCount: Int, sections: [QuizSection], rtl: Bool, layout: SheetLayouts) throws -> QuizSheet
}
struct SheetPerson { var studentName: String; var gradalId: String; var className: String }
enum AnswerSheetPDF {                        // UIKit
    /// One A4 page per person (or one blank page when `people` is empty); key: fill the right bubbles
    /// and print the key label in the name box. Port of reference/sheets.py page_shapes() + header.
    static func make(quiz: Quiz, people: [SheetPerson], settings: Settings, layout: SheetLayouts, key: Bool) -> Data
}
enum PaperPDF {                              // UIKit + WebKit
    /// The question paper (mark false) or the answer model (mark true), A4, paginated. Port of reference/paper.py.
    @MainActor static func make(quiz: Quiz, paper: Paper, settings: Settings, mark: Bool) async throws -> Data
}
```

### B. AI, books, question writer — `ios/Gradal/AI/`, `ios/Gradal/Exam/`

```swift
struct AIProvider { let id, name: String; let free: Bool; let base: String; let keyURL: URL; let note: String
                    let prefer: [String]; let avoid: [String]; let onlyFree: Bool }
enum AIProviders { static let all: [AIProvider] }        // reference/ai.py PROVIDERS, same order
struct LinkedProvider: Codable { var id: String; var model: String; var linkedAt: String; var lastError: String? }
@MainActor final class AIClient: ObservableObject {
    static let shared: AIClient
    @Published private(set) var linked: [LinkedProvider]  // persisted (UserDefaults); keys in the Keychain
    func link(_ providerId: String, key: String) async throws -> String   // checks GET /models, returns the model
    func unlink(_ providerId: String)
    func chat(_ messages: [[String: String]], jsonMode: Bool, exclude: Set<String>, temperature: Double) async throws -> (text: String, provider: String)
    func geminiPDF(_ pdf: Data, prompt: String) async throws -> String
}
enum BookText {                               // PDFKit
    static let maxPages = 30
    static func pageCount(_ url: URL) -> Int
    static func text(_ url: URL, from: Int, to: Int) throws -> (text: String, readable: Bool)
    static func subset(_ url: URL, from: Int, to: Int) throws -> Data
}
enum ExamMaker {
    static func clean(_ raw: Any) -> Question?                 // reference/exam_maker.py clean_item
    static func balance(_ questions: inout [Question], seed: UInt64?)
    static let sectionNames: [String: [Question.Kind: String]] // "ar": اختيار من متعدد / صح أو خطأ, "en": Multiple Choice / True or False
    /// Writes the questions (MCQ first, then true/false); progress gets Arabic status lines.
    @MainActor static func write(_ request: PaperRequest, bookURL: URL, ai: AIClient,
                                 progress: @escaping (String) -> Void) async throws -> (questions: [Question], providers: [String])
}
```

### C. Class lists and backup — `ios/Gradal/Import/`, `ios/Gradal/Backup/`, `ios/Gradal/Record/ZipReader.swift`

```swift
struct ZipReader { init(_ data: Data) throws; var names: [String]; func data(_ name: String) throws -> Data }  // stored + deflate (Compression)
enum XLSXReader { static func rows(_ data: Data) throws -> [[String]] }      // first worksheet
struct ImportedStudent { var name: String; var nationalId: String }
struct ImportedClass { var name: String; var students: [ImportedStudent] }
enum StudentsImport {                         // reference/students_import.py
    static func read(_ data: Data, filename: String, className: String) throws -> [ImportedClass]   // xlsx, html-as-xls, csv, txt
    static func pasted(_ text: String, className: String) throws -> [ImportedClass]
}
struct RosterSummary { var name: String; var prefix: Int; var count: Int; var added: Int; var inactive: Int }
enum Roster {                                 // reference/roster.py, on plain arrays
    static func merge(_ imported: [ImportedClass], classes: inout [SchoolClass], students: inout [Student]) throws -> [RosterSummary]
    static func archiveClass(_ id: String, label: String, classes: inout [SchoolClass], students: inout [Student]) throws
    static func archiveAll(label: String, classes: inout [SchoolClass], students: inout [Student])
    static func yearLabel(_ date: Date) -> String
}
enum Backup {
    /// Zips the whole data folder (store.json, books/, scans/) to a temporary .gradal-backup.zip for the share sheet.
    static func export(folder: URL) throws -> URL
    /// Replaces the data folder with a backup's content (validates store.json first).
    static func restore(_ zip: URL, into folder: URL) throws
}
```

### D. Store and screens — `ios/Gradal/Model/Store.swift`, `ios/Gradal/Views/`

`Store` (ObservableObject, `Application Support/Gradal/store.json` + `books/` + `scans/` + `prints/`) holds
classes, students, quizzes, scans, orphans, papers, books, settings; computes `quiz.sheet` with
`SheetGeometry` on every save; caches printable PDFs per quiz in `prints/<quizId>/`. Tabs: «الاختبارات»
(list; new from a book; new with a ready key; drafts; quiz page: papers to print/share, scan, results,
item analysis, record), «الطلاب» (import, paste, classes, archive, new year), «الإعدادات» (AI providers,
school header, backup/restore, about).
