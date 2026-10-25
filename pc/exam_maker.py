"""Writes a test from a book's pages: the teacher picks the book, the pages, the language and how many questions
of each kind; the linked AI providers write them; the teacher reviews and edits the draft before it becomes a quiz.

    job = Jobs(app); jid = job.start(request); job.get(jid).status()

Request: {name, subject, grade, language "ar"|"en", classIds, bookId, pageFrom, pageTo, mcq, tf, notes}.
Steps: the pages' text (books.py; Gemini transcribes scanned pages) -> one provider writes the questions as JSON ->
local checks (4 different options, one answer, no repeats, no "all of the above") -> a second provider, when one
is linked, reviews each question against the text and the failing ones are written again -> the answer letters are
balanced (options shuffled, never three equal letters in a row) -> the draft is saved in store.data["papers"].
"""

from __future__ import annotations

import json
import random
import re
import threading
import traceback
import uuid

import ai
import books
from store import now_iso

KINDS = ("mcq", "tf")
MAX_TEXT = 60000
ROUNDS = 3
BANNED = re.compile(r"(all of the above|none of the above|جميع ما سبق|كل ما سبق|لا شيء مما سبق|جميع الإجابات)", re.I)
SECTION = {"ar": {"mcq": "اختيار من متعدد", "tf": "صح أو خطأ"}, "en": {"mcq": "Multiple Choice", "tf": "True or False"}}
TF_WORDS = {"ar": ["صح", "خطأ"], "en": ["True", "False"]}


class ExamError(RuntimeError):
    """A message for the teacher, in Arabic."""


# ---------- the request ----------

def normalise_request(app, req: dict) -> dict:
    r = dict(req or {})
    out = {"name": str(r.get("name") or "").strip()[:80], "subject": str(r.get("subject") or "").strip()[:60],
           "grade": str(r.get("grade") or "").strip()[:60], "language": "ar" if r.get("language") == "ar" else "en",
           "notes": str(r.get("notes") or "").strip()[:500],
           "classIds": [c for c in r.get("classIds") or [] if isinstance(c, str)]}
    if not out["name"]:
        raise ExamError("اكتب اسم الاختبار")
    try:
        out["mcq"], out["tf"] = max(0, int(r.get("mcq") or 0)), max(0, int(r.get("tf") or 0))
    except (TypeError, ValueError):
        raise ExamError("عدد الأسئلة أرقام") from None
    total = out["mcq"] + out["tf"]
    if not app.min_questions <= total <= app.max_questions:
        raise ExamError(f"مجموع الأسئلة من {app.min_questions} إلى {app.max_questions}")
    book = next((b for b in app.store.data["books"] if b["id"] == r.get("bookId")), None)
    if not book:
        raise ExamError("اختر الكتاب")
    out["bookId"], out["bookName"] = book["id"], book["name"]
    out["pageFrom"], out["pageTo"] = books._check_range(book, r.get("pageFrom"), r.get("pageTo"))
    return out


# ---------- prompts ----------

def system_prompt(lang: str) -> str:
    if lang == "ar":
        return ("أنت معلم سعودي خبير يكتب أسئلة اختبار مدرسي من صفحات الكتاب المعطاة فقط، بالعربية الفصحى السليمة. "
                "القواعد: كل سؤال يُجاب من النص وحده؛ لا تكرار في المعنى؛ عبارة السؤال قصيرة وواضحة (لا تتجاوز 150 حرفًا)؛ "
                "في الاختيار من متعدد أربعة بدائل مختلفة ومعقولة وقصيرة، واحد منها فقط صحيح، ولا «جميع ما سبق» ولا «لا شيء مما سبق»؛ "
                "في الصح والخطأ عبارة واحدة صحيحة تمامًا أو خاطئة تمامًا بحسب النص، بلا نفي مزدوج. "
                "أعد JSON فقط بهذا الشكل: "
                '{"questions":[{"type":"mcq","text":"...","options":["...","...","...","..."],"answer":0},'
                '{"type":"tf","text":"...","answer":true}]} حيث answer في الاختيار رقم البديل الصحيح من 0 إلى 3.')
    return ("You are an experienced school teacher writing a classroom test only from the given textbook pages, in "
            "clear correct English. Rules: every question is answerable from the text alone; no two questions test the same "
            "point; stems are short and clear (max 150 characters); multiple choice has four different, plausible, short "
            "options with exactly one correct, never 'all/none of the above'; true/false statements are fully true or "
            "fully false according to the text, no double negatives. Return JSON only, shaped: "
            '{"questions":[{"type":"mcq","text":"...","options":["...","...","...","..."],"answer":0},'
            '{"type":"tf","text":"...","answer":true}]} where a multiple-choice answer is the index 0-3 of the correct option.')


