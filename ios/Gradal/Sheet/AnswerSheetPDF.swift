import CoreGraphics
import CoreText
import Foundation
import ImageIO

/// Whose answer sheet a page is: printed in the name box, the class line and the pre-filled ID bubbles.
struct SheetPerson: Hashable {
    var studentName: String
    var gradalId: String
    var className: String
}

/// The quiz code in the barcode cells. Port of reference/sheets.py crc6 / encode (the same bits as
/// SheetReader.readBarcode reads).
enum SheetBarcode {
    static func crc6(_ value: Int, _ nbits: Int, _ poly: Int = 0x03) -> Int {
        var crc = 0
        var i = nbits - 1
        while i >= 0 {
            let bit = (value >> i) & 1
            let top = (crc >> 5) & 1
            crc = (crc << 1) & 0x3F
            if top ^ bit != 0 { crc ^= poly }
            i -= 1
        }
        return crc
    }

    /// One bit per barcode cell, most significant first; nil when code or version is out of range.
    static func encode(_ code: Int, version: Int, layout: SheetLayouts) -> [Int]? {
        let b = layout.barcode
        guard code >= 0 && code < (1 << b.codeBits) && version >= 0 && version < (1 << b.versionBits) else { return nil }
        let payload = (code << b.versionBits) | version
        let word = (payload << b.crcBits) | crc6(payload, b.codeBits + b.versionBits, b.crcPoly)
        return (0..<b.bits).map { i in (word >> (b.bits - 1 - i)) & 1 }
    }
}

/// Printable answer sheets, one A4 page per person. Port of reference/sheets.py page_shapes() and
/// header_shapes(): the same shapes in the same order, colours, stroke widths and font sizes. The frame
/// (markers, orientation mark, barcode, ID bubbles) comes from shared/sheet-layouts.json and the question
/// area from quiz.sheet; the reader depends on these exact positions and on pure black.
///
/// CoreGraphics, CoreText and ImageIO only (no UIKit), so OMRCheck renders the same pages on macOS and
/// reads them back (`OMRCheck --sheet-selftest`).
enum AnswerSheetPDF {
    /// Points per millimetre.
    static let k: CGFloat = 72.0 / 25.4

    static let ink = CGColor(gray: 0, alpha: 1)
    static let paper = CGColor(gray: 1, alpha: 1)
    static let bubbleStroke = hex(0x555555)
    static let boxStroke = hex(0x5f5f5f)
    static let band = hex(0xe6e6e6)
    static let letter = hex(0xa8a8a8)
    static let soft = hex(0x6b7280)

    enum Anchor { case start, middle, end }
    enum Weight { case regular, bold }

    private struct Labels {
        let name, cls, code, id, key, correct, wrong: String
        let rules: [String]
        let choices: [String]

        static func of(_ language: String) -> Labels {
            if language == "ar" {
                return Labels(name: "الاسم", cls: "الفصل:", code: "رمز", id: "رقم الطالب", key: "مفتاح الإجابة",
                              correct: "صحيح", wrong: "خطأ",
                              rules: ["ظلّل دائرة واحدة لكل سؤال", "تظليلًا كاملًا بقلم رصاص داكن", "أو أزرق، وامسح الخطأ جيدًا."],
                              choices: Grading.arabicLetters)
            }
            return Labels(name: "Name", cls: "Class:", code: "Code", id: "Student ID", key: "ANSWER KEY",
                          correct: "Correct", wrong: "Wrong",
                          rules: ["Fill one circle per question", "completely with a dark pencil", "or blue pen. Erase mistakes."],
                          choices: Grading.letters)
        }
    }

