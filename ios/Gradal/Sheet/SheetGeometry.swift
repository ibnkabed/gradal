import Foundation

/// Why a quiz's questions cannot be laid out on the answer sheet.
enum SheetGeometryError: LocalizedError, Equatable {
    case questionCount
    case tooMany

    var errorDescription: String? {
        switch self {
        case .questionCount: return "عدد الأسئلة من 5 إلى 60"
        case .tooMany: return "الأسئلة أكثر مما تتسع له الورقة"
        }
    }
}

/// Where a quiz's questions go on the answer sheet. Port of reference/sheet_layout.py compute(): same
/// constants, same steps, same numbers (rounded to 0.001). Keep both in step; CI compares them
/// (`OMRCheck --geometry`, tools/check_geometry.py).
///
/// Gradal has no question-paper pages, so the questions are always split evenly over as few columns as
/// fit; inside a column there is one framed box per section (a section split over two columns repeats
/// its title with « (تابع)» / " (cont.)"), questions outside every section get their own box. An Arabic
/// quiz reads right to left: the first column on the right, the number at the box's right edge and
/// choice أ (index 0) the rightmost bubble.
enum SheetGeometry {
    static let version = 6   // 6: area 9 mm lower with the frame (layout 7); 5: above the raised bottom markers
    static let minQuestions = 5, maxQuestions = 60

    static let areaLeft = 22.0, areaRight = 156.0      // left of the student-ID block, right of the barcode
    static let areaTop = 65.0, areaBottom = 268.5      // under the name/ID row, above the bottom markers
    static let boxW = 31.0
    static let titleH = 6.5
    static let boxPadTop = 1.5, boxPadBottom = 1.0
    static let boxGap = 4.0
    static let numberRight = 6.5                       // question number right edge, from the box's left
    static let firstBubble = 9.6                       // bubble A centre, from the box's left
    static let choicePitch = 5.4
    static let maxPitch = 9.5
    static let minPitch = 5.6
    static let maxColumns = 4

    /// Like Python's round(x, 3), give or take a last-digit tie.
    static func r3(_ x: Double) -> Double { (x * 1000).rounded() / 1000 }

    /// A box before it is placed: its title and question range (1-based, inclusive).
    private struct Planned {
        var title: String
        var from: Int
        var to: Int
    }

    /// [(from, to)] 1-based per column: as few balanced columns as fit (_page_ranges without pages).
    static func columnRanges(_ n: Int) -> [(Int, Int)] {
        for cols in 1...maxColumns {
            let per = (n + cols - 1) / cols
            if (areaBottom - areaTop - titleH - boxPadTop - boxPadBottom) / Double(per) >= 7.0 || cols == maxColumns {
                var out: [(Int, Int)] = []
                var start = 1
                for c in 0..<cols {
                    let size = (c < n % cols || n % cols == 0) ? per : per - 1
                    out.append((start, start + size - 1))
                    start += size
                }
                return out.filter { $0.0 <= $0.1 }
            }
        }
        return []
    }

    /// The boxes of one column (_boxes_for): one per section crossing it, then the uncovered runs.
    private static func boxes(for range: (Int, Int), sections: [QuizSection], rtl: Bool) -> [Planned] {
        let (a, b) = range
        var boxes: [Planned] = []
        // sorted by "from", stable like Python's sorted
        let ordered = sections.enumerated().sorted { l, r in
            l.element.from != r.element.from ? l.element.from < r.element.from : l.offset < r.offset
        }.map(\.element)
        for s in ordered {
            let lo = max(a, s.from), hi = min(b, s.to)
            if lo > hi { continue }
            let label = s.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let title = label + (lo > s.from ? (rtl ? " (تابع)" : " (cont.)") : "")
            boxes.append(Planned(title: title, from: lo, to: hi))
        }
        var covered = Set<Int>()
        for bx in boxes { for q in bx.from...bx.to { covered.insert(q) } }
        if boxes.isEmpty || covered.count < b - a + 1 {
            // questions outside every section: their own box(es), in order
            var rest: [[Int]] = []
            var run: [Int] = []
            for q in a...b {
                if covered.contains(q) {
                    if !run.isEmpty { rest.append(run); run = [] }
                } else {
                    run.append(q)
                }
            }
            if !run.isEmpty { rest.append(run) }
            for r in rest {
                let first = r[0], last = r[r.count - 1]
                boxes.append(Planned(title: rtl ? "الأسئلة \(first)–\(last)" : "Questions \(first)–\(last)",
                                     from: first, to: last))
            }
            boxes = boxes.enumerated().sorted { l, r in
                l.element.from != r.element.from ? l.element.from < r.element.from : l.offset < r.offset
            }.map(\.element)
        }
        return boxes
    }

