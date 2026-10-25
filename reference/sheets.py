"""Printable answer sheets: the fixed frame from shared/sheet-layouts.json, the question area from the
quiz's own sheet (pc/sheet_layout.py, quiz["sheet"]): one column per page of the question paper, a
framed box per section. The labels follow the quiz language: Arabic (choices أ ب ج د, right to left)
or English (A B C D).

A page is first described as a list of primitives in millimetres (page_shapes), then written as
SVG for printing (page_svg / print_html, svgs_to_pdf) or rasterised with Pillow (page_raster) so the
tests can run pc/omr.py on exactly the same geometry. Top: the school header from the settings and
the quiz; under it the frame the reader uses: markers, orientation mark, barcode (quiz code), the
name box, the 3-digit ID and the question boxes.
"""

from __future__ import annotations

import base64
import html
import json
import re
from pathlib import Path

HERE = Path(__file__).resolve().parent
LAYOUT_PATH = HERE.parent / "shared" / "sheet-layouts.json"

INK = "#000000"
BUBBLE_STROKE = "#555555"
BOX_STROKE = "#5f5f5f"
BAND = "#e6e6e6"
LETTER = "#a8a8a8"
SOFT = "#6b7280"
FONT = "Arial, 'Segoe UI', Tahoma, sans-serif"
ARABIC_RE = re.compile(r"[\u0600-\u06FF]")


def load_layout() -> dict:
    return json.loads(LAYOUT_PATH.read_text(encoding="utf-8"))


# ---------- barcode (port of build_layouts.encode, same bits) ----------

def crc6(value: int, nbits: int, poly: int = 0x03) -> int:
    crc = 0
    for i in range(nbits - 1, -1, -1):
        bit = (value >> i) & 1
        top = (crc >> 5) & 1
        crc = (crc << 1) & 0x3F
        if top ^ bit:
            crc ^= poly
    return crc


def encode(code: int, version: int, layout: dict | None = None) -> list[int]:
    b = (layout or {}).get("barcode", {"bits": 22, "codeBits": 14, "versionBits": 2, "crcBits": 6, "crcPoly": 3})
    if not (0 <= code < (1 << b["codeBits"]) and 0 <= version < (1 << b["versionBits"])):
        raise ValueError("code or version out of range")
    payload = (code << b["versionBits"]) | version
    word = (payload << b["crcBits"]) | crc6(payload, b["codeBits"] + b["versionBits"], b["crcPoly"])
    return [(word >> (b["bits"] - 1 - i)) & 1 for i in range(b["bits"])]


# ---------- primitives ----------

def _rect(x, y, w, h, fill=INK, stroke=None, sw=0.0, rx=0.0):
    return {"t": "rect", "x": x, "y": y, "w": w, "h": h, "fill": fill, "stroke": stroke, "sw": sw, "rx": rx}


def _band(x0, y0, x1, y1, r, fill=BAND):
    """A box's title band: top corners rounded like the box, flat bottom."""
    d = (f"M{x0:.3f},{y1:.3f} V{y0 + r:.3f} Q{x0:.3f},{y0:.3f} {x0 + r:.3f},{y0:.3f} H{x1 - r:.3f} "
         f"Q{x1:.3f},{y0:.3f} {x1:.3f},{y0 + r:.3f} V{y1:.3f} Z")
    return {"t": "path", "d": d, "fill": fill, "box": [x0, y0, x1, y1]}


def _circle(cx, cy, r, fill=None, stroke=BUBBLE_STROKE, sw=0.2):
    return {"t": "circle", "cx": cx, "cy": cy, "r": r, "fill": fill, "stroke": stroke, "sw": sw}


def _text(x, y, text, size, fill=INK, anchor="start", weight=400, middle=False, small=""):
    return {"t": "text", "x": x, "y": y, "text": str(text), "size": size, "fill": fill, "anchor": anchor,
            "weight": weight, "middle": middle, "small": small}


def _line(x1, y1, x2, y2, stroke=SOFT, sw=0.25):
    return {"t": "line", "x1": x1, "y1": y1, "x2": x2, "y2": y2, "stroke": stroke, "sw": sw}


def _image(x, y, w, h, href):
    return {"t": "image", "x": x, "y": y, "w": w, "h": h, "href": href}


