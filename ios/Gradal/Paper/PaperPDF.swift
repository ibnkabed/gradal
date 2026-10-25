import Foundation
import UIKit
import WebKit

enum PaperPDFError: LocalizedError {
    case failed

    var errorDescription: String? { "تعذّر تجهيز ورقة الأسئلة" }
}

/// The question paper (mark false) or the answer model (mark true), A4, paginated. Port of
/// reference/paper.py paper_html(): the same HTML and CSS, laid out by WebKit offscreen and printed
/// page by page into a PDF.
enum PaperPDF {
    static let css = """
    @page { size: A4; margin: 12mm 12mm 14mm }
    * { box-sizing: border-box }
    body { margin: 0; font: 11.5pt/1.45 'Segoe UI', Tahoma, Arial, sans-serif; color: #000 }
    table.head { width: 100%; border: 1.2px solid #000; border-collapse: collapse; margin-bottom: 4mm }
    table.head td { vertical-align: middle; padding: 2mm 3mm; font-size: 10pt; line-height: 1.5 }
    table.head td.mid { text-align: center; width: 34% }
    table.head td.mid img { max-height: 18mm; max-width: 40mm }
    .who { display: flex; gap: 6mm; margin-bottom: 3mm; font-size: 10.5pt }
    .who span { flex: 1; border-bottom: 1px dotted #000; padding-bottom: 1mm }
    .note { font-size: 10pt; margin: 0 0 3mm; padding: 1.5mm 3mm; border: 1px solid #000; border-radius: 2mm; background: #f2f2f2 }
    h2 { font-size: 11.5pt; margin: 4mm 0 2mm; padding: 1mm 2mm; background: #e6e6e6; border-radius: 1.5mm }
    .q { break-inside: avoid; page-break-inside: avoid; padding: 1.6mm 0 1.8mm; border-bottom: 1px solid #ddd }
    .q .t { font-weight: 600 }
    .q .n { display: inline-block; min-width: 7mm; font-weight: 700 }
    .opts { display: grid; grid-template-columns: repeat(4, 1fr); gap: 1mm 4mm; margin-top: 1mm; padding-inline-start: 7mm }
    .opts.tf { grid-template-columns: repeat(4, 1fr) }
    .opt b { margin-inline-end: 1.5mm }
    .opt.right { font-weight: 700; text-decoration: underline }
    .opt.right::after { content: " ✔" }
    table.head.ar { direction: ltr; font-size: 10pt }
    table.head.ar td { padding: 0.6mm 2mm; line-height: 1.35; font-weight: 700; direction: rtl }
    table.head.ar td.val { text-align: center; width: 19% }
    table.head.ar td.lab { text-align: right; width: 9.5%; white-space: nowrap }
    table.head.ar td.logo { text-align: center; width: 48.5% }
    table.head.ar td.logo img { max-height: 21mm; max-width: 45mm }
    table.head.ar td.min { text-align: center; width: 23% }
    .title { text-align: center; font-weight: 700; font-size: 12.5pt; margin: 0 0 3mm }
    """

    private struct Texts {
        let name, cls, note, model, good: String
        let letters: [String]
        let tf: [String]

        static func of(_ lang: String) -> Texts {
            if lang == "ar" {
                return Texts(name: "اسم الطالب:", cls: "الفصل:", note: "أجب في ورقة الإجابة بتظليل دائرة واحدة لكل سؤال.",
                             model: "نموذج الإجابة", good: "انتهت الأسئلة، بالتوفيق",
                             letters: ["أ", "ب", "ج", "د"], tf: ["صح", "خطأ"])
            }
            return Texts(name: "Student's name:", cls: "Class:", note: "Answer on the answer sheet: fill one circle per question.",
                         model: "Answer key", good: "End of the questions. Good luck!",
                         letters: ["A", "B", "C", "D"], tf: ["True", "False"])
        }
    }

    /// A4 in points, and the printed area inside the page margins of the CSS @page (12 mm, 14 mm at the bottom).
    static let paperRect = CGRect(x: 0, y: 0, width: 595.2756, height: 841.8898)
    static let printableRect = CGRect(x: 34.0157, y: 34.0157, width: 595.2756 - 2 * 34.0157,
                                      height: 841.8898 - 34.0157 - 39.6850)

