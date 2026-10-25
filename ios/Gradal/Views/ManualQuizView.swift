import SwiftUI

/// A test prepared elsewhere: Gradal prints its answer sheets and grades them with the key typed here.
struct ManualQuizView: View {
    let quizId: String?
    let onSaved: (Quiz) -> Void
    @EnvironmentObject private var store: Store
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var subject = ""
    @State private var language = "ar"
    @State private var count = 20
    @State private var classIds: [String] = []
    @State private var key: [String] = Array(repeating: "", count: 20)
    @State private var error: String?
    @State private var loaded = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("اسم الاختبار", text: $name)
                    TextField("المادة", text: $subject)
                    Picker("ورقة الإجابة", selection: $language) {
                        Text("العربية (أ ب ج د)").tag("ar")
                        Text("English (A B C D)").tag("en")
                    }
                    Stepper("عدد الأسئلة: \(count)", value: $count, in: SheetGeometry.minQuestions...SheetGeometry.maxQuestions)
                } footer: {
                    Text("لاختبار أعددته بنفسك: يطبع Gradal ورقة الإجابة، ويصحح بالمفتاح الذي تدخله هنا.")
                }
                Section("الفصول") {
                    ClassPicker(selected: $classIds)
                }
                Section("مفتاح الإجابة") {
                    ForEach(0..<count, id: \.self) { i in
                        HStack(spacing: 8) {
                            Text("\(i + 1)")
                                .font(.body.monospacedDigit())
                                .frame(width: 30)
                            ForEach(Grading.letters, id: \.self) { letter in
                                let on = i < key.count && key[i] == letter
                                Button {
                                    while key.count <= i { key.append("") }
                                    key[i] = on ? "" : letter
                                } label: {
                                    Text(Grading.display(letter, language: language))
                                        .font(.callout.bold())
                                        .frame(width: 34, height: 34)
                                        .background(Circle().fill(on ? Color.primary.opacity(0.85) : Color.gray.opacity(0.12)))
                                        .foregroundColor(on ? Color(.systemBackground) : .primary)
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                        .environment(\.layoutDirection, language == "ar" ? LayoutDirection.rightToLeft : .leftToRight)
                    }
                }
                if let error {
                    Section { Text(error).foregroundColor(.red) }
                }
            }
            .navigationTitle(quizId == nil ? "اختبار بمفتاح جاهز" : "تعديل المفتاح")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("إلغاء") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("احفظ") { save() }
                }
            }
            .onAppear(perform: load)
        }
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        guard let id = quizId, let q = store.quiz(id) else { return }
        name = q.name
        subject = q.header.subject
        language = q.language
        count = q.questionCount
        classIds = q.classIds
        key = q.key
    }

    private func save() {
        let k = Array((key + Array(repeating: "", count: max(0, count - key.count))).prefix(count))
        do {
            let quiz = try store.saveManualQuiz(id: quizId, name: name, subject: subject, language: language,
                                                classIds: classIds, key: k)
            onSaved(quiz)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