    /// One A4 page per person (or one blank page when `people` is empty); key: fill the right bubbles
    /// and print the key label in the name box. Port of reference/sheets.py page_shapes() + header.
    static func make(quiz: Quiz, people: [SheetPerson], settings: Settings, layout: SheetLayouts, key: Bool) -> Data {
        let width = CGFloat(layout.page.widthMm) * k, height = CGFloat(layout.page.heightMm) * k
        var mediaBox = CGRect(x: 0, y: 0, width: width, height: height)
        let data = NSMutableData()
        let info = [kCGPDFContextTitle as String: quiz.name.isEmpty ? "Gradal" : quiz.name,
                    kCGPDFContextCreator as String: "Gradal"] as CFDictionary
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, info) else { return Data() }
        let pages = people.isEmpty ? [SheetPerson(studentName: "", gradalId: "", className: "")] : people
        let sheet = quiz.sheet ?? (try? SheetGeometry.compute(questionCount: quiz.questionCount, sections: quiz.sections,
                                                               rtl: quiz.isArabic, layout: layout))
        let logo = settings.headerLogo.flatMap { loadImage($0) }
        for person in pages {
            ctx.beginPDFPage(nil)
            ctx.saveGState()
            // PDF space is bottom-left in points; from here on, millimetres from the top-left corner
            ctx.translateBy(x: 0, y: height)
            ctx.scaleBy(x: k, y: -k)
            fillRect(ctx, 0, 0, layout.page.widthMm, layout.page.heightMm, paper)
            drawPage(ctx, quiz: quiz, sheet: sheet, person: person, settings: settings, logo: logo, layout: layout, key: key)
            ctx.restoreGState()
            ctx.endPDFPage()
        }
        ctx.closePDF()
        return data as Data
    }

    // MARK: - Page (page_shapes)

    private static func drawPage(_ ctx: CGContext, quiz: Quiz, sheet: QuizSheet?, person: SheetPerson, settings: Settings,
                                 logo: CGImage?, layout L: SheetLayouts, key: Bool) {
        let P = L.print
        let T = Labels.of(quiz.language)
        let rtl = quiz.language == "ar"
        let code = quiz.code
        let r = L.bubbleDiameterMm / 2
        drawHeader(ctx, P.headerBox, settings: settings, quiz: quiz, logo: logo)

        // frame: corner markers, orientation mark, barcode — solid black
        let m = L.markers.sizeMm
        for c in L.markers.centers where c.count >= 2 {
            fillRect(ctx, c[0] - m / 2, c[1] - m / 2, m, m, ink)
        }
        let o = L.orientationMark
        if o.center.count >= 2 {
            fillRect(ctx, o.center[0] - o.sizeMm / 2, o.center[1] - o.sizeMm / 2, o.sizeMm, o.sizeMm, ink)
        }
        if L.barcode.cellMm.count >= 2, let bits = SheetBarcode.encode(code, version: 0, layout: L) {
            let cw = L.barcode.cellMm[0], ch = L.barcode.cellMm[1]
            for (bit, cell) in zip(bits, L.barcode.cells) where bit != 0 && cell.count >= 2 {
                fillRect(ctx, cell[0] - cw / 2, cell[1] - ch / 2, cw, ch, ink)
            }
        }

        // name box, class, quiz
        if P.nameBox.count >= 4 {
            let nx0 = P.nameBox[0], ny0 = P.nameBox[1], nx1 = P.nameBox[2], ny1 = P.nameBox[3]
            strokeRect(ctx, nx0, ny0, nx1 - nx0, ny1 - ny0, ink, 0.3)
            drawText(ctx, T.name, at: pt(rtl ? nx1 - 1.5 : nx0 + 1.5, ny0 + 2.6), sizeMm: 2.3,
                     anchor: rtl ? .end : .start, color: soft, vCenter: true)
            let shown = key ? T.key : person.studentName
            if !shown.isEmpty {
                drawText(ctx, shown, at: pt((nx0 + nx1) / 2, ny0 + (ny1 - ny0) * 0.62), sizeMm: 4.2, anchor: .middle,
                         weight: .bold, vCenter: true)
            }
        }
        if P.infoAt.count >= 2 {
            let ix = P.infoAt[0], iy = P.infoAt[1]
            let className = prefix(person.className, 22)
            let quizName = prefix(quiz.name, 26)
            if rtl {   // one right-aligned run per line: Arabic reads well as a whole
                let rx = ix + 30.0
                if !className.isEmpty {
                    drawText(ctx, "\(T.cls) \(className)", at: pt(rx, iy - 4.0), sizeMm: 2.9, anchor: .end, weight: .bold,
                             vCenter: true)
                }
                drawText(ctx, "\(T.code) \(code)", at: pt(rx, iy + 1.5), sizeMm: 2.6, anchor: .end, color: soft,
                         vCenter: true)
                if !quiz.name.isEmpty {
                    drawText(ctx, quizName, at: pt(rx, iy + 6.3), sizeMm: 2.5, anchor: .end, color: soft, vCenter: true)
                }
            } else {   // separate text runs, so the bidi algorithm cannot reorder them
                if !className.isEmpty {
                    drawText(ctx, T.cls, at: pt(ix, iy - 4.0), sizeMm: 2.9, weight: .bold, vCenter: true)
                    drawText(ctx, className, at: pt(ix + 10.6, iy - 4.0), sizeMm: 2.9, vCenter: true)
                }
                drawText(ctx, T.code, at: pt(ix, iy + 1.5), sizeMm: 2.6, color: soft, vCenter: true)
                drawText(ctx, String(code), at: pt(ix + 10.6, iy + 1.5), sizeMm: 2.6, color: soft, vCenter: true)
                if !quiz.name.isEmpty {
                    drawText(ctx, quizName, at: pt(ix, iy + 6.3), sizeMm: 2.5, color: soft, vCenter: true)
                }
            }
        }

        // student ID: label, write-in boxes, bubbles 0-9 (pre-filled solid when personalised)
        if P.idLabelAt.count >= 2 {
            drawText(ctx, T.id, at: pt(P.idLabelAt[0], P.idLabelAt[1]), sizeMm: 2.8, anchor: .middle, weight: .bold,
                     vCenter: true)
        }
        if P.idBoxesY.count >= 2 {
            let by0 = P.idBoxesY[0], by1 = P.idBoxesY[1]
            let gid = Array(person.gradalId.filter { ch in
                if let v = ch.wholeNumberValue { return (0...9).contains(v) }
                return false
            }.prefix(L.idDigits))
            for (d, column) in L.idBubbles.enumerated() {
                guard let first = column.first, first.count >= 2 else { continue }
                let cx = first[0]
                let bw = 5.2
                strokeRect(ctx, cx - bw / 2, by0, bw, by1 - by0, ink, 0.25)
                if d < gid.count {
                    drawText(ctx, String(gid[d]), at: pt(cx, (by0 + by1) / 2), sizeMm: 3.6, anchor: .middle, weight: .bold,
                             vCenter: true)
                }
                for (v, p) in column.enumerated() where p.count >= 2 {
                    let filled = d < gid.count && gid[d].wholeNumberValue == v
                    circle(ctx, p[0], p[1], r, filled: filled)
                    if !filled {
                        drawText(ctx, String(v), at: pt(p[0], p[1]), sizeMm: 2.0, anchor: .middle, color: letter,
                                 vCenter: true)
                    }
                }
            }
        }

        // instructions, in the free space under the ID block; the sample bubbles stay at the same place
        let tx = rtl ? 190.0 : 159.5
        let anchor: Anchor = rtl ? .end : .start
        if let lastBubble = L.idBubbles.first?.last, lastBubble.count >= 2 {
            let ay = lastBubble[1] + 11
            for (i, line) in T.rules.enumerated() {
                drawText(ctx, line, at: pt(tx, ay + Double(i) * 4.2), sizeMm: 2.5, anchor: anchor, vCenter: true)
            }
            let exY = ay + Double(T.rules.count) * 4.2 + 3.5
            let sx = rtl ? 163.0 : 175.5
            drawText(ctx, T.correct, at: pt(tx, exY), sizeMm: 2.7, anchor: anchor, weight: .bold, vCenter: true)
            circle(ctx, sx, exY, r, filled: true)
            drawText(ctx, T.wrong, at: pt(tx, exY + 6), sizeMm: 2.7, anchor: anchor, weight: .bold, vCenter: true)
            for (i, mark) in ["✓", "✗", "•"].enumerated() {
                let cx = sx + Double(i) * 5.4
                circle(ctx, cx, exY + 6, r, filled: false)
                drawText(ctx, mark, at: pt(cx, exY + 6), sizeMm: 2.6, anchor: .middle, vCenter: true)
            }
        }

        // the question area: one column of framed boxes per section (quiz.sheet)
        guard let sheet else { return }
        let bubbles = sheet.questionBubbles
        let letters = T.choices
        for col in sheet.columns {
            for bx in col.boxes {
                let rr = 1.5
                fillBand(ctx, bx.x0, bx.y0, bx.x1, bx.titleY1, rr, band)
                strokeLine(ctx, bx.x0, bx.titleY1, bx.x1, bx.titleY1, boxStroke, 0.25)
                strokeRect(ctx, bx.x0, bx.y0, bx.x1 - bx.x0, bx.y1 - bx.y0, boxStroke, 0.3, rx: rr)
                drawText(ctx, bx.title, at: pt((bx.x0 + bx.x1) / 2, (bx.y0 + bx.titleY1) / 2), sizeMm: 2.8,
                         anchor: .middle, weight: .bold, vCenter: true)
                guard bx.from >= 1 && bx.to >= bx.from else { continue }
                for q in bx.from...bx.to where q - 1 < bubbles.count {
                    let row = bubbles[q - 1]
                    guard let first = row.first, first.count >= 2 else { continue }
                    drawText(ctx, String(q), at: pt(bx.numberX, first[1]), sizeMm: 2.8,
                             anchor: bx.numberAnchorStart ? .start : .end, weight: .bold, vCenter: true)
                    let right = key && q - 1 < quiz.key.count ? quiz.key[q - 1] : ""
                    for (c, p) in row.enumerated() where p.count >= 2 {
                        if c < L.choices.count && !right.isEmpty && right.contains(L.choices[c]) {
                            circle(ctx, p[0], p[1], r, filled: true)
                            continue
                        }
                        circle(ctx, p[0], p[1], r, filled: false)
                        if c < letters.count {
                            drawText(ctx, letters[c], at: pt(p[0], p[1]), sizeMm: 2.1, anchor: .middle, color: letter,
                                     vCenter: true)
                        }
                    }
                }
            }
        }
    }

    /// header_shapes(): a bordered strip, the school lines on the right, the quiz lines on the left,
    /// the school's logo (if any) in the middle.
    private static func drawHeader(_ ctx: CGContext, _ box: [Double], settings: Settings, quiz: Quiz, logo: CGImage?) {
        guard box.count >= 4 else { return }
        if quiz.isArabic {
            drawArabicHeader(ctx, box, settings: settings, quiz: quiz, logo: logo)
            return
        }
        let x0 = box[0], y0 = box[1], x1 = box[2], y1 = box[3]
        let h = y1 - y0
        strokeRect(ctx, x0, y0, x1 - x0, h, ink, 0.35)
        let school = Array(settings.lines.prefix(4))
        let mine = Array(quiz.header.lines.prefix(4))
        let pitch = 3.9
        for (lines, x, anchor) in [(school, x1 - 3, Anchor.end), (mine, x0 + 3, Anchor.start)] {
            let top = y0 + h / 2 - pitch * Double(lines.count - 1) / 2
            for (i, line) in lines.enumerated() {
                drawText(ctx, line, at: pt(x, top + Double(i) * pitch), sizeMm: 2.9, anchor: anchor,
                         weight: i == 0 ? .bold : .regular, vCenter: true)
            }
        }
        if let logo {
            drawImageFit(ctx, logo, (x0 + x1) / 2 - 15, y0 + 1.5, 30, h - 3)
        }
    }

    /// The Arabic header (PaperPDF.arabicHeaderHTML on paper): columns as in the owner's letters (Word grid
    /// 1971 / 990 / 5070 / 2415 twips): values, labels, the logo, the ministry lines; four rows.
    private static func drawArabicHeader(_ ctx: CGContext, _ box: [Double], settings: Settings, quiz: Quiz, logo: CGImage?) {
        let x0 = box[0], y0 = box[1], x1 = box[2], y1 = box[3]
        let w = x1 - x0, h = y1 - y0
        strokeRect(ctx, x0, y0, w, h, ink, 0.35)
        let grid = [1971.0, 990.0, 5070.0, 2415.0]
        let total = grid.reduce(0, +)
        let valX1 = x0 + w * grid[0] / total
        let labX1 = valX1 + w * grid[1] / total
        let logoX1 = labX1 + w * grid[2] / total
        let ministry = Array(settings.lines.prefix(4))
        let labels = ["المدرسة:", "المادة:", "الصف:", "المعلم:"]
        let values = [settings.schoolName, quiz.header.subject, quiz.header.grade, settings.teacher]
        let pitch = (h - 2.0) / 4
        for i in 0..<4 {
            let y = y0 + 1.0 + pitch * (Double(i) + 0.5)
            let value = values[i].trimmingCharacters(in: .whitespaces)
            if !value.isEmpty {
                drawText(ctx, prefix(value, 30), at: pt((x0 + valX1) / 2, y), sizeMm: 2.7, anchor: .middle, weight: .bold, vCenter: true)
            }
            drawText(ctx, labels[i], at: pt(labX1 - 1.2, y), sizeMm: 2.7, anchor: .end, weight: .bold, vCenter: true)
            if i < ministry.count {
                drawText(ctx, ministry[i], at: pt((logoX1 + x1) / 2, y), sizeMm: 2.7, anchor: .middle, weight: .bold, vCenter: true)
            }
        }
        if let logo {
            drawImageFit(ctx, logo, (labX1 + logoX1) / 2 - 17, y0 + 1.0, 34, h - 2)
        }
    }

    // MARK: - Primitives (millimetres, y down; the context is scaled by k and flipped)

    private static func hex(_ v: Int) -> CGColor {
        CGColor(srgbRed: CGFloat((v >> 16) & 0xff) / 255, green: CGFloat((v >> 8) & 0xff) / 255,
                blue: CGFloat(v & 0xff) / 255, alpha: 1)
    }

    private static func pt(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: x, y: y) }

    /// The first `n` Unicode scalars, like Python's s[:n].
    private static func prefix(_ s: String, _ n: Int) -> String {
        var scalars = String.UnicodeScalarView()
        scalars.append(contentsOf: s.unicodeScalars.prefix(n))
        return String(scalars)
    }

    private static func isArabic(_ s: String) -> Bool {
        s.unicodeScalars.contains { $0.value >= 0x0600 && $0.value <= 0x06FF }
    }

    private static func loadImage(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    private static func fillRect(_ ctx: CGContext, _ x: Double, _ y: Double, _ w: Double, _ h: Double, _ color: CGColor) {
        ctx.setFillColor(color)
        ctx.fill(CGRect(x: x, y: y, width: w, height: h))
    }

    /// An outlined rectangle (the stroke centred on the edge, like SVG), corners rounded by rx.
    private static func strokeRect(_ ctx: CGContext, _ x: Double, _ y: Double, _ w: Double, _ h: Double,
                                   _ color: CGColor, _ sw: Double, rx: Double = 0) {
        let rect = CGRect(x: x, y: y, width: w, height: h)
        ctx.setStrokeColor(color)
        ctx.setLineWidth(CGFloat(sw))
        if rx > 0 {
            let radius = min(CGFloat(rx), rect.width / 2, rect.height / 2)
            ctx.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
            ctx.strokePath()
        } else {
            ctx.stroke(rect)
        }
    }

    private static func strokeLine(_ ctx: CGContext, _ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double,
                                   _ color: CGColor, _ sw: Double) {
        ctx.setStrokeColor(color)
        ctx.setLineWidth(CGFloat(sw))
        ctx.setLineCap(.butt)
        ctx.move(to: CGPoint(x: x1, y: y1))
        ctx.addLine(to: CGPoint(x: x2, y: y2))
        ctx.strokePath()
    }

    /// A bubble: solid black when filled (no outline), else outlined #555555, 0.2 mm.
    private static func circle(_ ctx: CGContext, _ cx: Double, _ cy: Double, _ r: Double, filled: Bool) {
        let rect = CGRect(x: cx - r, y: cy - r, width: 2 * r, height: 2 * r)
        if filled {
            ctx.setFillColor(ink)
            ctx.fillEllipse(in: rect)
        } else {
            ctx.setStrokeColor(bubbleStroke)
            ctx.setLineWidth(0.2)
            ctx.strokeEllipse(in: rect)
        }
    }

    /// A box's title band: top corners rounded like the box, flat bottom (the reference's _band path).
    private static func fillBand(_ ctx: CGContext, _ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double, _ r: Double,
                                 _ color: CGColor) {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: x0, y: y1))
        path.addLine(to: CGPoint(x: x0, y: y0 + r))
        path.addQuadCurve(to: CGPoint(x: x0 + r, y: y0), control: CGPoint(x: x0, y: y0))
        path.addLine(to: CGPoint(x: x1 - r, y: y0))
        path.addQuadCurve(to: CGPoint(x: x1, y: y0 + r), control: CGPoint(x: x1, y: y0))
        path.addLine(to: CGPoint(x: x1, y: y1))
        path.closeSubpath()
        ctx.setFillColor(color)
        ctx.addPath(path)
        ctx.fillPath()
    }

    /// The image fitted and centred in the box (SVG preserveAspectRatio="xMidYMid meet"), upright although
    /// the context is flipped.
    private static func drawImageFit(_ ctx: CGContext, _ image: CGImage, _ x: Double, _ y: Double, _ w: Double, _ h: Double) {
        let iw = Double(image.width), ih = Double(image.height)
        guard iw > 0, ih > 0, w > 0, h > 0 else { return }
        let s = min(w / iw, h / ih)
        let dw = iw * s, dh = ih * s
        let left = x + (w - dw) / 2, top = y + (h - dh) / 2
        ctx.saveGState()
        ctx.translateBy(x: CGFloat(left), y: CGFloat(top + dh))
        ctx.scaleBy(x: 1, y: -1)
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: dw, height: dh))
        ctx.restoreGState()
    }

    /// The system font at `size` points; bold is the emphasized system font.
    private static func systemFont(_ size: CGFloat, bold: Bool) -> CTFont {
        if bold {
            if let font = CTFontCreateUIFontForLanguage(.emphasizedSystem, size, nil) { return font }
            if let base = CTFontCreateUIFontForLanguage(.system, size, nil),
               let font = CTFontCreateCopyWithSymbolicTraits(base, size, nil, .traitBold, .traitBold) {
                return font
            }
        }
        if let font = CTFontCreateUIFontForLanguage(.system, size, nil) { return font }
        return CTFontCreateWithName("Helvetica" as CFString, size, nil)
    }

    /// A paragraph style whose base writing direction is right to left (Arabic) or left to right.
    private static func paragraphStyle(rtl: Bool) -> CTParagraphStyle {
        var direction: CTWritingDirection = rtl ? .rightToLeft : .leftToRight
        return withUnsafeBytes(of: &direction) { raw -> CTParagraphStyle in
            var setting = CTParagraphStyleSetting(spec: .baseWritingDirection,
                                                  valueSize: MemoryLayout<CTWritingDirection>.size,
                                                  value: raw.baseAddress!)
            return CTParagraphStyleCreate(&setting, 1)
        }
    }

    /// Text at a point in millimetres, like the reference's SVG <text>: anchor start / middle / end puts the
    /// run's left edge / centre / right edge at x (the page is left to right, whatever the script); vCenter
    /// is dominant-baseline="central" (the font's em box centred on y), otherwise y is the baseline. Arabic
    /// runs get a right-to-left base direction and the reference's RLM marks. Call inside the mm-scaled,
    /// flipped page context; the text itself is laid out in points so the font picks its optical size.
    static func drawText(_ ctx: CGContext, _ text: String, at p: CGPoint, sizeMm: Double, anchor: Anchor = .start,
                         weight: Weight = .regular, color: CGColor = AnswerSheetPDF.ink, vCenter: Bool = false) {
        guard !text.isEmpty else { return }
        let arabic = isArabic(text)
        let shown = arabic ? "\u{200F}\(text)\u{200F}" : text
        let font = systemFont(CGFloat(sizeMm) * k, bold: weight == .bold)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
            NSAttributedString.Key(kCTParagraphStyleAttributeName as String): paragraphStyle(rtl: arabic),
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: shown, attributes: attributes) as CFAttributedString)
        let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        var x = p.x * k
        switch anchor {
        case .start: break
        case .middle: x -= width / 2
        case .end: x -= width
        }
        let baseline = p.y * k + (vCenter ? (CTFontGetAscent(font) - CTFontGetDescent(font)) / 2 : 0)
        ctx.saveGState()
        ctx.scaleBy(x: 1 / k, y: 1 / k)
        ctx.setFillColor(color)
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)   // the page context is flipped (y down)
        ctx.textPosition = CGPoint(x: x, y: baseline)
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }
}
