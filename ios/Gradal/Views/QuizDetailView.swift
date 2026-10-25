import SwiftUI

struct QuizDetailView: View {
    let quizId: String
    @EnvironmentObject private var store: Store
    @EnvironmentObject private var companion: Companion
    @EnvironmentObject private var prints: Prints
    @State private var scanning = false
    @State private var shared: SharedFile?
    @State private var shareError: String?

    var body: some View {
        Group {
            if let quiz = store.quiz(quizId) {
                content(quiz)
            } else {
                Text("حُذف هذا الاختبار.")
                    .foregroundColor(.secondary)
            }
        }
        .onAppear { store.openQuizId = quizId }
        .onDisappear {
            if store.openQuizId == quizId { store.openQuizId = nil }
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
        let counted = store.countedScans(quiz)
        let rows: [ResultRow] = counted.map { scan in
            let g = store.grade(scan, quiz: quiz)
            return ResultRow(scan: scan, name: store.displayName(scan, quiz: quiz), earned: g.earned, possible: g.possible)
        }
        .sorted { $0.name < $1.name }
        let percents = rows.map { percentOf($0.earned, $0.possible) }
        let average = percents.isEmpty ? 0 : percents.reduce(0, +) / Double(percents.count)

        return List {
            Section {
                let papers = prints.files(quiz.id)
                if papers.isEmpty {
                    Text("زامن مع الكمبيوتر لتنزيل أوراق هذا الاختبار، ثم تطبعها من هنا في أي مكان.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
                ForEach(papers) { paper in
                    let url = prints.url(quiz.id, paper.id)
                    Button {
                        Prints.printPDF(url, title: "\(quiz.name) — \(paper.title)")
                    } label: {
                        HStack {
                            Label(paper.title, systemImage: "printer")
                            Spacer()
                            Text(paper.pages == 1 ? "صفحة" : "\(paper.pages) صفحة")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .contextMenu {
                        Button {
                            shared = SharedFile(url: url)
                        } label: {
                            Label("مشاركة", systemImage: "square.and.arrow.up")
                        }
                    }
                }
            } header: {
                Text("الطباعة")
            } footer: {
                if !prints.files(quiz.id).isEmpty {
                    Text("اختر الطابعة وعدد النسخ في نافذة الطباعة. والضغط المطوّل يشارك الملف.")
                }
            }

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
            }

            Section {
                LabeledContent("رمز الاختبار", value: String(quiz.code))
                if !quiz.sheetReady {
                    Text("ورقة الإجابة لهذا الاختبار لم تُجهَّز بعد. زامن مع الكمبيوتر قبل المسح.")
                        .font(.footnote)
                        .foregroundColor(.orange)
                }
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
                            if store.db.pendingScanIds.contains(row.scan.id) {
                                Image(systemName: "arrow.up.circle")
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }
            }

            Section {
                Button {
                    do {
                        shared = SharedFile(url: try store.recordFile(quiz))
                    } catch {
                        shareError = "تعذر إنشاء ملف السجل."
                    }
                } label: {
                    Label("مشاركة السجل", systemImage: "square.and.arrow.up")
                }
                if let shareError {
                    Text(shareError).font(.caption).foregroundColor(.red)
                }
            } footer: {
                Text("ملف Excel بدرجات الطلاب في كل سؤال.")
            }
        }
        .navigationTitle(quiz.name)
        .sheet(item: $shared) { file in
            ShareSheet(items: [file.url])
        }
        .fullScreenCover(isPresented: $scanning) {
            ScannerView()
                .environmentObject(store)
                .environmentObject(companion)
                .environment(\.layoutDirection, .rightToLeft)
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
                let key = Grading.key(quiz, version: scan.version)
                let accepted = i < key.count ? key[i] : ""
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
            let keyA = Grading.key(quiz, version: 0)
            return Item(id: i, key: i < keyA.count ? keyA[i] : "", counted: counted, correct: correct,
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
