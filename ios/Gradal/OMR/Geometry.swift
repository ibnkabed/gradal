import Foundation

/// 8-bit grayscale image, row-major, no padding (0 black .. 255 white).
struct GrayImage {
    let width: Int
    let height: Int
    var pixels: [UInt8]
}

struct Pt: Equatable {
    var x: Double
    var y: Double

    init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    init(_ pair: [Double]) {
        x = pair.count > 0 ? pair[0] : 0
        y = pair.count > 1 ? pair[1] : 0
    }

    static func dist(_ a: Pt, _ b: Pt) -> Double {
        ((a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y)).squareRoot()
    }
}

/// 3x3 projective map, row-major, m[8] == 1. Maps page mm -> image px in the reader.
struct Homography {
    var m: [Double]

    /// dst ~ H * src for four point pairs (direct linear solve, h33 = 1), like omr.homography.
    init?(from src: [Pt], to dst: [Pt]) {
        guard src.count == 4, dst.count == 4 else { return nil }
        var a = [[Double]](repeating: [Double](repeating: 0, count: 9), count: 8)
        for i in 0..<4 {
            let x = src[i].x, y = src[i].y, u = dst[i].x, v = dst[i].y
            a[2 * i] = [x, y, 1, 0, 0, 0, -u * x, -u * y, u]
            a[2 * i + 1] = [0, 0, 0, x, y, 1, -v * x, -v * y, v]
        }
        for col in 0..<8 {
            var pivot = col
            for r in (col + 1)..<8 where abs(a[r][col]) > abs(a[pivot][col]) {
                pivot = r
            }
            if abs(a[pivot][col]) < 1e-12 { return nil }
            if pivot != col { a.swapAt(pivot, col) }
            let p = a[col][col]
            for r in 0..<8 where r != col {
                let f = a[r][col] / p
                if f != 0 {
                    for c in col..<9 { a[r][c] -= f * a[col][c] }
                }
            }
        }
        var h = [Double](repeating: 0, count: 9)
        for i in 0..<8 { h[i] = a[i][8] / a[i][i] }
        h[8] = 1
        m = h
    }

    @inline(__always)
    func apply(_ x: Double, _ y: Double) -> Pt {
        let w = m[6] * x + m[7] * y + m[8]
        return Pt(x: (m[0] * x + m[1] * y + m[2]) / w, y: (m[3] * x + m[4] * y + m[5]) / w)
    }

    @inline(__always)
    func apply(_ p: Pt) -> Pt { apply(p.x, p.y) }
}
