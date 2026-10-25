"""AI providers that write the questions. The teacher pastes a key in the settings; Gradal checks it at once,
picks that provider's best suitable model itself, and uses every linked provider in turn (free ones first).

    PROVIDERS                         -> the catalogue (name, sign-up page, key page, base URL, free or paid)
    link(store, pid, key)             -> checks the key (GET /models), stores key + chosen model
    unlink(store, pid)
    public_state(store)               -> what the settings page shows (never the key itself)
    chat(store, messages, ...)        -> (text, provider id): the first linked provider that answers
    gemini_pdf(store, pdf, prompt)    -> text: Gemini reads the PDF pages itself (scanned or badly encoded books)

All providers speak the OpenAI chat-completions dialect, so one client serves them all. Model names are
never hard-coded: each provider's own /models list is read, and the best match for the task is chosen
by the hints below (newest version first). Keys stay in the local data file and are never sent anywhere
but to their own provider.
"""

from __future__ import annotations

import base64
import json
import re
import time
import urllib.error
import urllib.request

from store import now_iso

UA = "Gradal/1.0 (+https://github.com/ibnkabed/gradal)"

# order = the order of use: free and good at Arabic first, the cheap paid one last
PROVIDERS = [
    {"id": "gemini", "name": "Google Gemini", "free": True,
     "base": "https://generativelanguage.googleapis.com/v1beta/openai",
     "keyUrl": "https://aistudio.google.com/apikey",
     "note": "مجاني بحصة يومية سخية، ويقرأ كتب PDF المصوّرة بنفسه. سجّل بحساب Google ثم «Create API key».",
     "prefer": ["flash"], "avoid": ["lite", "image", "tts", "audio", "live", "embedding", "vision", "thinking", "exp"]},
    {"id": "alibaba", "name": "Alibaba Qwen", "free": True,
     "base": "https://dashscope-intl.aliyuncs.com/compatible-mode/v1",
     "keyUrl": "https://modelstudio.console.alibabacloud.com/ap-southeast-1/settings/api-key",
     "note": "حصة مجانية عند التسجيل، وقوي في العربية. أنشئ مفتاحًا من صفحة API Key (منطقة سنغافورة).",
     "prefer": ["qwen-plus", "qwen-max", "qwen-turbo", "qwen"], "avoid": ["vl", "audio", "omni", "math", "coder", "embedding", "mt"]},
    {"id": "groq", "name": "Groq", "free": True,
     "base": "https://api.groq.com/openai/v1",
     "keyUrl": "https://console.groq.com/keys",
     "note": "مجاني وسريع جدًا. سجّل ثم «Create API Key».",
     "prefer": ["gpt-oss-120b", "llama-3.3-70b", "70b", "qwen"], "avoid": ["guard", "whisper", "tts", "-8b", "-20b", "compound"]},
    {"id": "cerebras", "name": "Cerebras", "free": True,
     "base": "https://api.cerebras.ai/v1",
     "keyUrl": "https://cloud.cerebras.ai/platform",
     "note": "مجاني بحدود في الدقيقة. سجّل ثم انسخ المفتاح من «API Keys».",
     "prefer": ["gpt-oss-120b", "qwen", "llama"], "avoid": ["-8b"]},
    {"id": "mistral", "name": "Mistral", "free": True,
     "base": "https://api.mistral.ai/v1",
     "keyUrl": "https://console.mistral.ai/api-keys",
     "note": "خطة «Experiment» مجانية. سجّل ثم «Create new key».",
     "prefer": ["mistral-medium", "mistral-large", "mistral-small"], "avoid": ["embed", "ocr", "moderation", "codestral", "pixtral", "voxtral"]},
    {"id": "openrouter", "name": "OpenRouter", "free": True,
     "base": "https://openrouter.ai/api/v1",
     "keyUrl": "https://openrouter.ai/keys",
     "note": "نماذج مجانية متعددة بحد يومي صغير. يُستعمل احتياطًا.",
     "prefer": [":free"], "avoid": [], "onlyFree": True},
    {"id": "deepseek", "name": "DeepSeek", "free": False,
     "base": "https://api.deepseek.com",
     "keyUrl": "https://platform.deepseek.com/api_keys",
     "note": "مدفوع لكنه رخيص جدًا، ويحتاج شحن رصيد صغير. يُستعمل بعد المجانيين.",
     "prefer": ["flash", "deepseek-chat", "deepseek"], "avoid": ["reasoner", "coder"]},
]
BY_ID = {p["id"]: p for p in PROVIDERS}


