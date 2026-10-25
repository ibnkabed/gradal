import Foundation

/// The record sheet (one worksheet per class), built from plain values.
struct RecordSection: Equatable {
    var name: String
    var from: Int    // 1-based, inclusive
    var to: Int

    /// The CI sample's sections, in record-sheet column order.
    static let midtermSections = [
        RecordSection(name: "القراءة", from: 11, to: 15),
        RecordSection(name: "الكتابة", from: 16, to: 17),
        RecordSection(name: "القواعد", from: 6, to: 10),
        RecordSection(name: "المفردات", from: 1, to: 5),
    ]
    static let midtermQuestions = 17
}

struct RecordStudent {
    var gradalId: String
    var name: String
    var points: [Double]?    // earned per question; nil = no scan (row keeps ID and name only)
}

struct RecordClass {
    var name: String
    var students: [RecordStudent]   // already in the computer's list order
}

enum RecordSheet {
    static func sheet(_ cls: RecordClass, questionCount n: Int, sections: [RecordSection]) -> XLSXSheet {
        var header: [XLSXCell] = [.text("ID"), .text("اسم الطالب"), .text("#")]
        for q in 1...max(n, 1) where q <= n { header.append(.number(Double(q))) }
        for s in sections { header.append(.text(s.name)) }
        header.append(.text("المجموع"))

        var rows: [[XLSXCell]] = [header]
        for (i, st) in cls.students.enumerated() {
            let r = i + 2
            var row: [XLSXCell] = []
            if let id = Int(st.gradalId) {
                row.append(.number(Double(id)))
            } else {
                row.append(st.gradalId.isEmpty ? .empty : .text(st.gradalId))
            }
            row.append(.text(st.name))
            if let points = st.points {
                let earned = (0..<n).map { $0 < points.count ? points[$0] : 0 }
                row.append(.number(earned.reduce(0, +)))
                for v in earned { row.append(.number(v)) }
            } else {
                row.append(.empty)
                for _ in 0..<n { row.append(.empty) }
            }
            for s in sections {
                let from = min(max(s.from, 1), max(n, 1))
                let to = min(max(s.to, 1), max(n, 1))
                if n == 0 || from > to {
                    row.append(.empty)
                } else {
                    // question q sits in column index q + 2 (A = 0: ID, B: name, C: #, D: question 1)
                    let first = XLSXWriter.columnName(from + 2)
                    let last = XLSXWriter.columnName(to + 2)
                    row.append(.formula("SUM(\(first)\(r):\(last)\(r))"))
                }
            }
            row.append(.formula("C\(r)"))
            rows.append(row)
        }
        return XLSXSheet(name: cls.name, rightToLeft: true, columnWidths: [10.63, 25.63, 5.63],
                         defaultWidth: 13, rows: rows, boldFirstRow: true)
    }

    static func workbook(_ classes: [RecordClass], questionCount: Int, sections: [RecordSection]) -> Data {
        XLSXWriter.workbook(classes.map { sheet($0, questionCount: questionCount, sections: sections) })
    }

    /// A fixed sample for CI (tools/check_record_xlsx.py): two classes, 17 questions, Midterm sections.
    static func sample() -> Data {
        let full = [Double](repeating: 1, count: 17)
        var some = full
        some[0] = 0
        some[16] = 0
        let a = RecordClass(name: "أول ثانوي 1", students: [
            RecordStudent(gradalId: "101", name: "ابراهيم خالد", points: full),
            RecordStudent(gradalId: "102", name: "احمد سعد", points: some),
            RecordStudent(gradalId: "103", name: "خالد محمد", points: nil),
        ])
        let b = RecordClass(name: "أول ثانوي 2", students: [
            RecordStudent(gradalId: "201", name: "سعود فهد", points: some),
            RecordStudent(gradalId: "202", name: "فيصل ناصر", points: nil),
        ])
        return workbook([a, b], questionCount: RecordSection.midtermQuestions, sections: RecordSection.midtermSections)
    }
}
