# Gradal: data and the answer sheet

Everything lives on the iPhone, in `Application Support/Gradal/`:

- `store.json`: classes, students, quizzes, scans, papers (questions written in Gradal), books, settings;
- `books/<id>.pdf`: the textbooks the teacher added (id = first 8 bytes of the file's SHA-256, hex);
- `scans/<id>.jpg`: each scanned sheet, straightened (4 px/mm grayscale);
- `prints/<quizId>/`: the printable PDFs, a cache rebuilt when the quiz, its classes or the settings change.

A backup is a zip of `store.json`, `books/` and `scans/` (Settings → «انسخ بياناتك احتياطًا»). AI keys stay in the
iPhone Keychain and are not in backups.

## Answer sheet

`shared/sheet-layouts.json` (built by `shared/build_layouts.py`, read its docstring) describes the fixed parts of
the paper: the header strip (school lines, the quiz's lines, an optional logo) — nobody reads it; four corner
markers + an orientation mark; a barcode column down the left edge carrying the **quiz code** (1000–9999,
CRC-6 protected; its 2-bit "version" field is always 0), so the phone knows the quiz from the sheet alone; the
student's **3-digit ID** (bubbles 0–9 per digit); and the questions (**5 to 60**), choices A–D (shown أ ب ج د on
Arabic quizzes), bubbles 3.6 mm.

**Question area.** Framed boxes, one per section, in as few balanced columns as fit; the row pitch stretches
so the sheet has no large empty space. An Arabic quiz reads right to left: the first column on the right, the
number at a box's right edge, choice أ (index 0) the rightmost bubble. `ios/Gradal/Sheet/SheetGeometry.swift`
(a port of `reference/sheet_layout.py`, checked against it in CI) computes the positions whenever a quiz is saved
and stores them in the quiz as `sheet` (`version` 4, `pitch`, `rtl`, `questionBubbles[question][choice] = [x, y]`
in millimetres on A4, `columns` with their boxes). The scanner reads the bubbles by choice index, so it is the same
for both directions. The reader (`ios/Gradal/OMR/SheetReader.swift`) is a line-by-line port of `reference/omr.py`.

## Records

```jsonc
// Class. prefix 1–9: the first digit of its students' IDs, unique among the classes not archived.
{ "id": "...", "name": "أول متوسط 1", "prefix": 1, "archived": "2025-2026 — 2026-06-20" }
// Student. gradalId: class prefix + 2-digit serial, fixed for good. order: place in the imported list.
{ "id": "...", "classIds": ["..."], "name": "...", "gradalId": "101", "nationalId": "...", "order": 1, "active": true }
// Quiz. key: accepted letters per question ("B", "AC"; "" = not counted). language "ar" | "en".
{ "id": "...", "code": 4407, "name": "...", "date": "2026-10-25", "classIds": ["..."], "language": "ar",
  "questionCount": 20, "sheet": { ... }, "key": ["A", "C", ...], "points": [1, ...],
  "sections": [ { "name": "اختيار من متعدد", "from": 1, "to": 15 }, { "name": "صح أو خطأ", "from": 16, "to": 20 } ],
  "header": { "subject": "العلوم", "title": "...", "grade": "...", "extra": "المعلم: ..." }, "paperId": "..." }
// Scan. answers: "" blank, "BD" more than one (never earns). studentId resolved by gradalId, else null.
{ "id": "...", "quizId": "...", "studentId": "..." | null, "gradalId": "101", "answers": ["A", "", "BD"],
  "earned": 12, "possible": 17, "scannedAt": "...", "edited": false, "hasImage": true }
// Paper. The questions written by the AI (or added by the teacher); a draft until approved (quizId set).
{ "id": "...", "createdAt": "...", "request": { "name", "subject", "grade", "language", "classIds", "bookId",
  "pageFrom", "pageTo", "mcq", "tf", "notes" }, "questions": [ { "kind": "mcq", "text": "...", "options": [4], "answer": 0 },
  { "kind": "tf", "text": "...", "options": [], "answer": 0 } ], "providers": ["gemini"], "quizId": null }
```

**Grading.** For question i: key[i] == "" → not counted; else possible += points[i]; earned += points[i] when the
answer is exactly one letter and it is in key[i]. The newest scan per student counts.

A true/false question is answered with bubble A (صح / True) or B (خطأ / False).

## Record sheet (Excel)

One worksheet per class of the quiz (right to left): `ID`, `اسم الطالب`, `#`, `1` … `N`, one column per section
(`=SUM()` over its questions), `المجموع` (`=C<r>`); one row per active student in list order, with the points
earned on each question; a student with no scan keeps an empty row.

## Class lists

From the teacher's Excel export of a class in Noor (xlsx, or the HTML table Noor saves as .xls), a CSV, or pasted
names. Classes match by name (new class → next free prefix); students by national ID, else by normalised name
within the class (no spaces, أ/إ/آ→ا, ة→ه, ى→ي); a new student → the next free serial; everyone's order refreshed;
students missing from a re-import of their class become inactive. **A new school year** archives every current
class and its students (kept for the old results); prefixes and serials are free again.
