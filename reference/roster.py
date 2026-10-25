"""Class lists (docs/DATA.md, «Class lists»): {classes: [{name, students: [name | {name, nationalId}]}]},
read from the teacher's Excel export of Noor or pasted names (students_import.py).

- classes match by name among the current ones; a new class gets the next free prefix 1-9 (prefixes of archived
  classes are free again: «بداية سنة أو فصل جديد» archives the year, archive_all / archive_class);
- students match by national ID when given, else by normalised name within the class; a new student gets prefix + the next
  free 2-digit serial in that class: the 3-digit gradalId is fixed for good;
- every student's `order` is refreshed from the list; students no longer listed become inactive.
"""

from __future__ import annotations

import re

from store import Store, bump, new_id, now_iso

_UNIFY = str.maketrans({"أ": "ا", "إ": "ا", "آ": "ا", "ٱ": "ا", "ة": "ه", "ى": "ي", "ـ": None})
_MARKS = re.compile(r"[ً-ْٰ]")   # harakat and dagger alef


def normalise(name: str) -> str:
    return re.sub(r"\s+", "", _MARKS.sub("", str(name or "")).translate(_UNIFY))


def clean_name(name: str) -> str:
    return re.sub(r"\s+", " ", str(name or "").replace("ـ", "")).strip()


class RosterError(ValueError):
    pass


def merge(store: Store, payload: dict) -> dict:
    """Applies one class list import. Returns a summary per class."""
    if not isinstance(payload, dict) or not isinstance(payload.get("classes"), list):
        raise RosterError("صيغة القائمة غير صحيحة")
    summary = []
    with store.lock:
        for entry in payload["classes"]:
            cname = clean_name((entry or {}).get("name"))
            # a student is a name, or {name, nationalId}
            people = []
            for item in (entry or {}).get("students") or []:
                name = clean_name(item.get("name") if isinstance(item, dict) else item)
                nid = str(item.get("nationalId") or "").strip() if isinstance(item, dict) else ""
                if name:
                    people.append((name, nid))
            names = [n for n, _ in people]
            if not cname:
                continue
            cls = next((c for c in store.current("classes") if normalise(c["name"]) == normalise(cname)), None)
            if cls is None:
                used = {c.get("prefix") for c in store.all("classes", include_deleted=True) if not c.get("archived")}
                free = [p for p in range(1, 10) if p not in used]
                if not free:
                    raise RosterError("لا بادئة متاحة لفصل جديد (1–9 كلها مستعملة)")
                cls = store.put("classes", {"id": new_id(), "name": cname, "prefix": free[0], "deleted": False})
            elif cls.get("deleted"):
                cls["deleted"] = False
                bump(cls)
            prefix = cls["prefix"]
            mine = [s for s in store.current("students") if cls["id"] in (s.get("classIds") or [])]
            serials = {int(s["gradalId"][1:]) for s in store.all("students", include_deleted=True) if not s.get("archived")
                       and str(s.get("gradalId", "")).isdigit() and len(s["gradalId"]) == 3 and s["gradalId"][0] == str(prefix)}
            unmatched = list(mine)
            added = 0
            for order, (name, nid) in enumerate(people, start=1):
                key = normalise(name)
                st = next((s for s in unmatched if nid and s.get("nationalId") == nid), None)                     or next((s for s in unmatched if normalise(s["name"]) == key), None)
                if st is None:
                    free = [n for n in range(1, 100) if n not in serials]
                    if not free:
                        raise RosterError(f"الفصل {cname} تجاوز 99 طالبًا")
                    serials.add(free[0])
                    st = store.put("students", {"id": new_id(), "classIds": [cls["id"]], "name": name,
                                                "gradalId": f"{prefix}{free[0]:02d}", "order": order, "active": True,
                                                "nationalId": nid, "deleted": False})
                    added += 1
                else:
                    unmatched.remove(st)
                    changes = {"order": order, "active": True}
                    if nid and st.get("nationalId") != nid:
                        changes["nationalId"] = nid
                    if st["name"] != name:
                        changes["name"] = name   # the list's spelling wins
                    if any(st.get(k) != v for k, v in changes.items()):
                        st.update(changes)
                        bump(st)
            gone = 0
            for st in unmatched:
                if st.get("active", True):
                    st["active"] = False
                    bump(st)
                    gone += 1
            summary.append({"name": cname, "prefix": prefix, "count": len(names), "added": added, "inactive": gone})
        store.data["roster"].update({"fetchedAt": payload.get("fetchedAt") or now_iso(), "importedAt": now_iso(),
                                   "classes": summary, "waiting": False, "error": None})
        store.save()
    return {"classes": summary}


def year_label(today=None) -> str:
    """«2025-2026 — 2026-10-21»: the school year being closed and the day. In August and September (a new year
    starting) that is the year just ended; later in the year (a new semester) the running one."""
    from datetime import date
    d = today or date.today()
    start = d.year - 1 if d.month <= 9 else d.year
    return f"{start}-{start + 1} — {d.isoformat()}"


def _archive(store: Store, classes: list[dict], label: str) -> dict:
    ids = {c["id"] for c in classes}
    n_students = 0
    for c in classes:
        c["archived"] = label
        bump(c)
    for s in store.current("students"):
        mine = set(s.get("classIds") or [])
        if mine and mine <= ids | {c["id"] for c in store.all("classes") if c.get("archived")}:
            s["archivedActive"] = bool(s.get("active", True))
            s["archived"] = label
            s["active"] = False
            bump(s)
            n_students += 1
    return {"classes": len(classes), "students": n_students, "label": label}


def archive_all(store: Store, label: str | None = None) -> dict:
    """A new school year or semester: every current class and its students leave the current lists (never
    deleted: old quizzes, scans and record sheets keep their names). Prefixes and serials are free again."""
    label = (label or "").strip()[:60] or year_label()
    with store.lock:
        out = _archive(store, store.current("classes"), label)
        store.data["roster"].update({"archivedAt": now_iso(), "archivedLabel": label})
        store.save()
    return out


def archive_class(store: Store, class_id: str, label: str | None = None) -> dict:
    """One class no longer taught («احذف الفصل»): archived like a year, its students with it."""
    label = (label or "").strip()[:60] or year_label()
    with store.lock:
        cls = next((c for c in store.current("classes") if c["id"] == class_id), None)
        if cls is None:
            raise RosterError("الفصل غير موجود")
        out = _archive(store, [cls], label)
        store.save()
    return out