LABELS = {
    "ar": {"name": "الاسم", "class": "الفصل:", "code": "رمز", "id": "رقم الطالب", "page": "صفحة",
           "key": "مفتاح الإجابة", "correct": "صحيح", "wrong": "خطأ",
           "rules": ("ظلّل دائرة واحدة لكل سؤال", "تظليلًا كاملًا بقلم رصاص داكن", "أو أزرق، وامسح الخطأ جيدًا."),
           "choices": ["أ", "ب", "ج", "د"]},
    "en": {"name": "Name", "class": "Class:", "code": "Code", "id": "Student ID", "page": "Page",
           "key": "ANSWER KEY", "correct": "Correct", "wrong": "Wrong",
           "rules": ("Fill one circle per question", "completely with a dark pencil", "or blue pen. Erase mistakes."),
           "choices": ["A", "B", "C", "D"]},
}


def labels(language: str | None) -> dict:
    return LABELS["ar" if language == "ar" else "en"]


def header_lines(settings: dict, quiz: dict) -> tuple[list[str], list[str]]:
    """The two text blocks of the header: the school's fixed lines (settings) and the quiz's lines."""
    school = [str(t).strip() for t in (settings.get("schoolLines") or []) if str(t).strip()][:4]
    h = quiz.get("header") or {}
    mine = [str(h.get(k) or "").strip() for k in ("subject", "title", "grade", "extra")]
    return school, [t for t in mine if t][:4]


def header_shapes(box, settings: dict, quiz: dict) -> list[dict]:
    """A bordered strip: the school lines on the right, the quiz lines on the left, the school's logo (if
    any, settings["logo"] as a data URL) in the middle."""
    x0, y0, x1, y1 = box
    h = y1 - y0
    out = [_rect(x0, y0, x1 - x0, h, fill=None, stroke=INK, sw=0.35)]
    school, mine = header_lines(settings, quiz)
    pitch = 3.9
    for lines, x, anchor in ((school, x1 - 3, "end"), (mine, x0 + 3, "start")):
        top = y0 + h / 2 - pitch * (len(lines) - 1) / 2
        for i, line in enumerate(lines):
            out.append(_text(x, top + i * pitch, line, 2.9, anchor=anchor, weight=700 if i == 0 else 400, middle=True))
    logo = settings.get("logo")
    if isinstance(logo, str) and logo.startswith("data:image/"):
        out.append(_image((x0 + x1) / 2 - 15, y0 + 1.5, 30, h - 3, logo))
    return out


