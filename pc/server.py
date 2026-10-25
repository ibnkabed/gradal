"""Gradal on the PC: the teacher's window (/api, this PC only) and the phone (/hello, /m).

    python pc/server.py [--port 7797] [--host 0.0.0.0] [--data DIR]

The data folder (default: Documents\\Gradal) holds everything: gradal.json, the books, the scanned sheets,
the printable PDFs and the record sheets (السجلات). Contract with the phone: shared/PROTOCOL.md.
"""

from __future__ import annotations

import argparse
import base64
import binascii
import hashlib
import hmac
import ipaddress
import json
import logging
import mimetypes
import os
import re
import secrets
import socket
import sys
import threading
import time
import traceback
from datetime import date
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, quote, unquote, urlparse

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import ai  # noqa: E402
import books  # noqa: E402
import exam_maker  # noqa: E402
import exports  # noqa: E402
import grading  # noqa: E402
import prints  # noqa: E402
import roster  # noqa: E402
import sheet_layout  # noqa: E402
import sheets  # noqa: E402
import students_import  # noqa: E402
from store import Store, bump, new_id, now_iso, valid_id  # noqa: E402

APP_ID = "gradal-public"
PORT = 7797
PROTOCOL_VERSION = 1
MAX_BODY = 40 * 1024 * 1024
MAX_BOOK = 300 * 1024 * 1024
MAX_IMAGE = 8 * 1024 * 1024
PIN_SECONDS = 120
PIN_TRIES = 5
MAX_SCANS_PER_POST = 10
POINT_CHOICES = (0.5, 1.0, 1.5, 2.0)
MIN_QUESTIONS, MAX_QUESTIONS = sheet_layout.MIN_QUESTIONS, sheet_layout.MAX_QUESTIONS
SHEET_CAPACITY = 100
PUBLIC = HERE / "public"
ASSETS = HERE / "assets"
LETTERS = "ABCD"
DEVICE_ID_RE = re.compile(r"^[a-z0-9-]{1,64}$")
HEADER_KEYS = ("subject", "title", "grade", "extra")
LOGO_MAX = 400 * 1024

log = logging.getLogger("gradal")


def default_data_dir() -> Path:
    return Path(os.path.expanduser("~")) / "Documents" / "Gradal"


# ---------- helpers ----------

def is_loopback(addr: str) -> bool:
    try:
        return ipaddress.ip_address(addr.split("%")[0]).is_loopback
    except ValueError:
        return False


def lan_addresses() -> list[str]:
    found = []
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
            s.connect(("192.168.1.1", 9))   # no packet is sent; picks the outgoing interface
            found.append(s.getsockname()[0])
    except OSError:
        pass
    try:
        for info in socket.getaddrinfo(socket.gethostname(), None, socket.AF_INET):
            found.append(info[4][0])
    except OSError:
        pass
    out = []
    for a in found:
        ip = ipaddress.ip_address(a)
        if ip.is_loopback or ip.is_link_local or a in out:
            continue
        out.append(a)
    return sorted(out, key=lambda a: (not ipaddress.ip_address(a).is_private, a))


def token_hash(token: str) -> str:
    return hashlib.sha256(token.encode("utf-8")).hexdigest()


def norm_letters(v) -> str:
    return "".join(c for c in LETTERS if c in str(v or "").upper())


def open_path(path: Path) -> None:
    os.startfile(str(path))  # noqa: S606 - the teacher's own file on their own PC


def layout_error_ar(msg: str) -> str:
    if msg.startswith("too many questions on one page"):
        return "أسئلة صفحة واحدة أكثر مما تتسع له الورقة"
    if msg.startswith("question count"):
        return f"عدد الأسئلة من {MIN_QUESTIONS} إلى {MAX_QUESTIONS}"
    return msg


class ApiError(Exception):
    def __init__(self, status: int, message: str):
        super().__init__(message)
        self.status = status
        self.message = message


# ---------- application ----------

