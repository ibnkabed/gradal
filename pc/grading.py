"""Grading, statistics and item analysis (shared/PROTOCOL.md, «Grading»)."""

from __future__ import annotations

import math
import statistics

from store import parse_time

CHOICES = "ABCD"


def key_for(quiz: dict, version) -> list[str]:
    keys = quiz.get("keys") or [[]]
    v = version if isinstance(version, int) and 0 <= version < len(keys) else 0
    return keys[v] if keys else []


def points_for(quiz: dict, i: int) -> float:
    pts = quiz.get("points") or []
    p = pts[i] if i < len(pts) else 1
    return p if isinstance(p, (int, float)) and p >= 0 else 1


def is_correct(key: str, answer: str) -> bool:
    return bool(key) and isinstance(answer, str) and len(answer) == 1 and answer in key


def grade(quiz: dict, answers: list, version) -> tuple[float, float]:
    """(earned, possible). Key '' = dropped; multi-letter answers never earn."""
    key = key_for(quiz, version)
    n = int(quiz.get("questionCount") or len(key))
    earned = possible = 0.0
    for i in range(n):
        k = key[i] if i < len(key) else ""
        if not k:
            continue
        p = points_for(quiz, i)
        possible += p
        a = answers[i] if i < len(answers) else ""
        if is_correct(k, a):
            earned += p
    return _num(earned), _num(possible)


def _num(x: float):
    return int(x) if float(x).is_integer() else round(x, 3)


def regrade(quiz: dict, scan: dict) -> bool:
    """Updates earned/possible in place; True when something changed."""
    e, p = grade(quiz, scan.get("answers") or [], scan.get("version"))
    if scan.get("earned") != e or scan.get("possible") != p:
        scan["earned"], scan["possible"] = e, p
        return True
    return False


def percent(scan: dict) -> float:
    p = scan.get("possible") or 0
    return round(100.0 * (scan.get("earned") or 0) / p, 2) if p else 0.0


def counted_scans(scans: list[dict]) -> list[dict]:
    """Newest non-deleted scan per student, plus every scan whose student is unknown."""
    best: dict[str, dict] = {}
    unknown = []
    for s in scans:
        if s.get("deleted"):
            continue
        sid = s.get("studentId")
        if not sid:
            unknown.append(s)
            continue
        cur = best.get(sid)
        if cur is None or parse_time(s.get("scannedAt")) > parse_time(cur.get("scannedAt")):
            best[sid] = s
    return list(best.values()) + unknown


def stats(scans: list[dict]) -> dict:
    pcts = [percent(s) for s in scans]
    if not pcts:
        return {"count": 0, "mean": None, "median": None, "high": None, "low": None, "stdev": None,
                "histogram": [0] * 10, "meanPoints": None}
    hist = [0] * 10
    for p in pcts:
        hist[min(9, int(p // 10))] += 1
    return {
        "count": len(pcts),
        "mean": round(statistics.fmean(pcts), 2),
        "median": round(statistics.median(pcts), 2),
        "high": max(pcts),
        "low": min(pcts),
        "stdev": round(statistics.pstdev(pcts), 2) if len(pcts) > 1 else 0.0,
        "histogram": hist,   # 0-9, 10-19, ... 90-100
        "meanPoints": round(statistics.fmean([s.get("earned") or 0 for s in scans]), 2),
    }


def item_analysis(quiz: dict, scans: list[dict]) -> list[dict]:
    """Per question: share correct, counts per letter, discrimination (top 27% minus bottom 27%)."""
    n = int(quiz.get("questionCount") or 0)
    ranked = sorted(scans, key=percent)
    group = max(1, int(round(len(ranked) * 0.27))) if ranked else 0
    low, high = ranked[:group], ranked[-group:] if group else []
    out = []
    for i in range(n):
        counts = {c: 0 for c in CHOICES}
        counts["blank"] = counts["multi"] = 0
        correct = counted = 0
        for s in scans:
            a = (s.get("answers") or [""] * n)[i] if i < len(s.get("answers") or []) else ""
            if not a:
                counts["blank"] += 1
            elif len(a) > 1:
                counts["multi"] += 1
            elif a in counts:
                counts[a] += 1
            k = key_for(quiz, s.get("version"))
            k = k[i] if i < len(k) else ""
            if k:
                counted += 1
                correct += is_correct(k, a)
        primary = key_for(quiz, 0)

        def share(group_scans):
            hits = tot = 0
            for s in group_scans:
                k = key_for(quiz, s.get("version"))
                k = k[i] if i < len(k) else ""
                if k:
                    tot += 1
                    ans = s.get("answers") or []
                    hits += is_correct(k, ans[i] if i < len(ans) else "")
            return hits / tot if tot else None

        top, bottom = share(high), share(low)
        out.append({
            "question": i + 1,
            "key": primary[i] if i < len(primary) else "",
            "percentCorrect": round(100.0 * correct / counted, 1) if counted else None,
            "counts": counts,
            "discrimination": round(top - bottom, 2) if top is not None and bottom is not None and len(scans) >= 2 else None,
        })
    return out


def histogram_labels() -> list[str]:
    return [f"{i * 10}–{i * 10 + 9}" if i < 9 else "90–100" for i in range(10)]


def safe_round(x):
    return None if x is None or (isinstance(x, float) and math.isnan(x)) else x
