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
            ForEach(groups(p.wrappedValue), id: \.self) { si in
                Section {
                    ForEach(indices(p.wrappedValue, si), id: \.self) { qi in
                        editor(p.questions[qi], number: qi + 1, letters: letters, tfWords: tfWords)
                    }
                    .onDelete { offsets in
                        let all = indices(p.wrappedValue, si)
                        p.wrappedValue.questions.remove(atOffsets: IndexSet(offsets.map { all[$0] }))
                    }
                    let kind = si >= 0 && si < p.wrappedValue.request.parts.count ? p.wrappedValue.request.parts[si].kind : nil
                    HStack {
                        if kind != .tf {
                            Button("+ سؤال اختيار") { add(p, .mcq, si) }
                        }
                        Spacer()
                        if kind != .mcq {
                            Button("+ صح أو خطأ") { add(p, .tf, si) }
                        }
                    }
                    .buttonStyle(.borderless)
                } header: {
                    if si >= 0, si < (p.wrappedValue.request.sections?.count ?? 0) {
                        TextField("اسم القسم", text: sectionName(p, si))
                            .font(.subheadline.weight(.bold))
                            .textCase(nil)
                    } else {
                        Text(si >= 0 && si < p.wrappedValue.request.parts.count ? p.wrappedValue.request.parts[si].name : "أسئلة أخرى")
                    }
                }
            }
            Section {
                EmptyView()
            } footer: {
                Text("الأسئلة: \(countWord(p.wrappedValue.questions.count, questionsForms)). اسحب السؤال لليسار لحذفه، والمجموع من \(SheetGeometry.minQuestions) إلى \(SheetGeometry.maxQuestions).")
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

    /// The parts shown: each part of the request (by index), then -1 for questions without a part.
    private func groups(_ p: Paper) -> [Int] {
        let parts = p.request.parts
        var out = Array(parts.indices)
        if p.questions.contains(where: { $0.section == nil || $0.section! >= parts.count }) { out.append(-1) }
        return out
    }

    private func indices(_ p: Paper, _ si: Int) -> [Int] {
        let n = p.request.parts.count
        return p.questions.indices.filter { i in
            let s = p.questions[i].section
            return si >= 0 ? s == si : (s == nil || s! >= n)
        }
    }

    private func add(_ p: Binding<Paper>, _ kind: Question.Kind, _ si: Int) {
        let q = Question(kind: kind, text: "", options: kind == .mcq ? ["", "", "", ""] : [], answer: 0,
                         section: si >= 0 ? si : nil)
        let last = indices(p.wrappedValue, si).last
        if let last { p.wrappedValue.questions.insert(q, at: last + 1) } else { p.wrappedValue.questions.append(q) }
    }

    private func sectionName(_ p: Binding<Paper>, _ si: Int) -> Binding<String> {
        Binding(get: { p.wrappedValue.request.sections?[si].name ?? "" },
                set: { p.wrappedValue.request.sections?[si].name = $0 })
    }

    @ViewBuilder
    private func editor(_ q: Binding<Question>, number n: Int, letters: [String], tfWords: [String]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("\(n).").bold()
                Text(q.wrappedValue.kind == .mcq ? "اختيار من متعدد" : "صح أو خطأ")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            TextField("نص السؤال", text: q.text, axis: .vertical)
                .font(.body.weight(.semibold))
            if q.wrappedValue.kind == .mcq {
                ForEach(0..<4, id: \.self) { k in
                    HStack {
                        Button {
                            q.wrappedValue.answer = k
                        } label: {
                            Image(systemName: q.wrappedValue.answer == k ? "checkmark.circle.fill" : "circle")
                                .foregroundColor(q.wrappedValue.answer == k ? .green : .secondary)
                        }
                        .buttonStyle(.borderless)
                        Text(letters[k] + ")")
                        TextField("البديل", text: optionBinding(q, k))
                    }
                }
            } else {
                Picker("الإجابة", selection: q.answer) {
                    Text(tfWords[0]).tag(0)
                    Text(tfWords[1]).tag(1)
                }
                .pickerStyle(.segmented)
            }
        }
        .padding(.vertical, 4)
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
