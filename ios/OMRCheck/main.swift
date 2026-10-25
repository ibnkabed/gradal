import CoreGraphics
import Foundation
import ImageIO

// CI checks for code shared with the iPhone app.
//   OMRCheck <folder> <sheet-layouts.json>
//     Runs the Swift sheet reader on synthetic photos (tools/make_test_sheets.py) and compares
//     with the truth files, like tools/check_omr.py. Exit 1 if any found sheet has a mismatch,
//     or if more than 15% of sheets are not found.
//   OMRCheck --xlsx <out.xlsx>
//     Writes the sample record sheet (checked by tools/check_record_xlsx.py).
//   OMRCheck --geometry <in.json> <out.json> [sheet-layouts.json]
//     Computes each quiz of in.json ([{"questionCount", "rtl", "sections": [{"name", "from", "to"}]}])
//     with SheetGeometry and writes [QuizSheet] (null where it throws) for tools/check_geometry.py.
//     The layouts default to shared/sheet-layouts.json in the current folder.
//   OMRCheck --import-selftest
//     Class lists: xlsx (XLSXWriter -> ZipReader -> XLSXReader), HTML, CSV, pasted names, Roster.merge
//     and archive, like reference/students_import.py and reference/roster.py. Exit 1 on any failure.
//   OMRCheck --exam-selftest
//     The question writer's pure rules (ExamMaker.clean, balance, parseJSON, AIProviders.pickModel,
//     BookRules), like reference/exam_maker.py, ai.py and books.py. Exit 1 on any failure.

struct TruthSheet: Decodable {
    let questionBubbles: [[[Double]]]?
}

struct Truth: Decodable {
    let sheet: TruthSheet?
    let quizCode: Int
    let version: Int
    let questionCount: Int
    let studentId: String
    let answers: [String]
}

func loadGray(_ url: URL) -> GrayImage? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
    let w = image.width, h = image.height
    guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpaceCreateDeviceGray(),
                              bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    guard let data = ctx.data else { return nil }
    let stride = ctx.bytesPerRow
    let src = data.assumingMemoryBound(to: UInt8.self)
    var pixels = [UInt8](repeating: 0, count: w * h)
    for y in 0..<h {
        for x in 0..<w { pixels[y * w + x] = src[y * stride + x] }
    }
    return GrayImage(width: w, height: h, pixels: pixels)
}

let args = CommandLine.arguments

if args.count >= 3 && args[1] == "--xlsx" {
    let out = URL(fileURLWithPath: args[2])
    do {
        try RecordSheet.sample().write(to: out, options: .atomic)
        print("wrote \(out.path)")
        exit(0)
    } catch {
        print("cannot write \(out.path): \(error)")
        exit(1)
    }
}

