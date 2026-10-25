"""Where a quiz's questions go on the answer sheet.

The fixed parts of the sheet (header, frame, markers, barcode, student ID, white probes) stay in
shared/sheet-layouts.json. The question area depends on the quiz:

- one column per page of the question paper (quiz["pages"], e.g. [20, 15]); optional — without it
  the questions are split evenly over as few columns as fit;
- inside a column, one framed box per section (quiz["sections"], ordered by question number;
  a section that crosses a page is split and its title repeated with "(cont.)"); optional —
  without sections each column is one box titled "Questions a–b";
- the frame of a box encloses its title band;
- the row pitch stretches so the longest column fills the question area (capped), so the
  sheet has no big empty space;
- an Arabic quiz (quiz["language"] == "ar") reads right to left: the number sits at the box's right
  edge and choice أ (index 0) is the rightmost bubble. Positions are per choice index, so the reader
  needs nothing else.

The PC computes this once per quiz and stores it in the quiz record as `sheet` (PROTOCOL.md);
the phone reads the bubble positions from there — it never recomputes them.

    compute(quiz, layout) -> {"version": 3, "questionBubbles": [[[x, y] x4] per question],
                              "pitch": p, "columns": [{"page": 1|None, "x0", "x1", "boxes": [...]}]}
"""

from __future__ import annotations

SHEET_VERSION = 4   # 4: area moved up with the frame (layout 4)

AREA_LEFT, AREA_RIGHT = 22.0, 156.0     # left of the student-ID block, right of the barcode
AREA_TOP, AREA_BOTTOM = 56.0, 279.0   # under the name/ID row; the frame starts at 34 since layout 4
PAGE_CAPTION_H = 5.0                    # "Page n" above a column, only when pages are given
BOX_W = 31.0
TITLE_H = 6.5
BOX_PAD_TOP, BOX_PAD_BOTTOM = 1.5, 1.0
BOX_GAP = 4.0
NUMBER_RIGHT = 6.5                      # question number right edge, from the box's left
FIRST_BUBBLE = 9.6                      # bubble A centre, from the box's left
CHOICE_PITCH = 5.4
MAX_PITCH = 9.5
MIN_PITCH = 5.6
MAX_COLUMNS = 4
MIN_QUESTIONS, MAX_QUESTIONS = 5, 60



class LayoutError(ValueError):
    pass


def section_label(section: dict) -> str:
    return str(section.get("name", "")).strip()


def is_rtl(quiz: dict) -> bool:
    return quiz.get("language") == "ar"


