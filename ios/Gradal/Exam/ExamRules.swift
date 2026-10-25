import Foundation

/// The question writer's pure rules (port of reference/exam_maker.py and the text part of reference/books.py):
/// prompts, JSON parsing, the local checks on each question, the answer-letter balance and the Arabic text fix.
/// Foundation only, so it is also compiled into OMRCheck (`--exam-selftest`). The steps that talk to the
/// providers and read the PDF are in ExamMaker.swift and BookText.swift.

/// A message for the teacher, in Arabic.
struct ExamError: LocalizedError, Equatable {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// A message for the teacher about the book or its pages, in Arabic.
struct BookError: LocalizedError, Equatable {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

// MARK: - Book text

enum BookRules {
    /// Pages per exam: enough for a unit, small enough for every provider.
    static let maxPages = 30
    static let minCharsPerPage = 120
    static let commonArabic: Set<String> = ["في", "من", "على", "إلى", "الى", "عن", "أن", "ان", "التي", "الذي",
                                            "هذا", "هذه", "مع", "كان", "لا", "ما", "هو", "هي"]

    /// Pages a...b (1-based) of a book of `pages` pages; reference/books.py _check_range.
    @discardableResult
    static func checkRange(from a: Int, to b: Int, pages: Int) throws -> (from: Int, to: Int) {
        guard 1 <= a, a <= b, b <= pages else {
            throw BookError("الصفحات من 1 إلى \(pages)، والأولى قبل الأخيرة")
        }
        if b - a + 1 > maxPages {
            throw BookError("اختر \(maxPages) صفحة على الأكثر للاختبار الواحد")
        }
        return (a, b)
    }

    static func isArabic(_ u: Unicode.Scalar) -> Bool { (0x0600...0x06FF).contains(u.value) }

    /// Presentation forms -> letters (NFKC); lines stored backwards (visual order) -> turned around, but only
    /// when the reversed common words clearly outnumber the forward ones.
    static func fixArabic(_ raw: String) -> String {
        var text = raw.precomposedStringWithCompatibilityMapping
        var words: [String] = []
        var word = String.UnicodeScalarView()
        for u in text.unicodeScalars {
            if isArabic(u) {
                word.append(u)
            } else if !word.isEmpty {
                words.append(String(word))
                word = String.UnicodeScalarView()
            }
        }
        if !word.isEmpty { words.append(String(word)) }
        let forward = words.filter { commonArabic.contains($0) }.count
        let backward = words.filter { commonArabic.contains(reversed($0)) }.count
        if backward > forward * 2 && backward >= 3 {
            text = text.split(omittingEmptySubsequences: false, whereSeparator: { $0.isNewline })
                .map { reversed(String($0)) }
                .joined(separator: "\n")
        }
        return text
    }

    /// Code point order reversed (Python's s[::-1]).
    static func reversed(_ s: String) -> String {
        String(String.UnicodeScalarView(s.unicodeScalars.reversed()))
    }

