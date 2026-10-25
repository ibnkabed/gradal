import Foundation
import PDFKit

/// A class list printed to PDF (Noor's reports). Gemini reads the PDF itself when it is linked (scanned pages and
/// Arabic text layers that come out backwards are no problem for it); else another linked provider reads its text;
/// with no provider, Gradal reads the text itself (StudentsText.fromText).
enum StudentsPDF {
    @MainActor
    static func read(_ data: Data, className: String, ai: AIClient) async throws -> [ImportedClass] {
        guard let doc = PDFDocument(data: data), doc.pageCount > 0 else {
            throw StudentsImportError(message: "تعذّر فتح ملف PDF")
        }
        var text = ""
        for i in 0..<doc.pageCount {
            text += (doc.page(at: i)?.string ?? "") + "\n"
        }
        text = BookRules.fixArabic(text)
        let hint = className.isEmpty ? "" : "\nIf the list does not name its class, use: \(className)"
        if ai.linked.contains(where: { $0.id == "gemini" }) {
            if let reply = try? await ai.geminiPDF(data, prompt: StudentsText.prompt + hint),
               let classes = try? StudentsText.fromJSON(ExamMaker.parseJSON(reply), className: className) {
                return classes
            }
        }
        if !ai.linked.isEmpty, text.count > 40 {
            let messages = [["role": "system", "content": StudentsText.prompt + hint],
                            ["role": "user", "content": String(text.prefix(60000))]]
            if let reply = try? await ai.chat(messages, temperature: 0.1),
               let classes = try? StudentsText.fromJSON(ExamMaker.parseJSON(reply.text), className: className) {
                return classes
            }
        }
        return try StudentsText.fromText(text, className: className)
    }
}
