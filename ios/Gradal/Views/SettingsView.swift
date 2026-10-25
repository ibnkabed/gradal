import SwiftUI

/// Pairing and sync with Gradal on the computer, and a line about the app.
struct SettingsView: View {
    @EnvironmentObject private var store: Store
    @EnvironmentObject private var companion: Companion
    @State private var pin = ""

    private var lastSyncText: String {
        guard let date = companion.lastSync else { return "لم تتم بعد" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("الحالة") {
                    LabeledContent("الكمبيوتر", value: companion.pcName ?? "لم يُعثر عليه بعد")
                    LabeledContent("العنوان", value: companion.host ?? "—")
                    LabeledContent("الاقتران", value: companion.paired ? "مقترن" : "غير مقترن")
                    LabeledContent("آخر مزامنة", value: lastSyncText)
                    LabeledContent("بانتظار الإرسال", value: "\(store.pendingCount)")
                }

                if !companion.status.isEmpty || companion.busy {
                    Section {
                        HStack(spacing: 10) {
                            if companion.busy { ProgressView() }
                            Text(companion.status)
                        }
                    }
                }

                if companion.awaitingPin && !companion.paired {
                    Section {
                        TextField("الرمز من أربعة أرقام", text: $pin)
                            .keyboardType(.numberPad)
                            .font(.title2.monospacedDigit())
                        Button("تأكيد الرمز") {
                            Task {
                                if await companion.pair(pin: pin) {
                                    pin = ""
                                    await companion.sync(store)
                                }
                            }
                        }
                        .disabled(pin.count < 4 || companion.busy)
                        Button("إلغاء", role: .cancel) {
                            pin = ""
                            companion.cancelPairing()
                        }
                    } header: {
                        Text("رمز الاقتران")
                    } footer: {
                        Text("الرمز يظهر في نافذة Gradal على الكمبيوتر لمدة دقيقتين.")
                    }
                }

                Section {
                    if companion.paired {
                        Button("مزامنة الآن") {
                            Task { await companion.sync(store) }
                        }
                    } else {
                        Button("اقتران") {
                            Task { await companion.startPairing() }
                        }
                    }
                    if companion.paired || companion.host != nil {
                        Button("نسيان الكمبيوتر", role: .destructive) {
                            pin = ""
                            companion.forget()
                        }
                    }
                } footer: {
                    Text("الجوال والكمبيوتر على الشبكة نفسها. كل ما تمسحه يبقى في الجوال حتى يصل إلى الكمبيوتر.")
                }
                .disabled(companion.busy)

                Section("عن التطبيق") {
                    Text("Gradal \(appVersion): تُعدّ الاختبار على الكمبيوتر، وتطبع أوراقه وتصحّحها بكاميرا الجوال، وتعود النتائج إلى الكمبيوتر.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
            }
            .navigationTitle("الإعدادات")
        }
    }
}