def _page_ranges(n: int, pages: list | None) -> tuple[list[tuple[int, int]], bool]:
    """[(from, to)] 1-based per column, and whether they are real question-paper pages."""
    counts = [int(c) for c in (pages or []) if int(c) > 0]
    if counts:
        if sum(counts) != n:
            raise LayoutError(f"pages add up to {sum(counts)}, the quiz has {n} questions")
        out, start = [], 1
        for c in counts:
            out.append((start, start + c - 1)); start += c
        return out, True
    for cols in range(1, MAX_COLUMNS + 1):       # as few balanced columns as fit
        per = -(-n // cols)
        if (AREA_BOTTOM - AREA_TOP - TITLE_H - BOX_PAD_TOP - BOX_PAD_BOTTOM) / per >= 7.0 or cols == MAX_COLUMNS:
            out, start = [], 1
            for c in range(cols):
                size = per if c < n % cols or n % cols == 0 else per - 1
                out.append((start, start + size - 1)); start += size
            return [r for r in out if r[0] <= r[1]], False
    raise AssertionError


def _boxes_for(rng: tuple[int, int], sections: list[dict], rtl: bool = False) -> list[dict]:
    a, b = rng
    boxes = []
    for s in sorted(sections, key=lambda s: int(s["from"])):
        lo, hi = max(a, int(s["from"])), min(b, int(s["to"]))
        if lo > hi:
            continue
        title = section_label(s) + ((" (تابع)" if rtl else " (cont.)") if lo > int(s["from"]) else "")
        boxes.append({"title": title, "from": lo, "to": hi})
    covered = {q for bx in boxes for q in range(bx["from"], bx["to"] + 1)}
    if not boxes or len(covered) < b - a + 1:
        # questions outside every section: their own box(es), in order
        rest, run = [], []
        for q in range(a, b + 1):
            if q in covered:
                if run: rest.append(run); run = []
            else:
                run.append(q)
        if run: rest.append(run)
        for r in rest:
            boxes.append({"title": (f"الأسئلة {r[0]}–{r[-1]}" if rtl else f"Questions {r[0]}–{r[-1]}"), "from": r[0], "to": r[-1]})
        boxes.sort(key=lambda bx: bx["from"])
    return boxes


def compute(quiz: dict, layout: dict) -> dict:
    n = int(quiz.get("questionCount") or 0)
    if not MIN_QUESTIONS <= n <= MAX_QUESTIONS:
        raise LayoutError(f"question count must be {MIN_QUESTIONS}–{MAX_QUESTIONS}")
    sections = [s for s in quiz.get("sections") or [] if int(s.get("from", 0)) >= 1 and int(s.get("to", 0)) >= int(s.get("from", 0))]
    ranges, real_pages = _page_ranges(n, quiz.get("pages"))
    if len(ranges) > MAX_COLUMNS:
        raise LayoutError(f"at most {MAX_COLUMNS} pages fit on the answer sheet")
    rtl = is_rtl(quiz)
    columns = [{"page": i + 1 if real_pages else None, "range": r, "boxes": _boxes_for(r, sections, rtl)} for i, r in enumerate(ranges)]
    if rtl:   # the first column on the right
        columns.reverse()

    top = AREA_TOP + (PAGE_CAPTION_H if real_pages else 0.0)
    avail = AREA_BOTTOM - top
    pitch = MAX_PITCH
    for col in columns:
        rows = col["range"][1] - col["range"][0] + 1
        fixed = len(col["boxes"]) * (TITLE_H + BOX_PAD_TOP + BOX_PAD_BOTTOM) + (len(col["boxes"]) - 1) * BOX_GAP
        pitch = min(pitch, (avail - fixed) / rows)
    if pitch < MIN_PITCH:
        raise LayoutError("too many questions on one page of the sheet: split them over more pages")

    gap = (AREA_RIGHT - AREA_LEFT - BOX_W * len(columns)) / (len(columns) + 1)
    bubbles: list = [None] * n
    out_cols = []
    for i, col in enumerate(columns):
        x0 = AREA_LEFT + gap + i * (BOX_W + gap)
        y = top
        boxes = []
        for bx in col["boxes"]:
            rows = bx["to"] - bx["from"] + 1
            y1 = y + TITLE_H + BOX_PAD_TOP + rows * pitch + BOX_PAD_BOTTOM
            row_y = []
            for k in range(rows):
                cy = y + TITLE_H + BOX_PAD_TOP + pitch * (k + 0.5)
                q = bx["from"] + k
                if rtl:
                    bubbles[q - 1] = [[round(x0 + BOX_W - FIRST_BUBBLE - c * CHOICE_PITCH, 3), round(cy, 3)]
                                      for c in range(len(layout["choices"]))]
                else:
                    bubbles[q - 1] = [[round(x0 + FIRST_BUBBLE + c * CHOICE_PITCH, 3), round(cy, 3)] for c in range(len(layout["choices"]))]
                row_y.append(round(cy, 3))
            boxes.append({"title": bx["title"], "from": bx["from"], "to": bx["to"],
                          "x0": round(x0, 3), "y0": round(y, 3), "x1": round(x0 + BOX_W, 3), "y1": round(y1, 3),
                          "titleY1": round(y + TITLE_H, 3), "rowsY": row_y,
                          "numberX": round(x0 + BOX_W - NUMBER_RIGHT if rtl else x0 + NUMBER_RIGHT, 3),
                          "numberAnchor": "start" if rtl else "end"})
            y = y1 + BOX_GAP
        out_cols.append({"page": col["page"], "x0": round(x0, 3), "x1": round(x0 + BOX_W, 3), "captionY": round(AREA_TOP + 3.5, 3), "boxes": boxes})
    return {"version": SHEET_VERSION, "pitch": round(pitch, 3), "questionBubbles": bubbles, "columns": out_cols,
            "rtl": rtl}
