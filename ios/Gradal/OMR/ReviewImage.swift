import CoreGraphics
import Foundation

/// The review copy of a scanned paper (owner, 2026-10-25): the whole page straightened at 8 px/mm with bilinear
/// sampling, then its levels stretched so the paper is white and the ink black. Only for showing and printing;
/// the reader (SheetReader, a port of pc/omr.py) never looks at it. The same file in Gradal and Gradal-Public.
enum ReviewImage {
    static let pxPerMm = 8.0

    /// The page through h (page mm -> image px, pixel centres on integers, as SheetReader.findMarkers).
    static func warp(_ gray: GrayImage, _ h: Homography, widthMm: Double, heightMm: Double,
                     pxPerMm: Double = pxPerMm) -> GrayImage {
        let W = Int(widthMm * pxPerMm), H = Int(heightMm * pxPerMm)
        var out = [UInt8](repeating: 255, count: W * H)
        let sw = gray.width, sh = gray.height
        let maxX = Double(sw - 1), maxY = Double(sh - 1)
        gray.pixels.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                for y in 0..<H {
                    let my = (Double(y) + 0.5) / pxPerMm
                    for x in 0..<W {
                        let p = h.apply((Double(x) + 0.5) / pxPerMm, my)
                        guard p.x.isFinite, p.y.isFinite, p.x >= 0, p.y >= 0, p.x < maxX, p.y < maxY else { continue }
                        let x0 = Int(p.x), y0 = Int(p.y)
                        let ax = p.x - Double(x0), ay = p.y - Double(y0)
                        let i = y0 * sw + x0
                        let top = Double(src[i]) * (1 - ax) + Double(src[i + 1]) * ax
                        let bottom = Double(src[i + sw]) * (1 - ax) + Double(src[i + sw + 1]) * ax
                        dst[y * W + x] = UInt8(min(255, max(0, (top * (1 - ay) + bottom * ay).rounded())))
                    }
                }
            }
        }
        return stretched(GrayImage(width: W, height: H, pixels: out))
    }

    /// Levels: the darkest 0.5% go to black and the paper (the median, most of the page) to white.
    static func stretched(_ image: GrayImage) -> GrayImage {
        var hist = [Int](repeating: 0, count: 256)
        for v in image.pixels { hist[Int(v)] += 1 }
        func level(_ share: Double) -> Int {
            let target = Int(Double(image.pixels.count) * share)
            var sum = 0
            for v in 0..<256 {
                sum += hist[v]
                if sum > target { return v }
            }
            return 255
        }
        let lo = Double(level(0.005)), hi = Double(level(0.5))
        guard hi - lo >= 24 else { return image }
        var table = [UInt8](repeating: 0, count: 256)
        for v in 0..<256 {
            let t = (Double(v) - lo) / (hi - lo)
            table[v] = UInt8(min(255, max(0, (t * 245 + 5).rounded())))
        }
        var out = image
        for i in out.pixels.indices { out.pixels[i] = table[Int(out.pixels[i])] }
        return out
    }

    static func cgImage(_ image: GrayImage) -> CGImage? {
        guard let provider = CGDataProvider(data: Data(image.pixels) as CFData) else { return nil }
        return CGImage(width: image.width, height: image.height, bitsPerComponent: 8, bitsPerPixel: 8,
                       bytesPerRow: image.width, space: CGColorSpaceCreateDeviceGray(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}
