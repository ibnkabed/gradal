import SwiftUI

/// The questions before (or after) approval: edit the text, the options and the right answer, delete or add,
/// then approve to make the quiz and its papers.
struct PaperReviewView: View {
    let paperId: String
    let onApproved: (Quiz) -> Void
    @EnvironmentObject private var store: Store
    @Environment(\.dismiss) private var dismiss
    @State private var paper: Paper?
    @State private var error: String?
    @State private var confirmDelete = false

    var body: some View {
        Group {
            if let binding = Binding($paper) {
                form(binding)
            } else {
                Text("المسودة غير موجودة.").foregroundColor(.secondary)
            }
        }
        .navigationTitle(paper?.quizId == nil ? "راجع الأسئلة" : "تعديل الأسئلة")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { if paper == nil { paper = store.paper(paperId) } }
    }

    private func form(_ p: Binding<Paper>) -> some View {
        let lang = p.wrappedValue.request.language
        let letters = lang == "ar" ? Grading.arabicLetters : Grading.letters
        let tfWords = lang == "ar" ? ["صح", "خطأ"] : ["True", "False"]
        return List {
            Section {
                TextField("اسم الاختبار", text: p.request.name)
                TextField("المادة", text: p.request.subject)
                TextField("الصف", text: p.request.grade)
            } footer: {
                Text("عدّل ما تشاء، ثم اعتمد الاختبار لتُجهَّز أوراقه.")
            }
            Section("الفصول") {
                ClassPicker(selected: p.request.classIds)
            }
            Section {
                ForEach(p.questions) { $q in
                    let n = (p.wrappedValue.questions.firstIndex { $0.id == q.id } ?? 0) + 1
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("\(n).").bold()
                            Text(q.kind == .mcq ? "اختيار من متعدد" : "صح أو خطأ")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        TextField("نص السؤال", text: $q.text, axis: .vertical)
                            .font(.body.weight(.semibold))
                        if q.kind == .mcq {
                            ForEach(0..<4, id: \.self) { k in
                                HStack {
                                    Button {
                                        q.answer = k
                                    } label: {
                                        Image(systemName: q.answer == k ? "checkmark.circle.fill" : "circle")
                                            .foregroundColor(q.answer == k ? .green : .secondary)
                                    }
                                    .buttonStyle(.borderless)
                                    Text(letters[k] + ")")
                                    TextField("البديل", text: optionBinding($q, k))
                                }
                            }
                        } else {
                            Picker("الإجابة", selection: $q.answer) {
                                Text(tfWords[0]).tag(0)
                                Text(tfWords[1]).tag(1)
                            }
                            .pickerStyle(.segmented)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .onDelete { p.wrappedValue.questions.remove(atOffsets: $0) }
                HStack {
                    Button("+ سؤال اختيار") {
                        p.wrappedValue.questions.append(Question(kind: .mcq, text: "", options: ["", "", "", ""], answer: 0))
                    }
                    Spacer()
                    Button("+ صح أو خطأ") {
                        p.wrappedValue.questions.append(Question(kind: .tf, text: "", options: [], answer: 0))
                    }
                }
                .buttonStyle(.borderless)
            } header: {
                Text("الأسئلة: " + countWord(p.wrappedValue.questions.count, questionsForms))
            } footer: {
                Text("اسحب السؤال لليسار لحذفه. وعدد الأسئلة من \(SheetGeometry.minQuestions) إلى \(SheetGeometry.maxQuestions).")
            }
            if let error {
                Section { Text(error).foregroundColor(.red) }
            }
            Section {
                Button {
                    approve(p.wrappedValue)
                } label: {
                    Text(p.wrappedValue.quizId == nil ? "اعتمد الاختبار" : "احفظ التعديل")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
                if p.wrappedValue.quizId == nil {
                    Button("احفظ المسودة") {
                        store.saveDraft(p.wrappedValue)
                        dismiss()
                    }
                    Button("احذف المسودة", role: .destructive) { confirmDelete = true }
                }
            }
        }
        .confirmationDialog("تُحذف المسودة نهائيًا؟", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("احذف", role: .destructive) {
                store.deleteDraft(paperId)
                dismiss()
            }
            Button("إلغاء", role: .cancel) {}
        }
    }

    private func optionBinding(_ q: Binding<Question>, _ k: Int) -> Binding<String> {
        Binding(get: { k < q.wrappedValue.options.count ? q.wrappedValue.options[k] : "" },
                set: { value in
                    while q.wrappedValue.options.count <= k { q.wrappedValue.options.append("") }
                    q.wrappedValue.options[k] = value
                })
    }

    private func approve(_ p: Paper) {
        error = nil
        do {
            let quiz = try store.approve(p)
            onApproved(quiz)
        } catch {
            self.error = error.localizedDescription
        }
    }
}
