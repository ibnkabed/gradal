"""Synthetic camera photos of filled Gradal sheets, for testing both readers.

    python tools/make_test_sheets.py [count] [out_dir]

Draws a sheet from shared/sheet-layouts.json (header, frame, barcode with a random quiz code
and model), pencils in random answers and a 3-digit ID, then
"photographs" it: perspective tilt, any rotation incl. upside down, uneven light, blur, noise,
JPEG. Writes <name>.jpg next to <name>.json (the truth). Default out: tools/test-sheets/.
The iOS CI job runs the Swift reader on the same files (ios/OMRCheck).
"""

from __future__ import annotations

import io
import json
import random
import sys
from pathlib import Path

import cv2
import numpy as np
from PIL import Image, ImageDraw, ImageFont

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / "shared"))
from build_layouts import encode  # noqa: E402
sys.path.insert(0, str(HERE.parent / "pc"))
import sheet_layout  # noqa: E402

LAYOUT = json.loads((HERE.parent / "shared" / "sheet-layouts.json").read_text(encoding="utf-8"))
PX = 8.0  # px per mm for the flat render


def font(size):
    try:
        return ImageFont.truetype("arial.ttf", size)
    except OSError:
        return ImageFont.load_default()


def render(truth: dict, rng: random.Random) -> np.ndarray:
    L = LAYOUT
    W, H = int(L["page"]["widthMm"] * PX), int(L["page"]["heightMm"] * PX)
    img = Image.new("L", (W, H), 255)
    d = ImageDraw.Draw(img)
    # the school header: a bordered box with text, like the real one (nobody reads it)
    x0, y0, x1, y1 = L["print"]["headerBox"]
    d.rectangle([x0 * PX, y0 * PX, x1 * PX, y1 * PX], outline=0, width=2)
    for i, line in enumerate(["Kingdom of Saudi Arabia", "Ministry of Education", "Department of Education",
                              "Education Office"]):
        d.text(((x0 + 3) * PX, (y0 + 1.5 + i * 3.4) * PX), line, fill=0, font=font(int(2.8 * PX)))
    for i, line in enumerate(["Secondary School", "Science", "Unit Test", "First Semester"]):
        d.text(((x1 - 55) * PX, (y0 + 1.5 + i * 3.4) * PX), line, fill=0, font=font(int(2.8 * PX)))
    d.rectangle([92 * PX, (y0 + 2) * PX, 116 * PX, (y1 - 2) * PX], fill=40)   # stands in for the logo
    s = L["markers"]["sizeMm"] * PX / 2
    for x, y in L["markers"]["centers"]:
        d.rectangle([x * PX - s, y * PX - s, x * PX + s, y * PX + s], fill=0)
    ox, oy = L["orientationMark"]["center"]; os_ = L["orientationMark"]["sizeMm"] * PX / 2
    d.rectangle([ox * PX - os_, oy * PX - os_, ox * PX + os_, oy * PX + os_], fill=0)
    cw, ch = (v * PX / 2 for v in L["barcode"]["cellMm"])
    for bit, (x, y) in zip(encode(truth["quizCode"], truth["version"]), L["barcode"]["cells"]):
        if bit:
            d.rectangle([x * PX - cw, y * PX - ch, x * PX + cw, y * PX + ch], fill=0)
    nx0, ny0, nx1, ny1 = L["print"]["nameBox"]
    d.rectangle([nx0 * PX, ny0 * PX, nx1 * PX, ny1 * PX], outline=0, width=2)
    d.text(((nx0 + 2) * PX, (ny0 + 2) * PX), truth.get("name", ""), fill=0, font=font(int(4 * PX)))
    r = L["bubbleDiameterMm"] / 2 * PX
    f = font(int(2.2 * PX))

    def bubble(x, y, label, filled):
        cx, cy = x * PX, y * PX
        d.ellipse([cx - r, cy - r, cx + r, cy + r], outline=60, width=max(1, int(0.2 * PX)))
        d.text((cx, cy), label, fill=150, font=f, anchor="mm")
        if filled:
            k = r * rng.uniform(0.7, 1.05)
            jx, jy = rng.uniform(-0.3, 0.3) * r, rng.uniform(-0.3, 0.3) * r
            d.ellipse([cx - k + jx, cy - k + jy, cx + k + jx, cy + k + jy], fill=rng.randint(25, 85))

    sid = truth["studentId"]
    for col, column in enumerate(L["idBubbles"]):
        for v, (x, y) in enumerate(column):
            bubble(x, y, str(v), int(sid[col]) == v)
    sheet = truth["sheet"]
    for col in sheet["columns"]:
        if col["page"]:
            d.text(((col["x0"] + col["x1"]) / 2 * PX, col["captionY"] * PX), f"Page {col['page']}", fill=0, font=font(int(3 * PX)), anchor="mm")
        for bx in col["boxes"]:
            d.rounded_rectangle([bx["x0"] * PX, bx["y0"] * PX, bx["x1"] * PX, bx["y1"] * PX], radius=int(1.5 * PX), outline=110, width=2)
            d.line([bx["x0"] * PX, bx["titleY1"] * PX, bx["x1"] * PX, bx["titleY1"] * PX], fill=110, width=2)
            d.text(((bx["x0"] + bx["x1"]) / 2 * PX, (bx["y0"] + bx["titleY1"]) / 2 * PX), bx["title"], fill=0, font=font(int(3 * PX)), anchor="mm")
    for q, row in enumerate(sheet["questionBubbles"][: truth["questionCount"]]):
        if sheet.get("rtl"):     # Arabic: the number right of choice أ, the rightmost bubble
            d.text(((row[0][0] + 3.1) * PX, row[0][1] * PX), str(q + 1), fill=0, font=font(int(3 * PX)), anchor="lm")
        else:
            d.text(((row[0][0] - 3.1) * PX, row[0][1] * PX), str(q + 1), fill=0, font=font(int(3 * PX)), anchor="rm")
        ans = truth["answers"][q]
        for c, (x, y) in enumerate(row):
            bubble(x, y, L["choices"][c], L["choices"][c] in ans)
        if rng.random() < 0.05 and len(ans) < 4:   # light erasure smudge: must stay unmarked
            free = [c for c in range(4) if L["choices"][c] not in ans]
            x, y = row[rng.choice(free)]
            d.ellipse([x * PX - r * 0.7, y * PX - r * 0.7, x * PX + r * 0.7, y * PX + r * 0.7], fill=215)
    return np.array(img)