class AIError(RuntimeError):
    """A message for the teacher, in Arabic."""


def _request(url: str, key: str, body: dict | None = None, timeout: float = 120) -> dict:
    data = json.dumps(body).encode("utf-8") if body is not None else None
    req = urllib.request.Request(url, data=data, method="POST" if body is not None else "GET",
                                 headers={"Authorization": f"Bearer {key}", "Content-Type": "application/json",
                                          "User-Agent": UA, "HTTP-Referer": "https://github.com/ibnkabed/gradal",
                                          "X-Title": "Gradal"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read().decode("utf-8"))


def _version_key(model_id: str) -> tuple:
    nums = [float(n) for n in re.findall(r"(\d+(?:\.\d+)?)", model_id)]
    return tuple(nums) or (0.0,)


def pick_model(pid: str, ids: list[str]) -> str | None:
    """The best model for writing questions among a provider's live list."""
    p = BY_ID[pid]
    names = [i.split("/", 1)[1] if i.startswith("models/") else i for i in ids]
    usable = [n for n in names if not any(a in n.lower() for a in p["avoid"])]
    if p.get("onlyFree"):
        usable = [n for n in usable if n.endswith(":free")]
    for hint in p["prefer"]:
        hits = [n for n in usable if hint in n.lower()]
        exact = [n for n in hits if n.lower() == hint]
        if exact:                         # a provider's own alias (e.g. qwen-plus) follows its newest version
            return exact[0]
        if hits:
            stable = [h for h in hits if "preview" not in h.lower()] or hits
            return sorted(stable, key=_version_key, reverse=True)[0]
    return usable[0] if usable else None


def _error_text(e: Exception) -> str:
    if isinstance(e, urllib.error.HTTPError):
        if e.code in (401, 403):
            return "المفتاح غير صحيح أو لا يملك صلاحية"
        if e.code == 429:
            return "انتهت الحصة المتاحة الآن، جرّب لاحقًا"
        if e.code == 402:
            return "الرصيد غير كافٍ"
        return f"رفض المزوّد الطلب ({e.code})"
    if isinstance(e, (urllib.error.URLError, TimeoutError, OSError)):
        return "تعذّر الاتصال بالمزوّد: تحقق من الإنترنت"
    return "ردّ غير متوقع من المزوّد"


def link(store, pid: str, key: str) -> dict:
    if pid not in BY_ID:
        raise AIError("مزوّد غير معروف")
    key = (key or "").strip()
    if len(key) < 10 or any(c.isspace() for c in key):
        raise AIError("الصق المفتاح كما نسخته، بلا مسافات")
    p = BY_ID[pid]
    try:
        listed = _request(p["base"] + "/models", key, timeout=30)
    except Exception as e:  # noqa: BLE001
        raise AIError(_error_text(e)) from None
    ids = [m.get("id", "") for m in listed.get("data") or [] if isinstance(m, dict)]
    model = pick_model(pid, ids)
    if not model:
        raise AIError("المفتاح يعمل، لكن لم أجد نموذجًا مناسبًا لكتابة الأسئلة عند هذا المزوّد")
    with store.lock:
        store.data["ai"][pid] = {"key": key, "model": model, "linkedAt": now_iso(), "lastError": None}
        store.save()
    return {"id": pid, "model": model}


def unlink(store, pid: str) -> None:
    with store.lock:
        store.data["ai"].pop(pid, None)
        store.save()


def linked(store) -> list[dict]:
    return [{**p, **store.data["ai"][p["id"]]} for p in PROVIDERS if store.data["ai"].get(p["id"], {}).get("key")]


def public_state(store) -> list[dict]:
    out = []
    for p in PROVIDERS:
        mine = store.data["ai"].get(p["id"]) or {}
        out.append({k: p[k] for k in ("id", "name", "free", "keyUrl", "note")} |
                   {"linked": bool(mine.get("key")), "model": mine.get("model"), "lastError": mine.get("lastError"),
                    "keyEnd": (mine.get("key") or "")[-4:] if mine.get("key") else ""})
    return out


def _note_error(store, pid: str, message: str | None) -> None:
    with store.lock:
        if pid in store.data["ai"]:
            store.data["ai"][pid]["lastError"] = message
            store.save()


def chat(store, messages: list[dict], *, json_mode: bool = True, exclude: set[str] | None = None,
         temperature: float = 0.7) -> tuple[str, str]:
    """Asks the linked providers in order until one answers. Raises AIError when none is linked or all fail."""
    providers = [p for p in linked(store) if p["id"] not in (exclude or set())]
    if not providers:
        raise AIError("لم يُربط أي مزوّد ذكاء اصطناعي. اربط واحدًا من «الإعدادات».")
    problems = []
    for p in providers:
        body = {"model": p["model"], "messages": messages, "temperature": temperature}
        if json_mode and p["id"] not in ("cerebras",):
            body["response_format"] = {"type": "json_object"}
        for attempt in range(2):
            try:
                reply = _request(p["base"] + "/chat/completions", p["key"], body, timeout=180)
                text = (reply.get("choices") or [{}])[0].get("message", {}).get("content") or ""
                if text.strip():
                    _note_error(store, p["id"], None)
                    return text, p["id"]
                raise ValueError("empty")
            except urllib.error.HTTPError as e:
                if e.code == 400 and "response_format" in body:
                    body.pop("response_format")       # some models refuse JSON mode: ask without it
                    continue
                if e.code == 429 and attempt == 0:
                    time.sleep(4)
                    continue
                problems.append(f"{p['name']}: {_error_text(e)}")
                _note_error(store, p["id"], _error_text(e))
                break
            except Exception as e:  # noqa: BLE001
                problems.append(f"{p['name']}: {_error_text(e)}")
                break
    raise AIError("لم ينجح أي مزوّد: " + "؛ ".join(problems))


def gemini_pdf(store, pdf: bytes, prompt: str) -> str:
    """Gemini's own API reads PDF pages as images (scanned books, broken Arabic text layers)."""
    g = store.data["ai"].get("gemini") or {}
    if not g.get("key"):
        raise AIError("هذا الكتاب صور لا نص فيها، ويقرؤه Gemini وحده: اربط Gemini من «الإعدادات».")
    url = f"https://generativelanguage.googleapis.com/v1beta/models/{g['model']}:generateContent"
    body = {"contents": [{"parts": [{"inline_data": {"mime_type": "application/pdf",
                                                     "data": base64.b64encode(pdf).decode()}},
                                    {"text": prompt}]}],
            "generationConfig": {"temperature": 0.2}}
    req = urllib.request.Request(url, data=json.dumps(body).encode("utf-8"), method="POST",
                                 headers={"x-goog-api-key": g["key"], "Content-Type": "application/json", "User-Agent": UA})
    try:
        with urllib.request.urlopen(req, timeout=300) as r:
            reply = json.loads(r.read().decode("utf-8"))
    except Exception as e:  # noqa: BLE001
        raise AIError("Gemini: " + _error_text(e)) from None
    parts = ((reply.get("candidates") or [{}])[0].get("content") or {}).get("parts") or []
    return "".join(p.get("text", "") for p in parts)
