import SwiftUI

/// The tests: make one (from a book, or with a ready key), review drafts, open a test, scan any sheet.
struct QuizListView: View {
    @EnvironmentObject private var store: Store
    @EnvironmentObject private var ai: AIClient
    @State private var scanning = false
    @State private var path = NavigationPath()
    @State private var newFromBook = false
    @State private var newManual = false

    enum Route: Hashable {
        case quiz(String)
        case draft(String)
    }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section {
                    Button {
                        newFromBook = true
                    } label: {
                        Label("اختبار جديد من كتاب", systemImage: "sparkles")
                            .font(.headline)
                            .frame(maxWidth: .infinity, minHeight: 48)
                    }
                    .buttonStyle(.borderedProminent)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    Button {
                        newManual = true
                    } label: {
                        Label("اختبار بمفتاح جاهز", systemImage: "list.number")
                            .frame(maxWidth: .infinity, minHeight: 40)
                    }
                    .buttonStyle(.bordered)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                } footer: {
                    if ai.linked.isEmpty {
                        Text("لكتابة الأسئلة من كتاب اربط مزوّد ذكاء اصطناعي مجانيًا من «الإعدادات».")
                    }
                }

                if !store.drafts.isEmpty {
                    Section("مسودات بانتظار مراجعتك") {
                        ForEach(store.drafts) { paper in
                            NavigationLink(value: Route.draft(paper.id)) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(paper.request.name).font(.headline)
                                    Text(countWord(paper.questions.count, questionsForms) + " — راجعها واعتمدها")
                                        .font(.caption)
                                        .foregroundColor(.orange)
                                }
                            }
                        }
                    }
                }

                Section("اختباراتي") {
                    if store.activeQuizzes.isEmpty {
                        Text("لا اختبارات بعد.")
                            .foregroundColor(.secondary)
                    }
                    ForEach(store.activeQuizzes) { quiz in
                        NavigationLink(value: Route.quiz(quiz.id)) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(quiz.name).font(.headline)
                                let scans = store.countedScans(quiz).count
                                Text("\(quiz.date) · \(countWord(quiz.questionCount, questionsForms)) · "
                                     + (scans == 0 ? "لم يُمسح بعد" : countWord(scans, sheetsForms)))
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("الاختبارات")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        scanning = true
                    } label: {
                        Label("امسح", systemImage: "camera.viewfinder")
                    }
                    .disabled(store.activeQuizzes.isEmpty)
                }
            }
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .quiz(let id):
                    QuizDetailView(quizId: id, path: $path)
                case .draft(let id):
                    PaperReviewView(paperId: id) { quiz in
                        path = NavigationPath()
                        path.append(Route.quiz(quiz.id))
                    }
                }
            }
            .sheet(isPresented: $newFromBook) {
                NewFromBookView { paperId in
                    newFromBook = false
                    path.append(Route.draft(paperId))
                }
                .environmentObject(store)
                .environmentObject(ai)
                .environment(\.layoutDirection, .rightToLeft)
            }
            .sheet(isPresented: $newManual) {
                ManualQuizView(quizId: nil) { quiz in
                    newManual = false
                    path.append(Route.quiz(quiz.id))
                }
                .environmentObject(store)
                .environment(\.layoutDirection, .rightToLeft)
            }
            .fullScreenCover(isPresented: $scanning) {
                ScannerView()
                    .environmentObject(store)
                    .environment(\.layoutDirection, .rightToLeft)
            }
        }
    }
}
