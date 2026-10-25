"""Gradal answer-sheet reader (reference implementation).

The iPhone app's Swift reader (ios/Gradal/OMR/) is a line-by-line port of this file, so keep the
two in step: same constants, same steps, same decisions. The PC uses it to read sheets that were
scanned or photographed outside the phone (tests and checks).

    read_sheet(gray, layout, question_count=None, question_bubbles=None) -> SheetRead | None

question_bubbles: the quiz's own positions (quiz["sheet"]["questionBubbles"], layout v3, from
pc/sheet_layout.py); without it the fixed v2 grid in the layout JSON is used.

`gray` is a 2-D uint8 numpy array (0 black .. 255 white). Steps:
 1. find the four solid corner markers on a downscaled copy (adaptive threshold + connected
    components + a square-shape filter + the largest convex quad of similar blobs);
 2. pick the rotation whose orientation mark (small square right of the top-left marker) is dark;
 3. fit the homography page-mm -> image from the four marker centres;
 4. read the barcode cells down the left edge (quiz code + version, CRC-checked); a sheet
    whose barcode does not check out is not read at all;
 5. for every bubble, compare the mean of its inner disc with the local paper white.
"""

from __future__ import annotations

import itertools
import math
from dataclasses import dataclass, field

import numpy as np

WORK_LONG_SIDE = 800       # marker search runs on this size
THRESH_RATIO = 0.72        # dark if pixel < local mean * ratio
MIN_MARKER_FRAC = 0.008    # marker side vs work long side
MAX_MARKER_FRAC = 0.07
MIN_FILL = 0.60            # tilted squares fill ~0.7 of their box; the checks below do the real work
MAX_AREA_SPREAD = 3.5      # biggest / smallest marker area
MAX_CANDIDATES = 24
INNER_RADIUS = 0.55        # sample this fraction of the bubble radius
MARK_DARKNESS = 0.35       # a bubble darker than this (0 paper .. 1 black) is marked ...
MARK_RELATIVE = 0.60       # ... if also at least this share of the darkest in its group
ORIENT_DARKNESS = 0.45
BAR_DARKNESS = 0.40       # a barcode cell darker than this is a 1
MAX_QUADS_TRIED = 40       # convex quads verified, biggest first
MARGIN_LIGHT = 0.25        # page margins must be lighter than this ...
MARGIN_SHARE = 0.85        # ... at this share of the probe points


@dataclass
class SheetRead:
    corners: list                      # marker centres in image px, page order TL TR BR BL
    homography: np.ndarray             # page mm -> image px (3x3)
    quiz_code: int                     # from the barcode, 1..9999
    version: int                       # from the barcode, 0..3 (model 1..4)
    student_id: str                    # digits; '?' where a column is blank or ambiguous
    answers: list = field(default_factory=list)    # per question: string of letters, '' = blank
    darkness: list = field(default_factory=list)   # per question: list of floats (for review)


# ---------- geometry ----------

def homography(src, dst) -> np.ndarray:
    """3x3 H with dst ~ H @ src for four point pairs (direct linear solve, h33 = 1)."""
    a, b = [], []
    for (x, y), (u, v) in zip(src, dst):
        a.append([x, y, 1, 0, 0, 0, -u * x, -u * y]); b.append(u)
        a.append([0, 0, 0, x, y, 1, -v * x, -v * y]); b.append(v)
    h = np.linalg.solve(np.array(a, float), np.array(b, float))
    return np.append(h, 1.0).reshape(3, 3)


def apply_h(h: np.ndarray, x: float, y: float) -> tuple[float, float]:
    w = h[2, 0] * x + h[2, 1] * y + h[2, 2]
    return (h[0, 0] * x + h[0, 1] * y + h[0, 2]) / w, (h[1, 0] * x + h[1, 1] * y + h[1, 2]) / w


def _polygon_area(pts) -> float:
    s = 0.0
    for i in range(len(pts)):
        x1, y1 = pts[i]; x2, y2 = pts[(i + 1) % len(pts)]
        s += x1 * y2 - x2 * y1
    return s / 2.0


