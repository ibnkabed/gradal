import Foundation

/// The AI providers that write the questions (port of reference/ai.py PROVIDERS and pick_model). Foundation
/// only, so it is also compiled into OMRCheck. All of them speak the OpenAI chat-completions dialect; model
/// names are never hard-coded: each provider's own /models list is read and the best match is chosen here.

struct AIProvider: Identifiable, Hashable {
    let id: String
    let name: String
    let free: Bool
    let base: String              // OpenAI-style base URL ("/models" and "/chat/completions" follow it)
    let keyURL: URL               // where the teacher makes a key
    let note: String              // shown in the settings, Arabic
    let prefer: [String]          // hints, best first, matched inside the lower-cased model id
    let avoid: [String]           // a model whose id contains any of these is never used
    let onlyFree: Bool            // OpenRouter: only ":free" models

    init(id: String, name: String, free: Bool, base: String, keyURL: String, note: String,
         prefer: [String], avoid: [String], onlyFree: Bool = false) {
        self.id = id
        self.name = name
        self.free = free
        self.base = base
        self.keyURL = URL(string: keyURL)!
        self.note = note
        self.prefer = prefer
        self.avoid = avoid
        self.onlyFree = onlyFree
    }
}

enum AIProviders {
    /// The order of use: free and good at Arabic first, the cheap paid one last.
    static let all: [AIProvider] = [
        AIProvider(id: "gemini", name: "Google Gemini", free: true,
                   base: "https://generativelanguage.googleapis.com/v1beta/openai",
                   keyURL: "https://aistudio.google.com/apikey",
                   note: "مجاني بحصة يومية سخية، ويقرأ كتب PDF المصوّرة بنفسه. سجّل بحساب Google ثم «Create API key».",
                   prefer: ["flash"],
                   avoid: ["lite", "image", "tts", "audio", "live", "embedding", "vision", "thinking", "exp"]),
        AIProvider(id: "alibaba", name: "Alibaba Qwen", free: true,
                   base: "https://dashscope-intl.aliyuncs.com/compatible-mode/v1",
                   keyURL: "https://modelstudio.console.alibabacloud.com/ap-southeast-1/settings/api-key",
                   note: "حصة مجانية عند التسجيل، وقوي في العربية. أنشئ مفتاحًا من صفحة API Key (منطقة سنغافورة).",
                   prefer: ["qwen-plus", "qwen-max", "qwen-turbo", "qwen"],
                   avoid: ["vl", "audio", "omni", "math", "coder", "embedding", "mt"]),
        AIProvider(id: "groq", name: "Groq", free: true,
                   base: "https://api.groq.com/openai/v1",
                   keyURL: "https://console.groq.com/keys",
                   note: "مجاني وسريع جدًا. سجّل ثم «Create API Key».",
                   prefer: ["gpt-oss-120b", "llama-3.3-70b", "70b", "qwen"],
                   avoid: ["guard", "whisper", "tts", "-8b", "-20b", "compound"]),
        AIProvider(id: "cerebras", name: "Cerebras", free: true,
                   base: "https://api.cerebras.ai/v1",
                   keyURL: "https://cloud.cerebras.ai/platform",
                   note: "مجاني بحدود في الدقيقة. سجّل ثم انسخ المفتاح من «API Keys».",
                   prefer: ["gpt-oss-120b", "qwen", "llama"],
                   avoid: ["-8b"]),
        AIProvider(id: "mistral", name: "Mistral", free: true,
                   base: "https://api.mistral.ai/v1",
                   keyURL: "https://console.mistral.ai/api-keys",
                   note: "خطة «Experiment» مجانية. سجّل ثم «Create new key».",
                   prefer: ["mistral-medium", "mistral-large", "mistral-small"],
                   avoid: ["embed", "ocr", "moderation", "codestral", "pixtral", "voxtral"]),
        AIProvider(id: "openrouter", name: "OpenRouter", free: true,
                   base: "https://openrouter.ai/api/v1",
                   keyURL: "https://openrouter.ai/keys",
                   note: "نماذج مجانية متعددة بحد يومي صغير. يُستعمل احتياطًا.",
                   prefer: [":free"], avoid: [], onlyFree: true),
        AIProvider(id: "deepseek", name: "DeepSeek", free: false,
                   base: "https://api.deepseek.com",
                   keyURL: "https://platform.deepseek.com/api_keys",
                   note: "مدفوع لكنه رخيص جدًا، ويحتاج شحن رصيد صغير. يُستعمل بعد المجانيين.",
                   prefer: ["flash", "deepseek-chat", "deepseek"],
                   avoid: ["reasoner", "coder"]),
    ]

    static func provider(_ id: String) -> AIProvider? { all.first { $0.id == id } }

    /// Where a provider sits in `all` (unknown ids last).
    static func order(_ id: String) -> Int { all.firstIndex { $0.id == id } ?? all.count }

    /// The best model for writing questions among a provider's live /models list (nil: none suitable).
    static func pickModel(_ providerId: String, ids: [String]) -> String? {
        guard let p = provider(providerId) else { return nil }
        return pickModel(p, ids: ids)
    }

    static func pickModel(_ p: AIProvider, ids: [String]) -> String? {
        let names = ids.map { $0.hasPrefix("models/") ? String($0.dropFirst("models/".count)) : $0 }
        var usable = names.filter { n in !p.avoid.contains { n.lowercased().contains($0) } }
        if p.onlyFree {
            usable = usable.filter { $0.hasSuffix(":free") }
        }
        for hint in p.prefer {
            let hits = usable.filter { $0.lowercased().contains(hint) }
            // a provider's own alias (e.g. qwen-plus) follows its newest version
            if let exact = hits.first(where: { $0.lowercased() == hint }) { return exact }
            if !hits.isEmpty {
                let stable = hits.filter { !$0.lowercased().contains("preview") }
                return newest(stable.isEmpty ? hits : stable)
            }
        }
        return usable.first
    }

    /// The first of the ids with the greatest version key (Python's stable sort, reversed, then [0]).
    private static func newest(_ ids: [String]) -> String {
        var best = ids[0]
        var bestKey = versionKey(best)
        for id in ids.dropFirst() {
            let key = versionKey(id)
            if bestKey.lexicographicallyPrecedes(key) {
                best = id
                bestKey = key
            }
        }
        return best
    }

    /// The numbers in a model id, in order ("gemini-3.8-flash" -> [3.8]); [0] when there are none.
    static func versionKey(_ modelId: String) -> [Double] {
        guard let re = try? NSRegularExpression(pattern: #"(\d+(?:\.\d+)?)"#) else { return [0] }
        let ns = modelId as NSString
        let nums = re.matches(in: modelId, range: NSRange(location: 0, length: ns.length))
            .compactMap { Double(ns.substring(with: $0.range)) }
        return nums.isEmpty ? [0] : nums
    }
}