    /// The pages' joined text as the AI gets it: Arabic fixed, blank runs and spaces squeezed, trimmed.
    static func tidy(_ raw: String) -> String {
        var text = raw
        if text.unicodeScalars.contains(where: isArabic) {
            text = fixArabic(text)
        }
        text = Pattern.replace(#"\n{3,}"#, in: text, with: "\n\n")
        text = Pattern.replace(#"[ \t]+"#, in: text, with: " ")
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// False when the pages are (mostly) scanned images: then Gemini reads the PDF itself.
    static func isReadable(_ text: String, pages: Int) -> Bool {
        Double(text.unicodeScalars.count) >= Double(minCharsPerPage) * Double(pages) * 0.5
    }
}

// MARK: - Questions

enum ExamMaker {
    static let maxText = 60000
    static let rounds = 3
    static let minQuestions = 5
    static let maxQuestions = 60

    static let sectionNames: [String: [Question.Kind: String]] = [
        "ar": [.mcq: "اختيار من متعدد", .tf: "صح أو خطأ"],
        "en": [.mcq: "Multiple Choice", .tf: "True or False"],
    ]

    static let transcribePrompt = "Transcribe all the text of these pages faithfully, in their original "
        + "language and reading order. Plain text only, no commentary."

    private static let banned = #"(all of the above|none of the above|جميع ما سبق|كل ما سبق|لا شيء مما سبق|جميع الإجابات)"#

    // MARK: prompts

    static func systemPrompt(_ language: String) -> String {
        if language == "ar" {
            return "أنت معلم سعودي خبير يكتب أسئلة اختبار مدرسي من صفحات الكتاب المعطاة فقط، بالعربية الفصحى السليمة. "
                + "القواعد: كل سؤال يُجاب من النص وحده؛ لا تكرار في المعنى؛ عبارة السؤال قصيرة وواضحة (لا تتجاوز 150 حرفًا)؛ "
                + "في الاختيار من متعدد أربعة بدائل مختلفة ومعقولة وقصيرة، واحد منها فقط صحيح، ولا «جميع ما سبق» ولا «لا شيء مما سبق»؛ "
                + "في الصح والخطأ عبارة واحدة صحيحة تمامًا أو خاطئة تمامًا بحسب النص، بلا نفي مزدوج. "
                + "أعد JSON فقط بهذا الشكل: "
                + #"{"questions":[{"type":"mcq","text":"...","options":["...","...","...","..."],"answer":0},"#
                + #"{"type":"tf","text":"...","answer":true}]} حيث answer في الاختيار رقم البديل الصحيح من 0 إلى 3."#
        }
        return "You are an experienced school teacher writing a classroom test only from the given textbook pages, in "
            + "clear correct English. Rules: every question is answerable from the text alone; no two questions test the same "
            + "point; stems are short and clear (max 150 characters); multiple choice has four different, plausible, short "
            + "options with exactly one correct, never 'all/none of the above'; true/false statements are fully true or "
            + "fully false according to the text, no double negatives. Return JSON only, shaped: "
            + #"{"questions":[{"type":"mcq","text":"...","options":["...","...","...","..."],"answer":0},"#
            + #"{"type":"tf","text":"...","answer":true}]} where a multiple-choice answer is the index 0-3 of the correct option."#
    }

    /// `need`: how many of each kind to write now; `avoid`: the stems already written (at most 60 are listed).
    static func userPrompt(_ request: PaperRequest, text: String, need: [Question.Kind: Int], avoid: [String]) -> String {
        let ar = request.language == "ar"
        var asks: [String] = []
        let mcq = need[.mcq] ?? 0, tf = need[.tf] ?? 0
        if mcq != 0 { asks.append("\(mcq) " + (ar ? "سؤال اختيار من متعدد" : "multiple-choice questions")) }
        if tf != 0 { asks.append("\(tf) " + (ar ? "عبارة صح أو خطأ" : "true/false statements")) }
        let subject = request.subject.isEmpty ? "-" : request.subject
        let grade = request.grade.isEmpty ? "-" : request.grade
        var head = ar
            ? "المادة: \(subject). الصف: \(grade). اكتب " + asks.joined(separator: " و") + "، موزعة على النص كله."
            : "Subject: \(subject). Grade: \(grade). Write " + asks.joined(separator: " and ") + ", spread over the whole text."
        if !request.notes.isEmpty {
            head += (ar ? "\nملاحظة المعلم: " : "\nTeacher's note: ") + request.notes
        }
        if !avoid.isEmpty {
            head += (ar ? "\nلا تكرر هذه الأسئلة الموجودة:\n" : "\nDo not repeat these existing questions:\n")
                + avoid.prefix(60).map { "- \($0)" }.joined(separator: "\n")
        }
        return head + (ar ? "\n\nنص الصفحات:\n" : "\n\nThe pages:\n") + text
    }

    /// The second provider's review: it lists the faulty questions by number (1-based).
    static func reviewMessages(_ request: PaperRequest, text: String, items: [Question]) -> [[String: String]] {
        let ar = request.language == "ar"
        let system = ar
            ? "أنت مراجع أسئلة دقيق. افحص كل سؤال على النص: هل الإجابة المعلّمة صحيحة يقينًا من النص؟ هل يوجد بديل آخر صحيح أيضًا؟ "
                + #"هل اللغة سليمة والسؤال واضح؟ أعد JSON فقط: {"bad":[{"n":رقم,"why":"السبب"}]} ولا تذكر السليم."#
            : "You are a strict question reviewer. Check each question against the text: is the marked answer certainly "
                + "correct from the text? Is another option also correct? Is the language correct and the stem clear? Return JSON "
                + #"only: {"bad":[{"n":number,"why":"reason"}]} listing only the faulty ones."#
        let user = (ar ? "الأسئلة:\n" : "Questions:\n") + shownJSON(items)
            + (ar ? "\n\nالنص:\n" : "\n\nThe text:\n") + text
        return [["role": "system", "content": system], ["role": "user", "content": user]]
    }

    /// The questions as Python's json.dumps(..., ensure_ascii=False) writes them, keys in the reference's order
    /// (n, type, text, options, answer; true/false has no options and a true/false answer).
    static func shownJSON(_ items: [Question]) -> String {
        let parts = items.enumerated().map { pair -> String in
            let i = pair.offset, q = pair.element
            var s = "{\"n\": \(i + 1), \"type\": \(jsonString(q.kind.rawValue)), \"text\": \(jsonString(q.text))"
            if q.kind == .mcq {
                s += ", \"options\": [" + q.options.map(jsonString).joined(separator: ", ") + "]"
                s += ", \"answer\": \(q.answer)"
            } else {
                s += ", \"answer\": " + (q.answer == 0 ? "true" : "false")
            }
            return s + "}"
        }
        return "[" + parts.joined(separator: ", ") + "]"
    }

    static func jsonString(_ s: String) -> String {
        var out = "\""
        for u in s.unicodeScalars {
            switch u {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            default:
                if u.value < 0x20 {
                    out += String(format: "\\u%04x", u.value)
                } else {
                    out.unicodeScalars.append(u)
                }
            }
        }
        return out + "\""
    }

    // MARK: parsing and checks

    /// The provider's reply as a JSON object: ``` fences removed; else the outermost {...}; else empty.
    static func parseJSON(_ reply: String) -> [String: Any] {
        var t = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        t = Pattern.replace(#"^```(?:json)?\s*|\s*```$"#, in: t, with: "")
        if let obj = try? JSONSerialization.jsonObject(with: Data(t.utf8)) {
            return obj as? [String: Any] ?? [:]
        }
        if let m = Pattern.firstMatch(#"\{.*\}"#, in: t, options: [.dotMatchesLineSeparators]),
           let obj = try? JSONSerialization.jsonObject(with: Data(m.utf8)) as? [String: Any] {
            return obj
        }
        return [:]
    }

    /// Lower-cased, every run of non-word characters made one space (for "is this the same question?").
    static func norm(_ s: String) -> String {
        Pattern.replace(#"[^\p{L}\p{N}_]+"#, in: s.lowercased(), with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// One question from the provider's JSON, or nil when it fails the local checks (reference clean_item):
    /// mcq: four different non-empty options of at most 90 characters, none "all/none of the above", answer
    /// 0-3 (or "0"-"3", "A"-"D"); tf: answer true/false (or "true", "صح", "صحيح", "t", "1" / "false", "خطأ",
    /// "خاطئ", "f", "0"); the stem 5-220 characters.
    static func clean(_ raw: Any) -> Question? {
        guard let d = raw as? [String: Any] else { return nil }
        let kindText = pyString(d["type"]).lowercased()
        let text = squash(pyString(d["text"]))
        let length = text.unicodeScalars.count
        guard let kind = Question.Kind(rawValue: kindText), length >= 5, length <= 220 else { return nil }

        if kind == .tf {
            var value: Bool?
            if let s = d["answer"] as? String {
                let word = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if ["true", "صح", "صحيح", "t", "1"].contains(word) {
                    value = true
                } else if ["false", "خطأ", "خاطئ", "f", "0"].contains(word) {
                    value = false
                }
            } else {
                value = jsonBool(d["answer"])
            }
            guard let value else { return nil }
            return Question(kind: .tf, text: text, options: [], answer: value ? 0 : 1)
        }

        guard let list = d["options"] as? [Any] else { return nil }
        let options = list.map { squash(pyString($0)) }
        guard options.count == 4,
              !options.contains(where: { $0.isEmpty || $0.unicodeScalars.count > 90 }),
              Set(options.map(norm)).count == 4,
              !options.contains(where: { Pattern.firstMatch(banned, in: $0, options: [.caseInsensitive]) != nil })
        else { return nil }

        var answer: Int?
        if let s = d["answer"] as? String {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if let n = decimalValue(t) {
                answer = n
            } else if t.count == 1, let i = ["A", "B", "C", "D"].firstIndex(of: t.uppercased()) {
                answer = i
            }
        } else {
            answer = jsonInt(d["answer"])
        }
        guard let answer, answer >= 0, answer <= 3 else { return nil }
        return Question(kind: .mcq, text: text, options: options, answer: answer)
    }

    /// Shuffles the options of each MCQ so the correct letters are spread evenly (each letter as often as the
    /// others, within one) and never three equal letters in a row; the right option stays the right one.
    /// A seed makes it repeatable (the self-test); nil uses the system generator.
    static func balance(_ questions: inout [Question], seed: UInt64?) {
        if let seed {
            var rng = SplitMix64(seed: seed)
            balance(&questions, using: &rng)
        } else {
            var rng = SystemRandomNumberGenerator()
            balance(&questions, using: &rng)
        }
    }

    static func balance<G: RandomNumberGenerator>(_ questions: inout [Question], using rng: inout G) {
        let mcq = questions.indices.filter { questions[$0].kind == .mcq }
        var pool = (0..<mcq.count).map { $0 % 4 }
        for _ in 0..<200 {
            pool.shuffle(using: &rng)
            if !hasTripleRun(pool) { break }
        }
        for (index, target) in zip(mcq, pool) {
            var q = questions[index]
            guard q.options.count == 4, q.answer >= 0, q.answer <= 3 else { continue }
            let right = q.options[q.answer]
            var others = q.options.enumerated().filter { $0.offset != q.answer }.map { $0.element }
            others.shuffle(using: &rng)
            others.insert(right, at: target)
            q.options = others
            q.answer = target
            questions[index] = q
        }
    }

    static func hasTripleRun(_ letters: [Int]) -> Bool {
        guard letters.count >= 3 else { return false }
        for i in 2..<letters.count where letters[i] == letters[i - 1] && letters[i - 1] == letters[i - 2] {
            return true
        }
        return false
    }

    // MARK: JSON values as Python sees them

    /// Python's str(v or ""): nil, null, false, 0 and "" give "".
    static func pyString(_ v: Any?) -> String {
        guard let v, !(v is NSNull) else { return "" }
        if let s = v as? String { return s }
        if let n = v as? NSNumber {
            if isBoolNumber(n) { return n.boolValue ? "True" : "" }
            if n.doubleValue == 0 { return "" }
            return CFNumberIsFloatType(n as CFNumber) ? "\(n.doubleValue)" : n.stringValue
        }
        return String(describing: v)
    }

    /// A JSON true/false (never a number).
    static func jsonBool(_ v: Any?) -> Bool? {
        guard let v, let n = v as? NSNumber, isBoolNumber(n) else { return nil }
        return n.boolValue
    }

    /// A JSON whole number (never true/false or a fraction).
    static func jsonInt(_ v: Any?) -> Int? {
        guard let v, let n = v as? NSNumber, !isBoolNumber(n), !CFNumberIsFloatType(n as CFNumber) else { return nil }
        return n.intValue
    }

    static func isBoolNumber(_ n: NSNumber) -> Bool {
        CFGetTypeID(n) == CFBooleanGetTypeID()
    }

    /// Python's s.isdigit() then int(s), for decimal digits of any script ("3", "٣").
    static func decimalValue(_ s: String) -> Int? {
        guard !s.isEmpty, s.unicodeScalars.count <= 18 else { return nil }
        var n = 0
        for u in s.unicodeScalars {
            guard u.properties.numericType == .decimal, let v = u.properties.numericValue else { return nil }
            n = n * 10 + Int(v)
        }
        return n
    }

    /// A review's question number: an index from a whole number or a string of digits.
    static func reviewNumber(_ v: Any?) -> Int? {
        if let s = v as? String { return decimalValue(s) }
        guard let n = jsonInt(v), n >= 0 else { return nil }
        return n
    }

    /// Every whitespace run made one space, trimmed.
    static func squash(_ s: String) -> String {
        Pattern.replace(#"\s+"#, in: s, with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// A small, repeatable generator (SplitMix64) for the seeded balance.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// NSRegularExpression in two calls.
enum Pattern {
    static func replace(_ pattern: String, in s: String, with template: String,
                        options: NSRegularExpression.Options = []) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern, options: options) else { return s }
        let range = NSRange(s.startIndex..<s.endIndex, in: s)
        return re.stringByReplacingMatches(in: s, options: [], range: range,
                                           withTemplate: NSRegularExpression.escapedTemplate(for: template))
    }

    static func firstMatch(_ pattern: String, in s: String, options: NSRegularExpression.Options = []) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: options) else { return nil }
        let range = NSRange(s.startIndex..<s.endIndex, in: s)
        guard let m = re.firstMatch(in: s, options: [], range: range), let r = Range(m.range, in: s) else { return nil }
        return String(s[r])
    }
}
