"""Gradal PC storage: one JSON file (gradal.json in the data folder), one lock, atomic writes.

Records follow shared/PROTOCOL.md. Every change bumps `updatedAt`; deletes are tombstones.
"""

from __future__ import annotations

import json
import os
import re
import threading
import uuid
from datetime import datetime, timedelta, timezone
from pathlib import Path

KINDS = ("classes", "students", "quizzes", "scans")
ID_RE = re.compile(r"^[0-9a-f][0-9a-f-]{7,63}$")
SYNC_LOG_LIMIT = 300
DEFAULT_SETTINGS = {
    # the fixed lines of the printed school header; per-quiz lines live in quiz["header"]
    "schoolLines": ["المملكة العربية السعودية", "وزارة التعليم", "", ""],
    "teacher": "",
    "logo": "",
}


def now_dt() -> datetime:
    return datetime.now(timezone.utc).replace(microsecond=0)


def iso(dt: datetime) -> str:
    return dt.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def now_iso() -> str:
    return iso(now_dt())


def parse_time(text) -> datetime:
    """ISO-8601 in any of the usual shapes ('Z' or offset, optional fraction). Bad -> epoch."""
    if not isinstance(text, str) or not text:
        return datetime(1970, 1, 1, tzinfo=timezone.utc)
    t = text.strip()
    if t.endswith("Z") or t.endswith("z"):
        t = t[:-1] + "+00:00"
    try:
        dt = datetime.fromisoformat(t)
    except ValueError:
        return datetime(1970, 1, 1, tzinfo=timezone.utc)
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return dt


def bump(record: dict) -> None:
    """Set updatedAt to now, strictly after the previous value (protocol timestamps have 1 s steps)."""
    prev = parse_time(record.get("updatedAt"))
    t = now_dt()
    if t <= prev:
        t = prev.replace(microsecond=0) + timedelta(seconds=1)
    record["updatedAt"] = iso(t)


def new_id() -> str:
    return str(uuid.uuid4())


def valid_id(value) -> bool:
    return isinstance(value, str) and bool(ID_RE.match(value))


def same_gradal_id(a, b) -> bool:
    a, b = str(a or ""), str(b or "")
    if not a or not b:
        return False
    if a == b:
        return True
    return a.isdigit() and b.isdigit() and int(a) == int(b)


class Store:
    def __init__(self, folder: Path):
        self.folder = Path(folder)
        self.folder.mkdir(parents=True, exist_ok=True)
        self.path = self.folder / "gradal.json"
        self.lock = threading.RLock()
        self.data = self._load()

    # ---------- persistence ----------

    def _empty(self) -> dict:
        return {"format": 2, "classes": [], "students": [], "quizzes": [], "scans": [], "devices": [], "syncLog": [],
                "settings": json.loads(json.dumps(DEFAULT_SETTINGS)), "roster": {}, "papers": {}, "books": [], "ai": {}}

    def _load(self) -> dict:
        data = self._empty()
        if self.path.exists():
            loaded = json.loads(self.path.read_text(encoding="utf-8"))
            data.update({k: v for k, v in loaded.items() if k in data})
            data["format"] = 2
            for k, v in DEFAULT_SETTINGS.items():
                data["settings"].setdefault(k, v)
        return data

    def save(self) -> None:
        with self.lock:
            tmp = self.path.with_name(f"gradal.{os.getpid()}.{threading.get_ident()}.tmp")
            tmp.write_text(json.dumps(self.data, ensure_ascii=False, indent=1), encoding="utf-8", newline="\n")
            for attempt in range(20):
                try:
                    os.replace(tmp, self.path)
                    return
                except PermissionError:   # a virus scanner or backup may hold the file for a moment
                    threading.Event().wait(0.05 * (attempt + 1))
            os.replace(tmp, self.path)

    def scans_dir(self, quiz_id: str) -> Path:
        assert valid_id(quiz_id)
        d = self.folder / "scans" / quiz_id
        d.mkdir(parents=True, exist_ok=True)
        return d

    def image_path(self, quiz_id: str, scan_id: str) -> Path:
        assert valid_id(quiz_id) and valid_id(scan_id)
        return self.folder / "scans" / quiz_id / f"{scan_id}.jpg"

    # ---------- queries ----------

    def all(self, kind: str, include_deleted: bool = False) -> list[dict]:
        rows = self.data[kind]
        return list(rows) if include_deleted else [r for r in rows if not r.get("deleted")]

    def get(self, kind: str, rid: str, include_deleted: bool = False) -> dict | None:
        for r in self.data[kind]:
            if r.get("id") == rid:
                return r if include_deleted or not r.get("deleted") else None
        return None

    def current(self, kind: str) -> list[dict]:
        """Records of this school year: not deleted and not archived (classes, students)."""
        return [r for r in self.all(kind) if not r.get("archived")]

    def student_by_gradal_id(self, gid, class_ids=None) -> dict | None:
        """Among the students of `class_ids` first (a quiz's classes, archived or not), then the current
        students; active ones first. gradalId is unique only among current students."""
        pool = []
        if class_ids:
            pool = [s for s in self.all("students") if set(s.get("classIds") or []) & set(class_ids)
                    and same_gradal_id(s.get("gradalId"), gid)]
        found = pool or [s for s in self.current("students") if same_gradal_id(s.get("gradalId"), gid)]
        found.sort(key=lambda s: not s.get("active", True))
        return found[0] if found else None

    def quiz_by_code(self, code) -> dict | None:
        return next((q for q in self.all("quizzes") if str(q.get("code")) == str(code)), None)

    # ---------- changes ----------

    def put(self, kind: str, record: dict) -> dict:
        """Local edit: insert or replace by id, bumping updatedAt."""
        with self.lock:
            existing = self.get(kind, record["id"], include_deleted=True)
            if existing is not None:
                record.setdefault("updatedAt", existing.get("updatedAt"))
                bump(record)
                self.data[kind][self.data[kind].index(existing)] = record
            else:
                bump(record)
                self.data[kind].append(record)
            return record

    def delete(self, kind: str, rid: str) -> bool:
        with self.lock:
            r = self.get(kind, rid)
            if r is None:
                return False
            r["deleted"] = True
            bump(r)
            return True

    def merge(self, kind: str, record: dict) -> bool:
        """Protocol merge rule: replace only if strictly newer. Returns True when stored."""
        with self.lock:
            existing = self.get(kind, record["id"], include_deleted=True)
            if existing is None:
                self.data[kind].append(record)
                return True
            if parse_time(record.get("updatedAt")) > parse_time(existing.get("updatedAt")):
                self.data[kind][self.data[kind].index(existing)] = record
                return True
            return False

    def log_sync(self, device: str, action: str, detail: str = "") -> None:
        with self.lock:
            self.data["syncLog"].append({"time": now_iso(), "device": device, "action": action, "detail": detail})
            del self.data["syncLog"][:-SYNC_LOG_LIMIT]