def page_shapes(layout: dict, *, quiz: dict, settings: dict | None = None, student_name: str = "",
                gradal_id: str = "", class_name: str = "", key: list[str] | None = None) -> list[dict]:
    """quiz: the saved quiz (code, sheet, language, header, name). key: the answer-key sheet: the correct
    bubbles of each question filled solid, the name box reads the key label."""
    L = layout
    P = L["print"]
    T = labels(quiz.get("language"))
    rtl = quiz.get("language") == "ar"
    sheet, code = quiz["sheet"], int(quiz["code"])
    r = L["bubbleDiameterMm"] / 2
    out = header_shapes(P["headerBox"], settings or {}, quiz)

    # frame: corner markers, orientation mark, barcode — solid black
    m = L["markers"]["sizeMm"]
    for x, y in L["markers"]["centers"]:
        out.append(_rect(x - m / 2, y - m / 2, m, m))
    o = L["orientationMark"]
    out.append(_rect(o["center"][0] - o["sizeMm"] / 2, o["center"][1] - o["sizeMm"] / 2, o["sizeMm"], o["sizeMm"]))
    cw, ch = L["barcode"]["cellMm"]
    for bit, (x, y) in zip(encode(code, 0, L), L["barcode"]["cells"]):
        if bit:
            out.append(_rect(x - cw / 2, y - ch / 2, cw, ch))

    # name box, class, quiz
    nx0, ny0, nx1, ny1 = P["nameBox"]
    out.append(_rect(nx0, ny0, nx1 - nx0, ny1 - ny0, fill=None, stroke=INK, sw=0.3))
    out.append(_text(nx1 - 1.5 if rtl else nx0 + 1.5, ny0 + 2.6, T["name"], 2.3, fill=SOFT, middle=True,
                     anchor="end" if rtl else "start"))
    shown = T["key"] if key else student_name
    if shown:
        out.append(_text((nx0 + nx1) / 2, ny0 + (ny1 - ny0) * 0.62, shown, 4.2, anchor="middle", weight=700, middle=True))
    ix, iy = P["infoAt"]
    if rtl:   # one right-aligned run per line: Arabic reads well as a whole
        rx = ix + 30.0
        if class_name:
            out.append(_text(rx, iy - 4.0, f"{T['class']} {class_name[:22]}", 2.9, weight=700, middle=True, anchor="end"))
        out.append(_text(rx, iy + 1.5, f"{T['code']} {code}", 2.6, fill=SOFT, middle=True, anchor="end"))
        if quiz.get("name"):
            out.append(_text(rx, iy + 6.3, str(quiz["name"])[:26], 2.5, fill=SOFT, middle=True, anchor="end"))
    else:     # separate text runs, so the bidi algorithm cannot reorder them
        if class_name:
            out.append(_text(ix, iy - 4.0, T["class"], 2.9, weight=700, middle=True))
            out.append(_text(ix + 10.6, iy - 4.0, class_name[:22], 2.9, middle=True))
        out.append(_text(ix, iy + 1.5, T["code"], 2.6, fill=SOFT, middle=True))
        out.append(_text(ix + 10.6, iy + 1.5, str(code), 2.6, fill=SOFT, middle=True))
        if quiz.get("name"):
            out.append(_text(ix, iy + 6.3, str(quiz["name"])[:26], 2.5, fill=SOFT, middle=True))

    # student ID: label, write-in boxes, bubbles 0-9 (pre-filled solid when personalised)
    lx, ly = P["idLabelAt"]
    out.append(_text(lx, ly, T["id"], 2.8, anchor="middle", weight=700, middle=True))
    by0, by1 = P["idBoxesY"]
    gid = "".join(ch for ch in str(gradal_id or "") if ch.isdigit())[: L["idDigits"]]
    for d, column in enumerate(L["idBubbles"]):
        cx = column[0][0]
        bw = 5.2
        out.append(_rect(cx - bw / 2, by0, bw, by1 - by0, fill=None, stroke=INK, sw=0.25))
        if d < len(gid):
            out.append(_text(cx, (by0 + by1) / 2, gid[d], 3.6, anchor="middle", weight=700, middle=True))
        for v, (x, y) in enumerate(column):
            filled = d < len(gid) and int(gid[d]) == v
            out.append(_circle(x, y, r, fill=INK if filled else None))
            if not filled:
                out.append(_text(x, y, v, 2.0, fill=LETTER, anchor="middle", middle=True))

    # instructions, in the free space under the ID block; the sample bubbles stay at the same place
    tx, anchor = (190.0, "end") if rtl else (159.5, "start")
    ay = L["idBubbles"][0][-1][1] + 11
    for i, line in enumerate(T["rules"]):
        out.append(_text(tx, ay + i * 4.2, line, 2.5, middle=True, anchor=anchor))
    ex_y = ay + len(T["rules"]) * 4.2 + 3.5
    sx = 163.0 if rtl else 175.5
    out.append(_text(tx, ex_y, T["correct"], 2.7, weight=700, middle=True, anchor=anchor))
    out.append(_circle(sx, ex_y, r, fill=INK))
    out.append(_text(tx, ex_y + 6, T["wrong"], 2.7, weight=700, middle=True, anchor=anchor))
    for k, mark in enumerate(("✓", "✗", "•")):
        cx = sx + k * 5.4
        out.append(_circle(cx, ex_y + 6, r))
        out.append(_text(cx, ex_y + 6, mark, 2.6, anchor="middle", middle=True))

    # the question area: one column per page, a framed box per section (quiz["sheet"])
    bubbles = sheet["questionBubbles"]
    letters = T["choices"]
    for col in sheet["columns"]:
        if col.get("page"):
            out.append(_text((col["x0"] + col["x1"]) / 2, col["captionY"] - 0.7, f"{T['page']} {col['page']}", 3.0,
                             anchor="middle", weight=700, middle=True))
        for bx in col["boxes"]:
            rr = 1.5
            out.append(_band(bx["x0"], bx["y0"], bx["x1"], bx["titleY1"], rr))
            out.append(_line(bx["x0"], bx["titleY1"], bx["x1"], bx["titleY1"], stroke=BOX_STROKE, sw=0.25))
            out.append(_rect(bx["x0"], bx["y0"], bx["x1"] - bx["x0"], bx["y1"] - bx["y0"], fill=None, stroke=BOX_STROKE,
                             sw=0.3, rx=rr))
            out.append(_text((bx["x0"] + bx["x1"]) / 2, (bx["y0"] + bx["titleY1"]) / 2, bx["title"], 2.8,
                             anchor="middle", weight=700, middle=True))
            for q in range(bx["from"], bx["to"] + 1):
                row = bubbles[q - 1]
                out.append(_text(bx["numberX"], row[0][1], q, 2.8, anchor=bx.get("numberAnchor", "end"), weight=700,
                                 middle=True))
                right = (key[q - 1] if key and q - 1 < len(key) else "") or ""
                for c, (x, y) in enumerate(row):
                    if L["choices"][c] in right:
                        out.append(_circle(x, y, r, fill=INK))
                        continue
                    out.append(_circle(x, y, r))
                    out.append(_text(x, y, letters[c], 2.1, fill=LETTER, anchor="middle", middle=True))
    return out