def user_prompt(req: dict, text: str, need: dict, avoid: list[str]) -> str:
    ar = req["language"] == "ar"
    asks = []
    if need.get("mcq"):
        asks.append(f"{need['mcq']} " + ("سؤال اختيار من متعدد" if ar else "multiple-choice questions"))
    if need.get("tf"):
        asks.append(f"{need['tf']} " + ("عبارة صح أو خطأ" if ar else "true/false statements"))
    head = (f"المادة: {req['subject'] or '-'}. الصف: {req['grade'] or '-'}. اكتب " + " و".join(asks) + "، موزعة على النص كله."
            if ar else f"Subject: {req['subject'] or '-'}. Grade: {req['grade'] or '-'}. Write " + " and ".join(asks)
            + ", spread over the whole text.")
    if req.get("notes"):
        head += ("\nملاحظة المعلم: " if ar else "\nTeacher's note: ") + req["notes"]
    if avoid:
        head += ("\nلا تكرر هذه الأسئلة الموجودة:\n" if ar else "\nDo not repeat these existing questions:\n") + "\n".join(
            f"- {a}" for a in avoid[:60])
    return head + ("\n\nنص الصفحات:\n" if ar else "\n\nThe pages:\n") + text


def review_prompt(req: dict, text: str, items: list[dict]) -> list[dict]:
    ar = req["language"] == "ar"
    shown = [{"n": i + 1, **{k: q[k] for k in ("type", "text", "options", "answer") if k in q}} for i, q in enumerate(items)]
    sys = ("أنت مراجع أسئلة دقيق. افحص كل سؤال على النص: هل الإجابة المعلّمة صحيحة يقينًا من النص؟ هل يوجد بديل آخر صحيح أيضًا؟ "
           "هل اللغة سليمة والسؤال واضح؟ أعد JSON فقط: {\"bad\":[{\"n\":رقم,\"why\":\"السبب\"}]} ولا تذكر السليم."
           if ar else
           "You are a strict question reviewer. Check each question against the text: is the marked answer certainly "
           "correct from the text? Is another option also correct? Is the language correct and the stem clear? Return JSON "
           'only: {"bad":[{"n":number,"why":"reason"}]} listing only the faulty ones.')
    return [{"role": "system", "content": sys},
            {"role": "user", "content": ("الأسئلة:\n" if ar else "Questions:\n") + json.dumps(shown, ensure_ascii=False)
             + ("\n\nالنص:\n" if ar else "\n\nThe text:\n") + text}]


# ---------- parsing and checks ----------

def parse_json(text: str) -> dict:
    t = text.strip()
    t = re.sub(r"^```(?:json)?\s*|\s*```$", "", t)
    try:
        return json.loads(t)
    except ValueError:
        m = re.search(r"\{.*\}", t, re.S)
        if m:
            try:
                return json.loads(m.group(0))
            except ValueError:
                pass
    return {}


def _norm(s: str) -> str:
    return re.sub(r"\W+", " ", str(s or "").lower()).strip()


