import Foundation

/// One read of a Gradal answer sheet.
struct SheetRead {
    var corners: [Pt]            // marker centres in image px, page order TL TR BR BL
    var homography: Homography   // page mm -> image px
    var quizCode: Int            // from the barcode, 1..9999
    var version: Int             // from the barcode, 0..3 (model 1..4)
    var studentId: String        // digits; '?' where a column is blank or ambiguous
    var answers: [String]        // per question: letters, "" = blank
    var darkness: [[Double]]     // per question, per choice (for review)
}

/// Port of pc/omr.py. Keep both in step: same constants, same steps, same decisions.
enum SheetReader {
    static let workLongSide = 800
    static let threshRatio = 0.72
    static let minMarkerFrac = 0.008
    static let maxMarkerFrac = 0.07
    static let minFill = 0.60
    static let maxAreaSpread = 3.5
    static let maxCandidates = 24
    static let innerRadius = 0.55
    static let markDarkness = 0.35
    static let markRelative = 0.60
    static let orientDarkness = 0.45
    static let barDarkness = 0.40
    static let maxQuadsTried = 40
    static let marginLight = 0.25
    static let marginShare = 0.85

    // MARK: - Geometry helpers

    static func polygonArea(_ pts: [Pt]) -> Double {
        var s = 0.0
        for i in 0..<pts.count {
            let a = pts[i], b = pts[(i + 1) % pts.count]
            s += a.x * b.y - b.x * a.y
        }
        return s / 2.0
    }

    static func isConvex(_ pts: [Pt]) -> Bool {
        var sign = 0
        for i in 0..<4 {
            let p1 = pts[i], p2 = pts[(i + 1) % 4], p3 = pts[(i + 2) % 4]
            let cross = (p2.x - p1.x) * (p3.y - p2.y) - (p2.y - p1.y) * (p3.x - p2.x)
            if cross == 0 { return false }
            let s = cross > 0 ? 1 : -1
            if sign != 0 && s != sign { return false }
            sign = s
        }
        return true
    }

    static func linspace(_ a: Double, _ b: Double, _ n: Int) -> [Double] {
        if n == 1 { return [a] }
        let step = (b - a) / Double(n - 1)
        return (0..<n).map { i in i == n - 1 ? b : a + Double(i) * step }
    }

    // MARK: - Image helpers