/// OMRCheck --import-selftest: class lists (ZipReader, XLSXReader, StudentsImport) and Roster.merge / archive,
/// against the behaviour of reference/students_import.py and reference/roster.py. Returns the failures.
func importSelfTest() -> [String] {
    var failures: [String] = []
    func expect(_ ok: Bool, _ what: String) {
        if !ok { failures.append(what) }
    }
    func message(_ error: Error) -> String { (error as? LocalizedError)?.errorDescription ?? "\(error)" }

    // 1. An .xlsx written by XLSXWriter: a title row, then Noor's header, two classes, a gap in a row.
    let sheet = XLSXSheet(name: "الطلاب", rightToLeft: true, columnWidths: [], defaultWidth: 12, rows: [
        [.text("قائمة طلاب المدرسة")],
        [.text("م"), .text("رقم الهوية"), .text("اسم الطالب"), .text("الفصل")],
        [.number(1), .text("1012345678"), .text("أحمد علي"), .text("أول 1")],
        [.number(2), .number(1_023_456_789), .text("خالد  محمد"), .text("أول ١")],
        [.number(3), .empty, .text("سعد فهد"), .text("ثاني 2")],
    ], boldFirstRow: false)
    let xlsx = XLSXWriter.workbook([sheet])
    do {
        let zip = try ZipReader(xlsx)
        expect(zip.names.contains("xl/workbook.xml") && zip.names.contains("xl/worksheets/sheet1.xml"),
               "zip names: \(zip.names)")
        let rows = try XLSXReader.rows(xlsx)
        expect(rows.count == 5, "xlsx row count \(rows.count)")
        if rows.count == 5 {
            expect(rows[0] == ["قائمة طلاب المدرسة"], "xlsx row 1 \(rows[0])")
            expect(rows[3] == ["2", "1023456789", "خالد  محمد", "أول ١"], "xlsx row 4 \(rows[3])")
            expect(rows[4] == ["3", "", "سعد فهد", "ثاني 2"], "xlsx row 5 \(rows[4])")
        }
        let classes = try StudentsImport.read(xlsx, filename: "noor.xlsx", className: "")
        let expected = [
            ImportedClass(name: "أول 1", students: [ImportedStudent(name: "أحمد علي", nationalId: "1012345678"),
                                                   ImportedStudent(name: "خالد محمد", nationalId: "1023456789")]),
            ImportedClass(name: "ثاني 2", students: [ImportedStudent(name: "سعد فهد", nationalId: "")]),
        ]
        expect(classes == expected, "xlsx import \(classes)")
    } catch {
        failures.append("xlsx: \(message(error))")
    }

    // 2. DEFLATE and STORE entries with a UTF-8 name, made by Python's zipfile.
    let zipped = "UEsDBBQAAAgIAEyAWV2nUzSQHQAAAIECAAAKAAAA2YbYtS9hLnR4dLux+cb2GxsVbuy8sfHGiptdCjdG+aP8jfTjcwEAUEsDBBQAAAAAAEyAWV0L+UNWBgAAAAYAAAAFAAAAYi50eHRzdG9yZWRQSwECFAAUAAAICABMgFldp1M0kB0AAACBAgAACgAAAAAAAAAAAAAAgAEAAAAA2YbYtS9hLnR4dFBLAQIUABQAAAAAAEyAWV0L+UNWBgAAAAYAAAAFAAAAAAAAAAAAAACAAUUAAABiLnR4dFBLBQYAAAAAAgACAGsAAABuAAAAAAA="
    do {
        guard let data = Data(base64Encoded: zipped) else { throw StudentsImportError(message: "base64") }
        let zip = try ZipReader(data)
        expect(zip.names == ["نص/a.txt", "b.txt"], "deflate zip names \(zip.names)")
        let deflated = try zip.data("نص/a.txt")
        let stored = try zip.data("b.txt")
        let text = String(decoding: deflated, as: UTF8.self)
        expect(text == String(repeating: "سطر عربي ", count: 40) + "\n", "deflated entry")
        expect(String(decoding: stored, as: UTF8.self) == "stored", "stored entry")
    } catch {
        failures.append("deflate: \(message(error))")
    }

    // 3. Noor's HTML table saved as .xls, entities included.
    let html = "<!DOCTYPE html><html><head><meta charset=\"utf-8\"><style>td{color:red}</style></head><body>"
        + "<table border=\"1\"><tr><th>م</th><th>اسم الطالب</th></tr>"
        + "<tr><td>1</td><td>عبد&nbsp;الله &amp; محمد</td></tr>"
        + "<tr><td>2</td><td>&#1601;&#1607;&#x62F; سعد</td></tr></table></body></html>"
    do {
        let classes = try StudentsImport.read(Data(html.utf8), filename: "list.xls", className: "أول 1")
        let names = classes.first?.students.map(\.name) ?? []
        expect(classes.count == 1 && classes[0].name == "أول 1" && names == ["عبد الله & محمد", "فهد سعد"],
               "html import \(classes)")
    } catch {
        failures.append("html: \(message(error))")
    }

    // 4. CSV with a quoted comma and Arabic-Indic digits in the ID.
    do {
        let csv = "اسم الطالب,رقم الهوية\n\"محمد, ناصر\",١٠٢٣٤٥٦٧٨٩\n"
        let classes = try StudentsImport.read(Data(csv.utf8), filename: "list.csv", className: "رابع 4")
        expect(classes == [ImportedClass(name: "رابع 4", students: [ImportedStudent(name: "محمد, ناصر",
                                                                                  nationalId: "1023456789")])],
               "csv import \(classes)")
    } catch {
        failures.append("csv: \(message(error))")
    }

    // 5. A legacy BIFF .xls is refused with the Arabic message.
    do {
        _ = try StudentsImport.read(Data([0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1, 0, 0]), filename: "a.xls", className: "")
        failures.append("legacy xls was read")
    } catch {
        expect(message(error) == StudentsImport.legacyXLS, "legacy xls message \(message(error))")
    }

    // 6. Pasted names with numbering.
    do {
        let classes = try StudentsImport.pasted("1. أحمد علي\n٢- خالد\r\n\n  3 • سعد  ", className: " أول 1 ")
        expect(classes.count == 1 && classes[0].name == "أول 1"
               && classes[0].students.map(\.name) == ["أحمد علي", "خالد", "سعد"], "pasted \(classes)")
    } catch {
        failures.append("pasted: \(message(error))")
    }

    // 7. Roster: reference test — «أحمد», «خالد»; then «خالد», «سعد» -> 101 inactive, 102 and 103 active.
    var classes: [SchoolClass] = []
    var students: [Student] = []
    do {
        let first = try Roster.merge([ImportedClass(name: "أول 1", students: [
            ImportedStudent(name: "أحمد", nationalId: ""), ImportedStudent(name: "خالد", nationalId: "")])],
            classes: &classes, students: &students)
        expect(first == [RosterSummary(name: "أول 1", prefix: 1, count: 2, added: 2, inactive: 0)], "merge 1 \(first)")
        let second = try Roster.merge([ImportedClass(name: "أول  1", students: [
            ImportedStudent(name: "خالد", nationalId: ""), ImportedStudent(name: "سعد", nationalId: "")])],
            classes: &classes, students: &students)
        expect(second == [RosterSummary(name: "أول 1", prefix: 1, count: 2, added: 1, inactive: 1)], "merge 2 \(second)")
        expect(classes.count == 1, "classes after merge \(classes.count)")
        func student(_ name: String) -> Student? { students.first { $0.name == name } }
        expect(student("أحمد")?.gradalId == "101" && student("أحمد")?.active == false, "أحمد 101 inactive")
        expect(student("خالد")?.gradalId == "102" && student("خالد")?.active == true && student("خالد")?.order == 1,
               "خالد 102 active")
        expect(student("سعد")?.gradalId == "103" && student("سعد")?.active == true && student("سعد")?.order == 2,
               "سعد 103 active")
        expect(Roster.normalise("أَحْمَـد  إبراهيم") == Roster.normalise("احمد ابراهيم"), "normalise")

        Roster.archiveAll(label: "  2025-2026  ", classes: &classes, students: &students)
        expect(classes.allSatisfy { $0.archived == "2025-2026" }, "archiveAll classes")
        expect(students.allSatisfy { $0.archived == "2025-2026" && !$0.active }, "archiveAll students")
        expect(student("خالد")?.archivedActive == true && student("أحمد")?.archivedActive == false, "archivedActive")
        let next = try Roster.merge([ImportedClass(name: "ثاني 2", students: [ImportedStudent(name: "فهد", nationalId: "")])],
                                    classes: &classes, students: &students)
        expect(next.first?.prefix == 1 && student("فهد")?.gradalId == "101", "prefix and serial free after archive")
    } catch {
        failures.append("roster: \(message(error))")
    }
    do {
        try Roster.archiveClass("missing", label: "", classes: &classes, students: &students)
        failures.append("archiveClass of a missing class did not throw")
    } catch {
        expect(message(error) == "الفصل غير موجود", "archiveClass message \(message(error))")
    }

    // 8. Year label: up to September the year just ended, from October the running one.
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone.current
    if let september = calendar.date(from: DateComponents(year: 2026, month: 9, day: 15, hour: 12)),
       let october = calendar.date(from: DateComponents(year: 2026, month: 10, day: 21, hour: 12)) {
        expect(Roster.yearLabel(september) == "2025-2026 — 2026-09-15", "yearLabel \(Roster.yearLabel(september))")
        expect(Roster.yearLabel(october) == "2026-2027 — 2026-10-21", "yearLabel \(Roster.yearLabel(october))")
    } else {
        failures.append("cannot make test dates")
    }
    return failures
}