    /// Port of reference/sheet_layout.py compute(): same constants, same numbers (rounded to 0.001).
    static func compute(questionCount: Int, sections: [QuizSection], rtl: Bool, layout: SheetLayouts) throws -> QuizSheet {
        let n = questionCount
        guard n >= minQuestions && n <= maxQuestions else { throw SheetGeometryError.questionCount }
        let valid = sections.filter { $0.from >= 1 && $0.to >= $0.from }
        let ranges = columnRanges(n)
        guard !ranges.isEmpty && ranges.count <= maxColumns else { throw SheetGeometryError.tooMany }

        var columns: [(range: (Int, Int), boxes: [Planned])] = ranges.map { r in
            (range: r, boxes: boxes(for: r, sections: valid, rtl: rtl))
        }
        if rtl { columns.reverse() }   // the first column on the right

        let top = areaTop + 0.0
        let avail = areaBottom - top
        var pitch = maxPitch
        for col in columns {
            let rows = col.range.1 - col.range.0 + 1
            let count = col.boxes.count
            let fixed = Double(count) * (titleH + boxPadTop + boxPadBottom) + Double(count - 1) * boxGap
            pitch = min(pitch, (avail - fixed) / Double(rows))
        }
        if pitch < minPitch { throw SheetGeometryError.tooMany }

        let choiceCount = layout.choices.count
        let gap = (areaRight - areaLeft - boxW * Double(columns.count)) / Double(columns.count + 1)
        var bubbles = [[[Double]]](repeating: [], count: n)
        var outColumns: [SheetColumn] = []
        for (i, col) in columns.enumerated() {
            let x0 = areaLeft + gap + Double(i) * (boxW + gap)
            var y = top
            var outBoxes: [SheetBox] = []
            for bx in col.boxes {
                let rows = bx.to - bx.from + 1
                let y1 = y + titleH + boxPadTop + Double(rows) * pitch + boxPadBottom
                for k in 0..<rows {
                    let cy = y + titleH + boxPadTop + pitch * (Double(k) + 0.5)
                    let q = bx.from + k
                    if rtl {
                        bubbles[q - 1] = (0..<choiceCount).map { c in
                            [r3(x0 + boxW - firstBubble - Double(c) * choicePitch), r3(cy)]
                        }
                    } else {
                        bubbles[q - 1] = (0..<choiceCount).map { c in
                            [r3(x0 + firstBubble + Double(c) * choicePitch), r3(cy)]
                        }
                    }
                }
                outBoxes.append(SheetBox(title: bx.title, from: bx.from, to: bx.to,
                                         x0: r3(x0), y0: r3(y), x1: r3(x0 + boxW), y1: r3(y1),
                                         titleY1: r3(y + titleH),
                                         numberX: r3(rtl ? x0 + boxW - numberRight : x0 + numberRight),
                                         numberAnchorStart: rtl))
                y = y1 + boxGap
            }
            outColumns.append(SheetColumn(x0: r3(x0), x1: r3(x0 + boxW), boxes: outBoxes))
        }
        return QuizSheet(version: version, pitch: r3(pitch), rtl: rtl, questionBubbles: bubbles, columns: outColumns)
    }
}
