import SwiftUI
import UniformTypeIdentifiers

/// A test from a book: the PDF, the pages, how many questions of each kind; the AI writes a draft to review.
struct NewFromBookView: View {
    let onDone: (String) -> Void
    @EnvironmentObject private var store: Store
    @EnvironmentObject private var ai: AIClient
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var subject = ""
    @State private var grade = ""
    @State private var language = "ar"
    @State private var bookId = ""
    @State private var pageFrom = 1
    @State private var pageTo = 10
    @State private var parts: [PaperSection] = PaperSection.defaults("ar")
    @State private var partsEdited = false
    @State private var classIds: [String] = []
    @State private var notes = ""
    @State private var picking = false
    @State private var running = false
    @State private var lines: [String] = []
    @State private var error: String?

    private var book: Book? { store.db.books.first { $0.id == bookId } }

    var body: some View {
        NavigationStack {
            Form {
                if ai.linked.isEmpty {
                    Section {
                        Text("اربط مزوّد ذكاء اصطناعي أولًا من «الإعدادات»: Gemini مجاني ويكفي.")
                            .foregroundColor(.orange)
                    }
                }
                Section("الاختبار") {
                    TextField("اسم الاختبار (مثال: اختبار الفترة الأولى)", text: $name)
                    TextField("المادة", text: $subject)
                    TextField("الصف", text: $grade)
                    Picker("لغة الأسئلة", selection: $language) {
                        Text("العربية").tag("ar")
                        Text("English").tag("en")
                    }
                    .pickerStyle(.segmented)
                }

                Section {
                    Picker("الكتاب", selection: $bookId) {
                        Text("اختر").tag("")
                        ForEach(store.db.books) { b in
                            Text(b.name).tag(b.id)
                        }
                    }
                    Button {
                        picking = true
                    } label: {
                        Label("أضف كتاب PDF", systemImage: "doc.badge.plus")
                    }
                    if let book {
                        Stepper("من صفحة \(pageFrom)", value: $pageFrom, in: 1...max(book.pages, 1))
                        Stepper("إلى صفحة \(pageTo)", value: $pageTo, in: 1...max(book.pages, 1))
                    }
                } header: {
                    Text("الكتاب")
                } footer: {
                    if let book {
                        Text("في الكتاب \(countWord(book.pages, pagesForms)). أرقام الصفحات كما في الملف نفسه، وثلاثون صفحة على الأكثر.")
                    }
                }

                Section {
                    ForEach($parts) { $part in
                        VStack(alignment: .leading, spacing: 6) {
                            TextField("اسم القسم", text: $part.name)
                                .font(.body.weight(.semibold))
                                .onChange(of: part.name) { _, _ in partsEdited = true }
                            Picker("النوع", selection: $part.kind) {
                                Text("اختيار من متعدد").tag(Question.Kind.mcq)
                                Text("صح أو خطأ").tag(Question.Kind.tf)
                            }
                            .pickerStyle(.segmented)
                            Stepper("عدد الأسئلة: \(part.count)", value: $part.count, in: 1...60)
                        }
                        .padding(.vertical, 2)
                    }
                    .onDelete { parts.remove(atOffsets: $0) }
                    .onMove { parts.move(fromOffsets: $0, toOffset: $1) }
                    Button {
                        parts.append(PaperSection(name: language == "ar" ? "السؤال \(ordinal(parts.count + 1))" : "Part \(parts.count + 1)",
                                                  kind: .mcq, count: 5))
                        partsEdited = true
                    } label: {
                        Label("أضف قسمًا", systemImage: "plus")
                    }
                } header: {
                    Text("الأقسام: " + countWord(parts.reduce(0) { $0 + $1.count }, questionsForms))
                } footer: {
                    Text("سمِّ كل قسم كما تريده في الورقة، واختر نوعه وعدد أسئلته. واسحب القسم لحذفه، والمجموع من \(SheetGeometry.minQuestions) إلى \(SheetGeometry.maxQuestions).")
                }

                Section("الفصول") {
                    ClassPicker(selected: $classIds)
                }

                Section("ملاحظة للكاتب (اختياري)") {
                    TextField("مثال: ركّز على المفاهيم لا على الأرقام", text: $notes, axis: .vertical)
                }

                if running || !lines.isEmpty || error != nil {
                    Section {
                        ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                            Text(line).font(.callout)
                        }
                        if running {
                            ProgressView()
                        }
                        if let error {
                            Text(error).foregroundColor(.red)
                        }
                    }
                }
            }
            .navigationTitle("اختبار من كتاب")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("إلغاء") { dismiss() }
                        .disabled(running)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("اكتب الأسئلة") { start() }
                        .disabled(running || ai.linked.isEmpty || book == nil)
                }
            }
            .fileImporter(isPresented: $picking, allowedContentTypes: [.pdf]) { result in
                guard case .success(let url) = result else { return }
                do {
                    let b = try store.addBook(from: url)
                    bookId = b.id
                    pageFrom = 1
                    pageTo = min(b.pages, 10)
                } catch {
                    self.error = error.localizedDescription
                }
            }
            .interactiveDismissDisabled(running)
            .onChange(of: language) { _, lang in
                if !partsEdited { parts = PaperSection.defaults(lang) }
            }
        }
    }

    /// Arabic ordinals for new parts' default names.
    private func ordinal(_ n: Int) -> String {
        let words = ["الأول", "الثاني", "الثالث", "الرابع", "الخامس", "السادس", "السابع", "الثامن", "التاسع", "العاشر"]
        return n <= words.count ? words[n - 1] : String(n)
    }

    /// The written questions (MCQ first, then true/false) dealt to the parts in the paper's order.
    static func assign(_ questions: [Question], to parts: [PaperSection]) -> [Question] {
        var pools: [Question.Kind: [Question]] = [.mcq: questions.filter { $0.kind == .mcq }, .tf: questions.filter { $0.kind == .tf }]
        var out: [Question] = []
        for (i, part) in parts.enumerated() {
            let take = Array((pools[part.kind] ?? []).prefix(part.count))
            pools[part.kind] = Array((pools[part.kind] ?? []).dropFirst(take.count))
            out += take.map { q in var q = q; q.section = i; return q }
        }
        return out
    }

    private func start() {
        guard let book else { return }
        let request = PaperRequest(name: name.trimmingCharacters(in: .whitespaces), subject: subject, grade: grade,
                                   language: language, classIds: classIds, bookId: book.id,
                                   pageFrom: pageFrom, pageTo: pageTo,
                                   mcq: parts.filter { $0.kind == .mcq }.reduce(0) { $0 + $1.count },
                                   tf: parts.filter { $0.kind == .tf }.reduce(0) { $0 + $1.count },
                                   notes: notes, sections: parts)
        error = nil
        lines = []
        do {
            try ExamMaker.validate(request, bookPages: book.pages)
        } catch {
            self.error = error.localizedDescription
            return
        }
        running = true
        Task {
            defer { running = false }
            do {
                let result = try await ExamMaker.write(request, bookURL: store.bookURL(book.id), ai: ai) { line in
                    lines.append(line)
                }
                let paper = Paper(createdAt: Stamp.now(), request: request,
                                  questions: Self.assign(result.questions, to: request.parts),
                                  providers: result.providers, quizId: nil)
                store.saveDraft(paper)
                onDone(paper.id)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