# ---------- SVG ----------

def _f(v: float) -> str:
    return f"{v:.3f}".rstrip("0").rstrip(".")


def _bidi(text: str) -> str:
    """Arabic text inside the left-to-right page: right-to-left marks keep its punctuation in place."""
    return f"\u200f{text}\u200f" if ARABIC_RE.search(text) else text


def page_svg(shapes: list[dict]) -> str:
    parts = ['<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 210 297" width="210mm" height="297mm" '
             f'direction="ltr" font-family="{FONT}">', '<rect x="0" y="0" width="210" height="297" fill="#ffffff"/>']
    for s in shapes:
        if s["t"] == "rect":
            fill = s["fill"] or "none"
            stroke = f' stroke="{s["stroke"]}" stroke-width="{_f(s["sw"])}"' if s["stroke"] else ""
            rx = f' rx="{_f(s["rx"])}"' if s.get("rx") else ""
            parts.append(f'<rect x="{_f(s["x"])}" y="{_f(s["y"])}" width="{_f(s["w"])}" height="{_f(s["h"])}"{rx} '
                         f'fill="{fill}"{stroke}/>')
        elif s["t"] == "path":
            parts.append(f'<path d="{s["d"]}" fill="{s["fill"]}"/>')
        elif s["t"] == "circle":
            fill = s["fill"] or "none"
            stroke = f' stroke="{s["stroke"]}" stroke-width="{_f(s["sw"])}"' if s["stroke"] and not s["fill"] else ""
            parts.append(f'<circle cx="{_f(s["cx"])}" cy="{_f(s["cy"])}" r="{_f(s["r"])}" fill="{fill}"{stroke}/>')
        elif s["t"] == "line":
            parts.append(f'<line x1="{_f(s["x1"])}" y1="{_f(s["y1"])}" x2="{_f(s["x2"])}" y2="{_f(s["y2"])}" '
                         f'stroke="{s["stroke"]}" stroke-width="{_f(s["sw"])}"/>')
        elif s["t"] == "image":
            parts.append(f'<image x="{_f(s["x"])}" y="{_f(s["y"])}" width="{_f(s["w"])}" height="{_f(s["h"])}" '
                         f'preserveAspectRatio="xMidYMid meet" href="{s["href"]}"/>')
        elif s["t"] == "text":
            base = ' dominant-baseline="central"' if s["middle"] else ""
            weight = f' font-weight="{s["weight"]}"' if s["weight"] != 400 else ""
            small = (f'<tspan font-size="{_f(s["size"] * 0.55)}" baseline-shift="super"> {html.escape(s["small"])}</tspan>'
                     if s.get("small") else "")
            parts.append(f'<text x="{_f(s["x"])}" y="{_f(s["y"])}" font-size="{_f(s["size"])}" fill="{s["fill"]}" '
                         f'text-anchor="{s["anchor"]}"{base}{weight}>{html.escape(_bidi(s["text"]))}{small}</text>')
    parts.append("</svg>")
    return "".join(parts)


PRINT_CSS = """
@page { size: A4; margin: 0 }
html, body { margin: 0; padding: 0; background: #5b6472 }
.bar { font: 600 14px 'Segoe UI', Tahoma, sans-serif; color: #fff; text-align: center; padding: 10px }
.page { width: 210mm; height: 297mm; margin: 0 auto 6mm; background: #fff; overflow: hidden;
        break-after: page; page-break-after: always; -webkit-print-color-adjust: exact; print-color-adjust: exact }
.page:last-child { break-after: auto; page-break-after: auto }
.page svg { display: block; width: 210mm; height: 297mm }
@media print { html, body { background: #fff } .bar { display: none } .page { margin: 0 } }
"""


def print_html(pages: list[str], title_note: str = "") -> str:
    note = html.escape(title_note)
    body = "".join(f'<div class="page">{svg}</div>' for svg in pages)
    return ("<!DOCTYPE html><html lang=\"ar\"><head><meta charset=\"utf-8\">"
            "<title>Gradal</title>"
            f"<style>{PRINT_CSS}</style></head><body>"
            f"<div class=\"bar\" dir=\"rtl\">{note} — اطبع بـ Ctrl+P (A4، بلا هوامش، بلا تصغير)</div>"
            f"{body}</body></html>")


def edge_path() -> Path | None:
    return next((p for p in (Path(r"C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe"),
                             Path(r"C:\Program Files\Microsoft\Edge\Application\msedge.exe")) if p.exists()), None)


