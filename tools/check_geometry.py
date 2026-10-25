"""Checks the iPhone app's sheet geometry (ios/Gradal/Sheet/SheetGeometry.swift) against reference/sheet_layout.py.

    python tools/check_geometry.py make <in.json> [count] [seed]
        Writes random quizzes: [{"questionCount", "rtl", "sections": [{"name", "from", "to"}]}],
        5-60 questions, Arabic or English, 0-4 sections (gaps, overlaps and sections past the last
        question included), plus two counts out of range.
    python tools/check_geometry.py compare <in.json> <swift_out.json>
        swift_out.json comes from `OMRCheck --geometry <in.json> <out.json>`: [QuizSheet or null].
        Computes each quiz with the reference and compares every number (|d| <= 0.002), every title,
        range, column and box. Exit code 0 only when everything matches.
"""

from __future__ import annotations

import json
import random
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "reference"))

import sheet_layout  # noqa: E402

LAYOUT_PATH = ROOT / "shared" / "sheet-layouts.json"
TOL = 0.002
NAMES = {
    True: ["المفردات", "القواعد", "القراءة", "الكتابة", " الاستماع ", "اختيار من متعدد", "صح أو خطأ"],
    False: ["Vocabulary", "Grammar", "Reading", "Writing", " Listening ", "Multiple Choice", "True or False"],
}


def make_quiz(rnd: random.Random) -> dict:
    n = rnd.randint(sheet_layout.MIN_QUESTIONS, sheet_layout.MAX_QUESTIONS)
    rtl = rnd.random() < 0.5
    sections = []
    k = rnd.randint(0, 4)
    if k:
        cuts = sorted(rnd.sample(range(2, n + 1), min(k - 1, n - 1))) if k > 1 else []
        starts = [1] + cuts
        ends = [c - 1 for c in cuts] + [n]
        for a, b in zip(starts, ends):
            style = rnd.random()
            if style < 0.15 and b > a:          # leave a gap at the end of the section
                b = rnd.randint(a, b - 1)
            elif style < 0.25:                  # overlap the next one / run past the last question
                b = min(b + rnd.randint(1, 5), n + 3)
            sections.append({"name": rnd.choice(NAMES[rtl]), "from": a, "to": b})
        if rnd.random() < 0.15:
            sections.append({"name": rnd.choice(NAMES[rtl]), "from": 0, "to": 3})      # ignored: from < 1
        if rnd.random() < 0.15:
            sections.append({"name": rnd.choice(NAMES[rtl]), "from": 9, "to": 4})      # ignored: to < from
        rnd.shuffle(sections)
    return {"questionCount": n, "rtl": rtl, "sections": sections}


def make(out: Path, count: int, seed: int) -> int:
    rnd = random.Random(seed)
    quizzes = [make_quiz(rnd) for _ in range(count)]
    quizzes.append({"questionCount": 5, "rtl": True, "sections": []})
    quizzes.append({"questionCount": 60, "rtl": False, "sections": []})
    quizzes.append({"questionCount": 4, "rtl": False, "sections": []})       # out of range
    quizzes.append({"questionCount": 61, "rtl": True, "sections": []})       # out of range
    out.write_text(json.dumps(quizzes, ensure_ascii=False, indent=1), encoding="utf-8")
    print(f"wrote {len(quizzes)} quizzes to {out}")
    return 0


def num(errs: list, where: str, ref, got) -> None:
    if not isinstance(got, (int, float)) or isinstance(got, bool) or abs(float(ref) - float(got)) > TOL:
        errs.append(f"{where}: reference {ref} != swift {got}")


