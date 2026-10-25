# Gradal: data model and phone ↔ PC protocol

The contract between the iPhone app (`ios/`) and the PC app (`pc/`). Change it here first, then both
sides. All JSON is UTF-8, keys camelCase, times ISO-8601 UTC (`2026-10-21T08:30:00Z`), ids lowercase
UUID strings unless stated.

## Answer sheet

`shared/sheet-layouts.json` (built by `shared/build_layouts.py`, read its docstring) describes the fixed
parts of the paper:

- top: the school header (school lines, the quiz's lines, an optional logo) — nobody reads it;
- under it the frame: four corner markers + an orientation mark, and a barcode column down the left
  edge carrying the **quiz code** (1000–9999), CRC-6 protected. The phone identifies the quiz and its
  key from the barcode alone: the teacher never picks a quiz before scanning;
- the student's **3-digit ID** (bubbles 0–9 per digit) and the questions (**5 to 60**), choices A–D
  (shown أ ب ج د on Arabic quizzes), small bubbles (3.6 mm).

**Question area.** Questions sit in framed boxes, one per section (`quiz.sections`, optional), in as few
balanced columns as fit; the row pitch stretches so the sheet has no large empty space. An Arabic quiz
(`language: "ar"`) reads right to left: the first column is on the right, the number at a box's right
edge, and choice أ (index 0) is the rightmost bubble. The positions therefore depend on the quiz: the PC
computes them with `pc/sheet_layout.py` whenever it saves a quiz and stores them in the quiz as `sheet`
(`{"version": 4, "questionBubbles": [[[x,y]×4] per question], "pitch": p, "columns": [...], "rtl": bool}`,
millimetres on A4). The phone never computes positions: it reads them from `quiz.sheet.questionBubbles`,
indexed by choice, so the reader is the same for both directions.

The reader is `pc/omr.py` (`read_sheet(gray, layout, question_count, question_bubbles)` → quiz code,
version, student id, answers); the Swift reader is a line-by-line port with the same constants. A sheet
whose barcode fails its CRC is not read. The barcode's 2-bit "version" field is always 0.

Personalised sheets (the normal case): one sheet per student of a class, in class-list order, with the
name printed and the ID bubbles pre-filled solid black. Blank sheets (ID left to the student) can be
printed too.

## Records

```jsonc
// Class. prefix: 1–9, the first digit of its students' IDs, unique among the classes that are not
// archived. archived: absent, or the label of the school year it was closed in.
{ "id": "...", "name": "أول متوسط 1", "prefix": 1, "archived": "2025-2026 — 2026-06-20", "updatedAt": "...", "deleted": false }

// Student. gradalId: exactly 3 digits = class prefix + 2-digit serial (01–99), fixed for the student.
// order: position in the imported class list. active: false once a re-import no longer lists him.
// nationalId (optional, never printed): matches re-imports.
{ "id": "...", "classIds": ["..."], "name": "...", "gradalId": "101", "order": 1, "active": true,
  "updatedAt": "...", "deleted": false }

// Quiz. code: unique 1000–9999, printed in the barcode. keys: exactly one key, a list of strings, one per
// question: accepted letters ("B", or "AC" = A or C both accepted), "" = question dropped (not counted).
// points: per question (0.5–2), default 1. language: "ar" | "en" (absent = "en"). header: the quiz's own
// header lines. sections: named question ranges (record-sheet columns and boxes on the sheet).
{ "id": "...", "code": 4407, "name": "اختبار الفترة الأولى", "date": "2026-10-21", "classIds": ["..."],
  "language": "ar", "questionCount": 20, "sheet": { "version": 4, ... },
  "keys": [["A","C","B", ...]], "points": [1,1,1, ...],
  "sections": [ { "name": "اختيار من متعدد", "from": 1, "to": 15 }, { "name": "صح أو خطأ", "from": 16, "to": 20 } ],
  "header": { "subject": "العلوم", "title": "اختبار الفترة الأولى", "grade": "الأول المتوسط", "extra": "المعلم: ..." },
  "updatedAt": "...", "deleted": false }

// Scan (one graded paper). quizId comes from the barcode code; answers per question ("" blank,
// "BD" = more than one, never earns points); studentId resolved by gradalId, else null ("unknown ID").
{ "id": "...", "quizId": "...", "studentId": "..." | null, "gradalId": "101", "version": 0,
  "answers": ["A","","BD", ...], "earned": 12, "possible": 17,
  "scannedAt": "...", "deviceId": "...", "edited": false, "hasImage": true, "updatedAt": "...", "deleted": false }
```

Grading (both sides, identical): k = keys[0]. For question i: k[i] == "" → not counted; else possible +=
points[i]; earned += points[i] if answers[i] is exactly one letter and it is in k[i]. A scan whose code
matches no quiz is kept aside on the phone until the quiz arrives.

Merge rule everywhere: a record replaces another with the same id only if its `updatedAt` is newer.
Deleting sets `deleted: true` (tombstone) and bumps `updatedAt`. Two scans of the same quiz + student are
both kept; the newest non-deleted one counts.

Quizzes are made on the PC only (from a book with AI, or with a ready key); the phone never creates or
edits them. The questions' texts stay on the PC (`papers` in its data), never in the quiz record.

## Record sheet (Excel)

Built identically by the phone (shared from the share sheet) and the PC (saved to
`<data>\السجلات\<quiz name> (<code>).xlsx`, rewritten after every sync):

- one worksheet per class of the quiz, named after the class, right-to-left sheet view;
- row 1: `ID`, `اسم الطالب`, `#`, `1` … `N`, then one column per section, then `المجموع`;
- one row per active student of the class in class-list order: gradalId (number), name, total earned,
  the points earned on each question (0 for wrong/blank), each section as `=SUM(...)` over its questions,
  and `المجموع` as `=C<r>`. A student with no scan keeps an empty row.

## Class lists

Imported on the PC from the teacher's Excel export of a class in Noor (xlsx, xls, or the HTML table Noor
saves as .xls), a CSV, or pasted names (`pc/students_import.py`). Merge: classes by name (new class → next
free prefix); students by national ID, else by normalised name within the class (strip spaces, unify
أ/إ/آ→ا, ة→ه, ى→ي); new student → next free serial in that class; everyone's `order` refreshed; students
missing from a re-import of their class → `active: false`.

