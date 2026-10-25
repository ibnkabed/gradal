"""The teacher's books: any subject's PDF (student book, teacher's guide, worksheet), kept in the data folder.

    add(store, folder, name, data)      -> the book record {id, name, pages, size, addedAt}
    remove(store, folder, book_id)
    pages_text(folder, book, a, b)      -> (text of pages a..b, readable): the text the AI writes from
    pages_pdf(folder, book, a, b)       -> those pages as a small PDF (for Gemini, when the text is unreadable)

Arabic PDFs often store their text in presentation forms or in visual (reversed) order; the text is
normalised (NFKC) and, when most words read backwards, each line is turned around. A page with almost no
text is a scanned image: then only Gemini can read the book (ai.gemini_pdf).
"""

from __future__ import annotations

import hashlib
import re
import unicodedata
from pathlib import Path

from store import now_iso

MAX_PAGES = 30          # pages per exam: enough for a unit, small enough for every provider
MIN_CHARS_PER_PAGE = 120
COMMON_AR = {"في", "من", "على", "إلى", "الى", "عن", "أن", "ان", "التي", "الذي", "هذا", "هذه", "مع", "كان", "لا", "ما", "هو", "هي"}
ARABIC = re.compile(r"[؀-ۿ]")


class BookError(ValueError):
    """A message for the teacher, in Arabic."""


def book_path(folder: Path, book: dict) -> Path:
    return Path(folder) / "books" / f"{book['id']}.pdf"


def add(store, folder: Path, name: str, data: bytes) -> dict:
    import pymupdf
    if data[:5] != b"%PDF-":
        raise BookError("الملف ليس PDF")
    try:
        with pymupdf.open(stream=data, filetype="pdf") as doc:
            pages = doc.page_count
    except Exception:  # noqa: BLE001
        raise BookError("تعذّر فتح ملف PDF") from None
    bid = hashlib.sha1(data).hexdigest()[:16]
    with store.lock:
        existing = next((b for b in store.data["books"] if b["id"] == bid), None)
        if existing:
            return existing
        path = Path(folder) / "books" / f"{bid}.pdf"
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
        book = {"id": bid, "name": (name or "كتاب").strip()[:120], "pages": pages, "size": len(data), "addedAt": now_iso()}
        store.data["books"].append(book)
        store.save()
    return book


def remove(store, folder: Path, book_id: str) -> None:
    with store.lock:
        book = next((b for b in store.data["books"] if b["id"] == book_id), None)
        if not book:
            raise BookError("الكتاب غير موجود")
        store.data["books"].remove(book)
        store.save()
    book_path(folder, book).unlink(missing_ok=True)


def _check_range(book: dict, a: int, b: int) -> tuple[int, int]:
    try:
        a, b = int(a), int(b)
    except (TypeError, ValueError):
        raise BookError("اكتب رقم الصفحة الأولى والأخيرة") from None
    if not 1 <= a <= b <= book["pages"]:
        raise BookError(f"الصفحات من 1 إلى {book['pages']}، والأولى قبل الأخيرة")
    if b - a + 1 > MAX_PAGES:
        raise BookError(f"اختر {MAX_PAGES} صفحة على الأكثر للاختبار الواحد")
    return a, b


def fix_arabic(text: str) -> str:
    """Presentation forms -> letters; lines stored backwards (visual order) -> turned around."""
    text = unicodedata.normalize("NFKC", text)
    words = re.findall(r"[؀-ۿ]+", text)
    forward = sum(1 for w in words if w in COMMON_AR)
    backward = sum(1 for w in words if w[::-1] in COMMON_AR)
    if backward > forward * 2 and backward >= 3:
        text = "\n".join(line[::-1] for line in text.splitlines())
    return text


def pages_text(folder: Path, book: dict, a, b) -> tuple[str, bool]:
    import pymupdf
    a, b = _check_range(book, a, b)
    chunks = []
    with pymupdf.open(str(book_path(folder, book))) as doc:
        for i in range(a - 1, b):
            chunks.append(doc[i].get_text("text"))   # the PDF's own order: sorting by x breaks Arabic lines
    text = "\n".join(chunks)
    if ARABIC.search(text):
        text = fix_arabic(text)
    text = re.sub(r"[ \t]+", " ", re.sub(r"\n{3,}", "\n\n", text)).strip()
    readable = len(text) >= MIN_CHARS_PER_PAGE * (b - a + 1) * 0.5
    return text, readable


def pages_pdf(folder: Path, book: dict, a, b) -> bytes:
    import pymupdf
    a, b = _check_range(book, a, b)
    with pymupdf.open(str(book_path(folder, book))) as doc:
        out = pymupdf.open()
        out.insert_pdf(doc, from_page=a - 1, to_page=b - 1)
        return out.tobytes(garbage=3, deflate=True)