def photograph(flat: np.ndarray, rng: random.Random, out_long: int = 1920) -> np.ndarray:
    h, w = flat.shape
    out_w, out_h = int(out_long * 0.75), out_long
    if rng.random() < 0.3:
        out_w, out_h = out_h, out_w
    scale = rng.uniform(0.62, 0.92) * min(out_w / w, out_h / h)
    cw, ch = w * scale, h * scale
    cx = out_w / 2 + rng.uniform(-0.06, 0.06) * out_w
    cy = out_h / 2 + rng.uniform(-0.06, 0.06) * out_h
    base = np.array([[-cw / 2, -ch / 2], [cw / 2, -ch / 2], [cw / 2, ch / 2], [-cw / 2, ch / 2]])
    turns = rng.choice([0, 0, 0, 2]) * 90 + rng.uniform(-12, 12)
    if out_w > out_h:
        turns += 90
    a = np.radians(turns)
    rot = np.array([[np.cos(a), -np.sin(a)], [np.sin(a), np.cos(a)]])
    pts = base @ rot.T
    pts += np.array([[rng.uniform(-0.07, 0.07) for _ in range(2)] for _ in range(4)]) * np.array([cw, ch])  # perspective
    pts += [cx, cy]
    src = np.float32([[0, 0], [w, 0], [w, h], [0, h]])
    m = cv2.getPerspectiveTransform(src, np.float32(pts))
    desk = rng.randint(70, 150)
    photo = cv2.warpPerspective(flat, m, (out_w, out_h), flags=cv2.INTER_AREA, borderValue=desk).astype(np.float32)
    # paper is a bit grey, light falls off across the frame
    yy, xx = np.mgrid[0:out_h, 0:out_w].astype(np.float32)
    gx, gy = rng.uniform(-1, 1), rng.uniform(-1, 1)
    light = 1.0 - rng.uniform(0.1, 0.4) * ((xx / out_w - 0.5) * gx + (yy / out_h - 0.5) * gy + 0.5)
    photo = photo * rng.uniform(0.78, 0.95) * light
    k = rng.choice([1, 3, 3, 5])
    photo = cv2.GaussianBlur(photo, (k, k), 0)
    photo += np.random.default_rng(rng.randint(0, 1 << 30)).normal(0, rng.uniform(2, 7), photo.shape)
    photo = np.clip(photo, 0, 255).astype(np.uint8)
    ok, buf = cv2.imencode(".jpg", photo, [cv2.IMWRITE_JPEG_QUALITY, rng.randint(60, 90)])
    return buf.tobytes()


def make(i: int, rng: random.Random, out: Path) -> None:
    n = rng.choice([10, 15, 17, 20, 25, 30, 35, 35, 40])   # a quiz has 10 to 40 questions
    answers = []
    for _ in range(n):
        p = rng.random()
        if p < 0.06:
            answers.append("")
        elif p < 0.10:
            answers.append("".join(sorted(rng.sample("ABCD", 2))))
        else:
            answers.append(rng.choice("ABCD"))
    quiz = {"questionCount": n, "language": rng.choice(["ar", "en"])}   # Arabic sheets mirror the choices
    if rng.random() < 0.7 and n >= 6:                      # pages of the question paper
        cut = rng.randint(n // 3, 2 * n // 3)
        quiz["pages"] = [cut, n - cut] if n <= 60 else [n // 3, n // 3, n - 2 * (n // 3)]
    if rng.random() < 0.7:                                 # skill sections
        a = 1; quiz["sections"] = []
        for name in ["المفردات", "القواعد", "القراءة", "الكتابة"]:
            if a > n: break
            b = n if name == "الكتابة" else min(n, a + rng.randint(2, max(2, n // 4)))
            quiz["sections"].append({"name": name, "from": a, "to": b}); a = b + 1
    try:
        sheet = sheet_layout.compute(quiz, LAYOUT)
    except sheet_layout.LayoutError:
        quiz.pop("pages", None)
        sheet = sheet_layout.compute(quiz, LAYOUT)
    truth = {
        "sheet": sheet,
        "quizCode": rng.randint(1000, 9999),
        "version": 0,
        "questionCount": n,
        "studentId": f"{rng.randint(1, 9)}{rng.randint(0, 9)}{rng.randint(0, 9)}",
        "answers": answers,
    }
    flat = render(truth, rng)
    name = f"sheet-{i:03d}"
    (out / f"{name}.jpg").write_bytes(photograph(flat, rng))
    (out / f"{name}.json").write_text(json.dumps(truth), encoding="utf-8")


def main() -> None:
    count = int(sys.argv[1]) if len(sys.argv) > 1 else 24
    out = Path(sys.argv[2]) if len(sys.argv) > 2 else HERE / "test-sheets"
    out.mkdir(parents=True, exist_ok=True)
    rng = random.Random(int(sys.argv[3]) if len(sys.argv) > 3 else 1448)
    for i in range(count):
        make(i, rng, out)
    print(f"{count} sheets")


if __name__ == "__main__":
    main()
