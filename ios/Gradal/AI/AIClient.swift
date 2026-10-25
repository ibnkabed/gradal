import Combine
import Foundation

/// The linked AI providers and the calls to them (port of reference/ai.py). The teacher pastes a key in the
/// settings; it is checked at once (GET /models), the provider's best model is picked, and every linked
/// provider is then used in `AIProviders.all` order until one answers. Keys live only in the Keychain
/// (account "ai.<providerId>") and are sent only to their own provider; they are never logged or printed.

/// A message for the teacher, in Arabic.
struct AIError: LocalizedError, Equatable {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// A linked provider as the settings show it (the key itself is in the Keychain).
struct LinkedProvider: Codable, Hashable, Identifiable {
    var id: String
    var model: String
    var linkedAt: String
    var lastError: String?
}

@MainActor
final class AIClient: ObservableObject {
    static let shared = AIClient()

    static let userAgent = "Gradal/1.0 (+https://github.com/ibnkabed/gradal)"
    private static let defaultsKey = "gradal.ai.linked"

    /// Kept in `AIProviders.all` order; persisted as JSON in UserDefaults.
    @Published private(set) var linked: [LinkedProvider] = []

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
        if let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
           let saved = try? JSONDecoder().decode([LinkedProvider].self, from: data) {
            // a record whose key is gone (e.g. restored on another phone) is not linked
            linked = Self.sorted(saved.filter { Self.key($0.id) != nil })
        }
    }

    // MARK: linking

    /// Checks the key with the provider's /models list and stores it with the chosen model; returns the model.
    func link(_ providerId: String, key rawKey: String) async throws -> String {
        guard let p = AIProviders.provider(providerId) else { throw AIError("مزوّد غير معروف") }
        let key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if key.unicodeScalars.count < 10 || key.unicodeScalars.contains(where: { $0.properties.isWhitespace }) {
            throw AIError("الصق المفتاح كما نسخته، بلا مسافات")
        }
        let listed: [String: Any]
        do {
            listed = try await request(p.base + "/models", key: key, body: nil, timeout: 30)
        } catch {
            throw AIError(Self.errorText(error))
        }
        let ids = (listed["data"] as? [Any] ?? []).compactMap { ($0 as? [String: Any])?["id"] as? String }
        guard let model = AIProviders.pickModel(p, ids: ids) else {
            throw AIError("المفتاح يعمل، لكن لم أجد نموذجًا مناسبًا لكتابة الأسئلة عند هذا المزوّد")
        }
        Keychain.set(key, for: Self.account(providerId))
        var list = linked.filter { $0.id != providerId }
        list.append(LinkedProvider(id: providerId, model: model, linkedAt: Stamp.now(), lastError: nil))
        linked = Self.sorted(list)
        save()
        return model
    }

    func unlink(_ providerId: String) {
        Keychain.set(nil, for: Self.account(providerId))
        linked.removeAll { $0.id == providerId }
        save()
    }

    func isLinked(_ providerId: String) -> Bool { linked.contains { $0.id == providerId } }

    /// The key's last four characters, for the settings ("…abcd"); "" when not linked.
    func keyEnd(_ providerId: String) -> String {
        guard isLinked(providerId), let key = Self.key(providerId) else { return "" }
        return String(key.suffix(4))
    }

    // MARK: calls

