import SwiftUI

/// One test: its papers to print, the scan button, the results, the analysis and the record sheet.
struct QuizDetailView: View {
    let quizId: String
    @Binding var path: NavigationPath
    @EnvironmentObject private var store: Store
    @State private var scanning = false
    @State private var shared: SharedFile?
    @State private var busyItem: String?
    @State private var problem: String?
    @State private var editingKey = false
    @State private var confirmDelete = false

    var body: some View {
        Group {
            if let quiz = store.quiz(quizId) {
                content(quiz)
            } else {
                Text("حُذف هذا الاختبار.")
                    .foregroundColor(.secondary)
            }
        }
    }

    private struct ResultRow: Identifiable {
        let scan: Scan
        let name: String
        let earned: Double
        let possible: Double
        var id: String { scan.id }
    }

    private func content(_ quiz: Quiz) -> some View {
        let rows: [ResultRow] = store.countedScans(quiz).map { scan in
            let g = store.grade(scan, quiz: quiz)
            return ResultRow(scan: scan, name: store.displayName(scan, quiz: quiz), earned: g.earned, possible: g.possible)
        }
        .sorted { $0.name < $1.name }
        let percents = rows.map { percentOf($0.earned, $0.possible) }
        let average = percents.isEmpty ? 0 : percents.reduce(0, +) / Double(percents.count)
        let classes = quiz.classIds.map { store.className($0) }.filter { !$0.isEmpty }.joined(separator: "، ")

        return List {
            Section {
                Button {
                    scanning = true
                } label: {
                    Label("امسح الأوراق", systemImage: "camera.viewfinder")
                        .font(.title3.bold())
                        .frame(maxWidth: .infinity, minHeight: 54)
                }
                .buttonStyle(.borderedProminent)
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            } footer: {
                Text("رمز الاختبار \(String(quiz.code)) · \(countWord(quiz.questionCount, questionsForms)) · \(classes)")
            }

            Section {
                ForEach(store.printItems(quiz)) { item in
                    Button {
                        open(item, quiz: quiz, share: false)
                    } label: {
                        HStack {
                            Label(item.title, systemImage: "printer")
                            Spacer()
                            if busyItem == item.id { ProgressView() }
                        }
                    }
                    .disabled(busyItem != nil)
                    .contextMenu {
                        Button {
                            open(item, quiz: quiz, share: true)
                        } label: {
                            Label("مشاركة PDF", systemImage: "square.and.arrow.up")
                        }
                    }
                }
                if let problem {
                    Text(problem).font(.caption).foregroundColor(.red)
                }
            } header: {
                Text("الأوراق")
            } footer: {
                Text("اختر الطابعة وعدد النسخ في نافذة الطباعة (A4، بلا تصغير). والضغط المطوّل يشارك الملف.")
            }

            Section("الإحصاءات") {
                LabeledContent("عدد الأوراق", value: "\(rows.count)")
                LabeledContent("المتوسط", value: "\(Int(average.rounded()))٪")
                LabeledContent("الأعلى", value: "\(Int((percents.max() ?? 0).rounded()))٪")
                LabeledContent("الأدنى", value: "\(Int((percents.min() ?? 0).rounded()))٪")
                NavigationLink("تحليل الأسئلة") {
                    ItemAnalysisView(quizId: quiz.id)
                }
            }

            Section("النتائج") {
                if rows.isEmpty {
                    Text("لم تُمسح أوراق بعد.")
                        .foregroundColor(.secondary)
                }
                ForEach(rows) { row in
                    NavigationLink {
                        ScanReviewView(scanId: row.scan.id, quizId: quiz.id)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(row.name)
                                    .foregroundColor(store.resolvedStudent(row.scan, quiz: quiz) == nil ? .orange : .primary)
                                Text("\(fmt(row.earned)) من \(fmt(row.possible))")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            Text("\(Int(percentOf(row.earned, row.possible).rounded()))٪")
                                .font(.headline.monospacedDigit())
                        }
                    }
                }
            }

            Section {
                Button {
                    do {
                        shared = SharedFile(url: try store.recordFile(quiz))
                    } catch {
                        problem = "تعذّر إنشاء ملف السجل."
                    }
                } label: {
                    Label("مشاركة السجل (Excel)", systemImage: "tablecells")
                }
                if let paperId = quiz.paperId {
                    NavigationLink {
                        PaperReviewView(paperId: paperId) { _ in
                            if !path.isEmpty { path.removeLast() }
                        }
                    } label: {
                        Label("عدّل الأسئلة", systemImage: "pencil")
                    }
                } else {
                    Button {
                        editingKey = true
                    } label: {
                        Label("عدّل المفتاح", systemImage: "pencil")
                    }
                }
                Button("احذف الاختبار", role: .destructive) { confirmDelete = true }
            } footer: {
                Text("السجل ملف Excel فيه ورقة لكل فصل ودرجة كل طالب في كل سؤال.")
            }
        }
        .navigationTitle(quiz.name)
        .sheet(item: $shared) { file in
            ShareSheet(items: [file.url])
        }
        .sheet(isPresented: $editingKey) {
            ManualQuizView(quizId: quiz.id) { _ in }
                .environmentObject(store)
                .environment(\.layoutDirection, .rightToLeft)
        }
        .confirmationDialog("يُحذف «\(quiz.name)» ونتائجه؟", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("احذف", role: .destructive) {
                store.deleteQuiz(quiz.id)
                if !path.isEmpty { path.removeLast() }
            }
            Button("إلغاء", role: .cancel) {}
        }
        .fullScreenCover(isPresented: $scanning) {
            ScannerView()
                .environmentObject(store)
                .environment(\.layoutDirection, .rightToLeft)
        }
    }

    /// Makes the PDF (first time only) then prints or shares it.
    private func open(_ item: PrintItem, quiz: Quiz, share: Bool) {
        problem = nil
        busyItem = item.id
        Task {
            defer { busyItem = nil }
            do {
                let url = try await store.printFile(item, quiz: quiz)
                if share {
                    shared = SharedFile(url: url)
                } else {
                    Printing.printPDF(url, title: "\(quiz.name) — \(item.title)")
                }
            } catch {
                problem = error.localizedDescription
            }
        }
    }
}