    /// The question paper (mark false) or the answer model (mark true), A4, paginated. Port of reference/paper.py.
    @MainActor static func make(quiz: Quiz, paper: Paper, settings: Settings, mark: Bool) async throws -> Data {
        let page = html(quiz: quiz, paper: paper, settings: settings, mark: mark)
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 595, height: 842), configuration: WKWebViewConfiguration())
        let loader = PaperLoader()
        webView.navigationDelegate = loader
        try await loader.load(page, in: webView)

        let renderer = UIPrintPageRenderer()
        renderer.addPrintFormatter(webView.viewPrintFormatter(), startingAtPageAt: 0)
        renderer.setValue(NSValue(cgRect: paperRect), forKey: "paperRect")
        renderer.setValue(NSValue(cgRect: printableRect), forKey: "printableRect")
        let count = renderer.numberOfPages
        guard count > 0 else { throw PaperPDFError.failed }

        let data = NSMutableData()
        UIGraphicsBeginPDFContextToData(data, paperRect, [kCGPDFContextTitle as String: quiz.name])
        renderer.prepare(forDrawingPages: NSRange(location: 0, length: count))
        let bounds = UIGraphicsGetPDFContextBounds()
        for i in 0..<count {
            UIGraphicsBeginPDFPage()
            renderer.drawPage(at: i, in: bounds)
        }
        UIGraphicsEndPDFContext()
        withExtendedLifetime(webView) {}
        withExtendedLifetime(loader) {}
        guard data.length > 0 else { throw PaperPDFError.failed }
        return data as Data
    }

    // MARK: - HTML (paper_html)

    static func escape(_ s: String) -> String {
        var out = ""
        for ch in s {
            switch ch {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&#x27;"
            default: out.append(ch)
            }
        }
        return out
    }

    /// The school lines on the right, the logo in the middle, the quiz lines on the left (always right to left,
    /// like the answer sheet).
    static func headerHTML(settings: Settings, quiz: Quiz) -> String {
        if quiz.isArabic { return arabicHeaderHTML(settings: settings, quiz: quiz) }
        let school = Array(settings.lines.prefix(4))
        let mine = Array(quiz.header.lines.prefix(4))
        let right = school.enumerated().map { i, t in i == 0 ? "<b>\(escape(t))</b>" : escape(t) }.joined(separator: "<br>")
        let left = mine.enumerated().map { i, t in i == 0 ? "<b>\(escape(t))</b>" : escape(t) }.joined(separator: "<br>")
        var mid = ""
        if let logo = settings.headerLogo {
            mid = "<img src=\"data:image/png;base64,\(logo.base64EncodedString())\" alt=\"\">"
        }
        return "<table class=\"head\" dir=\"rtl\"><tr><td style=\"text-align:right\">\(right)</td><td class=\"mid\">\(mid)</td>"
            + "<td style=\"text-align:left\" dir=\"auto\">\(left)</td></tr></table>"
    }

    /// The Arabic papers' header, as in the owner's Arabic letters: the ministry lines on the right, the logo in the
    /// middle, «المدرسة / المادة / الصف / المعلم» with their values on the left; the test's name under it.
    static func arabicHeaderHTML(settings: Settings, quiz: Quiz) -> String {
        let ministry = Array(settings.lines.prefix(4))
        let labels = ["المدرسة:", "المادة:", "الصف:", "المعلم:"]
        let values = [settings.schoolName, quiz.header.subject, quiz.header.grade, settings.teacher]
        var logo = ""
        if let data = settings.headerLogo {
            logo = "<img src=\"data:image/png;base64,\(data.base64EncodedString())\" alt=\"\">"
        }
        var rows = ""
        for i in 0..<4 {
            rows += "<tr><td class=\"val\">\(escape(values[i]))</td><td class=\"lab\">\(labels[i])</td>"
            if i == 0 { rows += "<td class=\"logo\" rowspan=\"4\">\(logo)</td>" }
            rows += "<td class=\"min\">\(escape(i < ministry.count ? ministry[i] : ""))</td></tr>"
        }
        return "<table class=\"head ar\">\(rows)</table><div class=\"title\">\(escape(quiz.name))</div>"
    }

    static func html(quiz: Quiz, paper: Paper, settings: Settings, mark: Bool) -> String {
        let lang = quiz.language == "ar" ? "ar" : "en"
        let T = Texts.of(lang)
        var out: [String] = []
        out.append("<!DOCTYPE html><html lang=\"\(lang)\" dir=\"\(lang == "ar" ? "rtl" : "ltr")\"><head><meta charset=\"utf-8\">"
                   + "<title>\(escape(quiz.name))</title><style>\(css)</style></head><body>")
        out.append(headerHTML(settings: settings, quiz: quiz))
        if mark {
            out.append("<div class=\"note\"><b>\(T.model)</b> — \(escape(quiz.name)) (\(quiz.code))</div>")
        } else {
            out.append("<div class=\"who\"><span>\(T.name)</span><span style=\"flex:.45\">\(T.cls)</span></div>")
            out.append("<div class=\"note\">\(T.note)</div>")
        }
        var sections: [Int: String] = [:]
        for s in quiz.sections { sections[s.from] = s.name }    // a later section with the same start wins
        for (i, q) in paper.questions.enumerated() {
            let n = i + 1
            if let name = sections[n] {
                out.append("<h2>\(escape(name))</h2>")
            }
            let opts = q.kind == .mcq ? q.options : T.tf
            let right = q.answer    // tf: 0 = true (صح), 1 = false (خطأ)
            var cells = ""
            for (j, o) in opts.enumerated() where j < T.letters.count {
                cells += "<div class=\"opt\(mark && j == right ? " right" : "")\"><b>\(T.letters[j]))</b>\(escape(o))</div>"
            }
            out.append("<div class=\"q\"><div class=\"t\"><span class=\"n\">\(n).</span> \(escape(q.text))</div>"
                       + "<div class=\"opts\(q.kind == .tf ? " tf" : "")\">\(cells)</div></div>")
        }
        out.append("<p style=\"text-align:center;margin-top:5mm;font-weight:600\">\(T.good)</p>")
        out.append("</body></html>")
        return out.joined()
    }
}

/// Waits for the offscreen web view to finish loading the page (or fail, or time out).
@MainActor
private final class PaperLoader: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<Void, Error>?

    func load(_ html: String, in webView: WKWebView) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            continuation = cont
            webView.loadHTMLString(html, baseURL: nil)
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                self?.finish(PaperPDFError.failed)
            }
        }
    }

    private func finish(_ error: Error?) {
        guard let cont = continuation else { return }
        continuation = nil
        if let error { cont.resume(throwing: error) } else { cont.resume() }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finish(nil)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finish(PaperPDFError.failed)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finish(PaperPDFError.failed)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        finish(PaperPDFError.failed)
    }
}
