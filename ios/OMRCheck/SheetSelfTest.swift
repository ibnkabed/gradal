import CoreGraphics
import Foundation
import ImageIO

/// OMRCheck --sheet-selftest: renders answer sheets with AnswerSheetPDF (the app's own drawing), rasterises
/// page 1 at 6 px/mm and reads it back with SheetReader. For each quiz (Arabic and English; 5, 20, 37 and
/// 60 questions; with and without sections; a random one-letter key per question): the key sheet must
/// read as the key, the personalised sheet (ID 312, nothing marked) as ID 312 with every answer blank,
/// both with the quiz's code and version 0. Returns the failures; with outDir, also writes PNGs of the
/// Arabic and English key sheets and one personalised sheet there.
func sheetSelfTest(layouts: SheetLayouts, outDir: URL?) -> [String] {
    var failures: [String] = []
    var rng = SelfTestRandom(seed: 0x6772_6164_616C)
    let pxPerMm = 6.0
    let personId = "312"
    if let outDir {
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
    }
    var settings = Settings()
    settings.schoolLines = ["المملكة العربية السعودية", "وزارة التعليم", "مدرسة الاختبار", ""]
    var wrotePersonal = false

    for language in ["ar", "en"] {
        for count in [5, 20, 37, 60] {
            for withSections in [false, true] {
                let label = "\(language) \(count)q \(withSections ? "sections" : "no sections")"
                let key = (0..<count).map { _ in layouts.choices[Int(rng.next() % UInt64(layouts.choices.count))] }
                var sections: [QuizSection] = []
                if withSections {
                    let names = language == "ar" ? ["المفردات", "القواعد", "القراءة"] : ["Vocabulary", "Grammar", "Reading"]
                    let a = max(1, count * 2 / 5), b = max(a + 1, count * 4 / 5)
                    sections.append(QuizSection(name: names[0], from: 1, to: a))
                    if b <= count { sections.append(QuizSection(name: names[1], from: a + 1, to: b)) }
                    if count >= 20 { sections.append(QuizSection(name: names[2], from: b + 1, to: count - 2)) }  // 2 uncovered
                }
                let code = 1000 + Int(rng.next() % 9000)
                var quiz = Quiz(code: code, name: language == "ar" ? "اختبار \(count)" : "Quiz \(count)",
                                date: "2026-10-25", classIds: [], language: language, key: key, sections: sections,
                                header: QuizHeader(subject: language == "ar" ? "اللغة الإنجليزية" : "English",
                                                   title: language == "ar" ? "اختبار قصير" : "Short quiz",
                                                   grade: language == "ar" ? "أول ثانوي" : "Grade 10", extra: ""))
                do {
                    quiz.sheet = try SheetGeometry.compute(questionCount: count, sections: sections,
                                                           rtl: language == "ar", layout: layouts)
                } catch {
                    failures.append("\(label): no geometry: \(error.localizedDescription)")
                    continue
                }
                let bubbles = quiz.sheet?.questionBubbles

                // (a) the key sheet
                let keyPDF = AnswerSheetPDF.make(quiz: quiz, people: [], settings: settings, layout: layouts, key: true)
                if let page = rasterizeFirstPage(keyPDF, pxPerMm: pxPerMm) {
                    if let outDir, count == 20, withSections {
                        writePNG(page.image, to: outDir.appendingPathComponent("key-\(language)-\(count)q.png"))
                    }
                    if let res = SheetReader.read(page.gray, layouts: layouts, questionCount: count, questionBubbles: bubbles) {
                        var errs: [String] = []
                        if res.quizCode != code { errs.append("code \(res.quizCode) != \(code)") }
                        if res.version != 0 { errs.append("version \(res.version) != 0") }
                        for q in 0..<count {
                            let got = q < res.answers.count ? res.answers[q] : "(missing)"
                            if got != key[q] {
                                let dark = q < res.darkness.count ? "\(res.darkness[q])" : ""
                                errs.append("q\(q + 1) '\(got)' != '\(key[q])' \(dark)")
                            }
                        }
                        if errs.isEmpty {
                            print("\(label) key sheet: ok")
                        } else {
                            failures.append("\(label) key sheet: " + errs.prefix(8).joined(separator: "; ")
                                            + (errs.count > 8 ? "; ... \(errs.count - 8) more" : ""))
                        }
                    } else {
                        failures.append("\(label) key sheet: NOT FOUND by the reader")
                    }
                } else {
                    failures.append("\(label) key sheet: cannot rasterise the PDF (\(keyPDF.count) bytes)")
                }

                // (b) a personalised sheet, nothing marked
                let person = SheetPerson(studentName: language == "ar" ? "محمد عبدالله" : "Sam Carter", gradalId: personId,
                                         className: language == "ar" ? "أول ثانوي 1" : "10A")
                let personalPDF = AnswerSheetPDF.make(quiz: quiz, people: [person], settings: settings, layout: layouts,
                                                      key: false)
                if let page = rasterizeFirstPage(personalPDF, pxPerMm: pxPerMm) {
                    if let outDir, !wrotePersonal, language == "ar", count == 37 {
                        writePNG(page.image, to: outDir.appendingPathComponent("personal-\(language)-\(count)q.png"))
                        wrotePersonal = true
                    }
                    if let res = SheetReader.read(page.gray, layouts: layouts, questionCount: count, questionBubbles: bubbles) {
                        var errs: [String] = []
                        if res.quizCode != code { errs.append("code \(res.quizCode) != \(code)") }
                        if res.version != 0 { errs.append("version \(res.version) != 0") }
                        if res.studentId != personId { errs.append("id '\(res.studentId)' != '\(personId)'") }
                        if res.answers.count != count { errs.append("\(res.answers.count) answers, expected \(count)") }
                        for (q, a) in res.answers.enumerated() where !a.isEmpty {
                            let dark = q < res.darkness.count ? "\(res.darkness[q])" : ""
                            errs.append("q\(q + 1) '\(a)' != '' \(dark)")
                        }
                        if errs.isEmpty {
                            print("\(label) personalised sheet: ok")
                        } else {
                            failures.append("\(label) personalised sheet: " + errs.prefix(8).joined(separator: "; ")
                                            + (errs.count > 8 ? "; ... \(errs.count - 8) more" : ""))
                        }
                    } else {
                        failures.append("\(label) personalised sheet: NOT FOUND by the reader")
                    }
                } else {
                    failures.append("\(label) personalised sheet: cannot rasterise the PDF (\(personalPDF.count) bytes)")
                }
            }
        }
    }
    return failures
}