struct ItemAnalysisView: View {
    let quizId: String
    @EnvironmentObject private var store: Store

    private struct Item: Identifiable {
        let id: Int
        let key: String
        let counted: Int
        let correct: Int
        let letters: [Int]
        let blank: Int
        let multiple: Int
    }

    private func items(_ quiz: Quiz) -> [Item] {
        let scans = store.countedScans(quiz)
        return (0..<quiz.questionCount).map { i in
            var counted = 0, correct = 0, blank = 0, multiple = 0
            var letters = [Int](repeating: 0, count: Grading.letters.count)
            for scan in scans {
                let answer = i < scan.answers.count ? scan.answers[i] : ""
                let accepted = i < quiz.key.count ? quiz.key[i] : ""
                if answer.isEmpty {
                    blank += 1
                } else if answer.count > 1 {
                    multiple += 1
                } else if let idx = Grading.letters.firstIndex(of: answer) {
                    letters[idx] += 1
                }
                if !accepted.isEmpty {
                    counted += 1
                    if Grading.isCorrect(answer: answer, key: accepted) { correct += 1 }
                }
            }
            return Item(id: i, key: i < quiz.key.count ? quiz.key[i] : "", counted: counted, correct: correct,
                        letters: letters, blank: blank, multiple: multiple)
        }
    }

    var body: some View {
        if let quiz = store.quiz(quizId) {
            List {
                Section {
                    Text("النسبة نسبة من أجاب صحيحًا، والأعداد عدد من اختار كل حرف. والحرف الأخضر هو الإجابة الصحيحة.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
                ForEach(items(quiz)) { item in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("السؤال \(item.id + 1)").font(.headline)
                            Spacer()
                            if item.counted == 0 {
                                Text("لا يُحتسب").foregroundColor(.secondary)
                            } else {
                                Text("\(Int((Double(item.correct) / Double(item.counted) * 100).rounded()))٪")
                                    .font(.headline.monospacedDigit())
                            }
                        }
                        HStack(spacing: 12) {
                            ForEach(Grading.letters.indices, id: \.self) { j in
                                let letter = Grading.letters[j]
                                let isKey = item.key.contains(letter)
                                Text("\(Grading.display(letter, language: quiz.language)) \(item.letters[j])")
                                    .font(.callout.monospacedDigit())
                                    .fontWeight(isKey ? .bold : .regular)
                                    .foregroundColor(isKey ? .green : .primary)
                            }
                            Text("فارغ \(item.blank)").font(.caption).foregroundColor(.secondary)
                            if item.multiple > 0 {
                                Text("متعدد \(item.multiple)").font(.caption).foregroundColor(.secondary)
                            }
                        }
                        .environment(\.layoutDirection, quiz.isArabic ? LayoutDirection.rightToLeft : .leftToRight)
                    }
                    .padding(.vertical, 2)
                }
            }
            .navigationTitle("تحليل الأسئلة")
        } else {
            Text("حُذف هذا الاختبار.")
        }
    }
}
