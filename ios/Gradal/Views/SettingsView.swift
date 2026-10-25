import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// AI providers (a key pasted once), the school header printed on every paper, backup, about.
struct SettingsView: View {
    @EnvironmentObject private var store: Store
    @EnvironmentObject private var ai: AIClient
    @State private var keys: [String: String] = [:]
    @State private var linking: String?
    @State private var aiMessage: [String: String] = [:]
    @State private var settings = Settings()
    @State private var logoItem: PhotosPickerItem?
    @State private var shared: SharedFile?
    @State private var restoring = false
    @State private var backupMessage: String?
    @State private var confirmRestore: URL?

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(AIProviders.all, id: \.id) { p in
                        provider(p)
                    }
                } header: {
                    Text("الذكاء الاصطناعي")
                } footer: {
                    Text("يكتب الأسئلة من كتابك. افتح صفحة المفتاح، وأنشئ مفتاحًا مجانيًا، ثم الصقه هنا. يكفي واحد، وربط اثنين يجعل الثاني يراجع ما كتبه الأول. والمفاتيح تبقى في هذا الجوال.")
                }

                Section {
                    ForEach(0..<4, id: \.self) { i in
                        TextField("سطر \(i + 1) من رأس الورقة", text: lineBinding(i))
                    }
                    TextField("اسم المعلم (اختياري)", text: $settings.teacher)
                    HStack {
                        if let data = settings.logoPNG, let img = UIImage(data: data) {
                            Image(uiImage: img).resizable().scaledToFit().frame(height: 40)
                        }
                        PhotosPicker(selection: $logoItem, matching: .images) {
                            Text(settings.logoPNG == nil ? "اختر شعارًا (اختياري)" : "غيّر الشعار")
                        }
                        if settings.logoPNG != nil {
                            Spacer()
                            Button("أزله", role: .destructive) { settings.logoPNG = nil }
                                .buttonStyle(.borderless)
                        }
                    }
                    if settings != store.db.settings {
                        Button("احفظ رأس الورقة") { store.updateSettings(settings) }
                    }
                } header: {
                    Text("رأس الورقة")
                } footer: {
                    Text("يُطبع أعلى ورقة الأسئلة وورقة الإجابة: أسطر المدرسة يمينًا، وبيانات الاختبار يسارًا، والشعار في الوسط.")
                }

                Section {
                    Button {
                        do {
                            shared = SharedFile(url: try store.exportBackup())
                        } catch {
                            backupMessage = error.localizedDescription
                        }
                    } label: {
                        Label("انسخ بياناتك احتياطًا", systemImage: "externaldrive.badge.icloud")
                    }
                    Button {
                        restoring = true
                    } label: {
                        Label("استعد نسخة احتياطية", systemImage: "arrow.counterclockwise")
                    }
                    if let backupMessage {
                        Text(backupMessage).font(.callout)
                    }
                } header: {
                    Text("بياناتك")
                } footer: {
                    Text("كل بياناتك في هذا الجوال وحده: الكتب والاختبارات والطلاب والأوراق الممسوحة. احفظ نسخة في «الملفات» أو iCloud Drive من حين لآخر.")
                }

                Section("عن التطبيق") {
                    LabeledContent("النسخة", value: appVersion)
                    Link("Gradal على GitHub", destination: URL(string: "https://github.com/ibnkabed/gradal")!)
                    Text("مجاني ومفتوح المصدر. يكتب الاختبار من كتابك بالذكاء الاصطناعي، ويطبع أوراقه، ويصححها بالكاميرا.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
            }
            .navigationTitle("الإعدادات")
            .onAppear { settings = store.db.settings }
            .onChange(of: logoItem) { _, item in
                guard let item else { return }
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self), let img = UIImage(data: data) {
                        settings.logoPNG = Self.shrink(img)
                    }
                }
            }
            .sheet(item: $shared) { file in
                ShareSheet(items: [file.url])
            }
            .fileImporter(isPresented: $restoring, allowedContentTypes: [.zip]) { result in
                if case .success(let url) = result { confirmRestore = url }
            }
            .confirmationDialog("تحل النسخة الاحتياطية محل كل بياناتك الحالية؟",
                                isPresented: Binding(get: { confirmRestore != nil }, set: { if !$0 { confirmRestore = nil } }),
                                titleVisibility: .visible) {
                Button("استعدها", role: .destructive) {
                    if let url = confirmRestore {
                        do {
                            try store.restoreBackup(url)
                            settings = store.db.settings
                            backupMessage = "استُعيدت النسخة الاحتياطية."
                        } catch {
                            backupMessage = error.localizedDescription
                        }
                    }
                    confirmRestore = nil
                }
                Button("إلغاء", role: .cancel) { confirmRestore = nil }
            }
        }
    }

    @ViewBuilder
    private func provider(_ p: AIProvider) -> some View {
        let mine = ai.linked.first { $0.id == p.id }
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(p.name).font(.headline)
                Text(p.free ? "مجاني" : "رخيص")
                    .font(.caption.bold())
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(p.free ? Color.green.opacity(0.15) : Color.orange.opacity(0.15)))
                Spacer()
                if mine != nil {
                    Image(systemName: "checkmark.seal.fill").foregroundColor(.green)
                }
            }
            Text(p.note).font(.footnote).foregroundColor(.secondary)
            if let mine {
                Text("النموذج: \(mine.model)").font(.caption).foregroundColor(.secondary)
                if let err = mine.lastError {
                    Text("آخر خطأ: \(err)").font(.caption).foregroundColor(.red)
                }
                Button("ألغِ الربط", role: .destructive) { ai.unlink(p.id) }
                    .buttonStyle(.borderless)
            } else {
                Link(destination: p.keyURL) {
                    Label("افتح صفحة المفتاح", systemImage: "safari")
                }
                .buttonStyle(.borderless)
                HStack {
                    SecureField("الصق المفتاح هنا", text: Binding(get: { keys[p.id] ?? "" }, set: { keys[p.id] = $0 }))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    if linking == p.id {
                        ProgressView()
                    } else {
                        Button("اربط") { link(p.id) }
                            .buttonStyle(.borderless)
                            .disabled((keys[p.id] ?? "").trimmingCharacters(in: .whitespaces).isEmpty || linking != nil)
                    }
                }
            }
            if let msg = aiMessage[p.id] {
                Text(msg).font(.caption).foregroundColor(msg.hasPrefix("رُبط") ? .green : .red)
            }
        }
        .padding(.vertical, 4)
    }

    private func link(_ id: String) {
        linking = id
        aiMessage[id] = nil
        Task {
            defer { linking = nil }
            do {
                let model = try await ai.link(id, key: keys[id] ?? "")
                keys[id] = nil
                aiMessage[id] = "رُبط بنجاح، والنموذج المختار \(model)"
            } catch {
                aiMessage[id] = error.localizedDescription
            }
        }
    }

    private func lineBinding(_ i: Int) -> Binding<String> {
        Binding(get: { i < settings.schoolLines.count ? settings.schoolLines[i] : "" },
                set: { value in
                    while settings.schoolLines.count <= i { settings.schoolLines.append("") }
                    settings.schoolLines[i] = value
                })
    }

    /// The logo printed 30 mm wide: 600 px is plenty, and keeps the saved data small.
    private static func shrink(_ image: UIImage) -> Data? {
        let maxSide: CGFloat = 600
        let scale = min(1, maxSide / max(image.size.width, image.size.height))
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }.pngData()
    }
}
