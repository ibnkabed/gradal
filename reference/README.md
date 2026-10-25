# Reference implementations (Python)

Gradal is an iPhone app. These Python files are the reference each Swift part was ported from, and the
continuous-integration checks compare the two:

- `omr.py`: the sheet reader (`ios/Gradal/OMR/SheetReader.swift` is a line-by-line port).
- `sheet_layout.py`: where the questions sit on the answer sheet (`ios/Gradal/Sheet/SheetGeometry.swift`).
- `sheets.py`, `paper.py`: the answer sheet and the question paper as printed.
- `exam_maker.py`, `ai.py`, `books.py`: writing questions from a PDF with the AI providers.
- `students_import.py`, `roster.py`: class lists from Noor's Excel export or pasted names.

They are not an app and are not needed to use Gradal.