class Gradal:
    min_questions, max_questions = MIN_QUESTIONS, MAX_QUESTIONS

    def __init__(self, data_dir: Path):
        self.data_dir = Path(data_dir)
        self.store = Store(self.data_dir)
        self.records_dir = self.data_dir / "السجلات"
        self.layout = sheets.load_layout()
        self.pin: dict | None = None
        self.pin_lock = threading.Lock()
        self.exams = exam_maker.Jobs(self)
        self.upgrade_sheets()

    # ----- quizzes -----

    def new_code(self) -> int:
        used = {q.get("code") for q in self.store.all("quizzes", True)}
        free = [c for c in range(1000, 10000) if c not in used]
        if not free:
            raise ApiError(409, "لا رمز متاح")
        return secrets.choice(free)

    def clean_quiz(self, q: dict, existing: dict | None = None) -> dict:
        try:
            n = int(q.get("questionCount") or 0)
        except (TypeError, ValueError):
            n = 0
        if not MIN_QUESTIONS <= n <= MAX_QUESTIONS:
            raise ApiError(400, f"عدد الأسئلة من {MIN_QUESTIONS} إلى {MAX_QUESTIONS}")
        raw = (q.get("keys") or [[]])[0]
        key = [norm_letters(raw[i]) if isinstance(raw, list) and i < len(raw) else "" for i in range(n)]
        pts = q.get("points") or []
        points = []
        for i in range(n):
            try:
                p = float(pts[i]) if i < len(pts) and pts[i] not in (None, "") else 1.0
            except (TypeError, ValueError):
                p = 1.0
            p = min(POINT_CHOICES, key=lambda c: abs(c - p))
            points.append(int(p) if p.is_integer() else p)
        sections = []
        for sec in q.get("sections") or []:
            if not isinstance(sec, dict):
                continue
            try:
                a, b = int(sec.get("from")), int(sec.get("to"))
            except (TypeError, ValueError):
                continue
            name = str(sec.get("name") or "").strip()[:40]
            if name and 1 <= a <= b <= n:
                sections.append({"name": name, "from": a, "to": b})
        header = {k: str((q.get("header") or {}).get(k) or "").strip()[:80] for k in HEADER_KEYS}
        name = str(q.get("name") or "").strip()
        if not name:
            raise ApiError(400, "اسم الاختبار مطلوب")
        try:
            code = int(q.get("code") or (existing or {}).get("code") or 0)
        except (TypeError, ValueError):
            code = 0
        return {"id": q["id"], "code": code, "name": name[:120], "date": str(q.get("date") or date.today().isoformat())[:10],
                "language": "ar" if q.get("language") == "ar" else "en",
                "classIds": [c for c in (q.get("classIds") or []) if isinstance(c, str)],
                "questionCount": n, "keys": [key], "points": points, "sections": sections, "header": header,
                "updatedAt": q.get("updatedAt") or (existing or {}).get("updatedAt"), "deleted": bool(q.get("deleted"))}

    def save_quiz(self, body: dict) -> dict:
        st = self.store
        with st.lock:
            existing = st.get("quizzes", body.get("id", "")) if body.get("id") else None
            body = dict(body)
            body["id"] = existing["id"] if existing else new_id()
            quiz = self.clean_quiz(body, existing)
            if not quiz["code"]:
                quiz["code"] = self.new_code()
            quiz["deleted"] = False
            self.with_sheet(quiz)
            st.put("quizzes", quiz)
            regraded = self.regrade_quiz(quiz)
            st.save()
        if regraded or any(s.get("quizId") == quiz["id"] for s in st.all("scans")):
            self.write_record(quiz)
        return {"quiz": quiz, "regraded": regraded}

    def with_sheet(self, quiz: dict) -> dict:
        try:
            quiz["sheet"] = sheet_layout.compute(quiz, self.layout)
        except sheet_layout.LayoutError as e:
            raise ApiError(400, layout_error_ar(str(e))) from None
        return quiz

    def upgrade_sheets(self) -> None:
        changed = False
        with self.store.lock:
            for q in self.store.all("quizzes"):
                if (q.get("sheet") or {}).get("version") == sheet_layout.SHEET_VERSION:
                    continue
                try:
                    q["sheet"] = sheet_layout.compute(q, self.layout)
                except sheet_layout.LayoutError as e:
                    log.warning("quiz %s: no sheet: %s", q.get("code"), e)
                    continue
                bump(q)
                changed = True
            if changed:
                self.store.save()

    def resolve_student(self, scan: dict) -> None:
        sid = scan.get("studentId")
        if sid and self.store.get("students", sid):
            return
        quiz = self.store.get("quizzes", scan.get("quizId") or "", include_deleted=True) or {}
        st = self.store.student_by_gradal_id(scan.get("gradalId"), quiz.get("classIds")) if scan.get("gradalId") else None
        scan["studentId"] = st["id"] if st else None

    def regrade_quiz(self, quiz: dict) -> int:
        changed = 0
        for s in self.store.all("scans"):
            if s.get("quizId") == quiz["id"] and grading.regrade(quiz, s):
                bump(s)
                changed += 1
        return changed

    def relink_unknown(self) -> None:
        for s in self.store.all("scans"):
            before = s.get("studentId")
            if before and self.store.get("students", before):
                continue
            self.resolve_student(s)
            if s.get("studentId") != before:
                bump(s)

    def write_record(self, quiz: dict) -> dict:
        """Rewrites السجلات/<name> (<code>).xlsx. Excel holding it open is reported, not fatal."""
        try:
            with self.store.lock:
                path = exports.save_record(self.store, quiz, self.records_dir)
            return {"path": str(path), "error": None}
        except PermissionError:
            return {"path": str(exports.record_path(self.records_dir, quiz)), "error": "الملف مفتوح في Excel: أغلقه ليُحدَّث"}
        except OSError as e:
            log.warning("record %s: %s", quiz.get("code"), e)
            return {"path": None, "error": f"تعذّر حفظ السجل: {e}"}

    # ----- papers (questions written in Gradal) -----

    def paper(self, pid: str) -> dict:
        p = self.store.data["papers"].get(pid)
        if not p:
            raise ApiError(404, "المسودة غير موجودة")
        return p

    @staticmethod
    def clean_questions(raw) -> list[dict]:
        out = []
        for q in raw if isinstance(raw, list) else []:
            item = exam_maker.clean_item(q)
            if item is None:
                raise ApiError(400, f"السؤال {len(out) + 1} ناقص: نص السؤال، وأربعة بدائل مختلفة، والإجابة الصحيحة")
            out.append(item)
        return out

    def save_paper(self, pid: str, body: dict) -> dict:
        with self.store.lock:
            p = self.paper(pid)
            if "questions" in body:
                p["questions"] = self.clean_questions(body["questions"])
            req = p["request"]
            for k in ("name", "subject", "grade"):
                if k in body:
                    req[k] = str(body[k] or "").strip()[:80]
            if "classIds" in body:
                req["classIds"] = [c for c in body["classIds"] or [] if isinstance(c, str)]
            p["updatedAt"] = now_iso()
            self.store.save()
        if p.get("quizId"):
            self.apply_paper(p)
        return p

    def apply_paper(self, p: dict) -> dict:
        """The paper's quiz: created on approval, kept in step with later edits of the questions."""
        req, qs = p["request"], p["questions"]
        if not MIN_QUESTIONS <= len(qs) <= MAX_QUESTIONS:
            raise ApiError(400, f"عدد الأسئلة من {MIN_QUESTIONS} إلى {MAX_QUESTIONS}")
        lang = req["language"]
        sections, start = [], 1
        for kind in exam_maker.KINDS:
            count = sum(1 for q in qs if q["type"] == kind)
            if count:
                sections.append({"name": exam_maker.SECTION[lang][kind], "from": start, "to": start + count - 1})
                start += count
        ordered = [q for k in exam_maker.KINDS for q in qs if q["type"] == k]
        key = [LETTERS[q["answer"]] if q["type"] == "mcq" else ("A" if q["answer"] else "B") for q in ordered]
        teacher = self.store.data["settings"].get("teacher") or ""
        body = {"id": p.get("quizId"), "name": req["name"], "language": lang, "classIds": req.get("classIds") or [],
                "questionCount": len(ordered), "keys": [key], "sections": sections,
                "header": {"subject": req.get("subject"), "title": req["name"], "grade": req.get("grade"),
                           "extra": (("المعلم: " if lang == "ar" else "Teacher: ") + teacher) if teacher else ""}}
        quiz = self.save_quiz(body)["quiz"]
        with self.store.lock:
            p["questions"], p["quizId"], p["status"] = ordered, quiz["id"], "approved"
            self.store.save()
        return quiz

    # ----- pairing -----

    def pin_state(self) -> dict | None:
        with self.pin_lock:
            if self.pin and self.pin["expires"] > time.time() and self.pin["tries"] < PIN_TRIES:
                return {"code": self.pin["code"], "deviceName": self.pin["deviceName"],
                        "secondsLeft": int(self.pin["expires"] - time.time())}
            self.pin = None
            return None

    def start_pair(self, device_name: str) -> None:
        with self.pin_lock:
            self.pin = {"code": f"{secrets.randbelow(10000):04d}", "deviceName": device_name[:60] or "iPhone",
                        "expires": time.time() + PIN_SECONDS, "tries": 0}

    def pair(self, pin: str, device_id: str, device_name: str) -> str:
        with self.pin_lock:
            p = self.pin
            if not p or p["expires"] <= time.time() or p["tries"] >= PIN_TRIES:
                self.pin = None
                raise ApiError(401, "no active PIN")
            if not hmac.compare_digest(str(pin).strip(), p["code"]):
                p["tries"] += 1
                if p["tries"] >= PIN_TRIES:
                    self.pin = None
                raise ApiError(401, "wrong PIN")
            self.pin = None
        token = secrets.token_urlsafe(32)
        with self.store.lock:
            devices = self.store.data["devices"]
            devices[:] = [d for d in devices if d["id"] != device_id]
            devices.append({"id": device_id, "name": (device_name or p["deviceName"])[:60], "tokenHash": token_hash(token),
                            "pairedAt": now_iso(), "lastSeen": now_iso(), "revoked": False})
            self.store.log_sync(device_name or device_id, "pair", "")
            self.store.save()
        return token

    def device_for(self, auth_header: str | None) -> dict:
        if not auth_header or not auth_header.startswith("Bearer "):
            raise ApiError(401, "missing token")
        h = token_hash(auth_header[7:].strip())
        for d in self.store.data["devices"]:
            if not d.get("revoked") and hmac.compare_digest(d["tokenHash"], h):
                d["lastSeen"] = now_iso()
                return d
        raise ApiError(401, "unknown token")

    # ----- phone sync -----

    def accept_scans(self, device: dict, scans: list) -> list[str]:
        if len(scans) > MAX_SCANS_PER_POST:
            raise ApiError(413, f"at most {MAX_SCANS_PER_POST} scans per request")
        accepted, touched = [], set()
        with self.store.lock:
            for raw in scans:
                if not isinstance(raw, dict):
                    continue
                sid, qid = str(raw.get("id", "")).lower(), str(raw.get("quizId", "")).lower()
                if not (valid_id(sid) and valid_id(qid)):
                    continue
                image_b64 = raw.get("imageJpegBase64")
                rec = {k: v for k, v in raw.items() if k != "imageJpegBase64"}
                rec.update({"id": sid, "quizId": qid,
                            "answers": [norm_letters(a) for a in (raw.get("answers") or [])][:SHEET_CAPACITY],
                            "gradalId": re.sub(r"\D", "", str(raw.get("gradalId") or ""))[:3], "version": 0,
                            "deviceId": str(raw.get("deviceId") or device["id"])[:64],
                            "edited": bool(raw.get("edited")), "deleted": bool(raw.get("deleted")),
                            "scannedAt": raw.get("scannedAt") or now_iso(), "updatedAt": raw.get("updatedAt") or now_iso()})
                if rec.get("studentId") is not None:
                    rec["studentId"] = str(rec["studentId"]).lower()
                image = None
                if image_b64:
                    try:
                        image = base64.b64decode(image_b64, validate=False)
                    except (binascii.Error, ValueError):
                        image = None
                    if image and (len(image) > MAX_IMAGE or image[:2] != b"\xff\xd8"):
                        image = None
                path = self.store.image_path(qid, sid)
                rec["hasImage"] = bool(image) or path.exists()
                self.resolve_student(rec)
                quiz = self.store.get("quizzes", qid)
                if quiz:
                    grading.regrade(quiz, rec)
                stored = self.store.merge("scans", rec)
                if image and (stored or not path.exists()):
                    self.store.scans_dir(qid)
                    path.write_bytes(image)
                if stored:
                    touched.add(qid)
                accepted.append(sid)
            self.store.log_sync(device["name"], "scans", f"{len(accepted)}")
            self.store.save()
        for qid in touched:
            quiz = self.store.get("quizzes", qid)
            if quiz:
                self.write_record(quiz)
        return accepted

    def snapshot(self) -> dict:
        with self.store.lock:
            return {"serverTime": now_iso(),
                    "classes": [c for c in self.store.all("classes", True) if not c.get("archived")],
                    "students": [s for s in self.store.all("students", True) if not s.get("archived")],
                    "quizzes": self.store.all("quizzes", True)}

    def scans_for_phone(self, quiz_id: str) -> list[dict]:
        with self.store.lock:
            return [dict(s) for s in self.store.all("scans", True) if s.get("quizId") == quiz_id]

    # ----- PC window -----

    def student_sort_key(self):
        prefix = {c["id"]: c.get("prefix") or 99 for c in self.store.all("classes")}

        def key(s):
            first = min((prefix.get(c, 99) for c in s.get("classIds") or []), default=99)
            return (not s.get("active", True), first, s.get("order") or 9999, s.get("name", ""))
        return key

    def results(self, quiz: dict) -> dict:
        st = self.store
        scans = [s for s in st.all("scans") if s.get("quizId") == quiz["id"]]
        counted = grading.counted_scans(scans)
        counted_ids = {s["id"] for s in counted}
        skey = self.student_sort_key()
        rows = []
        for s in scans:
            stu = st.get("students", s["studentId"]) if s.get("studentId") else None
            rows.append({"id": s["id"], "studentId": s.get("studentId"), "studentName": stu["name"] if stu else None,
                         "gradalId": (stu or {}).get("gradalId") or s.get("gradalId", ""), "readId": s.get("gradalId", ""),
                         "earned": s.get("earned"), "possible": s.get("possible"), "percent": grading.percent(s),
                         "scannedAt": s.get("scannedAt"), "edited": bool(s.get("edited")),
                         "hasImage": bool(s.get("hasImage")), "counted": s["id"] in counted_ids,
                         "_sort": (0,) if not stu else (1,) + skey(stu) + (s.get("scannedAt", ""),)})
        rows.sort(key=lambda r: r["_sort"])
        for r in rows:
            r.pop("_sort")
        return {"quiz": quiz, "rows": rows, "stats": grading.stats(counted),
                "items": grading.item_analysis(quiz, counted)}

    def state(self) -> dict:
        st = self.store
        with st.lock:
            counts: dict[str, int] = {}
            for s in st.all("scans"):
                counts[s["quizId"]] = counts.get(s["quizId"], 0) + 1
            papers = st.data["papers"].values()
            drafts = [{"id": p["id"], "name": p["request"]["name"], "createdAt": p["createdAt"], "count": len(p["questions"])}
                      for p in papers if p.get("status") == "draft"]
            with_paper = {p["quizId"]: p["id"] for p in papers if p.get("quizId")}
            settings = {k: v for k, v in st.data["settings"].items()}
            devices = [{k: d[k] for k in ("id", "name", "pairedAt", "lastSeen")} for d in st.data["devices"] if not d.get("revoked")]
            return {"classes": sorted(st.current("classes"), key=lambda c: (c.get("prefix") or 99, c["name"])),
                    "students": sorted(st.current("students"), key=self.student_sort_key()),
                    "quizzes": [{**q, "paperId": with_paper.get(q["id"]), "scans": counts.get(q["id"], 0)}
                                for q in sorted(st.all("quizzes"), key=lambda q: q.get("date", ""), reverse=True)],
                    "drafts": sorted(drafts, key=lambda d: d["createdAt"], reverse=True),
                    "books": st.data["books"], "settings": settings, "ai": ai.public_state(st),
                    "pin": self.pin_state(), "lan": lan_addresses(), "pcName": socket.gethostname(), "devices": devices,
                    "dataDir": str(self.data_dir), "yearLabel": roster.year_label(),
                    "minQuestions": MIN_QUESTIONS, "maxQuestions": MAX_QUESTIONS}


