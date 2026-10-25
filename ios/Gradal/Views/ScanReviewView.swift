import SwiftUI
import UIKit

struct ScanReviewView: View {
    let scanId: String
    let quizId: String
    @EnvironmentObject private var store: Store
    @Environment(\.dismiss) private var dismiss
    @State private var draft: Scan?
    @State private var image: UIImage?
    @State private var confirmDelete = false

    private func current() -> Scan? { draft ?? store.scan(scanId) }

    private func mutate(_ change: (inout Scan) -> Void) {
        guard var s = current() else { return }
        change(&s)
        draft = s
    }

    private func toggle(_ letter: String, _ i: Int) {
        mutate { s in
            while s.answers.count <= i { s.answers.append("") }
            var a = s.answers[i]
            if a.contains(letter) {
                a = a.replacingOccurrences(of: letter, with: "")
            } else {
                a += letter
            }
            s.answers[i] = Grading.normalized(a)
        }
    }

    private var studentBinding: Binding<String?> {
        Binding(get: { current()?.studentId },
                set: { value in mutate { $0.studentId = value } })
    }

    var body: some View {
        Group {
            if let quiz = store.quiz(quizId), let scan = current() {
                form(quiz, scan)
            } else {
                Text("حُذفت هذه الورقة.")
                    .foregroundColor(.secondary)
            }
        }
        .navigationTitle("مراجعة الورقة")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if draft != nil {
                ToolbarItem(placement: .confirmationAction) {
                    Button("حفظ") {
                        if let d = draft { store.updateScan(d) }
                        draft = nil
                    }
                }
            }
        }
        .onAppear { renderGraded() }
        .onChange(of: draft) { renderGraded() }
    }

    /// The paper as its correction copy (GradedPage), redrawn as the answers are edited.
    private func renderGraded() {
        guard let quiz = store.quiz(quizId), let scan = current(),
              FileManager.default.fileExists(atPath: store.imageURL(scanId).path),
              let cg = GradedPage.image(store.gradedPage(scan, quiz: quiz), bubbleRadiusMm: store.bubbleRadiusMm)
        else { return }
        image = UIImage(cgImage: cg)
    }

    private func form(_ quiz: Quiz, _ scan: Scan) -> some View {
        let key = quiz.key
        let g = Grading.grade(quiz, answers: scan.answers)
        let students = store.studentsFor(quiz)
        return List {
            if let image {
                Section {
                    NavigationLink {
                        ScrollView([.horizontal, .vertical]) {
                            Image(uiImage: image)
                                .resizable()
                                .interpolation(.high)
                                .scaledToFit()
                                .frame(width: 1100)
                        }
                        .navigationTitle("الورقة")
                    } label: {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(maxHeight: 360)
                            .frame(maxWidth: .infinity)
                    }
                }
            } else if scan.hasImage {
                Section {
                    Text("صورة الورقة غير متاحة.")
                        .foregroundColor(.secondary)
                }
            }

            Section {
                Picker("الطالب", selection: studentBinding) {
                    Text("غير محدد").tag(String?.none)
                    ForEach(students) { s in
                        Text("\(s.name) (\(s.gradalId))").tag(String?.some(s.id))
                    }
                }
                if scan.studentId == nil {
                    Text(store.displayName(scan, quiz: quiz))
                        .foregroundColor(store.resolvedStudent(scan, quiz: quiz) == nil ? .orange : .secondary)
                }
                LabeledContent("الرقم المقروء", value: scan.gradalId.isEmpty ? "—" : scan.gradalId)
                LabeledContent("الدرجة",
                               value: "\(fmt(g.earned)) من \(fmt(g.possible)) (\(Int(percentOf(g.earned, g.possible).rounded()))٪)")
                if scan.edited {
                    Text("عُدّلت يدويًا").font(.caption).foregroundColor(.secondary)
                }
            }

            Section("الإجابات") {
                ForEach(0..<quiz.questionCount, id: \.self) { i in
                    answerRow(i, scan: scan, accepted: i < key.count ? key[i] : "", language: quiz.language)
                }
            }

            Section {
                Button("حذف الورقة", role: .destructive) { confirmDelete = true }
            }
        }
        .confirmationDialog("حذف هذه الورقة؟", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("حذف", role: .destructive) {
                store.deleteScan(scanId)
                draft = nil
                dismiss()
            }
            Button("إلغاء", role: .cancel) {}
        }
    }

    /// Choices stay A–D inside; an Arabic quiz shows them as أ ب ج د, right to left like its sheet.
    private func answerRow(_ i: Int, scan: Scan, accepted: String, language: String?) -> some View {
        let answer = i < scan.answers.count ? scan.answers[i] : ""
        let counted = !accepted.isEmpty
        let right = Grading.isCorrect(answer: answer, key: accepted)
        return HStack(spacing: 8) {
            Text("\(i + 1)")
                .font(.body.monospacedDigit())
                .frame(width: 32)
            HStack(spacing: 5) {
                ForEach(Grading.letters, id: \.self) { letter in
                    let on = answer.contains(letter)
                    let isKey = accepted.contains(letter)
                    Button {
                        toggle(letter, i)
                    } label: {
                        Text(Grading.display(letter, language: language))
                            .font(.callout.bold())
                            .frame(width: 30, height: 30)
                            .background(Circle().fill(on ? Color.primary.opacity(0.8) : Color.gray.opacity(0.12)))
                            .overlay(Circle().stroke(isKey ? Color.green : Color.clear, lineWidth: 2))
                            .foregroundColor(on ? Color(.systemBackground) : Color.primary)
                    }
                    .buttonStyle(.borderless)
                }
            }
            .environment(\.layoutDirection, language == "ar" ? LayoutDirection.rightToLeft : .leftToRight)
            Spacer(minLength: 0)
            if !counted {
                Text("لا يُحتسب").font(.caption).foregroundColor(.secondary)
            } else if right {
                Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
            } else {
                Image(systemName: "xmark.circle.fill").foregroundColor(.red)
            }
        }
    }
}
