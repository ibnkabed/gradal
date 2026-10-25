import Darwin
import Foundation
import UIKit

/// The phone's own Wi-Fi IPv4 address.
func wifiIPv4Address() -> String? {
    var storage: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&storage) == 0, let first = storage else { return nil }
    defer { freeifaddrs(storage) }
    for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
        let flags = Int32(pointer.pointee.ifa_flags)
        guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0,
              let address = pointer.pointee.ifa_addr,
              address.pointee.sa_family == UInt8(AF_INET),
              String(cString: pointer.pointee.ifa_name) == "en0" else { continue }
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        guard getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count),
                          nil, 0, NI_NUMERICHOST) == 0 else { continue }
        return String(cString: host)
    }
    return nil
}

private struct QuizzesBody: Encodable { let quizzes: [Quiz] }
private struct AcceptedIds: Decodable { let accepted: [String] }
private struct ScansBody: Decodable { let scans: [Scan] }
private struct TokenBody: Decodable { let token: String }
private struct PrintsBody: Decodable { let files: [PrintFile] }

/// The PC companion (pc/): discovery, pairing and sync. Port 7797 and GET /hello app "gradal-public",
/// protocol 1; the endpoints are those of the shared protocol.
@MainActor
final class Companion: ObservableObject {
    static let port = 7797
    static let protocolVersion = 1
    private static let tokenAccount = "pcToken"
    private static let hostKey = "gradalHost"
    private static let nameKey = "gradalPcName"
    private static let lastSyncKey = "gradalLastSync"

    @Published private(set) var host: String?
    @Published private(set) var pcName: String?
    @Published private(set) var paired: Bool
    @Published private(set) var busy = false
    @Published private(set) var awaitingPin = false
    @Published private(set) var lastSync: Date?
    @Published var status = ""

    private var scheduled: Task<Void, Never>?

    private enum Failure: Error {
        case unauthorized
        case status(Int)
        case noHost
    }

    init() {
        host = UserDefaults.standard.string(forKey: Self.hostKey)
        pcName = UserDefaults.standard.string(forKey: Self.nameKey)
        paired = Keychain.get(Self.tokenAccount) != nil
        lastSync = UserDefaults.standard.object(forKey: Self.lastSyncKey) as? Date
    }

    // MARK: - HTTP