def html_to_pdf(page_html: str, out: Path) -> Path | None:
    """Microsoft Edge (headless) prints the page to PDF, exactly as it prints on paper. None without Edge."""
    import subprocess
    import tempfile
    edge = edge_path()
    if not edge:
        return None
    out = Path(out)
    with tempfile.TemporaryDirectory() as tmp:
        page = Path(tmp) / "page.html"
        page.write_text(page_html, encoding="utf-8")
        target = Path(tmp) / "out.pdf"
        subprocess.run([str(edge), "--headless=new", "--disable-gpu", "--no-pdf-header-footer",
                        f"--user-data-dir={Path(tmp) / 'prof'}", f"--print-to-pdf={target}", page.as_uri()],
                       timeout=180, capture_output=True, creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
        if target.exists() and target.stat().st_size > 1000:
            out.write_bytes(target.read_bytes())
            return out
    return None


def svgs_to_pdf(pages: list[str], out: Path) -> Path:
    """Sheets as a PDF file: through Edge (fonts as on paper); without Edge, MuPDF converts the SVGs."""
    if html_to_pdf(print_html(pages), out):
        return Path(out)
    import pymupdf
    doc = pymupdf.open()
    for svg in pages:
        src = pymupdf.open("svg", svg.encode("utf-8"))
        doc.insert_pdf(pymupdf.open("pdf", src.convert_to_pdf()))
    doc.save(str(out))
    return Path(out)


# ---------- raster (tests) ----------

def page_raster(shapes: list[dict], px_per_mm: float = 8.0):
    """Grayscale numpy image of the page. Text is drawn only when it is plain ASCII (no shaping
    here); the logo is drawn as a grey block."""
    import numpy as np
    from PIL import Image, ImageDraw, ImageFont

    W, H = int(round(210 * px_per_mm)), int(round(297 * px_per_mm))
    img = Image.new("L", (W, H), 255)
    d = ImageDraw.Draw(img)

    def gray(color):
        if not color:
            return None
        c = color.lstrip("#")
        rr, gg, bb = int(c[0:2], 16), int(c[2:4], 16), int(c[4:6], 16)
        return int(round(0.299 * rr + 0.587 * gg + 0.114 * bb))

    fonts = {}

    def font(size_mm):
        px = max(6, int(round(size_mm * px_per_mm)))
        if px not in fonts:
            try:
                fonts[px] = ImageFont.truetype("arial.ttf", px)
            except OSError:
                fonts[px] = ImageFont.load_default()
        return fonts[px]

    k = px_per_mm
    for s in shapes:
        if s["t"] == "rect":
            box = [s["x"] * k, s["y"] * k, (s["x"] + s["w"]) * k - 1, (s["y"] + s["h"]) * k - 1]
            if s.get("rx"):
                d.rounded_rectangle(box, radius=s["rx"] * k, fill=gray(s["fill"]) if s["fill"] else None,
                                    outline=gray(s["stroke"]) if s["stroke"] else None,
                                    width=max(1, int(round(s["sw"] * k))))
                continue
            if s["fill"]:
                d.rectangle(box, fill=gray(s["fill"]))
            if s["stroke"]:
                d.rectangle(box, outline=gray(s["stroke"]), width=max(1, int(round(s["sw"] * k))))
        elif s["t"] == "path":
            x0, y0, x1, y1 = s["box"]
            d.rectangle([x0 * k, y0 * k, x1 * k, y1 * k], fill=gray(s["fill"]))
        elif s["t"] == "circle":
            box = [(s["cx"] - s["r"]) * k, (s["cy"] - s["r"]) * k, (s["cx"] + s["r"]) * k, (s["cy"] + s["r"]) * k]
            if s["fill"]:
                d.ellipse(box, fill=gray(s["fill"]))
            else:
                d.ellipse(box, outline=gray(s["stroke"]), width=max(1, int(round(s["sw"] * k))))
        elif s["t"] == "line":
            d.line([s["x1"] * k, s["y1"] * k, s["x2"] * k, s["y2"] * k], fill=gray(s["stroke"]),
                   width=max(1, int(round(s["sw"] * k))))
        elif s["t"] == "image":
            d.rectangle([s["x"] * k, s["y"] * k, (s["x"] + s["w"]) * k, (s["y"] + s["h"]) * k], fill=90)
        elif s["t"] == "text" and s["text"].isascii():
            anchor = {"start": "l", "middle": "m", "end": "r"}[s["anchor"]] + ("m" if s["middle"] else "s")
            d.text((s["x"] * k, s["y"] * k), s["text"], fill=gray(s["fill"]), font=font(s["size"]), anchor=anchor)
    return np.array(img)
