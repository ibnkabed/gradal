import CoreGraphics
import CoreText
import Foundation

/// A scanned paper as its correction copy (owner, 2026-10-25): the straightened photo of the whole page, a green
/// ring on every accepted letter, a red ring on every marked letter that is not accepted (a wrong letter, or a
/// second letter on one question), the points each question earned beside its row, and the score in the free space
/// under the student-ID block. Everything is placed in page millimetres, as the photo was straightened to the page.
/// One page per paper, so a quiz's papers make one PDF. The same file in Gradal and Gradal-Public.
enum GradedPage {
    struct Question {
        var bubbles: [[Double]]   // [choice] -> [x, y] mm, choices A–D
        var answer: String        // marked letters
        var key: String           // accepted letters; "" = not counted
        var earned: Double
    }

    struct Page {
        var image: CGImage?       // the straightened sheet, the whole page; nil: drawn on white
        var questions: [Question]
        var earned: Double
        var possible: Double
        var scoreLabel: String    // «Score» or «الدرجة», in the sheet's language
        var noImage: String       // shown where the photo would be
    }

    static let widthMm = 210.0, heightMm = 297.0
    static let letters = ["A", "B", "C", "D"]
    /// Under the ID block's instructions and sample bubbles, right of the question area (areaRight 156).
    static let scoreBox = CGRect(x: 157, y: 162, width: 38, height: 26)

    static let green = CGColor(srgbRed: 0.0, green: 0.62, blue: 0.24, alpha: 1)
    static let red = CGColor(srgbRed: 0.86, green: 0.08, blue: 0.08, alpha: 1)
    static let grey = CGColor(srgbRed: 0.45, green: 0.45, blue: 0.45, alpha: 1)

    /// Draws the page into ctx, whose units are page millimetres with y down.
    static func draw(_ ctx: CGContext, _ page: Page, bubbleRadiusMm r: Double) {
        let full = CGRect(x: 0, y: 0, width: widthMm, height: heightMm)
        ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(full)
        if let image = page.image {
            ctx.saveGState()
            ctx.translateBy(x: 0, y: heightMm)       // images draw bottom-up
            ctx.scaleBy(x: 1, y: -1)
            ctx.interpolationQuality = .high
            ctx.draw(image, in: full)
            ctx.restoreGState()
        } else {
            text(ctx, page.noImage, at: CGPoint(x: widthMm / 2, y: 120), size: 4, color: grey, bold: false)
        }

        let ring = r + 0.85
        ctx.setLineWidth(0.5)
        for q in page.questions {
            guard let first = q.bubbles.first, first.count >= 2, let last = q.bubbles.last, last.count >= 2 else { continue }
            let counted = !q.key.isEmpty
            if counted {
                for (i, letter) in letters.enumerated() where i < q.bubbles.count && q.bubbles[i].count >= 2 {
                    let accepted = q.key.contains(letter), marked = q.answer.contains(letter)
                    guard accepted || marked else { continue }
                    let c = q.bubbles[i]
                    ctx.setStrokeColor(accepted ? green : red)
                    ctx.strokeEllipse(in: CGRect(x: c[0] - ring, y: c[1] - ring, width: 2 * ring, height: 2 * ring))
                }
            }
            // the points, past the last choice (right of D, or left of it on a right-to-left sheet)
            let dir = last[0] >= first[0] ? 1.0 : -1.0
            let at = CGPoint(x: last[0] + dir * (r + 2.1), y: last[1])
            if counted {
                text(ctx, number(q.earned), at: at, size: 2.6, color: q.earned > 0 ? green : red, bold: true)
            } else {
                text(ctx, "—", at: at, size: 2.6, color: grey, bold: true)
            }
        }

        let box = scoreBox
        let path = CGPath(roundedRect: box, cornerWidth: 2, cornerHeight: 2, transform: nil)
        ctx.addPath(path)
        ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.94))
        ctx.fillPath()
        ctx.addPath(path)
        ctx.setStrokeColor(red)
        ctx.setLineWidth(0.6)
        ctx.strokePath()
        let percent = page.possible > 0 ? Int((page.earned / page.possible * 100).rounded()) : 0
        text(ctx, page.scoreLabel, at: CGPoint(x: box.midX, y: box.minY + 4.5), size: 3.2, color: red, bold: true)
        text(ctx, "\(number(page.earned)) / \(number(page.possible))", at: CGPoint(x: box.midX, y: box.minY + 12.8),
             size: 7, color: red, bold: true)
        text(ctx, "\(percent)%", at: CGPoint(x: box.midX, y: box.minY + 21.2), size: 3.6, color: red, bold: false)
    }

    /// One A4 page per paper.
    static func pdf(_ pages: [Page], bubbleRadiusMm: Double) -> Data {
        let data = NSMutableData()
        let k = 72 / 25.4
        var box = CGRect(x: 0, y: 0, width: widthMm * k, height: heightMm * k)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: &box, nil) else { return Data() }
        for page in pages {
            ctx.beginPDFPage(nil)
            ctx.saveGState()
            ctx.translateBy(x: 0, y: box.height)
            ctx.scaleBy(x: k, y: -k)
            draw(ctx, page, bubbleRadiusMm: bubbleRadiusMm)
            ctx.restoreGState()
            ctx.endPDFPage()
        }
        ctx.closePDF()
        return data as Data
    }

    /// The page as a picture, for the screen.
    static func image(_ page: Page, bubbleRadiusMm: Double, pxPerMm: Double = ReviewImage.pxPerMm) -> CGImage? {
        let W = Int(widthMm * pxPerMm), H = Int(heightMm * pxPerMm)
        guard let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.translateBy(x: 0, y: CGFloat(H))
        ctx.scaleBy(x: pxPerMm, y: -pxPerMm)
        draw(ctx, page, bubbleRadiusMm: bubbleRadiusMm)
        return ctx.makeImage()
    }

    /// 1, 0.5, 1.5 — no trailing zeros.
    static func number(_ v: Double) -> String {
        v == v.rounded() ? String(Int(v)) : String(format: "%g", v)
    }

    /// One line centred on p (size in mm), upright in a y-down context.
    static func text(_ ctx: CGContext, _ s: String, at p: CGPoint, size: CGFloat, color: CGColor, bold: Bool) {
        let font = CTFontCreateUIFontForLanguage(bold ? .emphasizedSystem : .system, size, nil)
            ?? CTFontCreateWithName((bold ? "Helvetica-Bold" : "Helvetica") as CFString, size, nil)
        let attrs: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: attrs) as CFAttributedString)
        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        let w = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
        ctx.saveGState()
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        ctx.textPosition = CGPoint(x: p.x - w / 2, y: p.y + (ascent - descent) / 2)
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }
}