def _is_convex(pts) -> bool:
    sign = 0
    for i in range(4):
        x1, y1 = pts[i]; x2, y2 = pts[(i + 1) % 4]; x3, y3 = pts[(i + 2) % 4]
        cross = (x2 - x1) * (y3 - y2) - (y2 - y1) * (x3 - x2)
        if cross == 0:
            return False
        s = 1 if cross > 0 else -1
        if sign and s != sign:
            return False
        sign = s
    return True


# ---------- image helpers ----------

def downscale(gray: np.ndarray, long_side: int) -> tuple[np.ndarray, float]:
    h, w = gray.shape
    f = max(1, int(math.ceil(max(h, w) / long_side)))
    if f == 1:
        return gray.astype(np.float32), 1.0
    hh, ww = h // f, w // f
    small = gray[: hh * f, : ww * f].astype(np.float32).reshape(hh, f, ww, f).mean(axis=(1, 3))
    return small, float(f)


def dark_mask(img: np.ndarray) -> np.ndarray:
    h, w = img.shape
    win = max(15, (max(h, w) // 12) | 1)
    half = win // 2
    ii = np.zeros((h + 1, w + 1), np.float64)
    ii[1:, 1:] = img.cumsum(0).cumsum(1)
    ys = np.arange(h); xs = np.arange(w)
    y0 = np.clip(ys - half, 0, h); y1 = np.clip(ys + half + 1, 0, h)
    x0 = np.clip(xs - half, 0, w); x1 = np.clip(xs + half + 1, 0, w)
    total = ii[y1][:, x1] - ii[y0][:, x1] - ii[y1][:, x0] + ii[y0][:, x0]
    count = (y1 - y0)[:, None] * (x1 - x0)[None, :]
    return img < (total / count) * THRESH_RATIO


def components(mask: np.ndarray) -> list[dict]:
    """8-connected blobs: area, bbox, centroid. Plain two-pass union-find so Swift can mirror it."""
    h, w = mask.shape
    labels = np.zeros((h, w), np.int32)
    parent = [0]

    def find(a):
        while parent[a] != a:
            parent[a] = parent[parent[a]]
            a = parent[a]
        return a

    nxt = 1
    for y in range(h):
        row = mask[y]
        if not row.any():
            continue
        for x in np.flatnonzero(row):
            best = 0
            for dy, dx in ((-1, -1), (-1, 0), (-1, 1), (0, -1)):
                yy, xx = y + dy, x + dx
                if 0 <= yy and 0 <= xx < w:
                    l = labels[yy, xx]
                    if l:
                        l = find(l)
                        if not best:
                            best = l
                        elif l != best:
                            parent[max(l, best)] = min(l, best)
                            best = min(l, best)
            if not best:
                parent.append(nxt); best = nxt; nxt += 1
            labels[y, x] = best
    blobs: dict[int, dict] = {}
    ys, xs = np.nonzero(labels)
    for y, x in zip(ys, xs):
        r = find(labels[y, x])
        b = blobs.get(r)
        if b is None:
            blobs[r] = b = {"area": 0, "sx": 0.0, "sy": 0.0, "x0": x, "x1": x, "y0": y, "y1": y}
        b["area"] += 1; b["sx"] += x; b["sy"] += y
        b["x0"] = min(b["x0"], x); b["x1"] = max(b["x1"], x)
        b["y0"] = min(b["y0"], y); b["y1"] = max(b["y1"], y)
    return list(blobs.values())


# ---------- step 1+2: markers ----------

def find_markers(gray: np.ndarray, layout: dict):
    small, f = downscale(gray, WORK_LONG_SIDE)
    mask = dark_mask(small)
    long_side = max(small.shape)
    lo, hi = MIN_MARKER_FRAC * long_side, MAX_MARKER_FRAC * long_side
    cands = []
    for b in components(mask):
        bw, bh = b["x1"] - b["x0"] + 1, b["y1"] - b["y0"] + 1
        if not (lo <= bw <= hi and lo <= bh <= hi):
            continue
        if not (0.55 <= bw / bh <= 1.8):
            continue
        if b["area"] / (bw * bh) < MIN_FILL:
            continue
        cands.append((b["area"], b["sx"] / b["area"], b["sy"] / b["area"]))
    cands.sort(reverse=True)
    cands = cands[:MAX_CANDIDATES]
    if len(cands) < 4:
        return None

    m = layout["markers"]["centers"]
    want = (math.dist(m[0], m[1]) / math.dist(m[1], m[2]))
    quads = []
    for combo in itertools.combinations(cands, 4):
        areas = [c[0] for c in combo]
        if max(areas) / min(areas) > MAX_AREA_SPREAD:
            continue
        pts = [(c[1], c[2]) for c in combo]
        cx = sum(p[0] for p in pts) / 4; cy = sum(p[1] for p in pts) / 4
        pts.sort(key=lambda p: math.atan2(p[1] - cy, p[0] - cx))
        if not _is_convex(pts):
            continue
        s = [math.dist(pts[i], pts[(i + 1) % 4]) for i in range(4)]
        ratio = min(s[0] + s[2], s[1] + s[3]) / max(s[0] + s[2], s[1] + s[3])
        if not (want * 0.6 <= ratio <= min(1.0, want * 1.45)):
            continue
        quads.append((abs(_polygon_area(pts)), pts))
    quads.sort(key=lambda q: q[0], reverse=True)
    page = layout["markers"]["centers"]
    o = layout["orientationMark"]
    for _, pts in quads[:MAX_QUADS_TRIED]:
        # atan2 order is clockwise on screen (y down). One of the four rotations puts TL first:
        # among those that look like a sheet and carry a valid barcode, the darkest orientation mark wins.
        full = [((x + 0.5) * f - 0.5, (y + 0.5) * f - 0.5) for x, y in pts]
        best = None
        for k in range(4):
            corners = full[k:] + full[:k]
            h = homography(page, corners)
            if not _verify(gray, h, layout) or read_barcode(gray, h, layout) is None:
                continue
            d = _darkness_at(gray, h, o["center"], o["sizeMm"] * 0.3, _local_white(gray, h, o["center"], 10.0))
            if best is None or d > best[0]:
                best = (d, corners, h)
        if best is not None:
            return best[1], best[2]
    return None


def _verify(gray: np.ndarray, h: np.ndarray, layout: dict) -> bool:
    """True only if the page drawn through h looks like a Gradal sheet: solid square markers,
    a dark orientation mark, and blank margins. Rejects stray quads and wrong rotations."""
    size = layout["markers"]["sizeMm"]
    for c in layout["markers"]["centers"]:
        white = _local_white(gray, h, c, size * 1.6)
        for dx in (-0.3, 0.0, 0.3):
            for dy in (-0.3, 0.0, 0.3):
                p = apply_h(h, c[0] + dx * size, c[1] + dy * size)
                if 1.0 - _sample(gray, *p) / white < 0.45:
                    return False
    o = layout["orientationMark"]
    if _darkness_at(gray, h, o["center"], o["sizeMm"] * 0.3, _local_white(gray, h, o["center"], 10.0)) < ORIENT_DARKNESS:
        return False
    probes = layout["whiteProbes"]
    light = 0
    for x, y in probes:
        white = _local_white(gray, h, (x, y), 5.0)
        if 1.0 - _sample(gray, *apply_h(h, x, y)) / white < MARGIN_LIGHT:
            light += 1
    return light >= MARGIN_SHARE * len(probes)


# ---------- step 4: bubbles ----------

def _disc_points(radius_mm: float, rings: int = 3, per_ring: int = 8):
    pts = [(0.0, 0.0)]
    for i in range(1, rings + 1):
        rr = radius_mm * i / rings
        n = per_ring * i
        pts += [(rr * math.cos(2 * math.pi * j / n), rr * math.sin(2 * math.pi * j / n)) for j in range(n)]
    return pts


def _sample(gray: np.ndarray, x: float, y: float) -> float:
    h, w = gray.shape
    xi = min(max(int(round(x)), 0), w - 1); yi = min(max(int(round(y)), 0), h - 1)
    return float(gray[yi, xi])


def _local_white(gray, h, center, half_mm: float) -> float:
    """Paper brightness around a point: the 90th percentile of a sparse grid of samples."""
    vals = []
    steps = 9
    for i in range(steps):
        for j in range(steps):
            px = center[0] - half_mm + 2 * half_mm * i / (steps - 1)
            py = center[1] - half_mm + 2 * half_mm * j / (steps - 1)
            vals.append(_sample(gray, *apply_h(h, px, py)))
    vals.sort()
    return max(vals[int(len(vals) * 0.9)], 1.0)


def _darkness_at(gray, h, center, radius_mm, white) -> float:
    pts = _disc_points(radius_mm)
    mean = sum(_sample(gray, *apply_h(h, center[0] + dx, center[1] + dy)) for dx, dy in pts) / len(pts)
    return min(1.0, max(0.0, 1.0 - mean / white))


def _marked(values: list[float]) -> list[int]:
    top = max(values) if values else 0.0
    return [i for i, v in enumerate(values) if v >= MARK_DARKNESS and v >= MARK_RELATIVE * top]


def crc6(value: int, nbits: int, poly: int = 0x03) -> int:
    crc = 0
    for i in range(nbits - 1, -1, -1):
        top = (crc >> 5) & 1
        crc = (crc << 1) & 0x3F
        if top ^ ((value >> i) & 1):
            crc ^= poly
    return crc


def read_barcode(gray, h, layout):
    """(quiz_code, version) or None when the cells do not form a valid code."""
    bc = layout["barcode"]
    half = min(bc["cellMm"]) / 2 * 0.6
    word = 0
    for c in bc["cells"]:
        white = _local_white(gray, h, c, 6.0)
        word = (word << 1) | (1 if _darkness_at(gray, h, c, half, white) >= BAR_DARKNESS else 0)
    crc_bits = bc["crcBits"]
    payload, crc = word >> crc_bits, word & ((1 << crc_bits) - 1)
    payload_bits = bc["codeBits"] + bc["versionBits"]
    if crc6(payload, payload_bits, bc["crcPoly"]) != crc:
        return None
    code, version = payload >> bc["versionBits"], payload & ((1 << bc["versionBits"]) - 1)
    if not 1 <= code <= 9999:
        return None
    return code, version


def read_sheet(gray: np.ndarray, layout: dict, question_count: int | None = None, question_bubbles: list | None = None):
    found = find_markers(gray, layout)
    if found is None:
        return None
    corners, h = found
    code = read_barcode(gray, h, layout)
    if code is None:
        return None
    r_in = layout["bubbleDiameterMm"] / 2 * INNER_RADIUS

    def group(points):
        cx = sum(p[0] for p in points) / len(points); cy = sum(p[1] for p in points) / len(points)
        span = max(abs(p[0] - cx) for p in points) + 4.0
        white = _local_white(gray, h, (cx, cy), max(span, 6.0))
        return [_darkness_at(gray, h, p, r_in, white) for p in points]

    digits = []
    for column in layout["idBubbles"]:
        marked = _marked(group(column))
        digits.append(str(marked[0]) if len(marked) == 1 else "?")
    student_id = "".join(digits)

    grid = question_bubbles or layout["questionBubbles"]
    n = min(question_count or len(grid), len(grid))
    letters = layout["choices"]
    answers, darkness = [], []
    for q in grid[:n]:
        vals = group(q)
        darkness.append([round(v, 3) for v in vals])
        answers.append("".join(letters[i] for i in _marked(vals)))
    return SheetRead(corners=corners, homography=h, quiz_code=code[0], version=code[1],
                     student_id=student_id, answers=answers, darkness=darkness)


def warp_page(gray: np.ndarray, h: np.ndarray, layout: dict, px_per_mm: float = 4.0) -> np.ndarray:
    """The whole sheet straightened to px_per_mm (for the review image)."""
    W = int(layout["page"]["widthMm"] * px_per_mm); H = int(layout["page"]["heightMm"] * px_per_mm)
    ys, xs = np.mgrid[0:H, 0:W].astype(np.float64)
    mx = (xs + 0.5) / px_per_mm; my = (ys + 0.5) / px_per_mm
    w = h[2, 0] * mx + h[2, 1] * my + h[2, 2]
    u = (h[0, 0] * mx + h[0, 1] * my + h[0, 2]) / w
    v = (h[1, 0] * mx + h[1, 1] * my + h[1, 2]) / w
    gh, gw = gray.shape
    ui = np.clip(np.rint(u).astype(int), 0, gw - 1); vi = np.clip(np.rint(v).astype(int), 0, gh - 1)
    return gray[vi, ui]
