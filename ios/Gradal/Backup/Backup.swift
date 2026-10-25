import Foundation

/// The whole data folder as one .zip for Files / iCloud, and back. The printouts cache (prints/) is left out:
/// the Store makes it again. The caller reloads the Store after a restore.
enum Backup {
    enum BackupError: LocalizedError {
        case notBackup
        case nothingToSave
        case cannotRead
        case failed

        var errorDescription: String? {
            switch self {
            case .notBackup: return "ليس هذا ملف نسخة احتياطية من Gradal"
            case .nothingToSave: return "لا توجد بيانات لنسخها بعد"
            case .cannotRead: return "تعذّرت قراءة ملف النسخة الاحتياطية"
            case .failed: return "تعذّرت استعادة النسخة الاحتياطية، وبقيت البيانات كما كانت"
            }
        }
    }

    /// Folders under the data folder that are a cache, not data.
    static let skipped: Set<String> = ["prints"]

    /// Zips the whole data folder (store.json, books/, scans/) to a temporary Gradal-backup-<yyyy-MM-dd>.zip
    /// for the share sheet.
    static func export(folder: URL) throws -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: folder.appendingPathComponent("store.json").path) else {
            throw BackupError.nothingToSave
        }
        var archive = ZipWriter()
        guard let walker = fm.enumerator(atPath: folder.path) else { throw BackupError.nothingToSave }
        var paths: [String] = []
        while let next = walker.nextObject() as? String {
            let rel = next.replacingOccurrences(of: "\\", with: "/")
            let parts = rel.split(separator: "/").map(String.init)
            if parts.isEmpty { continue }
            if parts.contains(where: { $0.hasPrefix(".") }) || (parts.count >= 1 && skipped.contains(parts[0])) {
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: folder.appendingPathComponent(rel).path, isDirectory: &isDir), isDir.boolValue {
                    walker.skipDescendants()
                }
                continue
            }
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: folder.appendingPathComponent(rel).path, isDirectory: &isDir),
                  !isDir.boolValue else { continue }
            paths.append(rel)
        }
        // store.json first, then the rest in a stable order.
        paths.sort { a, b in
            if a == "store.json" { return b != "store.json" }
            if b == "store.json" { return false }
            return a < b
        }
        for rel in paths {
            let content = try Data(contentsOf: folder.appendingPathComponent(rel))
            archive.add(rel, content)
        }
        let out = fm.temporaryDirectory.appendingPathComponent("Gradal-backup-\(DayFormat.today()).zip")
        if fm.fileExists(atPath: out.path) { try fm.removeItem(at: out) }
        try archive.finish().write(to: out, options: .atomic)
        return out
    }

    /// Replaces the data folder with a backup's content. store.json must be a JSON object with "quizzes";
    /// everything is written to a fresh folder first, and the data folder is swapped only when that succeeded.
    static func restore(_ zip: URL, into folder: URL) throws {
        let fm = FileManager.default
        guard let data = try? Data(contentsOf: zip) else { throw BackupError.cannotRead }
        guard let reader = try? ZipReader(data),
              let storeData = try? reader.data("store.json"),
              let object = try? JSONSerialization.jsonObject(with: storeData),
              let dict = object as? [String: Any], dict["quizzes"] != nil else {
            throw BackupError.notBackup
        }

        // Only plain relative paths: no absolute paths, no "..", no cache folders.
        var files: [String] = []
        for name in reader.names {
            if name.hasSuffix("/") { continue }
            let parts = name.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            if name.hasPrefix("/") || name.contains("\\") || parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) {
                throw BackupError.notBackup
            }
            if skipped.contains(parts[0]) || parts.contains(where: { $0.hasPrefix(".") }) { continue }
            files.append(name)
        }

        let parent = folder.deletingLastPathComponent()
        let token = UUID().uuidString.lowercased()
        let staging = parent.appendingPathComponent(".Gradal-restore-\(token)", isDirectory: true)
        let old = parent.appendingPathComponent(".Gradal-old-\(token)", isDirectory: true)
        do {
            try fm.createDirectory(at: staging, withIntermediateDirectories: true)
            for name in files {
                let target = staging.appendingPathComponent(name)
                try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try reader.data(name).write(to: target)
            }
            for dir in ["books", "scans", "prints"] {
                try fm.createDirectory(at: staging.appendingPathComponent(dir, isDirectory: true),
                                       withIntermediateDirectories: true)
            }
        } catch {
            try? fm.removeItem(at: staging)
            if error is ZipReader.ZipError { throw BackupError.notBackup }
            throw BackupError.failed
        }

        // Swap: the old folder is kept until the new one is in place.
        let hadOld = fm.fileExists(atPath: folder.path)
        do {
            if hadOld { try fm.moveItem(at: folder, to: old) }
        } catch {
            try? fm.removeItem(at: staging)
            throw BackupError.failed
        }
        do {
            try fm.moveItem(at: staging, to: folder)
        } catch {
            if hadOld { try? fm.moveItem(at: old, to: folder) }
            try? fm.removeItem(at: staging)
            throw BackupError.failed
        }
        if hadOld { try? fm.removeItem(at: old) }
    }
}
