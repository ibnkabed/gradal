"""Every paper of a quiz as a ready PDF, for the PC window and for the phone (which prints them at school with
AirPrint, without the PC).

    files(app, quiz)          -> [{id, title, pages, bytes, updatedAt}] — built or refreshed as needed
    path_of(app, quiz, fid)   -> the PDF on disk (None when it is not one of the quiz's files)

The papers: the question paper and the answer model (when the quiz was written in Gradal), the answer-key
sheet, one PDF of personalised answer sheets per class of the quiz (class-list order), and one blank sheet
(the copies are chosen in the print dialog). Files live in <data>/prints/<quizId>/ with a fingerprint of
what they were built from; a file is rebuilt only when that changes (new students, edited quiz or settings).
"""

from __future__ import annotations

import hashlib
import json
import re
import threading
from datetime import datetime, timezone
from pathlib import Path

import exports
import paper
import sheets

_lock = threading.Lock()
SAFE_ID = re.compile(r"^(paper|model|key|blank|class-[0-9a-f-]{36})$")


def _now() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _pdf_pages(path: Path) -> int:
    try:
        import pymupdf
        with pymupdf.open(str(path)) as doc:
            return doc.page_count
    except Exception:  # noqa: BLE001
        return 0


def quiz_paper(app, quiz: dict) -> dict | None:
    return next((p for p in app.store.data["papers"].values() if p.get("quizId") == quiz["id"]), None)


def _wanted(app, quiz: dict) -> list[dict]:
    """The quiz's papers: id, title, how to build it, and what it is built from."""
    settings = app.store.data["settings"]
    base = {"quiz": {k: quiz.get(k) for k in ("code", "sheet", "header", "name", "language", "keys", "sections")},
            "settings": settings, "layout": app.layout.get("version")}
    out = []
    pp = quiz_paper(app, quiz)
    if pp:
        out.append({"id": "paper", "title": "ورقة الأسئلة", "html": lambda: paper.paper_html(quiz, pp, settings),
                    "from": {**base, "questions": pp["questions"]}})
        out.append({"id": "model", "title": "نموذج الإجابة", "html": lambda: paper.paper_html(quiz, pp, settings, mark=True),
                    "from": {**base, "questions": pp["questions"], "mark": True}})
    key = (quiz.get("keys") or [[]])[0]
    out.append({"id": "key", "title": "ورقة الإجابة — المفتاح",
                "svgs": lambda: [sheets.page_svg(sheets.page_shapes(app.layout, quiz=quiz, settings=settings, key=key))],
                "from": {**base, "key": True}})
    classes = {c["id"]: c for c in app.store.all("classes")}
    for cid in quiz.get("classIds") or []:
        cls = classes.get(cid)
        if not cls:
            continue
        students = exports.class_students(app.store, cid)
        if not students:
            continue

        def build(cls=cls, students=students):
            return [sheets.page_svg(sheets.page_shapes(app.layout, quiz=quiz, settings=settings, student_name=s["name"],
                                                       gradal_id=s["gradalId"], class_name=cls["name"])) for s in students]
        out.append({"id": f"class-{cid}", "title": f"أوراق الإجابة — {cls['name']} ({students_ar(len(students))})", "svgs": build,
                    "from": {**base, "class": cls["name"], "students": [(s["name"], s["gradalId"]) for s in students]}})
    out.append({"id": "blank", "title": "ورقة إجابة فارغة",
                "svgs": lambda: [sheets.page_svg(sheets.page_shapes(app.layout, quiz=quiz, settings=settings))],
                "from": {**base, "blank": True}})
    return out


def students_ar(n: int) -> str:
    return "طالب واحد" if n == 1 else "طالبان" if n == 2 else f"{n} طلاب" if 3 <= n <= 10 else f"{n} طالبًا"


def _fingerprint(obj) -> str:
    return hashlib.sha256(json.dumps(obj, ensure_ascii=False, sort_keys=True, default=str).encode("utf-8")).hexdigest()


def _build(app, quiz: dict, want: dict) -> dict:
    folder = app.data_dir / "prints" / quiz["id"]
    meta_path = folder / "meta.json"
    try:
        meta = json.loads(meta_path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        meta = {}
    fp = _fingerprint(want["from"])
    path = folder / f"{want['id']}.pdf"
    row = meta.get(want["id"]) or {}
    if row.get("fp") != fp or not path.exists():
        folder.mkdir(parents=True, exist_ok=True)
        tmp = path.with_suffix(".tmp.pdf")
        if "html" in want:
            if not sheets.html_to_pdf(want["html"](), tmp):
                raise RuntimeError("Microsoft Edge is needed to make the question paper PDF")
        else:
            sheets.svgs_to_pdf(want["svgs"](), tmp)
        tmp.replace(path)
        row = {"fp": fp, "pages": _pdf_pages(path), "updatedAt": _now()}
        meta[want["id"]] = row
        meta_path.write_text(json.dumps(meta, ensure_ascii=False, indent=1), encoding="utf-8")
    return {"id": want["id"], "title": want["title"], "pages": row.get("pages", 0), "bytes": path.stat().st_size,
            "updatedAt": row.get("updatedAt", ""), "path": path}


def files(app, quiz: dict) -> list[dict]:
    with _lock:
        rows = [_build(app, quiz, w) for w in _wanted(app, quiz)]
    return [{k: v for k, v in r.items() if k != "path"} for r in rows]


def path_of(app, quiz: dict, fid: str) -> Path | None:
    if not SAFE_ID.match(fid or ""):
        return None
    with _lock:
        for w in _wanted(app, quiz):
            if w["id"] == fid:
                return _build(app, quiz, w)["path"]
    return None
