import CoreGraphics
import Foundation
import ImageIO

// CI checks for code shared with the iPhone app.
//   OMRCheck <folder> <sheet-layouts.json>
//     Runs the Swift sheet reader on synthetic photos (tools/make_test_sheets.py) and compares
//     with the truth files, like tools/check_omr.py. Exit 1 if any found sheet has a mismatch,
//     or if more than 15% of sheets are not found.
//   OMRCheck --xlsx <out.xlsx>
//     Writes the sample record sheet (checked by tools/check_record_xlsx.py).

struct TruthSheet: Decodable {
    let questionBubbles: [[[Double]]]?
}

struct Truth: Decodable {
    let sheet: TruthSheet?
    let quizCode: Int
    let version: Int
    let questionCount: Int
    let studentId: String
    let answers: [String]
}

func loadGray(_ url: URL) -> GrayImage? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
    let w = image.width, h = image.height
    guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpaceCreateDeviceGray(),
                              bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    guard let data = ctx.data else { return nil }
    let stride = ctx.bytesPerRow
    let src = data.assumingMemoryBound(to: UInt8.self)
    var pixels = [UInt8](repeating: 0, count: w * h)
    for y in 0..<h {
        for x in 0..<w { pixels[y * w + x] = src[y * stride + x] }
    }
    return GrayImage(width: w, height: h, pixels: pixels)
}

let args = CommandLine.arguments

if args.count >= 3 && args[1] == "--xlsx" {
    let out = URL(fileURLWithPath: args[2])
    do {
        try RecordSheet.sample().write(to: out, options: .atomic)
        print("wrote \(out.path)")
        exit(0)
    } catch {
        print("cannot write \(out.path): \(error)")
        exit(1)
    }
}

guard args.count >= 3 else {
    print("usage: OMRCheck <folder> <sheet-layouts.json> | OMRCheck --xlsx <out.xlsx>")
    exit(2)
}
let folder = URL(fileURLWithPath: args[1], isDirectory: true)
let layouts: SheetLayouts
do {
    layouts = try SheetLayouts.load(from: URL(fileURLWithPath: args[2]))
} catch {
    print("cannot read layouts: \(error)")
    exit(2)
}

let files = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
    .filter { $0.pathExtension == "json" }
    .sorted { $0.lastPathComponent < $1.lastPathComponent }
if files.isEmpty {
    print("no truth files in \(folder.path)")
    exit(2)
}

var badSheets = 0
var notFound = 0
var totalQ = 0
var wrongQ = 0
var totalMs = 0.0

for truthURL in files {
    let name = truthURL.deletingPathExtension().lastPathComponent
    guard let data = try? Data(contentsOf: truthURL),
          let truth = try? JSONDecoder().decode(Truth.self, from: data) else {
        print("\(name): bad truth file")
        badSheets += 1
        continue
    }
    guard let gray = loadGray(truthURL.deletingPathExtension().appendingPathExtension("jpg")) else {
        print("\(name): cannot load image")
        notFound += 1
        continue
    }
    let start = DispatchTime.now().uptimeNanoseconds
    let result = SheetReader.read(gray, layouts: layouts, questionCount: truth.questionCount,
                                  questionBubbles: truth.sheet?.questionBubbles)
    let ms = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    totalMs += ms
    guard let res = result else {
        print("\(name) [\(truth.questionCount)q]: NOT FOUND (\(Int(ms)) ms)")
        notFound += 1
        continue
    }
    var errs: [String] = []
    if res.studentId != truth.studentId {
        errs.append("id '\(res.studentId)' != '\(truth.studentId)'")
    }
    if res.quizCode != truth.quizCode {
        errs.append("code \(res.quizCode) != \(truth.quizCode)")
    }
    if res.version != truth.version {
        errs.append("version \(res.version) != \(truth.version)")
    }
    for (q, pair) in zip(res.answers, truth.answers).enumerated() {
        totalQ += 1
        if pair.0 != pair.1 {
            wrongQ += 1
            errs.append("q\(q + 1) '\(pair.0)' != '\(pair.1)' \(res.darkness[q])")
        }
    }
    let status = errs.isEmpty ? "ok" : errs.prefix(6).joined(separator: "; ")
    print("\(name) [\(truth.questionCount)q] \(Int(ms)) ms: \(status)")
    if !errs.isEmpty { badSheets += 1 }
}

let found = files.count - notFound
print("")
print("sheets: \(files.count); not found: \(notFound); found with errors: \(badSheets); wrong answers: \(wrongQ)/\(totalQ); mean \(Int(totalMs / Double(max(files.count, 1)))) ms")
if badSheets > 0 || Double(notFound) > 0.15 * Double(files.count) || found == 0 {
    exit(1)
}
exit(0)
