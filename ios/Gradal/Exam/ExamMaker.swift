import Foundation

/// Writes a test from a book's pages (port of reference/exam_maker.py ExamJob): the pages' text (Gemini
/// transcribes scanned pages) -> one provider writes the questions as JSON -> local checks (ExamRules.swift)
/// -> a second linked provider reviews them against the text and the failing ones are written again -> MCQ
/// first, then true/false -> the answer letters are balanced. The teacher reviews the draft afterwards.
extension ExamMaker {
    /// True while a test is being written (one at a time, like the reference's Jobs).
    @MainActor private static var running = false

    /// The request as the reference normalises it: trimmed and cut to length, language "ar" or "en",
    /// counts never negative.
    static func normalized(_ r: PaperRequest) -> PaperRequest {
        func cut(_ s: String, _ n: Int) -> String {
            String(s.trimmingCharacters(in: .whitespacesAndNewlines).prefix(n))
        }
        var out = r
        out.name = cut(r.name, 80)
        out.subject = cut(r.subject, 60)
        out.grade = cut(r.grade, 60)
        out.language = r.language == "ar" ? "ar" : "en"
        out.notes = cut(r.notes, 500)
        out.mcq = max(0, r.mcq)
        out.tf = max(0, r.tf)
        return out
    }

    /// Checks what the teacher asked for before any provider is called (reference normalise_request).
    static func validate(_ request: PaperRequest, bookPages: Int) throws {
        let r = normalized(request)
        if r.name.isEmpty { throw ExamError("اكتب اسم الاختبار") }
        let total = r.mcq + r.tf
        if total < minQuestions || total > maxQuestions {
            throw ExamError("مجموع الأسئلة من \(minQuestions) إلى \(maxQuestions)")
        }
        if r.bookId.isEmpty { throw ExamError("اختر الكتاب") }
        try BookRules.checkRange(from: r.pageFrom, to: r.pageTo, pages: bookPages)
    }

    /// Writes the questions (MCQ first, then true/false); progress gets Arabic status lines. Returns the
    /// questions and the ids of the providers that wrote or reviewed them.
    @MainActor
    static func write(_ request: PaperRequest, bookURL: URL, ai: AIClient,
                      progress: @escaping (String) -> Void) async throws -> (questions: [Question], providers: [String]) {
        if running { throw ExamError("اختبار آخر يُكتب الآن، انتظره") }
        running = true
        defer { running = false }
        let req = normalized(request)
        do {
            return try await run(req, bookURL: bookURL, ai: ai, progress: progress)
        } catch let e as ExamError {
            throw e
        } catch let e as AIError {
            throw e
        } catch let e as BookError {
            throw e
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ExamError("خطأ غير متوقع أثناء كتابة الأسئلة")
        }
    }

