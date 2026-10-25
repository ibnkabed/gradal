import Foundation
import PDFKit

/// A book's pages for the question writer (port of reference/books.py pages_text and pages_pdf). The text
/// rules (Arabic fix, readability) are in ExamRules.swift (BookRules). Pages are 1-based and inclusive.
enum BookText {
    static let maxPages = BookRules.maxPages

    static func pageCount(_ url: URL) -> Int {
        PDFDocument(url: url)?.pageCount ?? 0
    }

    private static func open(_ url: URL) throws -> PDFDocument {
        guard let doc = PDFDocument(url: url) else { throw BookError("تعذّر فتح ملف PDF") }
        return doc
    }

    /// The text of pages a...b in the PDF's own order, and whether it is real text (false: scanned images,
    /// so Gemini must read the pages itself).
    static func text(_ url: URL, from a: Int, to b: Int) throws -> (text: String, readable: Bool) {
        let doc = try open(url)
        try BookRules.checkRange(from: a, to: b, pages: doc.pageCount)
        var chunks: [String] = []
        for i in (a - 1)..<b {
            chunks.append(doc.page(at: i)?.string ?? "")
        }
        let text = BookRules.tidy(chunks.joined(separator: "\n"))
        return (text, BookRules.isReadable(text, pages: b - a + 1))
    }

    /// Pages a...b as a small PDF of their own (for Gemini).
    static func subset(_ url: URL, from a: Int, to b: Int) throws -> Data {
        let doc = try open(url)
        try BookRules.checkRange(from: a, to: b, pages: doc.pageCount)
        let out = PDFDocument()
        for i in (a - 1)..<b {
            guard let page = doc.page(at: i)?.copy() as? PDFPage else { continue }
            out.insert(page, at: out.pageCount)
        }
        guard out.pageCount > 0, let data = out.dataRepresentation() else { throw BookError("تعذّر فتح ملف PDF") }
        return data
    }
}