def clean_item(raw) -> dict | None:
    if not isinstance(raw, dict):
        return None
    kind = str(raw.get("type") or "").lower()
    text = re.sub(r"\s+", " ", str(raw.get("text") or "")).strip()
    if kind not in KINDS or not 5 <= len(text) <= 220:
        return None
    if kind == "tf":
        ans = raw.get("answer")
        if isinstance(ans, str):
            word = ans.strip().lower()
            ans = True if word in ("true", "صح", "صحيح", "t", "1") else False if word in ("false", "خطأ", "خاطئ", "f", "0") else None
        if not isinstance(ans, bool):
            return None
        return {"type": "tf", "text": text, "answer": ans}
    opts = [re.sub(r"\s+", " ", str(o or "")).strip() for o in raw.get("options") or []]
    if len(opts) != 4 or any(not o or len(o) > 90 for o in opts) or len({_norm(o) for o in opts}) != 4:
        return None
    if any(BANNED.search(o) for o in opts):
        return None
    ans = raw.get("answer")
    if isinstance(ans, str) and ans.strip().isdigit():
        ans = int(ans.strip())
    elif isinstance(ans, str) and ans.strip().upper() in "ABCD" and len(ans.strip()) == 1:
        ans = "ABCD".index(ans.strip().upper())
    if not isinstance(ans, int) or isinstance(ans, bool) or not 0 <= ans <= 3:
        return None
    return {"type": "mcq", "text": text, "options": opts, "answer": ans}


def balance(items: list[dict], rng: random.Random) -> None:
    """Shuffles the options of each MCQ so the correct letters are spread evenly and never three in a row."""
    mcq = [q for q in items if q["type"] == "mcq"]
    pool = [i % 4 for i in range(len(mcq))]
    for _ in range(200):
        rng.shuffle(pool)
        if all(not (pool[i] == pool[i - 1] == pool[i - 2]) for i in range(2, len(pool))):
            break
    for q, target in zip(mcq, pool):
        right = q["options"][q["answer"]]
        others = [o for i, o in enumerate(q["options"]) if i != q["answer"]]
        rng.shuffle(others)
        others.insert(target, right)
        q["options"], q["answer"] = others, target


# ---------- the job ----------