**New school year.** The PC archives every current class and its students (`archived` = the year label,
`active: false`, `archivedActive`), never deleting them; prefixes and serials are free again. The phone
never sees archived records (they are left out of `/m/snapshot`).

## Network

The PC listens on `0.0.0.0:7797` (HTTP, local network only). The phone finds it by sweeping its own /24
(`.1`–`.254`, batches of 32, 1.5 s timeout) for `GET /hello`, remembers the address, and sweeps again only
when the remembered one stops answering.

Endpoints for the PC's own window (`/api/...`) answer only to `127.0.0.1` (Host checked, and
`X-Gradal: 1` on every non-GET). Phone endpoints (`/m/...`) need `Authorization: Bearer <token>` except
`/hello` and the two pairing calls.

| Method | Path | Body → Reply |
|---|---|---|
| GET | `/hello` | → `{ "app": "gradal-public", "protocol": 1, "pcName": "..." }` |
| POST | `/m/pair/start` | `{ "deviceName": "iPhone" }` → `{ "ok": true }`; the PC window shows a 4-digit PIN for 2 minutes |
| POST | `/m/pair` | `{ "pin": "4821", "deviceId": "...", "deviceName": "iPhone" }` → `{ "token": "..." }` (401 on wrong / expired PIN; 5 wrong tries cancel the PIN) |
| GET | `/m/snapshot` | → `{ "serverTime": "...", "classes": [...], "students": [...], "quizzes": [...] }` (deleted records included; archived left out) |
| POST | `/m/quizzes` | → `{ "accepted": 0 }` (kept for older phones; quizzes are made on the PC) |
| POST | `/m/scans` | `{ "scans": [ { ...scan, "imageJpegBase64": "..." | null } ] }` → `{ "accepted": ["id", ...] }`; at most 10 per request; the image is the straightened sheet (4 px/mm grayscale JPEG) |
| GET | `/m/scans?quizId=...` | → `{ "scans": [...] }` without images |
| GET | `/m/prints?quizId=...` | → `{ "files": [ { "id", "title", "pages", "bytes", "updatedAt" } ] }` — the quiz's papers as PDFs |
| GET | `/m/print?quizId=...&id=...` | → the PDF (`application/pdf`); 404 for an id not listed |

The phone checks `app` and `protocol` from `/hello` and refuses to sync with a different number. The PC
keeps only a hash of each token; the phone keeps its token in the Keychain and forgets it on 401.

**Printing from the phone.** The papers of a quiz (`pc/prints.py`): `paper` (question paper) and `model`
(answer model) when the questions were written in Gradal, `key` (the answer sheet with the right bubbles
filled), `class-<classId>` (the personalised sheets of each of its classes) and `blank` (one blank sheet;
copies are chosen in the print dialog). `updatedAt` changes only when a file was rebuilt. On each sync the
phone downloads the papers of the quizzes dated in the last 60 days (and the one on screen) whose
`updatedAt` changed, keeps them, and prints them with AirPrint without the PC.

Sync order on the phone: push pending scans (oldest first, 10 at a time) → pull snapshot → pull scans for
the open quiz (or the three newest) → pull the papers to print. The phone works fully offline; scans wait
in its queue until the PC is reachable.
