"""Runs the Python reader (pc/omr.py) on the test sheets and compares with the truth files.

    python tools/check_omr.py [dir]

Exit code 0 only when every sheet is found and every answer, ID digit, quiz code and version matches.
"""

from __future__ import annotations

import json
import sys
import time
from pathlib import Path

import numpy as np
from PIL import Image

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / "pc"))
import omr  # noqa: E402

LAYOUT = json.loads((HERE.parent / "shared" / "sheet-layouts.json").read_text(encoding="utf-8"))


def main() -> int:
    folder = Path(sys.argv[1]) if len(sys.argv) > 1 else HERE / "test-sheets"
    bad = 0
    total_q = wrong_q = 0
    for truth_file in sorted(folder.glob("*.json")):
        truth = json.loads(truth_file.read_text(encoding="utf-8"))
        gray = np.array(Image.open(truth_file.with_suffix(".jpg")).convert("L"))
        t = time.perf_counter()
        res = omr.read_sheet(gray, LAYOUT, truth["questionCount"], (truth.get("sheet") or {}).get("questionBubbles"))
        ms = (time.perf_counter() - t) * 1000
        if res is None:
            print(f"{truth_file.stem}: NOT FOUND ({ms:.0f} ms)")
            bad += 1
            continue
        errs = []
        if res.student_id != truth["studentId"]:
            errs.append(f"id {res.student_id!r} != {truth['studentId']!r}")
        if res.quiz_code != truth["quizCode"]:
            errs.append(f"code {res.quiz_code} != {truth['quizCode']}")
        if res.version != truth["version"]:
            errs.append(f"version {res.version} != {truth['version']}")
        for q, (got, want) in enumerate(zip(res.answers, truth["answers"])):
            total_q += 1
            if got != want:
                wrong_q += 1
                errs.append(f"q{q + 1} {got!r} != {want!r} {res.darkness[q]}")
        status = "ok" if not errs else "; ".join(errs[:6])
        print(f"{truth_file.stem} [{truth['questionCount']}q] {ms:.0f} ms: {status}")
        bad += bool(errs)
    print(f"\nsheets with errors: {bad}; wrong answers: {wrong_q}/{total_q}")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
