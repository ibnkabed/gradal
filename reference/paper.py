"""The question paper and its answer model, as HTML printed to PDF by Edge (sheets.html_to_pdf).

    paper_html(quiz, paper, settings, mark=False) -> the page: the school header, the student's name line,
        the instructions, then the questions (multiple choice with four options in a row, true/false with
        the two words); mark=True is the answer model: the right option bold and ticked.

Arabic quizzes read right to left with options أ ب ج د; English quizzes left to right with A B C D. The
students answer on the answer sheet, so the paper says so at the top.
"""

from __future__ import annotations

import html

import sheets

CSS = """
@page { size: A4; margin: 12mm 12mm 14mm }
* { box-sizing: border-box }
body { margin: 0; font: 11.5pt/1.45 'Segoe UI', Tahoma, Arial, sans-serif; color: #000 }
table.head { width: 100%; border: 1.2px solid #000; border-collapse: collapse; margin-bottom: 4mm }
table.head td { vertical-align: middle; padding: 2mm 3mm; font-size: 10pt; line-height: 1.5 }
table.head td.mid { text-align: center; width: 34% }
table.head td.mid img { max-height: 18mm; max-width: 40mm }
.who { display: flex; gap: 6mm; margin-bottom: 3mm; font-size: 10.5pt }
.who span { flex: 1; border-bottom: 1px dotted #000; padding-bottom: 1mm }
.note { font-size: 10pt; margin: 0 0 3mm; padding: 1.5mm 3mm; border: 1px solid #000; border-radius: 2mm; background: #f2f2f2 }
h2 { font-size: 11.5pt; margin: 4mm 0 2mm; padding: 1mm 2mm; background: #e6e6e6; border-radius: 1.5mm }
.q { break-inside: avoid; page-break-inside: avoid; padding: 1.6mm 0 1.8mm; border-bottom: 1px solid #ddd }
.q .t { font-weight: 600 }
.q .n { display: inline-block; min-width: 7mm; font-weight: 700 }
.opts { display: grid; grid-template-columns: repeat(4, 1fr); gap: 1mm 4mm; margin-top: 1mm; padding-inline-start: 7mm }
.opts.tf { grid-template-columns: repeat(4, 1fr) }
.opt b { margin-inline-end: 1.5mm }
.opt.right { font-weight: 700; text-decoration: underline }
.opt.right::after { content: " ✔" }
"""

TEXT = {
    "ar": {"name": "اسم الطالب:", "class": "الفصل:", "note": "أجب في ورقة الإجابة بتظليل دائرة واحدة لكل سؤال.",
           "model": "نموذج الإجابة", "letters": ["أ", "ب", "ج", "د"], "good": "انتهت الأسئلة، بالتوفيق"},
    "en": {"name": "Student's name:", "class": "Class:", "note": "Answer on the answer sheet: fill one circle per question.",
           "model": "Answer key", "letters": ["A", "B", "C", "D"], "good": "End of the questions. Good luck!"},
}
TF = {"ar": ["صح", "خطأ"], "en": ["True", "False"]}


def _e(s) -> str:
    return html.escape(str(s or ""))


def header_html(settings: dict, quiz: dict) -> str:
    school, mine = sheets.header_lines(settings, quiz)
    logo = settings.get("logo") if str(settings.get("logo") or "").startswith("data:image/") else ""
    right = "<br>".join((f"<b>{_e(t)}</b>" if i == 0 else _e(t)) for i, t in enumerate(school))
    left = "<br>".join((f"<b>{_e(t)}</b>" if i == 0 else _e(t)) for i, t in enumerate(mine))
    mid = f'<img src="{logo}" alt="">' if logo else ""
    # the header is always laid out right-to-left (school lines on the right), like the answer sheet
    return (f'<table class="head" dir="rtl"><tr><td style="text-align:right">{right}</td><td class="mid">{mid}</td>'
            f'<td style="text-align:left" dir="auto">{left}</td></tr></table>')


def paper_html(quiz: dict, paper: dict, settings: dict, mark: bool = False) -> str:
    lang = "ar" if quiz.get("language") == "ar" else "en"
    T = TEXT[lang]
    out = [f'<!DOCTYPE html><html lang="{lang}" dir="{"rtl" if lang == "ar" else "ltr"}"><head><meta charset="utf-8">'
           f"<title>{_e(quiz.get('name'))}</title><style>{CSS}</style></head><body>", header_html(settings, quiz)]
    if mark:
        out.append(f'<div class="note"><b>{T["model"]}</b> — {_e(quiz.get("name"))} ({quiz.get("code")})</div>')
    else:
        out.append(f'<div class="who"><span>{T["name"]}</span><span style="flex:.45">{T["class"]}</span></div>')
        out.append(f'<div class="note">{T["note"]}</div>')
    n = 0
    sections = {s["from"]: s["name"] for s in quiz.get("sections") or []}
    for q in paper["questions"]:
        n += 1
        if n in sections:
            out.append(f"<h2>{_e(sections[n])}</h2>")
        if q["type"] == "mcq":
            opts = q["options"]
        else:
            opts = TF[lang]
        right = q["answer"] if q["type"] == "mcq" else (0 if q["answer"] else 1)
        cells = "".join(f'<div class="opt{" right" if mark and i == right else ""}"><b>{T["letters"][i]})</b>{_e(o)}</div>'
                        for i, o in enumerate(opts))
        out.append(f'<div class="q"><div class="t"><span class="n">{n}.</span> {_e(q["text"])}</div>'
                   f'<div class="opts{" tf" if q["type"] == "tf" else ""}">{cells}</div></div>')
    out.append(f'<p style="text-align:center;margin-top:5mm;font-weight:600">{T["good"]}</p>')
    out.append("</body></html>")
    return "".join(out)
