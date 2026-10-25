import Foundation
import SwiftUI
import UIKit

/// One paper of a quiz the PC prepared as a PDF (GET /m/prints, shared/PROTOCOL.md).
struct PrintFile: Codable, Identifiable, Hashable {
    var id: String
    var title: String
    var pages: Int
    var bytes: Int
    var updatedAt: String
}

/// The quizzes' papers kept on the phone, so they print at school without the PC:
/// Application Support/Gradal/prints/<quizId>/<id>.pdf, and index.json listing them.
@MainActor
final class Prints: ObservableObject {
    static let shared = Prints()

    @Published private(set) var index: [String: [PrintFile]] = [:]
    private let folder: URL

    private init() {
        folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Gradal/prints", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: folder.appendingPathComponent("index.json")),
           let saved = try? JSONDecoder().decode([String: [PrintFile]].self, from: data) {
            index = saved
        }
    }

    func url(_ quizId: String, _ fileId: String) -> URL {
        folder.appendingPathComponent(quizId, isDirectory: true).appendingPathComponent("\(fileId).pdf")
    }

    /// The papers of a quiz that are on the phone.
    func files(_ quizId: String) -> [PrintFile] {
        (index[quizId] ?? []).filter { FileManager.default.fileExists(atPath: url(quizId, $0.id).path) }
    }

    /// Whether this listed file must be downloaded again.
    func needs(_ quizId: String, _ file: PrintFile) -> Bool {
        guard let mine = index[quizId]?.first(where: { $0.id == file.id }) else { return true }
        return mine.updatedAt != file.updatedAt || !FileManager.default.fileExists(atPath: url(quizId, file.id).path)
    }

    func store(_ quizId: String, _ file: PrintFile, data: Data) throws {
        let target = url(quizId, file.id)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: target, options: .atomic)
        var list = index[quizId] ?? []
        list.removeAll { $0.id == file.id }
        list.append(file)
        index[quizId] = list
        save()
    }

    /// After a full listing: keeps its order, drops what the PC no longer lists.
    func settle(_ quizId: String, listed: [PrintFile]) {
        let keep = Set(listed.map(\.id))
        for old in index[quizId] ?? [] where !keep.contains(old.id) {
            try? FileManager.default.removeItem(at: url(quizId, old.id))
        }
        let have = Dictionary((index[quizId] ?? []).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        index[quizId] = listed.compactMap { have[$0.id] }
        save()
    }

    /// Quizzes no longer on the phone (deleted) lose their papers.
    func prune(keeping quizIds: Set<String>) {
        for quizId in index.keys where !quizIds.contains(quizId) {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(quizId, isDirectory: true))
            index[quizId] = nil
        }
        save()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(index) else { return }
        try? data.write(to: folder.appendingPathComponent("index.json"), options: .atomic)
    }

    /// The system print dialog (AirPrint): printer, copies and pages are chosen there.
    static func printPDF(_ url: URL, title: String) {
        let info = UIPrintInfo(dictionary: nil)
        info.outputType = .grayscale
        info.jobName = title
        let controller = UIPrintInteractionController.shared
        controller.printInfo = info
        controller.printingItem = url
        _ = controller.present(animated: true)
    }
}
