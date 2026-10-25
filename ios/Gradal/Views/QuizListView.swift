import SwiftUI

/// Quizzes come from the computer only; the phone prints, scans and shows results.
struct QuizListView: View {
    @EnvironmentObject private var store: Store
    @EnvironmentObject private var companion: Companion
    @State private var scanning = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        scanning = true
                    } label: {
                        Label("امسح", systemImage: "camera.viewfinder")
                            .font(.title2.bold())
                            .frame(maxWidth: .infinity, minHeight: 60)
                    }
                    .buttonStyle(.borderedProminent)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                } footer: {
                    Text("امسح أي ورقة من أي اختبار: الجوال يعرف الاختبار من شريط الورقة.")
                }

                if !store.orphanGroups.isEmpty {
                    Section {
                        ForEach(store.orphanGroups) { group in
                            HStack {
                                Text("اختبار غير معروف (\(String(group.code)))")
                                    .foregroundColor(.orange)
                                Spacer()
                                Text("الأوراق: \(group.count)")
                                    .foregroundColor(.secondary)
                            }
                        }
                        .onDelete { offsets in
                            let groups = store.orphanGroups
                            for i in offsets where i < groups.count {
                                store.deleteOrphans(code: groups[i].code)
                            }
                        }
                    } header: {
                        Text("بانتظار اختبارها")
                    } footer: {
                        Text("تُصحَّح هذه الأوراق تلقائيًا حين يصل اختبارها من الكمبيوتر.")
                    }
                }

                Section("الاختبارات") {
                    if store.activeQuizzes.isEmpty {
                        Text("لا اختبارات بعد. أنشئ الاختبار في Gradal على الكمبيوتر، ثم زامن من «الإعدادات».")
                            .foregroundColor(.secondary)
                    }
                    ForEach(store.activeQuizzes) { quiz in
                        NavigationLink(value: quiz.id) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(quiz.name.isEmpty ? "بلا اسم" : quiz.name)
                                    .font(.headline)
                                Text("\(quiz.date) · الرمز \(String(quiz.code)) · \(quiz.questionCount) سؤالًا · الأوراق: \(store.countedScans(quiz).count)")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("الاختبارات")
            .navigationDestination(for: String.self) { id in
                QuizDetailView(quizId: id)
            }
            .fullScreenCover(isPresented: $scanning) {
                ScannerView()
                    .environmentObject(store)
                    .environmentObject(companion)
                    .environment(\.layoutDirection, .rightToLeft)
            }
        }
    }
}