    @MainActor
    private static func run(_ req: PaperRequest, bookURL: URL, ai: AIClient,
                            progress: @escaping (String) -> Void) async throws -> (questions: [Question], providers: [String]) {
        progress("أقرأ صفحات الكتاب…")
        let text = try await sourceText(req, bookURL: bookURL, ai: ai, progress: progress)
        let want: [Question.Kind: Int] = [.mcq: req.mcq, .tf: req.tf]
        let kinds: [Question.Kind] = [.mcq, .tf]
        func missing(_ have: [Question]) -> [Question.Kind: Int] {
            var need: [Question.Kind: Int] = [:]
            for k in kinds { need[k] = (want[k] ?? 0) - have.filter { $0.kind == k }.count }
            return need
        }

        var used: [String] = []
        var items: [Question] = []
        for round in 0..<rounds {
            let need = missing(items)
            if !need.values.contains(where: { $0 != 0 }) { break }
            progress(round == 0 ? "أكتب الأسئلة…" : "أكمل الأسئلة الناقصة…")
            let more = try await writeRound(req, text: text, need: need, have: items, exclude: [], ai: ai, used: &used)
            items += more
        }

        // a second provider reviews; the faulty questions are written again by the first
        let writer = used.first
        let reviewers = ai.linked.map { $0.id }.filter { $0 != writer }
        if !reviewers.isEmpty && !items.isEmpty {
            progress("مزوّد ثانٍ يراجع الأسئلة على النص…")
            do {
                let reply = try await ai.chat(reviewMessages(req, text: text, items: items), jsonMode: true,
                                              exclude: writer.map { [$0] } ?? [], temperature: 0.1)
                used.append(reply.provider)
                let listed = parseJSON(reply.text)["bad"] as? [Any] ?? []
                var bad = Set<Int>()
                for entry in listed {
                    guard let d = entry as? [String: Any], let n = reviewNumber(d["n"]) else { continue }
                    let i = n - 1
                    if i >= 0 && i < items.count { bad.insert(i) }
                }
                if !bad.isEmpty {
                    progress("أعيد كتابة \(bad.count) سؤالًا لم تجتز المراجعة…")
                    let kept = items.enumerated().filter { !bad.contains($0.offset) }.map { $0.element }
                    let rejected = bad.sorted().map { items[$0] }
                    let rewritten = try await writeRound(req, text: text, need: missing(kept), have: kept + rejected,
                                                         exclude: [], ai: ai, used: &used)
                    items = kept + rewritten
                }
            } catch is AIError {
                progress("تعذّرت المراجعة الثانية، فبقيت الأسئلة كما كُتبت")
            }
        }

        items = kinds.flatMap { k in items.filter { $0.kind == k } }       // MCQ first, then true/false
        if items.isEmpty {
            throw ExamError("لم يُكتب أي سؤال صالح. جرّب صفحات أخرى أو مزوّدًا آخر.")
        }
        balance(&items, seed: nil)
        if missing(items).values.contains(where: { $0 != 0 }) {
            progress("كُتب \(items.count) سؤالًا، أقل من المطلوب: أكمل الباقي يدويًا في المراجعة")
        }
        progress("جاهز للمراجعة")
        return (items, Array(Set(used)).sorted())
    }

    /// The pages' text, cut to maxText; scanned pages are transcribed by Gemini.
    @MainActor
    private static func sourceText(_ req: PaperRequest, bookURL: URL, ai: AIClient,
                                   progress: @escaping (String) -> Void) async throws -> String {
        let a = req.pageFrom, b = req.pageTo
        let read = try await Task.detached(priority: .userInitiated) {
            try BookText.text(bookURL, from: a, to: b)
        }.value
        var text = read.text
        if !read.readable {
            progress("صفحات الكتاب صور: يقرؤها Gemini…")
            let pdf = try await Task.detached(priority: .userInitiated) {
                try BookText.subset(bookURL, from: a, to: b)
            }.value
            text = try await ai.geminiPDF(pdf, prompt: transcribePrompt)
            if text.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars.count < 200 {
                throw ExamError("لم يُستخرج نص كافٍ من هذه الصفحات")
            }
        }
        return String(String.UnicodeScalarView(text.unicodeScalars.prefix(maxText)))
    }

    /// One writing call: asks for `need`, keeps the questions that pass the checks, are not repeats of `have`
    /// and fit the counts.
    @MainActor
    private static func writeRound(_ req: PaperRequest, text: String, need: [Question.Kind: Int], have: [Question],
                                   exclude: Set<String>, ai: AIClient, used: inout [String]) async throws -> [Question] {
        let messages = [["role": "system", "content": systemPrompt(req.language)],
                        ["role": "user", "content": userPrompt(req, text: text, need: need, avoid: have.map { $0.text })]]
        let reply = try await ai.chat(messages, jsonMode: true, exclude: exclude, temperature: 0.7)
        used.append(reply.provider)
        var seen = Set(have.map { norm($0.text) })
        var out: [Question] = []
        for raw in parseJSON(reply.text)["questions"] as? [Any] ?? [] {
            guard let q = clean(raw) else { continue }
            let key = norm(q.text)
            if !seen.contains(key) && (need[q.kind] ?? 0) > out.filter({ $0.kind == q.kind }).count {
                seen.insert(key)
                out.append(q)
            }
        }
        return out
    }
}
