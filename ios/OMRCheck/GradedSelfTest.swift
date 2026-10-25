import CoreGraphics
import Foundation
import ImageIO

/// OMRCheck --graded <sheets dir> <sheet-layouts.json> <out dir>
/// The correction copy (ReviewImage + GradedPage) of the first test sheets, written as graded.pdf and graded-1.png so
/// it can be looked at: the key differs from the paper on every third question, question 2 is worth 2 points and
/// question 5 is not counted. Fails when a sheet is not read or the PDF comes out empty.
func gradedSelfTest(sheets: URL, layoutsURL: URL, out: URL) -> Bool {
    guard let layouts = try? SheetLayouts.load(from: layoutsURL) else {
        print("FAIL: cannot read \(layoutsURL.path)")
        return false
    }
    try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    let names = ((try? FileManager.default.contentsOfDirectory(atPath: sheets.path)) ?? [])
        .filter { $0.hasSuffix(".jpg") }.sorted().prefix(4)
    let r = layouts.bubbleDiameterMm / 2
    var pages: [GradedPage.Page] = []
    for (n, name) in names.enumerated() {
        let jpg = sheets.appendingPathComponent(name)
        guard let gray = loadGray(jpg),
              let data = try? Data(contentsOf: jpg.deletingPathExtension().appendingPathExtension("json")),
              let truth = try? JSONDecoder().decode(Truth.self, from: data),
              let bubbles = truth.sheet?.questionBubbles,
              let read = SheetReader.read(gray, layouts: layouts, questionCount: truth.questionCount,
                                          questionBubbles: bubbles) else {
            print("FAIL: \(name) not read")
            return false
        }
        let review = ReviewImage.warp(gray, read.homography, widthMm: layouts.page.widthMm,
                                      heightMm: layouts.page.heightMm)
        var possible = 0.0, earned = 0.0
        let questions = (0..<min(truth.questionCount, bubbles.count)).map { i -> GradedPage.Question in
            let answer = i < read.answers.count ? read.answers[i] : ""
            let truthAnswer = i < truth.answers.count ? truth.answers[i] : ""
            var key = truthAnswer.isEmpty ? "B" : String(truthAnswer.prefix(1))
            if i % 3 == 2 { key = GradedPage.letters.first { !answer.contains($0) } ?? "A" }
            if i == 4 { key = "" }
            let points = i == 1 ? 2.0 : 1.0
            let right = !key.isEmpty && answer.count == 1 && key.contains(answer)
            if !key.isEmpty { possible += points }
            if right { earned += points }
            return GradedPage.Question(bubbles: bubbles[i], answer: answer, key: key, earned: right ? points : 0)
        }
        pages.append(GradedPage.Page(image: ReviewImage.cgImage(review), questions: questions, earned: earned,
                                     possible: possible, scoreLabel: n % 2 == 0 ? "Score" : "الدرجة", noImage: ""))
        if n == 0, let cg = GradedPage.image(pages[0], bubbleRadiusMm: r),
           let dest = CGImageDestinationCreateWithURL(out.appendingPathComponent("graded-1.png") as CFURL,
                                                      "public.png" as CFString, 1, nil) {
            CGImageDestinationAddImage(dest, cg, nil)
            CGImageDestinationFinalize(dest)
        }
    }
    if let last = pages.last {
        pages.append(GradedPage.Page(image: nil, questions: last.questions, earned: last.earned, possible: last.possible,
                                     scoreLabel: "Score", noImage: "صورة هذه الورقة ليست على هذا الجوال"))
    }
    let pdf = GradedPage.pdf(pages, bubbleRadiusMm: r)
    guard pages.count >= 2, pdf.count > 20_000 else {
        print("FAIL: graded PDF has \(pages.count) page(s), \(pdf.count) bytes")
        return false
    }
    do {
        try pdf.write(to: out.appendingPathComponent("graded.pdf"), options: .atomic)
    } catch {
        print("FAIL: cannot write graded.pdf: \(error)")
        return false
    }
    print("graded: \(pages.count) page(s), \(pdf.count / 1024) KB in \(out.path)")
    return true
}