# ---------- HTTP ----------

class Handler(BaseHTTPRequestHandler):
    server_version = "Gradal/1"
    protocol_version = "HTTP/1.1"
    app: Gradal

    def log_message(self, fmt, *args):
        log.info("%s %s", self.client_address[0], fmt % args)

    def send_bytes(self, status: int, body: bytes, ctype: str, extra: dict | None = None):
        self.send_response(status)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        for k, v in (extra or {}).items():
            self.send_header(k, v)
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def send_json(self, obj, status: int = 200):
        self.send_bytes(status, json.dumps(obj, ensure_ascii=False).encode("utf-8"), "application/json; charset=utf-8")

    def send_download(self, body: bytes, ctype: str, filename: str, inline: bool = False):
        ascii_name = re.sub(r"[^A-Za-z0-9._-]+", "_", filename) or "gradal"
        kind = "inline" if inline else "attachment"
        self.send_bytes(200, body, ctype, {"Content-Disposition":
                                           f"{kind}; filename=\"{ascii_name}\"; filename*=UTF-8''{quote(filename)}"})

    def read_body(self) -> None:
        self._body = b""
        try:
            length = int(self.headers.get("Content-Length") or 0)
        except ValueError:
            length = 0
        limit = MAX_BOOK if is_loopback(self.client_address[0]) else MAX_BODY
        if length > limit:
            self.close_connection = True
            raise ApiError(413, "الملف أكبر من المسموح")
        if length > 0:
            self._body = self.rfile.read(length)

    def body_json(self) -> dict:
        raw = getattr(self, "_body", b"")
        if not raw:
            return {}
        try:
            data = json.loads(raw.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError):
            raise ApiError(400, "bad JSON") from None
        if not isinstance(data, dict):
            raise ApiError(400, "JSON object expected")
        return data

    def local_only(self) -> None:
        if not is_loopback(self.client_address[0]):
            raise ApiError(403, "forbidden")
        host = (self.headers.get("Host") or "").lower()
        port = self.server.server_address[1]
        if host not in (f"127.0.0.1:{port}", f"localhost:{port}", "127.0.0.1", "localhost"):
            raise ApiError(403, "forbidden host")   # DNS-rebinding guard
        if self.command not in ("GET", "HEAD") and self.headers.get("X-Gradal") != "1":
            raise ApiError(403, "missing X-Gradal header")   # blocks cross-site form posts

    def do_GET(self):
        self.dispatch()

    def do_HEAD(self):
        self.dispatch()

    def do_POST(self):
        self.dispatch()

    def do_DELETE(self):
        self.dispatch()

    def dispatch(self):
        url = urlparse(self.path)
        path = url.path
        query = {k: v[-1] for k, v in parse_qs(url.query).items()}
        try:
            self.read_body()
            if path == "/hello":
                return self.send_json({"app": APP_ID, "protocol": PROTOCOL_VERSION, "pcName": socket.gethostname()})
            if path.startswith("/m/"):
                return self.phone(path, query)
            self.local_only()
            if path.startswith("/api/"):
                return self.api(path, query)
            return self.static(path)
        except ApiError as e:
            if self.command not in ("GET", "HEAD"):
                self.close_connection = True
            self.send_json({"error": e.message}, e.status)
        except Exception:  # noqa: BLE001
            log.error("error on %s %s\n%s", self.command, self.path, traceback.format_exc())
            self.close_connection = True
            self.send_json({"error": "خطأ داخلي في البرنامج"}, 500)

    def static(self, path: str):
        if self.command not in ("GET", "HEAD"):
            raise ApiError(405, "method not allowed")
        files = {"/": PUBLIC / "index.html", "/index.html": PUBLIC / "index.html", "/app.js": PUBLIC / "app.js",
                 "/styles.css": PUBLIC / "styles.css", "/app-icon.png": ASSETS / "app-icon.png",
                 "/favicon.ico": ASSETS / "gradal.ico"}
        f = files.get(path)
        if not f or not f.exists():
            raise ApiError(404, "not found")
        ctype = mimetypes.guess_type(f.name)[0] or "application/octet-stream"
        if ctype.startswith("text/") or ctype.endswith("javascript"):
            ctype += "; charset=utf-8"
        self.send_bytes(200, f.read_bytes(), ctype)

    # ----- phone -----

    def phone(self, path: str, query: dict):
        app = self.app
        m = self.command
        if path == "/m/pair/start" and m == "POST":
            app.start_pair(str(self.body_json().get("deviceName") or "iPhone"))
            return self.send_json({"ok": True})
        if path == "/m/pair" and m == "POST":
            body = self.body_json()
            device_id = str(body.get("deviceId") or "").lower()
            if not DEVICE_ID_RE.match(device_id):
                raise ApiError(400, "deviceId required")
            token = app.pair(str(body.get("pin") or ""), device_id, str(body.get("deviceName") or "iPhone"))
            return self.send_json({"token": token})
        with app.store.lock:
            device = app.device_for(self.headers.get("Authorization"))
        if path == "/m/snapshot" and m == "GET":
            snap = app.snapshot()
            with app.store.lock:
                app.store.log_sync(device["name"], "snapshot", "")
                app.store.save()
            return self.send_json(snap)
        if path == "/m/quizzes" and m == "POST":
            return self.send_json({"accepted": 0})        # quizzes are made on the PC only
        if path == "/m/scans" and m == "POST":
            scans = self.body_json().get("scans") or []
            return self.send_json({"accepted": app.accept_scans(device, scans if isinstance(scans, list) else [])})
        if path == "/m/scans" and m == "GET":
            return self.send_json({"scans": app.scans_for_phone(str(query.get("quizId", "")).lower())})
        if path in ("/m/prints", "/m/print") and m in ("GET", "HEAD"):
            quiz = app.store.get("quizzes", str(query.get("quizId", "")).lower())
            if not quiz:
                raise ApiError(404, "quiz not found")
            if path == "/m/prints":
                return self.send_json({"files": prints.files(app, quiz)})
            f = prints.path_of(app, quiz, str(query.get("id", "")))
            if f is None or not f.exists():
                raise ApiError(404, "file not found")
            return self.send_bytes(200, f.read_bytes(), "application/pdf")
        raise ApiError(404, "not found")

    # ----- PC window -----

    def api(self, path: str, query: dict):
        app, st, m = self.app, self.app.store, self.command
        parts = [unquote(p) for p in path.split("/") if p][1:]
        head = parts[0] if parts else ""
        rid = parts[1] if len(parts) > 1 else None
        sub = parts[2] if len(parts) > 2 else None
        sub2 = parts[3] if len(parts) > 3 else None
        try:
            return self._api(app, st, m, head, rid, sub, sub2, query)
        except (exam_maker.ExamError, ai.AIError, books.BookError, students_import.ImportError_,
                roster.RosterError) as e:
            raise ApiError(400, str(e)) from None

    def _api(self, app, st, m, head, rid, sub, sub2, query):
        if head == "state" and m == "GET":
            return self.send_json(app.state())

        # settings and AI providers
        if head == "settings" and m == "POST":
            body = self.body_json()
            with st.lock:
                s = st.data["settings"]
                if isinstance(body.get("schoolLines"), list):
                    s["schoolLines"] = [str(x).strip()[:70] for x in body["schoolLines"]][:4]
                if "teacher" in body:
                    s["teacher"] = str(body.get("teacher") or "").strip()[:60]
                if "logo" in body:
                    logo = str(body.get("logo") or "")
                    if logo and (not re.match(r"^data:image/(png|jpeg);base64,", logo) or len(logo) > LOGO_MAX):
                        raise ApiError(400, "الشعار صورة PNG أو JPG أصغر من 300 كيلوبايت")
                    s["logo"] = logo
                st.save()
            return self.send_json(st.data["settings"])
        if head == "ai" and rid and sub == "link" and m == "POST":
            return self.send_json(ai.link(st, rid, str(self.body_json().get("key") or "")))
        if head == "ai" and rid and sub == "unlink" and m == "POST":
            ai.unlink(st, rid)
            return self.send_json({"ok": True})

        # phone pairing
        if head == "pair" and rid == "cancel" and m == "POST":
            with app.pin_lock:
                app.pin = None
            return self.send_json({"ok": True})
        if head == "devices" and rid and m == "DELETE":
            with st.lock:
                for d in st.data["devices"]:
                    if d["id"] == rid:
                        d["revoked"] = True
                st.save()
            return self.send_json({"ok": True})

        # students
        if head == "students" and rid == "import" and m == "POST":
            name = unquote(self.headers.get("X-Filename") or "")
            cls = unquote(self.headers.get("X-Class") or "")
            payload = students_import.read_file(getattr(self, "_body", b""), name, cls)
            summary = roster.merge(st, payload)
            with st.lock:
                app.relink_unknown()
                st.save()
            return self.send_json({"ok": True, **summary})
        if head == "students" and rid == "paste" and m == "POST":
            body = self.body_json()
            summary = roster.merge(st, students_import.read_pasted(body.get("text"), str(body.get("className") or "")))
            with st.lock:
                app.relink_unknown()
                st.save()
            return self.send_json({"ok": True, **summary})
        if head == "classes" and rid and sub == "archive" and m == "POST":
            return self.send_json({"ok": True, **roster.archive_class(st, rid, "")})
        if head == "new-year" and m == "POST":
            return self.send_json({"ok": True, **roster.archive_all(st, str(self.body_json().get("label") or ""))})

        # books
        if head == "books" and not rid and m == "POST":
            name = unquote(self.headers.get("X-Filename") or "")
            name = re.sub(r"\.pdf$", "", name, flags=re.I)
            return self.send_json({"book": books.add(st, app.data_dir, name, getattr(self, "_body", b""))})
        if head == "books" and rid and m == "DELETE":
            books.remove(st, app.data_dir, rid)
            return self.send_json({"ok": True})

        # writing a test
        if head == "exams" and not rid and m == "POST":
            return self.send_json({"id": app.exams.start(self.body_json())})
        if head == "exams" and rid and m == "GET":
            job = app.exams.get(rid)
            if not job:
                raise ApiError(404, "لا مهمة بهذا الرقم")
            return self.send_json(job.status())
        if head == "papers" and rid:
            if not sub and m == "GET":
                return self.send_json(app.paper(rid))
            if not sub and m == "POST":
                return self.send_json(app.save_paper(rid, self.body_json()))
            if not sub and m == "DELETE":
                with st.lock:
                    p = app.paper(rid)
                    if p.get("quizId"):
                        raise ApiError(400, "هذه أسئلة اختبار معتمد: احذف الاختبار نفسه")
                    st.data["papers"].pop(rid, None)
                    st.save()
                return self.send_json({"ok": True})
            if sub == "approve" and m == "POST":
                body = self.body_json()
                if body:
                    app.save_paper(rid, body)
                return self.send_json({"quiz": app.apply_paper(app.paper(rid))})

        # quizzes
        if head == "quizzes" and not rid and m == "POST":
            return self.send_json(app.save_quiz(self.body_json()))
        if head == "quizzes" and rid:
            quiz = st.get("quizzes", rid)
            if not quiz:
                raise ApiError(404, "الاختبار غير موجود")
            if not sub and m == "DELETE":
                with st.lock:
                    st.delete("quizzes", rid)
                    for p in list(st.data["papers"].values()):
                        if p.get("quizId") == rid:
                            st.data["papers"].pop(p["id"], None)
                    st.save()
                return self.send_json({"ok": True})
            if sub == "results" and m == "GET":
                with st.lock:
                    return self.send_json(app.results(quiz))
            if sub == "key" and m == "POST":
                body = self.body_json()
                with st.lock:
                    rec = dict(quiz)
                    for k in ("keys", "points", "classIds", "name"):
                        if k in body:
                            rec[k] = body[k]
                    clean = app.clean_quiz(rec, quiz)
                    rec.update({k: clean[k] for k in ("keys", "points", "classIds", "name")})
                    st.put("quizzes", rec)
                    regraded = app.regrade_quiz(rec)
                    st.save()
                if any(s.get("quizId") == rec["id"] for s in st.all("scans")):
                    app.write_record(rec)
                return self.send_json({"quiz": rec, "regraded": regraded})
            if sub == "files" and m == "GET":
                return self.send_json({"files": prints.files(app, quiz)})
            if sub == "file" and sub2 and m == "GET":
                f = prints.path_of(app, quiz, sub2)
                if f is None or not f.exists():
                    raise ApiError(404, "الملف غير موجود")
                return self.send_download(f.read_bytes(), "application/pdf", f"{quiz['name']} - {sub2}.pdf", inline=True)
            if sub == "record" and m == "GET":
                with st.lock:
                    data = exports.record_bytes(st, quiz)
                return self.send_download(data, "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
                                          exports.record_path(app.records_dir, quiz).name)

        # scans
        if head == "scans" and rid:
            scan = st.get("scans", rid)
            if not scan:
                raise ApiError(404, "الورقة غير موجودة")
            quiz = st.get("quizzes", scan["quizId"], include_deleted=True)
            if sub == "image" and m == "GET":
                p = st.image_path(scan["quizId"], scan["id"])
                if not p.exists():
                    raise ApiError(404, "لا صورة")
                return self.send_bytes(200, p.read_bytes(), "image/jpeg")
            if not sub and m == "GET":
                stu = st.get("students", scan["studentId"]) if scan.get("studentId") else None
                return self.send_json({"scan": scan, "quiz": quiz, "student": stu})
            if not sub and m == "POST":
                body = self.body_json()
                with st.lock:
                    rec = dict(scan)
                    if "answers" in body:
                        n = (quiz or {}).get("questionCount") or len(body["answers"])
                        rec["answers"] = [norm_letters(a) for a in (body.get("answers") or [])][:n]
                        rec["answers"] += [""] * (n - len(rec["answers"]))
                    if "studentId" in body:
                        sid = body["studentId"]
                        stu = st.get("students", sid) if sid else None
                        if sid and not stu:
                            raise ApiError(400, "الطالب غير موجود")
                        rec["studentId"] = sid or None
                        if stu:
                            rec["gradalId"] = stu.get("gradalId", rec.get("gradalId", ""))
                    rec["edited"] = True
                    if quiz:
                        grading.regrade(quiz, rec)
                    st.put("scans", rec)
                    st.save()
                if quiz and not quiz.get("deleted"):
                    app.write_record(quiz)
                return self.send_json({"scan": rec})
            if not sub and m == "DELETE":
                with st.lock:
                    st.delete("scans", rid)
                    st.save()
                if quiz and not quiz.get("deleted"):
                    app.write_record(quiz)
                return self.send_json({"ok": True})

        if head == "open-data" and m == "POST":
            open_path(app.data_dir)
            return self.send_json({"ok": True})

        raise ApiError(404, "not found")


def make_server(data_dir: Path, host: str = "0.0.0.0", port: int = PORT) -> ThreadingHTTPServer:
    app = Gradal(Path(data_dir))
    handler = type("GradalHandler", (Handler,), {"app": app})
    server = ThreadingHTTPServer((host, port), handler)
    server.daemon_threads = True
    server.app = app
    return server


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=PORT)
    ap.add_argument("--host", default="0.0.0.0")
    ap.add_argument("--data", default=str(default_data_dir()))
    args = ap.parse_args()
    data = Path(args.data)
    data.mkdir(parents=True, exist_ok=True)
    logging.basicConfig(filename=str(data / "gradal.log"), encoding="utf-8", level=logging.INFO,
                        format="%(asctime)s %(levelname)s %(message)s")
    server = make_server(data, args.host, args.port)
    log.info("Gradal listening on %s:%s (pid %s)", args.host, args.port, os.getpid())
    try:
        server.serve_forever()
    finally:
        log.info("stopped")


if __name__ == "__main__":
    main()
