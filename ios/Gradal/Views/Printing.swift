import SwiftUI
import UIKit

/// The system print dialog (AirPrint): printer, copies and pages are chosen there.
enum Printing {
    static func printPDF(_ url: URL, title: String) {
        let info = UIPrintInfo(dictionary: nil)
        info.outputType = .grayscale
        info.jobName = title
        let controller = UIPrintInteractionController.shared
        controller.printInfo = info
        controller.printingItem = url
        _ = controller.present(animated: true)
    }
}

/// Arabic counted nouns: 1, 2, 3-10, 11+.
func countWord(_ n: Int, _ forms: (one: String, two: String, few: String, many: String)) -> String {
    if n == 1 { return forms.one }
    if n == 2 { return forms.two }
    return (3...10).contains(n) ? "\(n) \(forms.few)" : "\(n) \(forms.many)"
}

let questionsForms = (one: "سؤال واحد", two: "سؤالان", few: "أسئلة", many: "سؤالًا")
let sheetsForms = (one: "ورقة واحدة", two: "ورقتان", few: "أوراق", many: "ورقة")
let studentsForms = (one: "طالب واحد", two: "طالبان", few: "طلاب", many: "طالبًا")
let pagesForms = (one: "صفحة واحدة", two: "صفحتان", few: "صفحات", many: "صفحة")

/// Ticks for the classes a quiz is for.
struct ClassPicker: View {
    @EnvironmentObject private var store: Store
    @Binding var selected: [String]

    var body: some View {
        if store.activeClasses.isEmpty {
            Text("لا فصول بعد: أضفها من تبويب «الطلاب».")
                .foregroundColor(.secondary)
        }
        ForEach(store.activeClasses) { cls in
            Toggle(cls.name, isOn: Binding(
                get: { selected.contains(cls.id) },
                set: { on in
                    if on { if !selected.contains(cls.id) { selected.append(cls.id) } } else { selected.removeAll { $0 == cls.id } }
                }))
        }
    }
}