/// Page 1 of a PDF drawn on white into an 8-bit gray bitmap at pxPerMm, as the reader's GrayImage
/// (row 0 at the top, like loadGray) and as a CGImage for the PNGs.
func rasterizeFirstPage(_ pdf: Data, pxPerMm: Double) -> (gray: GrayImage, image: CGImage)? {
    guard let provider = CGDataProvider(data: pdf as CFData),
          let document = CGPDFDocument(provider),
          let page = document.page(at: 1) else { return nil }
    let box = page.getBoxRect(.mediaBox)
    let scale = CGFloat(pxPerMm * 25.4 / 72.0)
    let w = Int((box.width * scale).rounded()), h = Int((box.height * scale).rounded())
    guard w > 0, h > 0,
          let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpaceCreateDeviceGray(),
                              bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
    ctx.setFillColor(CGColor(gray: 1, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    ctx.interpolationQuality = .high
    ctx.scaleBy(x: scale, y: scale)
    ctx.translateBy(x: -box.minX, y: -box.minY)
    ctx.drawPDFPage(page)
    guard let data = ctx.data, let image = ctx.makeImage() else { return nil }
    let stride = ctx.bytesPerRow
    let src = data.assumingMemoryBound(to: UInt8.self)
    var pixels = [UInt8](repeating: 255, count: w * h)
    for y in 0..<h {
        for x in 0..<w { pixels[y * w + x] = src[y * stride + x] }
    }
    return (GrayImage(width: w, height: h, pixels: pixels), image)
}

func writePNG(_ image: CGImage, to url: URL) {
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
        print("cannot write \(url.path)")
        return
    }
    CGImageDestinationAddImage(dest, image, nil)
    if CGImageDestinationFinalize(dest) {
        print("wrote \(url.path)")
    } else {
        print("cannot write \(url.path)")
    }
}

/// A small, repeatable generator (SplitMix64) so every run checks the same sheets.
struct SelfTestRandom {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