    private func call(_ path: String, method: String = "GET", json: Data? = nil,
                      timeout: TimeInterval = 30, auth: Bool = true) async throws -> Data {
        guard let host, let url = URL(string: "http://\(host):\(Self.port)\(path)") else { throw Failure.noHost }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = timeout
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if let json {
            request.httpBody = json
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if auth, let token = Keychain.get(Self.tokenAccount) {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 { throw Failure.unauthorized }
        guard (200..<300).contains(code) else { throw Failure.status(code) }
        return data
    }

    // MARK: - Discovery

    /// What GET /hello says.
    struct Hello: Sendable {
        let name: String
        let proto: Int
    }

    /// GET /hello; the PC's name and protocol when it is a Gradal companion.
    nonisolated static func probe(_ address: String) async -> Hello? {
        guard let url = URL(string: "http://\(address):\(port)/hello") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 1.5
        request.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              body["app"] as? String == "gradal-public"
        else { return nil }
        let name = body["pcName"] as? String ?? address
        let proto = (body["protocol"] as? Int) ?? (body["protocol"] as? Double).map { Int($0) } ?? 0
        return Hello(name: name, proto: proto)
    }

    /// Refuses a PC that speaks another protocol version.
    private func accept(_ hello: Hello, silent: Bool) -> Bool {
        if hello.proto == Self.protocolVersion { return true }
        status = hello.proto < Self.protocolVersion
            ? "حدّث تطبيق الكمبيوتر: Gradal على الكمبيوتر أقدم من تطبيق الجوال."
            : "حدّث تطبيق الجوال: Gradal على الكمبيوتر أحدث من تطبيق الجوال."
        return false
    }

    /// The remembered address first; sweep the /24 (batches of 32) only when it stops answering.
    func locate(silent: Bool) async -> Bool {
        if let saved = host, let hello = await Self.probe(saved) {
            remember(host: saved, name: hello.name)
            return accept(hello, silent: silent)
        }
        guard let own = wifiIPv4Address() else {
            if !silent { status = "الجوال غير متصل بالواي فاي." }
            return false
        }
        let parts = own.split(separator: ".")
        guard parts.count == 4 else { return false }
        let prefix = parts.prefix(3).joined(separator: ".")
        let candidates = (1...254).map { "\(prefix).\($0)" }.filter { $0 != own }
        if !silent { status = "أبحث عن الكمبيوتر على الشبكة…" }
        for start in stride(from: 0, to: candidates.count, by: 32) {
            let slice = Array(candidates[start..<min(start + 32, candidates.count)])
            let hit = await withTaskGroup(of: (String, Hello)?.self, returning: (String, Hello)?.self) { group in
                for address in slice {
                    group.addTask {
                        if let hello = await Companion.probe(address) { return (address, hello) }
                        return nil
                    }
                }
                var found: (String, Hello)?
                for await result in group {
                    if let result, found == nil { found = result }
                }
                return found
            }
            if let hit {
                remember(host: hit.0, name: hit.1.name)
                return accept(hit.1, silent: silent)
            }
        }
        if !silent {
            status = "لم أجد الكمبيوتر. شغّل Gradal على الكمبيوتر، واجعل الجوال والكمبيوتر على الشبكة نفسها."
        }
        return false
    }

    private func remember(host: String, name: String) {
        self.host = host
        pcName = name
        UserDefaults.standard.set(host, forKey: Self.hostKey)
        UserDefaults.standard.set(name, forKey: Self.nameKey)
    }

    // MARK: - Pairing

    func startPairing() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        guard await locate(silent: false) else { return }
        do {
            let body = try JSONSerialization.data(withJSONObject: ["deviceName": UIDevice.current.name])
            _ = try await call("/m/pair/start", method: "POST", json: body, auth: false)
            awaitingPin = true
            status = "ظهر رمز من أربعة أرقام على الكمبيوتر. اكتبه هنا خلال دقيقتين."
        } catch {
            status = "تعذر طلب الرمز من الكمبيوتر."
        }
    }

    /// Returns true when the PIN was accepted and the token saved.
    func pair(pin: String) async -> Bool {
        guard !busy else { return false }
        busy = true
        defer { busy = false }
        let digits = String(pin.compactMap { ch -> Character? in
            guard let v = ch.wholeNumberValue, v < 10 else { return nil }
            return Character(String(v))
        })
        do {
            let body = try JSONSerialization.data(withJSONObject: [
                "pin": digits, "deviceId": DeviceIdentity.id, "deviceName": UIDevice.current.name,
            ])
            let data = try await call("/m/pair", method: "POST", json: body, auth: false)
            let reply = try JSONDecoder().decode(TokenBody.self, from: data)
            Keychain.set(reply.token, for: Self.tokenAccount)
            paired = true
            awaitingPin = false
            status = "تم الاقتران."
            return true
        } catch Failure.unauthorized {
            status = "الرمز غير صحيح أو انتهت مدته. اطلب رمزًا جديدًا إن لزم."
        } catch {
            status = "تعذر الاقتران. تأكد أن الكمبيوتر يعمل."
        }
        return false
    }

    func cancelPairing() {
        awaitingPin = false
        status = ""
    }

    /// Forgets the token and the remembered address.
    func forget() {
        scheduled?.cancel()
        Keychain.set(nil, for: Self.tokenAccount)
        UserDefaults.standard.removeObject(forKey: Self.hostKey)
        UserDefaults.standard.removeObject(forKey: Self.nameKey)
        UserDefaults.standard.removeObject(forKey: Self.lastSyncKey)
        host = nil
        pcName = nil
        paired = false
        awaitingPin = false
        lastSync = nil
        status = ""
    }

    private func dropToken() {
        Keychain.set(nil, for: Self.tokenAccount)
        paired = false
        status = "انتهى الاقتران. اضغط «اقتران» من جديد."
    }

    // MARK: - Sync

    /// When the app comes to the front.
    func autoSync(_ store: Store) {
        guard paired else { return }
        Task { await sync(store, silent: true) }
    }

    /// A few seconds after local changes (new scans, edits).
    func scheduleSync(_ store: Store, delay: Double = 4) {
        guard paired else { return }
        scheduled?.cancel()
        scheduled = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            while self?.busy == true {
                if Task.isCancelled { return }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
            if Task.isCancelled { return }
            await self?.sync(store, silent: true)
        }
    }

    /// Order per PROTOCOL: quizzes → scans (oldest first, 10 per request) → snapshot → scans on screen.
    func sync(_ store: Store, silent: Bool = false) async {
        guard !busy else { return }
        guard paired else {
            if !silent { status = "اقترن بالكمبيوتر أولًا." }
            return
        }
        busy = true
        defer { busy = false }
        guard await locate(silent: silent) else { return }
        do {
            let quizzes = store.pendingQuizzes
            if !quizzes.isEmpty {
                if !silent { status = "أرسل الاختبارات…" }
                let body = try JSONEncoder().encode(QuizzesBody(quizzes: quizzes))
                _ = try await call("/m/quizzes", method: "POST", json: body, timeout: 60)
                store.markQuizzesSynced(quizzes)
            }

            let scans = store.pendingScans
            var sent = 0
            for start in stride(from: 0, to: scans.count, by: 10) {
                let chunk = Array(scans[start..<min(start + 10, scans.count)])
                if !silent { status = "أرسل الأوراق: \(sent) من \(scans.count)…" }
                let body = try scansPayload(chunk, store)
                let data = try await call("/m/scans", method: "POST", json: body, timeout: 120)
                let reply = try JSONDecoder().decode(AcceptedIds.self, from: data)
                let accepted = Set(reply.accepted)
                store.markScansSynced(chunk.filter { accepted.contains($0.id) })
                sent += accepted.count
            }

            if !silent { status = "أنزّل الطلاب والاختبارات…" }
            let snapData = try await call("/m/snapshot", timeout: 60)
            let snapshot = try JSONDecoder().decode(Snapshot.self, from: snapData)
            store.applySnapshot(snapshot)

            for quizId in store.quizzesToRefresh() {
                let encoded = quizId.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? quizId
                let data = try await call("/m/scans?quizId=\(encoded)", timeout: 60)
                let pulled = try JSONDecoder().decode(ScansBody.self, from: data)
                store.mergeScans(pulled.scans)
            }

            await downloadPrints(store, silent: silent)

            let now = Date()
            lastSync = now
            UserDefaults.standard.set(now, forKey: Self.lastSyncKey)
            status = store.pendingCount == 0 ? "تمت المزامنة." : "تمت المزامنة، وبقي \(store.pendingCount) بانتظار الإرسال."
        } catch Failure.unauthorized {
            dropToken()
        } catch {
            if !silent { status = "انقطع الاتصال. ما لم يُرسل باقٍ في الجوال ويُرسل لاحقًا." }
        }
    }

    /// The papers of the recent quizzes (the last 60 days, and the one on screen), so they print without
    /// the PC. A PC without /m/prints (older) or a failed file leaves what the phone already has.
    private func downloadPrints(_ store: Store, silent: Bool) async {
        let shelf = Prints.shared
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let since = formatter.string(from: Date().addingTimeInterval(-60 * 86400))
        let quizzes = store.activeQuizzes.filter { $0.date >= since || $0.id == store.openQuizId }
        shelf.prune(keeping: Set(quizzes.map(\.id)))
        for quiz in quizzes {
            let qid = quiz.id.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? quiz.id
            guard let data = try? await call("/m/prints?quizId=\(qid)", timeout: 180),
                  let listed = try? JSONDecoder().decode(PrintsBody.self, from: data).files else { continue }
            for file in listed where shelf.needs(quiz.id, file) {
                if !silent { status = "أنزّل أوراق الطباعة: \(quiz.name)…" }
                let fid = file.id.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? file.id
                if let pdf = try? await call("/m/print?quizId=\(qid)&id=\(fid)", timeout: 180) {
                    try? shelf.store(quiz.id, file, data: pdf)
                }
            }
            shelf.settle(quiz.id, listed: listed)
        }
    }

    /// Scan JSON plus the straightened sheet as base64 JPEG (null when there is none).
    private func scansPayload(_ scans: [Scan], _ store: Store) throws -> Data {
        var items: [[String: Any]] = []
        let encoder = JSONEncoder()
        for scan in scans {
            let data = try encoder.encode(scan)
            guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            if !scan.deleted, scan.hasImage, let image = try? Data(contentsOf: store.imageURL(scan.id)) {
                object["imageJpegBase64"] = image.base64EncodedString()
            } else {
                object["imageJpegBase64"] = NSNull()
            }
            items.append(object)
        }
        return try JSONSerialization.data(withJSONObject: ["scans": items])
    }
}
