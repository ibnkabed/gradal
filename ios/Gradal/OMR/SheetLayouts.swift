import Foundation

/// shared/sheet-layouts.json (layout v2), decoded. Units are millimetres on an A4 portrait page.
struct SheetLayouts: Decodable {
    struct Page: Decodable {
        let widthMm: Double
        let heightMm: Double
    }

    struct Markers: Decodable {
        let sizeMm: Double
        let centers: [[Double]]
    }

    struct OrientationMark: Decodable {
        let center: [Double]
        let sizeMm: Double
    }

    struct Barcode: Decodable {
        let bits: Int
        let cells: [[Double]]
        let cellMm: [Double]
        let codeBits: Int
        let versionBits: Int
        let crcBits: Int
        let crcPoly: Int
    }

    let version: Int
    let page: Page
    let markers: Markers
    let orientationMark: OrientationMark
    let whiteProbes: [[Double]]
    let barcode: Barcode
    let bubbleDiameterMm: Double
    let choices: [String]
    let maxVersions: Int
    let idDigits: Int
    let idBubbles: [[[Double]]]        // [digit][value 0..9] -> [x, y]
    let maxQuestions: Int
    let rowsPerColumn: Int
    let questionBubbles: [[[Double]]]  // [question][choice] -> [x, y]

    static func load(from url: URL) throws -> SheetLayouts {
        try JSONDecoder().decode(SheetLayouts.self, from: Data(contentsOf: url))
    }
}
