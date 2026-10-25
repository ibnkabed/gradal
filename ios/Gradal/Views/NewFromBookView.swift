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
    @State private var mcq = 15
    @State private var tf = 5
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

                Section("عدد الأسئلة") {
                    Stepper("اختيار من متعدد: \(mcq)", value: $mcq, in: 0...60)
                    Stepper("صح أو خطأ: \(tf)", value: $tf, in: 0...60)
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
        }
    }

    private func start() {
        guard let book else { return }
        let request = PaperRequest(name: name.trimmingCharacters(in: .whitespaces), subject: subject, grade: grade,
                                   language: language, classIds: classIds, bookId: book.id,
                                   pageFrom: pageFrom, pageTo: pageTo, mcq: mcq, tf: tf, notes: notes)
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
                let paper = Paper(createdAt: Stamp.now(), request: request, questions: result.questions,
                                  providers: result.providers, quizId: nil)
                store.saveDraft(paper)
                onDone(paper.id)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
