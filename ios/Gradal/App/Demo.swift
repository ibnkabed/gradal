import Foundation

/// Screenshot mode for the README (2026-11-02): `-demo <screen>` opens the app on sample classes, tests and
/// graded papers in a folder of its own, never the teacher's. Screens: quizzes, detail, students, settings, about (settings scrolled to «عن التطبيق»).
/// The CI job `screenshots.yml` launches each one in the simulator and saves the screen.
enum Demo {
    static let screen: String? = {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-demo"), i + 1 < args.count else { return nil }
        return args[i + 1]
    }()

    /// The tab the screen lives in: 0 الاختبارات, 1 الطلاب, 2 الإعدادات.
    static var tab: Int {
        switch screen {
        case "students": return 1
        case "settings", "about": return 2
        default: return 0
        }
    }

    /// The test opened in the tests tab (its results), set by `seed`.
    static var openQuiz: String?

    static func folder() -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("GradalDemo", isDirectory: true)
        try? FileManager.default.removeItem(at: folder)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// Two classes, two tests with keys, and graded papers for the first test.
    @MainActor
    static func seed(_ store: Store) {
        let names1 = ["عبدالرحمن خالد العتيبي", "فيصل سعد القحطاني", "محمد عبدالله الشهري", "نواف فهد الدوسري",
                      "سلمان ناصر الغامدي", "يوسف أحمد الزهراني", "تركي سعود المطيري", "عمر حسن الحربي",
                      "زياد علي السبيعي", "مشاري ماجد العنزي"]
        let names2 = ["بدر صالح الشمري", "راكان عادل القرني", "حمد إبراهيم المالكي", "ريان طلال العمري",
                      "سعود منصور الرشيدي", "خالد وليد الجهني"]
        _ = try? store.pasteStudents(names1.joined(separator: "\n"), className: "٣/١")
        _ = try? store.pasteStudents(names2.joined(separator: "\n"), className: "٣/٢")
        let classIds = store.db.classes.map(\.id)
        let letters = ["A", "B", "C", "D"]
        let key = (0..<20).map { letters[($0 * 7 + 3) % 4] }
        guard let quiz = try? store.saveManualQuiz(id: nil, name: "اختبار الفترة الأولى", subject: "الرياضيات",
                                                   language: "ar", classIds: classIds, key: key) else { return }
        _ = try? store.saveManualQuiz(id: nil, name: "اختبار قصير: الكسور", subject: "الرياضيات",
                                      language: "ar", classIds: classIds,
                                      key: (0..<10).map { letters[($0 * 3 + 1) % 4] })
        // each student misses a different number of questions, so the results and the analysis vary
        for (n, student) in store.db.students.prefix(13).enumerated() {
            var answers = key
            for q in 0..<((n * 3) % 9) { answers[(q * 5 + n) % key.count] = letters[(letters.firstIndex(of: key[(q * 5 + n) % key.count])! + 1) % 4] }
            store.addDemoScan(quizId: quiz.id, studentId: student.id, answers: answers)
        }
        openQuiz = screen == "detail" ? quiz.id : nil
    }
}
