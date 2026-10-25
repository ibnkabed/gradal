import SwiftUI
import UniformTypeIdentifiers

/// Class lists: imported from Noor's Excel export or pasted, each student with a 3-digit ID printed on his sheet.
struct StudentsView: View {
    @EnvironmentObject private var store: Store
    @EnvironmentObject private var ai: AIClient
    @State private var className = ""
    @State private var adding = false
    @State private var reading = false
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
                        Label("استورد ملف Excel أو PDF من نور", systemImage: "square.and.arrow.down")
                    }
                    .disabled(reading)
                    Button {
                        pasting = true
                    } label: {
                        Label("الصق الأسماء", systemImage: "doc.on.clipboard")
                    }
                    Button {
                        adding = true
                    } label: {
                        Label("أضف طالبًا", systemImage: "person.badge.plus")
                    }
                    if reading {
                        HStack {
                            ProgressView()
                            Text("أقرأ الملف…").foregroundColor(.secondary)
                        }
                    }
                    if let message {
                        Text(message).font(.callout).foregroundColor(failed ? .red : .green)
                    }
                } header: {
                    Text("إضافة فصل")
                } footer: {
                    Text("صدّر قائمة الطلاب من نور ملف Excel أو PDF، ثم اختره هنا: يعرف Gradal الفصول ويعطي كل طالب رقمه وحده. وملف PDF يقرؤه الذكاء الاصطناعي إن رُبط. ولكل طالب رقم من ثلاث خانات يُطبع مظللًا في ورقته: الأولى رقم الفصل، والباقيتان ترتيبه. والفصول تسعة على الأكثر في السنة.")
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
                          allowedContentTypes: [.spreadsheet, .pdf, .commaSeparatedText, .html, .plainText, .data]) { result in
                guard case .success(let url) = result else { return }
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                guard let data = try? Data(contentsOf: url) else {
                    failed = true
                    message = "تعذّرت قراءة الملف"
                    return
                }
                if data.starts(with: Array("%PDF-".utf8)) {
                    reading = true
                    Task {
                        defer { reading = false }
                        do {
                            let summary = try await store.importStudentsPDF(data, className: className, ai: ai)
                            run { summary }
                        } catch {
                            failed = true
                            message = error.localizedDescription
                        }
                    }
                } else {
                    run { try store.importStudents(data, filename: url.lastPathComponent, className: className) }
                }
            }
            .sheet(isPresented: $adding) {
                AddStudentView { name, cls in
                    let student = try store.addStudent(name: name, className: cls)
                    failed = false
                    message = "أُضيف \(student.name) برقم \(student.gradalId)"
                }
                .environmentObject(store)
                .environment(\.layoutDirection, .rightToLeft)
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

private struct AddStudentView: View {
    let onAdd: (String, String) throws -> Void
    @EnvironmentObject private var store: Store
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var classId = ""
    @State private var newClass = ""
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                TextField("اسم الطالب", text: $name)
                Picker("الفصل", selection: $classId) {
                    ForEach(store.activeClasses) { Text($0.name).tag($0.id) }
                    Text("فصل جديد").tag("")
                }
                if classId.isEmpty {
                    TextField("اسم الفصل الجديد", text: $newClass)
                }
                if let error {
                    Text(error).foregroundColor(.red)
                }
            }
            .navigationTitle("أضف طالبًا")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("إلغاء") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("أضف") {
                        do {
                            try onAdd(name, classId.isEmpty ? newClass : store.className(classId))
                            dismiss()
                        } catch {
                            self.error = error.localizedDescription
                        }
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear { if classId.isEmpty { classId = store.activeClasses.first?.id ?? "" } }
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