if args.count >= 2 && args[1] == "--import-selftest" {
    let failures = importSelfTest()
    for f in failures { print("FAIL: \(f)") }
    print(failures.isEmpty ? "import self-test: ok" : "import self-test: \(failures.count) failure(s)")
    exit(failures.isEmpty ? 0 : 1)
}

/// OMRCheck --exam-selftest: the question writer's pure rules (ExamMaker.clean, balance, parseJSON,
/// AIProviders.pickModel, BookRules) against the behaviour of reference/exam_maker.py, ai.py and books.py.
/// Returns the failures.
func examSelfTest() -> [String] {
    var failures: [String] = []
    func expect(_ ok: Bool, _ what: String) {
        if !ok { failures.append(what) }
    }
    func cleaned(_ json: String) -> Question? {
        guard let raw = try? JSONSerialization.jsonObject(with: Data(json.utf8)) else {
            failures.append("bad test JSON: \(json)")
            return nil
        }
        return ExamMaker.clean(raw)
    }
    func mcq(_ options: String, answer: String) -> String {
        #"{"type":"mcq","text":"ما عاصمة المملكة العربية السعودية؟","options":"# + options + #","answer":"# + answer + "}"
    }
    func tf(_ answer: String) -> String {
        #"{"type":"tf","text":"الشمس نجم من النجوم","answer":"# + answer + "}"
    }
    let four = #"["الرياض","جدة","مكة المكرمة","الدمام"]"#

    // 1. clean: what the reference accepts and rejects
    if let q = cleaned(mcq(four, answer: "0")) {
        expect(q.kind == .mcq && q.answer == 0 && q.options == ["الرياض", "جدة", "مكة المكرمة", "الدمام"],
               "clean good mcq \(q)")
    } else {
        failures.append("clean rejected a good mcq")
    }
    let spaced = #"{"type":"MCQ","text":"  ما   عاصمة المملكة؟ ","options":["الرياض"," جدة ","مكة","الدمام"],"answer":"B"}"#
    if let q = cleaned(spaced) {
        expect(q.answer == 1 && q.text == "ما عاصمة المملكة؟" && q.options[1] == "جدة", "clean letter answer \(q)")
    } else {
        failures.append("clean rejected answer \"B\"")
    }
    expect(cleaned(mcq(four, answer: #""2""#))?.answer == 2, "clean answer \"2\"")
    expect(cleaned(mcq(four, answer: "3"))?.answer == 3, "clean answer 3")
    let rejected: [(String, String)] = [
        (mcq(#"["الرياض","الرياض","الرياض","الرياض"]"#, answer: "0"), "4 identical options"),
        (mcq(#"["الرياض","الرياض!","جدة","مكة"]"#, answer: "0"), "options equal after normalising"),
        (mcq(#"["الرياض","جدة","مكة","جميع ما سبق"]"#, answer: "0"), "جميع ما سبق"),
        (mcq(#"["Riyadh","Jeddah","Makkah","All of the above"]"#, answer: "0"), "All of the above"),
        (mcq(#"["الرياض","جدة","مكة"]"#, answer: "0"), "three options"),
        (mcq(#"["الرياض","","مكة","الدمام"]"#, answer: "0"), "an empty option"),
        (mcq(#"["الرياض","جدة","مكة",""# + String(repeating: "ب", count: 91) + #""]"#, answer: "0"), "an option over 90"),
        (mcq(four, answer: "4"), "answer 4"),
        (mcq(four, answer: "-1"), "answer -1"),
        (mcq(four, answer: "true"), "answer true for mcq"),
        (mcq(four, answer: "1.5"), "answer 1.5"),
        (mcq(four, answer: #""E""#), "answer \"E\""),
        (#"{"type":"mcq","text":"abc","options":["a","b","c","d"],"answer":0}"#, "a stem under 5"),
        (#"{"type":"essay","text":"اكتب فقرة عن الوطن","answer":0}"#, "type essay"),
        (tf(#""ربما""#), "tf ربما"),
        (tf("1"), "tf answer the number 1"),
        (#"["not","a","dict"]"#, "not an object"),
    ]
    for (json, what) in rejected {
        expect(cleaned(json) == nil, "clean accepted: \(what)")
    }
    let tfCases: [(String, Int)] = [(#""صح""#, 0), (#""خطأ""#, 1), (#"" True ""#, 0), (#""f""#, 1), ("true", 0), ("false", 1)]
    for (answer, want) in tfCases {
        let q = cleaned(tf(answer))
        expect(q?.kind == .tf && q?.answer == want && q?.options.isEmpty == true, "clean tf \(answer) -> \(String(describing: q))")
    }

    // 2. balance: 20 MCQ -> each letter 5 times, never three in a row, the right option kept
    var questions = (0..<20).map { i in
        Question(kind: .mcq, text: "سؤال \(i)", options: ["a\(i)", "b\(i)", "c\(i)", "d\(i)"], answer: i % 3 == 0 ? 0 : 2)
    }
    questions.append(Question(kind: .tf, text: "عبارة", options: [], answer: 1))
    let before = questions
    for seed in UInt64(1)...UInt64(40) {
        var qs = before
        ExamMaker.balance(&qs, seed: seed)
        let letters = qs.filter { $0.kind == .mcq }.map { $0.answer }
        for letter in 0..<4 {
            expect(letters.filter { $0 == letter }.count == 5, "balance seed \(seed): letter \(letter) in \(letters)")
        }
        expect(!ExamMaker.hasTripleRun(letters), "balance seed \(seed): three in a row \(letters)")
        for (a, b) in zip(before, qs) where a.kind == .mcq {
            expect(b.options[b.answer] == a.options[a.answer] && Set(b.options) == Set(a.options),
                   "balance seed \(seed): right option lost in \(b)")
        }
        expect(qs.last == before.last, "balance seed \(seed): true/false changed")
    }
    var once = before, again = before
    ExamMaker.balance(&once, seed: 7)
    ExamMaker.balance(&again, seed: 7)
    expect(once == again, "balance with a seed is not repeatable")
    expect(ExamMaker.hasTripleRun([0, 1, 1, 1]) && !ExamMaker.hasTripleRun([0, 0, 1, 1, 0, 0]), "hasTripleRun")

    // 3. parseJSON: fences, prose around the object, junk
    let fenced = ExamMaker.parseJSON("```json\n{\"questions\":[{\"type\":\"tf\",\"text\":\"الشمس نجم\",\"answer\":true}]}\n```")
    let fencedList = fenced["questions"] as? [Any] ?? []
    expect(fencedList.count == 1 && fencedList.first.flatMap(ExamMaker.clean)?.answer == 0, "parseJSON fenced \(fenced)")
    let plainFence = ExamMaker.parseJSON("```\n{\"a\": 1}\n```")
    expect(ExamMaker.jsonInt(plainFence["a"]) == 1, "parseJSON plain fence \(plainFence)")
    let prose = ExamMaker.parseJSON("Here you go: {\"bad\":[{\"n\":2,\"why\":\"x\"}]} hope it helps")
    let bad = prose["bad"] as? [Any] ?? []
    expect(bad.count == 1 && ExamMaker.reviewNumber((bad.first as? [String: Any])?["n"]) == 2, "parseJSON prose \(prose)")
    expect(ExamMaker.parseJSON("no json here").isEmpty, "parseJSON junk")
    expect(ExamMaker.reviewNumber("3") == 3 && ExamMaker.reviewNumber(true) == nil, "reviewNumber")

    // 4. pickModel on sample /models lists
    let picks: [(String, [String], String?)] = [
        ("gemini", ["models/gemini-3.8-flash", "models/gemini-3.8-flash-lite", "models/gemini-3.8-pro-preview"], "gemini-3.8-flash"),
        ("alibaba", ["qwen-plus-2025-12-01", "qwen-plus", "qwen-vl-max"], "qwen-plus"),
        ("groq", ["openai/gpt-oss-20b", "openai/gpt-oss-120b", "llama-3.1-8b-instant"], "openai/gpt-oss-120b"),
        ("deepseek", ["deepseek-flash", "deepseek-v4-pro", "deepseek-reasoner"], "deepseek-flash"),
        ("gemini", ["models/gemini-2.5-flash", "models/gemini-3.1-flash", "models/gemini-3.2-flash-preview"], "gemini-3.1-flash"),
        ("openrouter", ["openai/gpt-4o", "meta/llama-4:free"], "meta/llama-4:free"),
        ("groq", ["whisper-large-v3"], nil),
    ]
    for (provider, ids, want) in picks {
        let got = AIProviders.pickModel(provider, ids: ids)
        expect(got == want, "pickModel \(provider) \(ids) -> \(got ?? "nil"), want \(want ?? "nil")")
    }
    expect(AIProviders.all.map { $0.id } == ["gemini", "alibaba", "groq", "cerebras", "mistral", "openrouter", "deepseek"],
           "provider order")

    // 5. book text: Arabic fix, tidy, page range
    let backwards = ["في", "من", "على"].map(BookRules.reversed).joined(separator: " ")
    expect(BookRules.fixArabic(backwards) == "على من في", "fixArabic reversed line: \(BookRules.fixArabic(backwards))")
    let forward = "ذهب الولد إلى المدرسة في الصباح من البيت"
    expect(BookRules.fixArabic(forward) == forward, "fixArabic kept a forward line")
    expect(BookRules.fixArabic("\u{FEFB}") == "\u{0644}\u{0627}", "fixArabic NFKC")
    expect(BookRules.tidy("a  \t b\n\n\n\nc  ") == "a b\n\nc", "tidy")
    expect((try? BookRules.checkRange(from: 1, to: 30, pages: 100)) != nil, "checkRange 1-30")
    for (a, b) in [(0, 5), (5, 4), (90, 101)] {
        expect((try? BookRules.checkRange(from: a, to: b, pages: 100)) == nil, "checkRange \(a)-\(b) accepted")
    }
    do {
        try BookRules.checkRange(from: 1, to: 31, pages: 100)
        failures.append("checkRange 1-31 accepted")
    } catch {
        expect(error.localizedDescription == "اختر 30 صفحة على الأكثر للاختبار الواحد", "checkRange message \(error)")
    }

    // 6. the review's question list, as Python's json.dumps writes it
    let shown = ExamMaker.shownJSON([Question(kind: .mcq, text: "س", options: ["a", "b", "c", "d"], answer: 2),
                                     Question(kind: .tf, text: "ع \"x\"", options: [], answer: 1)])
    expect(shown == #"[{"n": 1, "type": "mcq", "text": "س", "options": ["a", "b", "c", "d"], "answer": 2}, {"n": 2, "type": "tf", "text": "ع \"x\"", "answer": false}]"#,
           "shownJSON \(shown)")
    return failures
}

if args.count >= 2 && args[1] == "--exam-selftest" {
    let failures = examSelfTest()
    for f in failures { print("FAIL: \(f)") }
    print(failures.isEmpty ? "exam self-test: ok" : "exam self-test: \(failures.count) failure(s)")
    exit(failures.isEmpty ? 0 : 1)
}

struct GeometryInput: Decodable {
    let questionCount: Int
    let rtl: Bool
    let sections: [QuizSection]
}

if args.count >= 4 && args[1] == "--geometry" {
    let inURL = URL(fileURLWithPath: args[2])
    let outURL = URL(fileURLWithPath: args[3])
    let layoutPath = args.count >= 5 ? args[4] : "shared/sheet-layouts.json"
    do {
        let geometryLayouts = try SheetLayouts.load(from: URL(fileURLWithPath: layoutPath))
        let inputs = try JSONDecoder().decode([GeometryInput].self, from: Data(contentsOf: inURL))
        var sheets: [QuizSheet?] = []
        var failed = 0
        for input in inputs {
            do {
                sheets.append(try SheetGeometry.compute(questionCount: input.questionCount, sections: input.sections,
                                                        rtl: input.rtl, layout: geometryLayouts))
            } catch {
                sheets.append(nil)
                failed += 1
            }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(sheets).write(to: outURL, options: .atomic)
        print("wrote \(sheets.count) sheets (\(failed) not laid out) to \(outURL.path)")
        exit(0)
    } catch {
        print("geometry: \(error)")
        exit(1)
    }
}

guard args.count >= 3 else {
    print("usage: OMRCheck <folder> <sheet-layouts.json> | OMRCheck --xlsx <out.xlsx> | OMRCheck --geometry <in.json> <out.json> [sheet-layouts.json]")
    exit(2)
}
let folder = URL(fileURLWithPath: args[1], isDirectory: true)
let layouts: SheetLayouts
do {
    layouts = try SheetLayouts.load(from: URL(fileURLWithPath: args[2]))
} catch {
    print("cannot read layouts: \(error)")
    exit(2)
}

let files = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
    .filter { $0.pathExtension == "json" }
    .sorted { $0.lastPathComponent < $1.lastPathComponent }
if files.isEmpty {
    print("no truth files in \(folder.path)")
    exit(2)
}

var badSheets = 0
var notFound = 0
var totalQ = 0
var wrongQ = 0
var totalMs = 0.0

for truthURL in files {
    let name = truthURL.deletingPathExtension().lastPathComponent
    guard let data = try? Data(contentsOf: truthURL),
          let truth = try? JSONDecoder().decode(Truth.self, from: data) else {
        print("\(name): bad truth file")
        badSheets += 1
        continue
    }
    guard let gray = loadGray(truthURL.deletingPathExtension().appendingPathExtension("jpg")) else {
        print("\(name): cannot load image")
        notFound += 1
        continue
    }
    let start = DispatchTime.now().uptimeNanoseconds
    let result = SheetReader.read(gray, layouts: layouts, questionCount: truth.questionCount,
                                  questionBubbles: truth.sheet?.questionBubbles)
    let ms = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    totalMs += ms
    guard let res = result else {
        print("\(name) [\(truth.questionCount)q]: NOT FOUND (\(Int(ms)) ms)")
        notFound += 1
        continue
    }
    var errs: [String] = []
    if res.studentId != truth.studentId {
        errs.append("id '\(res.studentId)' != '\(truth.studentId)'")
    }
    if res.quizCode != truth.quizCode {
        errs.append("code \(res.quizCode) != \(truth.quizCode)")
    }
    if res.version != truth.version {
        errs.append("version \(res.version) != \(truth.version)")
    }
    for (q, pair) in zip(res.answers, truth.answers).enumerated() {
        totalQ += 1
        if pair.0 != pair.1 {
            wrongQ += 1
            errs.append("q\(q + 1) '\(pair.0)' != '\(pair.1)' \(res.darkness[q])")
        }
    }
    let status = errs.isEmpty ? "ok" : errs.prefix(6).joined(separator: "; ")
    print("\(name) [\(truth.questionCount)q] \(Int(ms)) ms: \(status)")
    if !errs.isEmpty { badSheets += 1 }
}

let found = files.count - notFound
print("")
print("sheets: \(files.count); not found: \(notFound); found with errors: \(badSheets); wrong answers: \(wrongQ)/\(totalQ); mean \(Int(totalMs / Double(max(files.count, 1)))) ms")
if badSheets > 0 || Double(notFound) > 0.15 * Double(files.count) || found == 0 {
    exit(1)
}
exit(0)
