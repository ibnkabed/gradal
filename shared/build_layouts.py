"""Builds sheet-layouts.json: the single source of truth for the Gradal answer sheet.

Both sides read the JSON: the PC companion draws printable sheets from it, and the iPhone app
samples the bubbles and the barcode at the same places. Never edit the JSON by hand; change
this file and run:

    python Gradal/shared/build_layouts.py

Units are millimetres on an A4 portrait page, origin at the top-left corner of the paper.

The page has the school header on top, which nobody reads, and under it the frame:
four solid corner markers (their centres are the reference frame the reader maps to the
photo), a smaller square right of the top-left marker that tells which way is up, and a
column of barcode cells down the left edge carrying the quiz code and the model (version),
so the phone knows the quiz without being told. Inside the frame: the student's 3-digit ID
and up to 100 questions with choices A-D. Question i always sits at the same place whatever
the quiz length; a shorter quiz just prints fewer rows.

Barcode: 22 cells, top to bottom, dark = 1. Bits (MSB first): quiz code (14 bits, 0..9999),
version (2 bits, 0..3), CRC-6 (polynomial x^6 + x + 1, init 0) of those 16 bits.
"""

from __future__ import annotations

import json
from pathlib import Path

LAYOUT_VERSION = 5   # 5: bottom markers raised 13 mm — home printers clip the last ~10 mm of A4
PAGE = {"widthMm": 210.0, "heightMm": 297.0}

HEADER_BOX = [12.45, 8.0, 197.55, 24.0]       # x0, y0, x1, y1 of the school header

MARKER_SIZE = 7.0
FRAME_TOP, FRAME_BOTTOM, FRAME_LEFT, FRAME_RIGHT = 34.0, 272.0, 14.0, 196.0   # bottom markers end 21.5 mm above the edge
MARKERS = [[FRAME_LEFT, FRAME_TOP], [FRAME_RIGHT, FRAME_TOP],
           [FRAME_RIGHT, FRAME_BOTTOM], [FRAME_LEFT, FRAME_BOTTOM]]          # TL, TR, BR, BL
ORIENTATION = {"center": [26.0, FRAME_TOP], "sizeMm": 3.5}

BARCODE_BITS = 22
BARCODE_X = FRAME_LEFT
BARCODE_TOP = 58.0                             # far from the corners: never under a rotated orientation probe
BARCODE_PITCH = 9.0
BARCODE_CELL = [3.0, 5.0]                      # width, height

BUBBLE_D = 3.6                                 # small on purpose: students asked for it
CHOICES = ["A", "B", "C", "D"]
CHOICE_PITCH = 5.4
ROW_PITCH = 8.0
COLUMN_PITCH = 33.0
ROWS_PER_COLUMN = 25
MAX_QUESTIONS = 100
QUESTIONS_LEFT = 24.0                          # left edge of the first column's number
QUESTION_LABEL_W = 8.0                         # number -> bubble A
QUESTIONS_TOP = 60.0

ID_DIGITS = 3
ID_X = 166.0                                   # centre of digit column 0
ID_PITCH_X = 6.0
ID_TOP = 60.0                                  # centre of value 0
ID_PITCH_Y = 5.2

NAME_BOX = [34.0, 40.0, 120.0, 49.0]
INFO_AT = [124.0, 46.5]                        # class / model text, left aligned
ID_LABEL_AT = [ID_X + ID_PITCH_X, 44.0]        # centred over the ID block
ID_BOXES_Y = [47.5, 53.5]                      # write-in boxes above the ID bubbles


def r(v: float) -> float:
    return round(v, 3)


def crc6(value: int, nbits: int) -> int:
    crc = 0
    for i in range(nbits - 1, -1, -1):
        bit = (value >> i) & 1
        top = (crc >> 5) & 1
        crc = (crc << 1) & 0x3F
        if top ^ bit:
            crc ^= 0x03
    return crc


def encode(code: int, version: int) -> list[int]:
    assert 0 <= code <= 9999 and 0 <= version <= 3
    payload = (code << 2) | version
    word = (payload << 6) | crc6(payload, 16)
    return [(word >> (BARCODE_BITS - 1 - i)) & 1 for i in range(BARCODE_BITS)]


def build() -> dict:
    ids = [[[r(ID_X + d * ID_PITCH_X), r(ID_TOP + v * ID_PITCH_Y)] for v in range(10)]
           for d in range(ID_DIGITS)]
    questions = []
    for q in range(MAX_QUESTIONS):
        col, row = divmod(q, ROWS_PER_COLUMN)
        x0 = QUESTIONS_LEFT + col * COLUMN_PITCH + QUESTION_LABEL_W
        y = QUESTIONS_TOP + row * ROW_PITCH
        questions.append([[r(x0 + c * CHOICE_PITCH), r(y)] for c in range(len(CHOICES))])
    barcode = [[r(BARCODE_X), r(BARCODE_TOP + i * BARCODE_PITCH)] for i in range(BARCODE_BITS)]

    # Points that must be blank paper on a real sheet: bands outside the frame between the
    # markers. The reader rejects any marker guess that does not leave these light.
    W, H = PAGE["widthMm"], PAGE["heightMm"]
    probes = []
    for i in range(12):
        probes.append([r(34 + i * (186 - 34) / 11), r(FRAME_TOP - 6.0)])        # under the header
        probes.append([r(24 + i * (186 - 24) / 11), r(FRAME_BOTTOM + 6.0)])     # below the frame
    for i in range(16):
        y = FRAME_TOP + 9 + i * (FRAME_BOTTOM - FRAME_TOP - 18) / 15
        probes.append([r(FRAME_LEFT - 7.0), r(y)])
        probes.append([r(FRAME_RIGHT + 7.0), r(y)])

    return {
        "version": LAYOUT_VERSION,
        "page": PAGE,
        "markers": {"sizeMm": MARKER_SIZE, "centers": MARKERS},
        "orientationMark": ORIENTATION,
        "whiteProbes": probes,
        "barcode": {"bits": BARCODE_BITS, "cells": barcode, "cellMm": BARCODE_CELL,
                    "codeBits": 14, "versionBits": 2, "crcBits": 6, "crcPoly": 3},
        "bubbleDiameterMm": BUBBLE_D,
        "choices": CHOICES,
        "maxVersions": 4,
        "idDigits": ID_DIGITS,
        "idBubbles": ids,                    # [digit][value 0..9] -> [x, y]
        "maxQuestions": MAX_QUESTIONS,
        "rowsPerColumn": ROWS_PER_COLUMN,
        "questionBubbles": questions,        # [question][choice] -> [x, y]
        "questionLabelOffsetMm": -QUESTION_LABEL_W + 2.5,   # right edge of the number, from bubble A
        "print": {
            "headerBox": HEADER_BOX,
            "nameBox": NAME_BOX,
            "infoAt": INFO_AT,
            "idLabelAt": ID_LABEL_AT,
            "idBoxesY": ID_BOXES_Y,
        },
    }


def main() -> None:
    out = Path(__file__).with_name("sheet-layouts.json")
    out.write_text(json.dumps(build(), indent=1) + "\n", encoding="utf-8", newline="\n")
    print(f"wrote {out.name}")
    assert encode(4407, 1) == encode(4407, 1) and encode(4407, 0) != encode(4407, 1)


if __name__ == "__main__":
    main()