def compare_one(ref: dict, got: dict) -> list[str]:
    errs: list[str] = []
    if got.get("version") != ref["version"]:
        errs.append(f"version: reference {ref['version']} != swift {got.get('version')}")
    if got.get("rtl") != ref["rtl"]:
        errs.append(f"rtl: reference {ref['rtl']} != swift {got.get('rtl')}")
    num(errs, "pitch", ref["pitch"], got.get("pitch"))
    rb, gb = ref["questionBubbles"], got.get("questionBubbles") or []
    if len(rb) != len(gb):
        errs.append(f"questionBubbles: reference {len(rb)} questions != swift {len(gb)}")
    for q, (rrow, grow) in enumerate(zip(rb, gb), 1):
        if len(rrow) != len(grow):
            errs.append(f"q{q}: reference {len(rrow)} choices != swift {len(grow)}")
            continue
        for c, (rp, gp) in enumerate(zip(rrow, grow)):
            if len(gp) != 2:
                errs.append(f"q{q} choice {c}: swift point {gp}")
                continue
            num(errs, f"q{q} choice {c} x", rp[0], gp[0])
            num(errs, f"q{q} choice {c} y", rp[1], gp[1])
    rc, gc = ref["columns"], got.get("columns") or []
    if len(rc) != len(gc):
        errs.append(f"columns: reference {len(rc)} != swift {len(gc)}")
    for i, (rcol, gcol) in enumerate(zip(rc, gc), 1):
        num(errs, f"column {i} x0", rcol["x0"], gcol.get("x0"))
        num(errs, f"column {i} x1", rcol["x1"], gcol.get("x1"))
        rbx, gbx = rcol["boxes"], gcol.get("boxes") or []
        if len(rbx) != len(gbx):
            errs.append(f"column {i}: reference {len(rbx)} boxes != swift {len(gbx)}")
        for j, (r, g) in enumerate(zip(rbx, gbx), 1):
            where = f"column {i} box {j}"
            if g.get("title") != r["title"]:
                errs.append(f"{where} title: reference {r['title']!r} != swift {g.get('title')!r}")
            for key in ("from", "to"):
                if g.get(key) != r[key]:
                    errs.append(f"{where} {key}: reference {r[key]} != swift {g.get(key)}")
            for key in ("x0", "y0", "x1", "y1", "titleY1", "numberX"):
                num(errs, f"{where} {key}", r[key], g.get(key))
            if g.get("numberAnchorStart") != (r["numberAnchor"] == "start"):
                errs.append(f"{where} number anchor: reference {r['numberAnchor']} != swift start={g.get('numberAnchorStart')}")
    return errs


def compare(inp: Path, swift: Path) -> int:
    layout = json.loads(LAYOUT_PATH.read_text(encoding="utf-8"))
    quizzes = json.loads(inp.read_text(encoding="utf-8"))
    sheets = json.loads(swift.read_text(encoding="utf-8"))
    if len(quizzes) != len(sheets):
        print(f"FAIL: {len(quizzes)} quizzes, swift wrote {len(sheets)} sheets")
        return 1
    bad = 0
    reason = ""
    for i, (quiz, got) in enumerate(zip(quizzes, sheets)):
        label = (f"#{i} [{quiz['questionCount']}q {'ar' if quiz['rtl'] else 'en'}, "
                 f"{len(quiz['sections'])} sections]")
        ref_quiz = {"questionCount": quiz["questionCount"], "language": "ar" if quiz["rtl"] else "en",
                    "sections": quiz["sections"]}
        try:
            ref = sheet_layout.compute(ref_quiz, layout)
        except sheet_layout.LayoutError as e:
            ref = None
            reason = str(e)
        if ref is None or got is None:
            if (ref is None) != (got is None):
                bad += 1
                print(f"{label}: reference {'error: ' + reason if ref is None else 'sheet'}, "
                      f"swift {'error' if got is None else 'sheet'}")
            continue
        errs = compare_one(ref, got)
        if errs:
            bad += 1
            print(f"{label} sections={json.dumps(quiz['sections'], ensure_ascii=False)}")
            for e in errs[:12]:
                print(f"    {e}")
            if len(errs) > 12:
                print(f"    ... {len(errs) - 12} more")
    print(f"\n{len(quizzes)} quizzes; mismatches: {bad}")
    return 1 if bad else 0


def main() -> int:
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8")
    if len(sys.argv) >= 3 and sys.argv[1] == "make":
        count = int(sys.argv[3]) if len(sys.argv) > 3 else 200
        seed = int(sys.argv[4]) if len(sys.argv) > 4 else 1
        return make(Path(sys.argv[2]), count, seed)
    if len(sys.argv) >= 4 and sys.argv[1] == "compare":
        return compare(Path(sys.argv[2]), Path(sys.argv[3]))
    print(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main())
