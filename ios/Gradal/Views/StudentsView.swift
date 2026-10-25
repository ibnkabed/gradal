import SwiftUI
import UniformTypeIdentifiers

/// Class lists: imported from Noor's Excel export or pasted, each student with a 3-digit ID printed on his sheet.
struct StudentsView: View {
    @EnvironmentObject private var store: Store
    @State private var className = ""
    @State private var importing = false
    @State private var pasting = false
    @State private var message: String?
    @State private var failed = false
    @State private var confirmYear = false
    @State private var archiveId: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("اسم الفصل (إن لم يكن في الملف)", text: $className)
                    Button {
                        importing = true
                    } label: {
                        Label("استورد ملف Excel من نور", systemImage: "square.and.arrow.down")
                    }
                    Button {
                        pasting = true
                    } label: {
                        Label("الصق الأسماء", systemImage: "doc.on.clipboard")
                    }
                    if let message {
                        Text(message).font(.callout).foregroundColor(failed ? .red : .green)
                    }
                } header: {
                    Text("إضافة فصل")
                } footer: {
                    Text("صدّر قائمة طلاب الفصل من نور ملف Excel، ثم اختره هنا. ولكل طالب رقم من ثلاث خانات يُطبع مظللًا في ورقته: الأولى رقم الفصل، والباقيتان ترتيبه. والفصول تسعة على الأكثر في السنة.")
                }

                ForEach(store.activeClasses) { cls in
                    Section {
                        DisclosureGroup {
                            ForEach(store.students(inClass: cls.id)) { s in
                                HStack {
                                    Text(s.gradalId).font(.body.monospacedDigit()).foregroundColor(.secondary)
                                    Text(s.name)
                                }
                            }
                            Button("انقل الفصل إلى الأرشيف", role: .destructive) { archiveId = cls.id }
                        } label: {
                            HStack {
                                Text(cls.name).font(.headline)
                                Spacer()
                                Text(countWord(store.students(inClass: cls.id).count, studentsForms))
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }

                if !store.activeClasses.isEmpty {
                    Section {
                        Button("ابدأ سنة دراسية جديدة", role: .destructive) { confirmYear = true }
                    } footer: {
                        Text("تُنقل الفصول الحالية وطلابها إلى الأرشيف، وتبقى أسماؤهم في نتائج الاختبارات القديمة. ثم تستورد قوائم السنة الجديدة.")
                    }
                }
            }
            .navigationTitle("الطلاب")
            .fileImporter(isPresented: $importing,
                          allowedContentTypes: [.spreadsheet, .commaSeparatedText, .html, .plainText, .data]) { result in
                guard case .success(let url) = result else { return }
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                run {
                    try store.importStudents(Data(contentsOf: url), filename: url.lastPathComponent, className: className)
                }
            }
            .sheet(isPresented: $pasting) {
                PasteNamesView(className: className) { text, name in
                    run { try store.pasteStudents(text, className: name) }
                }
                .environment(\.layoutDirection, .rightToLeft)
            }
            .confirmationDialog("تُنقل كل الفصول الحالية إلى الأرشيف لتبدأ سنة جديدة؟", isPresented: $confirmYear,
                                titleVisibility: .visible) {
                Button("ابدأ سنة جديدة", role: .destructive) { store.startNewYear() }
                Button("إلغاء", role: .cancel) {}
            }
            .confirmationDialog("يُنقل الفصل وطلابه إلى الأرشيف، وتبقى نتائجه القديمة؟",
                                isPresented: Binding(get: { archiveId != nil }, set: { if !$0 { archiveId = nil } }),
                                titleVisibility: .visible) {
                Button("انقل إلى الأرشيف", role: .destructive) {
                    if let id = archiveId { run { try store.archiveClass(id); return [] } }
                    archiveId = nil
                }
                Button("إلغاء", role: .cancel) { archiveId = nil }
            }
        }
    }

    private func run(_ action: () throws -> [RosterSummary]) {
        do {
            let summary = try action()
            failed = false
            message = summary.isEmpty ? nil : summary.map {
                "\($0.name): \(countWord($0.count, studentsForms))" + ($0.added > 0 ? "، الجدد \($0.added)" : "")
            }.joined(separator: " · ")
        } catch {
            failed = true
            message = error.localizedDescription
        }
    }
}

private struct PasteNamesView: View {
    @State var className: String
    let onAdd: (String, String) -> Void
    @State private var text = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                TextField("اسم الفصل", text: $className)
                Section("الأسماء، اسم في كل سطر") {
                    TextEditor(text: $text).frame(minHeight: 260)
                }
            }
            .navigationTitle("الصق الأسماء")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("إلغاء") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("أضف") {
                        onAdd(text, className)
                        dismiss()
                    }
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}