class ExamJob:
    def __init__(self, app, req: dict):
        self.app, self.req = app, req
        self.messages: list[str] = []
        self.state = "running"
        self.result: dict | None = None
        self.error: str | None = None
        self.used: list[str] = []

    def say(self, msg: str) -> None:
        self.messages.append(msg)

    def status(self) -> dict:
        return {"state": self.state, "messages": self.messages[-12:], "error": self.error, "result": self.result}

    def source_text(self) -> str:
        app, req = self.app, self.req
        book = next(b for b in app.store.data["books"] if b["id"] == req["bookId"])
        text, readable = books.pages_text(app.data_dir, book, req["pageFrom"], req["pageTo"])
        if not readable:
            self.say("صفحات الكتاب صور: يقرؤها Gemini…")
            pdf = books.pages_pdf(app.data_dir, book, req["pageFrom"], req["pageTo"])
            text = ai.gemini_pdf(app.store, pdf, "Transcribe all the text of these pages faithfully, in their original "
                                                  "language and reading order. Plain text only, no commentary.")
            if len(text.strip()) < 200:
                raise ExamError("لم يُستخرج نص كافٍ من هذه الصفحات")
        return text[:MAX_TEXT]

    def write(self, text: str, need: dict, have: list[dict], exclude: set[str]) -> list[dict]:
        msgs = [{"role": "system", "content": system_prompt(self.req["language"])},
                {"role": "user", "content": user_prompt(self.req, text, need, [q["text"] for q in have])}]
        reply, pid = ai.chat(self.app.store, msgs, exclude=exclude)
        self.used.append(pid)
        data = parse_json(reply)
        seen = {_norm(q["text"]) for q in have}
        out = []
        for raw in data.get("questions") or []:
            q = clean_item(raw)
            if q and _norm(q["text"]) not in seen and need.get(q["type"], 0) > sum(1 for x in out if x["type"] == q["type"]):
                seen.add(_norm(q["text"]))
                out.append(q)
        return out

    def run(self) -> None:
        req = self.req
        try:
            self.say("أقرأ صفحات الكتاب…")
            text = self.source_text()
            want = {"mcq": req["mcq"], "tf": req["tf"]}
            items: list[dict] = []
            for rnd in range(ROUNDS):
                need = {k: want[k] - sum(1 for q in items if q["type"] == k) for k in KINDS}
                if not any(need.values()):
                    break
                self.say("أكتب الأسئلة…" if rnd == 0 else "أكمل الأسئلة الناقصة…")
                items += self.write(text, need, items, set())
            # a second provider reviews; the faulty questions are written again by the first
            writer = self.used[0] if self.used else None
            reviewers = [p["id"] for p in ai.linked(self.app.store) if p["id"] != writer]
            if reviewers and items:
                self.say("مزوّد ثانٍ يراجع الأسئلة على النص…")
                try:
                    reply, pid = ai.chat(self.app.store, review_prompt(req, text, items), exclude={writer}, temperature=0.1)
                    bad = {int(b.get("n", 0)) - 1 for b in parse_json(reply).get("bad") or [] if isinstance(b, dict)
                           and str(b.get("n", "")).isdigit()}
                    bad = {i for i in bad if 0 <= i < len(items)}
                    if bad:
                        self.say(f"أعيد كتابة {len(bad)} سؤالًا لم تجتز المراجعة…")
                        kept = [q for i, q in enumerate(items) if i not in bad]
                        need = {k: want[k] - sum(1 for q in kept if q["type"] == k) for k in KINDS}
                        items = kept + self.write(text, need, kept + [items[i] for i in bad], set())
                except ai.AIError:
                    self.say("تعذّرت المراجعة الثانية، فبقيت الأسئلة كما كُتبت")
            items = [q for k in KINDS for q in items if q["type"] == k]       # MCQ first, then true/false
            if not items:
                raise ExamError("لم يُكتب أي سؤال صالح. جرّب صفحات أخرى أو مزوّدًا آخر.")
            balance(items, random.Random())
            short = {k: want[k] - sum(1 for q in items if q["type"] == k) for k in KINDS}
            paper = {"id": str(uuid.uuid4()), "status": "draft", "createdAt": now_iso(), "request": req,
                     "questions": items, "providers": sorted(set(self.used))}
            with self.app.store.lock:
                self.app.store.data["papers"][paper["id"]] = paper
                self.app.store.save()
            self.result = {"paperId": paper["id"], "count": len(items), "short": short}
            if any(short.values()):
                self.say(f"كُتب {len(items)} سؤالًا، أقل من المطلوب: أكمل الباقي يدويًا في المراجعة")
            self.say("جاهز للمراجعة")
            self.state = "done"
        except (ExamError, ai.AIError, books.BookError) as e:
            self.error, self.state = str(e), "error"
        except Exception:  # noqa: BLE001
            traceback.print_exc()
            self.error, self.state = "خطأ غير متوقع أثناء كتابة الأسئلة", "error"


class Jobs:
    def __init__(self, app):
        self.app = app
        self.jobs: dict[str, ExamJob] = {}
        self.lock = threading.Lock()

    def start(self, request: dict) -> str:
        req = normalise_request(self.app, request)
        with self.lock:
            if any(j.state == "running" for j in self.jobs.values()):
                raise ExamError("اختبار آخر يُكتب الآن، انتظره")
            jid = str(uuid.uuid4())
            job = ExamJob(self.app, req)
            self.jobs[jid] = job
        threading.Thread(target=job.run, daemon=True).start()
        return jid

    def get(self, jid: str) -> ExamJob | None:
        return self.jobs.get(jid)