    /// Integer box average so the long side is at most longSide. Returns the factor used.
    static func downscale(_ gray: GrayImage, longSide: Int) -> (width: Int, height: Int, pixels: [Float], factor: Double) {
        let f = max(1, Int((Double(max(gray.width, gray.height)) / Double(longSide)).rounded(.up)))
        if f == 1 {
            return (gray.width, gray.height, gray.pixels.map { Float($0) }, 1.0)
        }
        let ww = gray.width / f, hh = gray.height / f
        var out = [Float](repeating: 0, count: ww * hh)
        let div = Float(f * f)
        let srcWidth = gray.width
        gray.pixels.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                for y in 0..<hh {
                    for x in 0..<ww {
                        var s = 0
                        for dy in 0..<f {
                            let row = (y * f + dy) * srcWidth + x * f
                            for dx in 0..<f { s += Int(src[row + dx]) }
                        }
                        dst[y * ww + x] = Float(s) / div
                    }
                }
            }
        }
        return (ww, hh, out, Double(f))
    }

    /// Adaptive threshold via an integral image: dark if pixel < local mean * threshRatio.
    static func darkMask(_ img: [Float], width w: Int, height h: Int) -> [Bool] {
        let win = max(15, (max(h, w) / 12) | 1)
        let half = win / 2
        let stride = w + 1
        var ii = [Double](repeating: 0, count: (w + 1) * (h + 1))
        for y in 0..<h {
            var rowSum = 0.0
            for x in 0..<w {
                rowSum += Double(img[y * w + x])
                ii[(y + 1) * stride + x + 1] = ii[y * stride + x + 1] + rowSum
            }
        }
        var mask = [Bool](repeating: false, count: w * h)
        for y in 0..<h {
            let y0 = max(y - half, 0), y1 = min(y + half + 1, h)
            for x in 0..<w {
                let x0 = max(x - half, 0), x1 = min(x + half + 1, w)
                let total = ii[y1 * stride + x1] - ii[y0 * stride + x1] - ii[y1 * stride + x0] + ii[y0 * stride + x0]
                let count = Double((y1 - y0) * (x1 - x0))
                mask[y * w + x] = Double(img[y * w + x]) < (total / count) * threshRatio
            }
        }
        return mask
    }

    struct Blob {
        var area: Int
        var sx: Double
        var sy: Double
        var x0: Int
        var x1: Int
        var y0: Int
        var y1: Int
    }

    /// 8-connected blobs, two-pass union-find (same as omr.components).
    static func components(_ mask: [Bool], width w: Int, height h: Int) -> [Blob] {
        var labels = [UInt32](repeating: 0, count: w * h)
        var parent: [UInt32] = [0]

        func find(_ start: UInt32) -> UInt32 {
            var a = start
            while parent[Int(a)] != a {
                parent[Int(a)] = parent[Int(parent[Int(a)])]
                a = parent[Int(a)]
            }
            return a
        }

        let ndy = [-1, -1, -1, 0]
        let ndx = [-1, 0, 1, -1]
        var next: UInt32 = 1
        for y in 0..<h {
            for x in 0..<w where mask[y * w + x] {
                var best: UInt32 = 0
                for k in 0..<4 {
                    let yy = y + ndy[k], xx = x + ndx[k]
                    if yy >= 0 && xx >= 0 && xx < w {
                        var l = labels[yy * w + xx]
                        if l != 0 {
                            l = find(l)
                            if best == 0 {
                                best = l
                            } else if l != best {
                                let lo = min(l, best), hi = max(l, best)
                                parent[Int(hi)] = lo
                                best = lo
                            }
                        }
                    }
                }
                if best == 0 {
                    parent.append(next)
                    best = next
                    next += 1
                }
                labels[y * w + x] = best
            }
        }

        var slot = [Int](repeating: -1, count: parent.count)
        var blobs: [Blob] = []
        for y in 0..<h {
            for x in 0..<w {
                let l = labels[y * w + x]
                if l == 0 { continue }
                let r = Int(find(l))
                if slot[r] < 0 {
                    slot[r] = blobs.count
                    blobs.append(Blob(area: 0, sx: 0, sy: 0, x0: x, x1: x, y0: y, y1: y))
                }
                let i = slot[r]
                blobs[i].area += 1
                blobs[i].sx += Double(x)
                blobs[i].sy += Double(y)
                if x < blobs[i].x0 { blobs[i].x0 = x }
                if x > blobs[i].x1 { blobs[i].x1 = x }
                if y < blobs[i].y0 { blobs[i].y0 = y }
                if y > blobs[i].y1 { blobs[i].y1 = y }
            }
        }
        return blobs
    }

    // MARK: - Sampling

    /// Nearest pixel with round-half-to-even (Python round / numpy rint), clamped to the image.
    @inline(__always)
    static func sample(_ gray: GrayImage, _ p: Pt) -> Double {
        Double(gray.pixels[pixelIndex(gray, p)])
    }

    @inline(__always)
    static func pixelIndex(_ gray: GrayImage, _ p: Pt) -> Int {
        var xi = 0, yi = 0
        if !p.x.isNaN {
            let xc = min(max(p.x.rounded(.toNearestOrEven), 0), Double(gray.width - 1))
            xi = Int(xc)
        }
        if !p.y.isNaN {
            let yc = min(max(p.y.rounded(.toNearestOrEven), 0), Double(gray.height - 1))
            yi = Int(yc)
        }
        return yi * gray.width + xi
    }

    /// Paper brightness around a point: the 90th percentile of a 9x9 grid of samples.
    static func localWhite(_ gray: GrayImage, _ h: Homography, _ center: Pt, _ halfMm: Double) -> Double {
        let steps = 9
        var vals: [Double] = []
        vals.reserveCapacity(steps * steps)
        for i in 0..<steps {
            for j in 0..<steps {
                let px = center.x - halfMm + 2 * halfMm * Double(i) / Double(steps - 1)
                let py = center.y - halfMm + 2 * halfMm * Double(j) / Double(steps - 1)
                vals.append(sample(gray, h.apply(px, py)))
            }
        }
        vals.sort()
        return max(vals[Int(Double(vals.count) * 0.9)], 1.0)
    }

    static func discPoints(_ radiusMm: Double, rings: Int = 3, perRing: Int = 8) -> [Pt] {
        var pts = [Pt(x: 0, y: 0)]
        for i in 1...rings {
            let rr = radiusMm * Double(i) / Double(rings)
            let n = perRing * i
            for j in 0..<n {
                let a = 2 * Double.pi * Double(j) / Double(n)
                pts.append(Pt(x: rr * cos(a), y: rr * sin(a)))
            }
        }
        return pts
    }

    static func darkness(_ gray: GrayImage, _ h: Homography, _ center: Pt, _ disc: [Pt], _ white: Double) -> Double {
        var sum = 0.0
        for d in disc {
            sum += sample(gray, h.apply(center.x + d.x, center.y + d.y))
        }
        let mean = sum / Double(disc.count)
        return min(1.0, max(0.0, 1.0 - mean / white))
    }

    static func marked(_ values: [Double]) -> [Int] {
        let top = values.max() ?? 0
        var out: [Int] = []
        for (i, v) in values.enumerated() where v >= markDarkness && v >= markRelative * top {
            out.append(i)
        }
        return out
    }

    // MARK: - Step 1+2: markers

    static func findMarkers(_ gray: GrayImage, _ layout: SheetLayouts) -> (corners: [Pt], h: Homography)? {
        let small = downscale(gray, longSide: workLongSide)
        let mask = darkMask(small.pixels, width: small.width, height: small.height)
        let longSide = Double(max(small.width, small.height))
        let lo = minMarkerFrac * longSide, hi = maxMarkerFrac * longSide

        struct Cand { let area: Int; let x: Double; let y: Double }
        var cands: [Cand] = []
        for b in components(mask, width: small.width, height: small.height) {
            let bw = Double(b.x1 - b.x0 + 1), bh = Double(b.y1 - b.y0 + 1)
            if !(lo <= bw && bw <= hi && lo <= bh && bh <= hi) { continue }
            let aspect = bw / bh
            if !(0.55 <= aspect && aspect <= 1.8) { continue }
            if Double(b.area) / (bw * bh) < minFill { continue }
            cands.append(Cand(area: b.area, x: b.sx / Double(b.area), y: b.sy / Double(b.area)))
        }
        cands.sort { a, b in
            if a.area != b.area { return a.area > b.area }
            if a.x != b.x { return a.x > b.x }
            return a.y > b.y
        }
        if cands.count > maxCandidates { cands = Array(cands.prefix(maxCandidates)) }
        if cands.count < 4 { return nil }

        let page = layout.markers.centers.map { Pt($0) }
        guard page.count == 4 else { return nil }
        let want = Pt.dist(page[0], page[1]) / Pt.dist(page[1], page[2])

        struct Quad { let area: Double; let order: Int; let pts: [Pt] }
        var quads: [Quad] = []
        let n = cands.count
        for a in 0..<n {
            for b in (a + 1)..<n {
                for c in (b + 1)..<n {
                    for d in (c + 1)..<n {
                        let combo = [cands[a], cands[b], cands[c], cands[d]]
                        var amax = combo[0].area, amin = combo[0].area
                        for q in combo { amax = max(amax, q.area); amin = min(amin, q.area) }
                        if Double(amax) / Double(amin) > maxAreaSpread { continue }
                        var pts = combo.map { Pt(x: $0.x, y: $0.y) }
                        let cx = pts.reduce(0.0) { $0 + $1.x } / 4
                        let cy = pts.reduce(0.0) { $0 + $1.y } / 4
                        pts.sort { atan2($0.y - cy, $0.x - cx) < atan2($1.y - cy, $1.x - cx) }
                        if !isConvex(pts) { continue }
                        let s = (0..<4).map { Pt.dist(pts[$0], pts[($0 + 1) % 4]) }
                        let p1 = s[0] + s[2], p2 = s[1] + s[3]
                        let ratio = min(p1, p2) / max(p1, p2)
                        if !(want * 0.6 <= ratio && ratio <= min(1.0, want * 1.45)) { continue }
                        quads.append(Quad(area: abs(polygonArea(pts)), order: quads.count, pts: pts))
                    }
                }
            }
        }
        quads.sort { a, b in a.area != b.area ? a.area > b.area : a.order < b.order }

        let f = small.factor
        let o = layout.orientationMark
        let oc = Pt(o.center)
        let oDisc = discPoints(o.sizeMm * 0.3)
        for quad in quads.prefix(maxQuadsTried) {
            // atan2 order is clockwise on screen (y down). One of the four rotations puts TL first:
            // among those that look like a sheet and carry a valid barcode, the darkest orientation mark wins.
            let full = quad.pts.map { Pt(x: ($0.x + 0.5) * f - 0.5, y: ($0.y + 0.5) * f - 0.5) }
            var best: (d: Double, corners: [Pt], h: Homography)?
            for k in 0..<4 {
                let corners = Array(full[k...] + full[..<k])
                guard let h = Homography(from: page, to: corners) else { continue }
                if !verify(gray, h, layout) || readBarcode(gray, h, layout) == nil { continue }
                let d = darkness(gray, h, oc, oDisc, localWhite(gray, h, oc, 10.0))
                if best == nil || d > best!.d { best = (d, corners, h) }
            }
            if let best { return (best.corners, best.h) }
        }
        return nil
    }

    /// True only if the page drawn through h looks like a Gradal sheet: solid square markers,
    /// a dark orientation mark, and blank margins.
    static func verify(_ gray: GrayImage, _ h: Homography, _ layout: SheetLayouts) -> Bool {
        let size = layout.markers.sizeMm
        let centers = layout.markers.centers.map { Pt($0) }
        let offsets = [-0.3, 0.0, 0.3]
        for c in centers {
            let white = localWhite(gray, h, c, size * 1.6)
            for dx in offsets {
                for dy in offsets {
                    let p = h.apply(c.x + dx * size, c.y + dy * size)
                    if 1.0 - sample(gray, p) / white < 0.45 { return false }
                }
            }
        }
        let o = layout.orientationMark
        let oc = Pt(o.center)
        let oWhite = localWhite(gray, h, oc, 10.0)
        if darkness(gray, h, oc, discPoints(o.sizeMm * 0.3), oWhite) < orientDarkness { return false }

        let probes = layout.whiteProbes.map { Pt($0) }
        var light = 0
        for p in probes {
            let white = localWhite(gray, h, p, 5.0)
            if 1.0 - sample(gray, h.apply(p)) / white < marginLight { light += 1 }
        }
        return Double(light) >= marginShare * Double(probes.count)
    }

    // MARK: - Step 4: bubbles

    static func crc6(_ value: Int, _ nbits: Int, _ poly: Int = 0x03) -> Int {
        var crc = 0
        var i = nbits - 1
        while i >= 0 {
            let top = (crc >> 5) & 1
            crc = (crc << 1) & 0x3F
            if top ^ ((value >> i) & 1) != 0 { crc ^= poly }
            i -= 1
        }
        return crc
    }

    /// (quizCode, version) or nil when the cells do not form a valid code.
    static func readBarcode(_ gray: GrayImage, _ h: Homography, _ layout: SheetLayouts) -> (code: Int, version: Int)? {
        let bc = layout.barcode
        let half = (bc.cellMm.min() ?? 3.0) / 2 * 0.6
        let disc = discPoints(half)
        var word = 0
        for raw in bc.cells {
            let c = Pt(raw)
            let white = localWhite(gray, h, c, 6.0)
            word = (word << 1) | (darkness(gray, h, c, disc, white) >= barDarkness ? 1 : 0)
        }
        let payload = word >> bc.crcBits
        let crc = word & ((1 << bc.crcBits) - 1)
        if crc6(payload, bc.codeBits + bc.versionBits, bc.crcPoly) != crc { return nil }
        let code = payload >> bc.versionBits
        let version = payload & ((1 << bc.versionBits) - 1)
        if !(1 <= code && code <= 9999) { return nil }
        return (code, version)
    }

    /// Steps 1-4: markers, homography and a valid barcode.
    struct Located {
        let corners: [Pt]
        let h: Homography
        let code: Int
        let version: Int
    }

    static func locate(_ gray: GrayImage, _ layouts: SheetLayouts) -> Located? {
        guard let found = findMarkers(gray, layouts) else { return nil }
        guard let code = readBarcode(gray, found.h, layouts) else { return nil }
        return Located(corners: found.corners, h: found.h, code: code.code, version: code.version)
    }

    /// Like omr.read_sheet(gray, layout, question_count, question_bubbles).
    static func read(_ gray: GrayImage, layouts: SheetLayouts, questionCount: Int? = nil,
                     questionBubbles: [[[Double]]]? = nil) -> SheetRead? {
        guard let located = locate(gray, layouts) else { return nil }
        return readBubbles(gray, layouts, located, questionCount: questionCount, questionBubbles: questionBubbles)
    }

    /// Step 5 on a located sheet. questionBubbles: the quiz's own positions (quiz.sheet, layout v3);
    /// without them the fixed v2 grid of the layout JSON is used.
    static func readBubbles(_ gray: GrayImage, _ layouts: SheetLayouts, _ located: Located,
                            questionCount: Int?, questionBubbles: [[[Double]]]?) -> SheetRead {
        let h = located.h
        let disc = discPoints(layouts.bubbleDiameterMm / 2 * innerRadius)

        func group(_ raw: [[Double]]) -> [Double] {
            let points = raw.map { Pt($0) }
            guard !points.isEmpty else { return [] }
            let cx = points.reduce(0.0) { $0 + $1.x } / Double(points.count)
            let cy = points.reduce(0.0) { $0 + $1.y } / Double(points.count)
            let span = (points.map { abs($0.x - cx) }.max() ?? 0) + 4.0
            let white = localWhite(gray, h, Pt(x: cx, y: cy), max(span, 6.0))
            return points.map { darkness(gray, h, $0, disc, white) }
        }

        var digits = ""
        for column in layouts.idBubbles {
            let m = marked(group(column))
            digits += m.count == 1 ? String(m[0]) : "?"
        }

        var grid = layouts.questionBubbles
        if let own = questionBubbles, !own.isEmpty { grid = own }
        var n = grid.count
        if let q = questionCount, q > 0 { n = q }
        n = min(n, grid.count)
        var answers: [String] = []
        var darknessList: [[Double]] = []
        for q in grid.prefix(n) {
            let vals = group(q)
            darknessList.append(vals.map { ($0 * 1000).rounded() / 1000 })
            answers.append(marked(vals).map { $0 < layouts.choices.count ? layouts.choices[$0] : "?" }.joined())
        }
        return SheetRead(corners: located.corners, homography: h, quizCode: located.code, version: located.version,
                         studentId: digits, answers: answers, darkness: darknessList)
    }

    /// The whole sheet straightened to pxPerMm (for the review image), like omr.warp_page.
    static func warpPage(_ gray: GrayImage, _ h: Homography, _ layout: SheetLayouts, pxPerMm: Double = 4.0) -> GrayImage {
        let W = Int(layout.page.widthMm * pxPerMm), H = Int(layout.page.heightMm * pxPerMm)
        var out = [UInt8](repeating: 255, count: W * H)
        gray.pixels.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                for y in 0..<H {
                    let my = (Double(y) + 0.5) / pxPerMm
                    for x in 0..<W {
                        let mx = (Double(x) + 0.5) / pxPerMm
                        dst[y * W + x] = src[pixelIndex(gray, h.apply(mx, my))]
                    }
                }
            }
        }
        return GrayImage(width: W, height: H, pixels: out)
    }
}