    /// Asks the linked providers in order until one answers: (text, provider id). JSON mode is asked for
    /// (not from Cerebras) and dropped when a model refuses it (HTTP 400); a 429 is retried once after 4 s.
    func chat(_ messages: [[String: String]], jsonMode: Bool = true, exclude: Set<String> = [],
              temperature: Double = 0.7) async throws -> (text: String, provider: String) {
        let providers = linked.filter { !exclude.contains($0.id) }
        if providers.isEmpty {
            throw AIError("لم يُربط أي مزوّد ذكاء اصطناعي. اربط واحدًا من «الإعدادات».")
        }
        var problems: [String] = []
        for entry in providers {
            guard let p = AIProviders.provider(entry.id), let key = Self.key(entry.id) else { continue }
            var body: [String: Any] = ["model": entry.model, "messages": messages, "temperature": temperature]
            if jsonMode && p.id != "cerebras" {
                body["response_format"] = ["type": "json_object"]
            }
            attempts: for attempt in 0..<2 {
                var waitFirst = false
                do {
                    let reply = try await request(p.base + "/chat/completions", key: key, body: body, timeout: 180)
                    let text = Self.chatText(reply)
                    if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        noteError(p.id, nil)
                        return (text, p.id)
                    }
                    problems.append("\(p.name): \(Self.errorText(Unexpected()))")
                    break attempts
                } catch let e as HTTPFailure {
                    if e.code == 400 && body["response_format"] != nil {
                        body.removeValue(forKey: "response_format")   // some models refuse JSON mode: ask without it
                        continue attempts
                    }
                    if e.code == 429 && attempt == 0 {
                        waitFirst = true
                    } else {
                        let text = Self.errorText(e)
                        problems.append("\(p.name): \(text)")
                        noteError(p.id, text)
                        break attempts
                    }
                } catch {
                    problems.append("\(p.name): \(Self.errorText(error))")
                    break attempts
                }
                if waitFirst {
                    try await Task.sleep(nanoseconds: 4_000_000_000)
                }
            }
        }
        throw AIError("لم ينجح أي مزوّد: " + problems.joined(separator: "؛ "))
    }

    /// Gemini's own API reads the PDF pages as images (scanned books, broken Arabic text layers).
    func geminiPDF(_ pdf: Data, prompt: String) async throws -> String {
        guard let g = linked.first(where: { $0.id == "gemini" }), let key = Self.key("gemini") else {
            throw AIError("هذا الكتاب صور لا نص فيها، ويقرؤه Gemini وحده: اربط Gemini من «الإعدادات».")
        }
        let model = g.model.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? g.model
        guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent") else {
            throw AIError("Gemini: " + Self.errorText(Unexpected()))
        }
        let body: [String: Any] = [
            "contents": [["parts": [["inline_data": ["mime_type": "application/pdf",
                                                    "data": pdf.base64EncodedString()]],
                                    ["text": prompt]]]],
            "generationConfig": ["temperature": 0.2],
        ]
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 300
        req.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        let reply: [String: Any]
        do {
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            reply = try await send(req)
        } catch {
            throw AIError("Gemini: " + Self.errorText(error))
        }
        let candidate = (reply["candidates"] as? [Any])?.first as? [String: Any]
        let parts = (candidate?["content"] as? [String: Any])?["parts"] as? [Any] ?? []
        return parts.compactMap { ($0 as? [String: Any])?["text"] as? String }.joined()
    }

    // MARK: private

    private struct HTTPFailure: Error { let code: Int }
    private struct Unexpected: Error {}

    private static func account(_ providerId: String) -> String { "ai.\(providerId)" }

    private static func key(_ providerId: String) -> String? { Keychain.get(account(providerId)) }

    private static func sorted(_ list: [LinkedProvider]) -> [LinkedProvider] {
        list.sorted { AIProviders.order($0.id) < AIProviders.order($1.id) }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(linked) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }

    private func noteError(_ providerId: String, _ message: String?) {
        guard let i = linked.firstIndex(where: { $0.id == providerId }) else { return }
        if linked[i].lastError == message { return }
        linked[i].lastError = message
        save()
    }

    /// GET (body nil) or POST JSON with the headers every provider gets.
    private func request(_ urlString: String, key: String, body: [String: Any]?, timeout: TimeInterval) async throws -> [String: Any] {
        guard let url = URL(string: urlString) else { throw Unexpected() }
        var req = URLRequest(url: url)
        req.httpMethod = body == nil ? "GET" : "POST"
        req.timeoutInterval = timeout
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("https://github.com/ibnkabed/gradal", forHTTPHeaderField: "HTTP-Referer")
        req.setValue("Gradal", forHTTPHeaderField: "X-Title")
        if let body {
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        return try await send(req)
    }

    /// Throws HTTPFailure for a non-2xx status, URLError for the network, Unexpected for a reply that is
    /// not a JSON object.
    private func send(_ req: URLRequest) async throws -> [String: Any] {
        let (data, response) = try await session.data(for: req)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw HTTPFailure(code: http.statusCode)
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw Unexpected() }
        return obj
    }

    private static func chatText(_ reply: [String: Any]) -> String {
        let first = (reply["choices"] as? [Any])?.first as? [String: Any]
        let message = first?["message"] as? [String: Any]
        return message?["content"] as? String ?? ""
    }

    /// reference/ai.py _error_text.
    private static func errorText(_ error: Error) -> String {
        if let e = error as? HTTPFailure {
            switch e.code {
            case 401, 403: return "المفتاح غير صحيح أو لا يملك صلاحية"
            case 429: return "انتهت الحصة المتاحة الآن، جرّب لاحقًا"
            case 402: return "الرصيد غير كافٍ"
            default: return "رفض المزوّد الطلب (\(e.code))"
            }
        }
        if error is URLError || (error as NSError).domain == NSURLErrorDomain || (error as NSError).domain == NSPOSIXErrorDomain {
            return "تعذّر الاتصال بالمزوّد: تحقق من الإنترنت"
        }
        return "ردّ غير متوقع من المزوّد"
    }
}
