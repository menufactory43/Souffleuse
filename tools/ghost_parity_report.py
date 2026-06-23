#!/usr/bin/env python3
"""Compare ghost speed and precision from Souffleuse/Cotypist JSONL traces.

Inputs:
  - SouffleuseParityEval JSONL produced with PARITY_JSONL=...
  - SouffleuseCotypistObserve JSONL produced with observe --phrase ...

The report mirrors the important metrics from SouffleuseParityEval:
KTC (keystrokes to correct word), saved keystrokes, stability, coverage,
and latency per typed character. Cotypist rows with source="none" are counted
at timeout_ms so misses do not disappear from latency percentiles.
"""

import argparse
import json
import statistics
from collections import Counter, defaultdict


def load_jsonl(path):
    rows = []
    with open(path, encoding="utf-8") as f:
        for line_no, line in enumerate(f, 1):
            line = line.strip()
            if not line:
                continue
            try:
                rows.append(json.loads(line))
            except json.JSONDecodeError as exc:
                raise SystemExit(f"{path}:{line_no}: invalid JSON: {exc}") from exc
    return rows


def is_word_char(ch):
    return ch.isalpha() or ch.isdigit() or ch in ("'", "\u2019", "-")


def word_ranges(chars):
    out = []
    i = 0
    while i < len(chars):
        if is_word_char(chars[i]):
            start = i
            while i < len(chars) and is_word_char(chars[i]):
                i += 1
            out.append((start, i - start))
        else:
            i += 1
    return out


def is_sentence_initial(chars, word_start):
    i = word_start - 1
    while i >= 0 and chars[i] in (" ", "\t"):
        i -= 1
    return i < 0 or chars[i] in ".!?"


def common_prefix_len(a, b):
    n = 0
    while n < len(a) and n < len(b) and a[n] == b[n]:
        n += 1
    return n


def percentile(values, q):
    if not values:
        return 0
    values = sorted(values)
    return values[min(len(values) - 1, int(len(values) * q))]


def mean(values):
    return int(sum(values) / len(values)) if values else 0


def pct(a, b):
    return "-" if b == 0 else f"{100.0 * a / b:.0f}%"


def pad(value, width):
    value = str(value)
    return value + " " * max(0, width - len(value))


def step_latency(row):
    if isinstance(row.get("ms"), int):
        return row["ms"]
    if isinstance(row.get("latency_ms"), int):
        return row["latency_ms"]
    if isinstance(row.get("wait_ms"), int):
        return row["wait_ms"]
    if isinstance(row.get("timeout_ms"), int):
        return row["timeout_ms"]
    return 0


def step_index(row):
    if isinstance(row.get("i"), int):
        return row["i"]
    if isinstance(row.get("prefix_len"), int):
        return row["prefix_len"]
    return len(row.get("prefix", ""))


def step_boundary(row):
    if isinstance(row.get("boundary"), bool):
        return row["boundary"]
    prefix = row.get("prefix", "")
    return not prefix or prefix[-1].isspace()


def load_runs(paths):
    runs = {}
    for path in paths:
        for row in load_jsonl(path):
            target = row.get("target")
            if not target:
                raise SystemExit(
                    f"{path}: row lacks target. Re-run SouffleuseParityEval/CotypistObserve "
                    "after this change, or add target to the JSONL."
                )
            engine = row.get("engine") or "cotypist"
            sentence = int(row.get("sentence", 0))
            key = (engine, target, sentence)
            run = runs.setdefault(key, {
                "engine": engine,
                "target": target,
                "steps": {},
                "wait_total": Counter(),
                "wait_visible": Counter(),
                "source_counts": Counter(),
            })
            idx = step_index(row)
            if idx <= 0:
                continue
            source = row.get("source", "")
            if source:
                run["source_counts"][source] += 1
            ghost = row.get("ghost", "") or row.get("inserted", "")
            if ghost == "\t":
                ghost = ""
            if isinstance(row.get("wait_ms"), int):
                wait = row["wait_ms"]
                run["wait_total"][wait] += 1
                if ghost:
                    run["wait_visible"][wait] += 1
            step = {
                "ghost": ghost,
                "ms": step_latency(row),
                "g2": bool(row.get("g2", False)),
                "boundary": step_boundary(row),
                "kind": row.get("kind", ""),
                "source": source,
            }
            prior = run["steps"].get(idx)
            if prior is None:
                run["steps"][idx] = step
            elif step["ghost"] and (not prior["ghost"] or step["ms"] < prior["ms"]):
                run["steps"][idx] = step
    return list(runs.values())


def score(runs, engine):
    sc = defaultdict(int)
    sc["engine"] = engine
    sc["ktc_hit_at"] = {1: 0, 2: 0, 3: 0, 4: 0}
    sc["ktc_letters_needed"] = []
    sc["lat_all"] = []
    sc["lat_visible"] = []
    sc["lat_mid"] = []
    sc["lat_boundary"] = []
    sc["source_counts"] = Counter()
    sc["wait_total"] = Counter()
    sc["wait_visible"] = Counter()

    for run in runs:
        target = run["target"]
        chars = list(target)
        steps = run["steps"]
        n = len(chars)
        sc["total_chars"] += n
        sc["source_counts"].update(run["source_counts"])
        sc["wait_total"].update(run["wait_total"])
        sc["wait_visible"].update(run["wait_visible"])

        for i in range(1, n):
            st = steps.get(i)
            if not st:
                continue
            sc["steps_total"] += 1
            if st["g2"]:
                sc["steps_g2"] += 1
            if st["ghost"]:
                sc["steps_non_empty"] += 1
                sc["lat_visible"].append(st["ms"])
            sc["lat_all"].append(st["ms"])
            if st["boundary"]:
                sc["lat_boundary"].append(st["ms"])
            else:
                sc["lat_mid"].append(st["ms"])

        for start, length in word_ranges(chars):
            initial = is_sentence_initial(chars, start)
            if not initial and start > 0 and chars[start - 1] == " " and length >= 3:
                st = steps.get(start)
                if st:
                    sc["hit_at0_total"] += 1
                    truth = chars[start:]
                    if common_prefix_len(list(st["ghost"]), truth) >= length:
                        sc["hit_at0_words"] += 1
            if length < 3 or initial:
                continue
            sc["ktc_words"] += 1
            first_hit = None
            correct_at = {}
            for k in range(1, length):
                i = start + k
                st = steps.get(i)
                if not st:
                    continue
                truth = chars[i:]
                ok = bool(st["ghost"]) and common_prefix_len(list(st["ghost"]), truth) >= (length - k)
                correct_at[k] = ok
                if ok and first_hit is None:
                    first_hit = k
            if first_hit is None:
                sc["ktc_never"] += 1
            else:
                sc["ktc_letters_needed"].append(first_hit)
                for bucket in (1, 2, 3, 4):
                    if first_hit <= bucket:
                        sc["ktc_hit_at"][bucket] += 1
            for k in range(1, length - 1):
                if correct_at.get(k) is True and (k + 1) in correct_at:
                    sc["hold_pairs"] += 1
                    if correct_at[k + 1] is True:
                        sc["hold_kept"] += 1

        for i in range(1, n - 1):
            a = steps.get(i)
            b = steps.get(i + 1)
            if not a or not b or not a["ghost"]:
                continue
            typed = chars[i]
            if a["ghost"][0] != typed:
                continue
            expected = a["ghost"][1:]
            if not expected:
                continue
            sc["slide_pairs"] += 1
            if b["ghost"] and (b["ghost"].startswith(expected) or expected.startswith(b["ghost"])):
                sc["slide_coherent"] += 1

        for mode in ("full", "word"):
            i = 1
            saved = 0
            accepts = 0
            while i < n:
                st = steps.get(i)
                if not st or not st["ghost"]:
                    i += 1
                    continue
                ghost = list(st["ghost"])
                truth = chars[i:]
                match = common_prefix_len(ghost, truth)
                accept_len = 0
                if mode == "full":
                    if match == len(ghost):
                        accept_len = match
                else:
                    j = match
                    while j > 0:
                        if j == len(ghost) or ghost[j] == " ":
                            break
                        j -= 1
                    accept_len = j
                if accept_len >= 2:
                    saved += accept_len - 1
                    accepts += 1
                    i += accept_len
                else:
                    i += 1
            if mode == "full":
                sc["saved_full"] += saved
                sc["accepts_full"] += accepts
            else:
                sc["saved_word"] += saved
                sc["accepts_word"] += accepts

    return sc


def format_lat(values):
    return f"{mean(values)} / {percentile(values, 0.5)}"


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("jsonl", nargs="+", help="JSONL trace(s) to compare")
    args = parser.parse_args()

    runs = load_runs(args.jsonl)
    by_engine = defaultdict(list)
    for run in runs:
        by_engine[run["engine"]].append(run)
    cards = [score(engine_runs, engine) for engine, engine_runs in sorted(by_engine.items())]

    print(f"Ghost parity report - {len(runs)} run(s), {sum(c['steps_total'] for c in cards)} judged steps")
    labels = [c["engine"] for c in cards]

    def row(label, values):
        print("  " + pad(label, 44) + "".join(pad(v, 18) for v in values))

    row("", labels)
    print("  " + "-" * (44 + 18 * len(cards)))

    row("QUALITY - correct word KTC", ["" for _ in cards])
    for k in (1, 2, 3, 4):
        row(f"  correct ghost at <= {k} typed letter(s)",
            [pct(c["ktc_hit_at"][k], c["ktc_words"]) for c in cards])
    row("  never correct on word", [pct(c["ktc_never"], c["ktc_words"]) for c in cards])
    row("  median letters needed", [
        percentile(c["ktc_letters_needed"], 0.5) if c["ktc_letters_needed"] else "-"
        for c in cards
    ])
    row("  whole word guessed at 0 letters", [pct(c["hit_at0_words"], c["hit_at0_total"]) for c in cards])

    print("")
    row("SAVINGS - perfect user, Tab=1 key", ["" for _ in cards])
    row("  saved keystrokes full-accept", [pct(c["saved_full"], c["total_chars"]) for c in cards])
    row("  saved keystrokes word-accept", [pct(c["saved_word"], c["total_chars"]) for c in cards])
    row("  accepts full / word", [f"{c['accepts_full']} / {c['accepts_word']}" for c in cards])

    print("")
    row("STABILITY / COVERAGE", ["" for _ in cards])
    row("  correct ghost stays correct at k+1", [pct(c["hold_kept"], c["hold_pairs"]) for c in cards])
    row("  coherent slide when typed == ghost head", [pct(c["slide_coherent"], c["slide_pairs"]) for c in cards])
    row("  non-empty ghost coverage", [pct(c["steps_non_empty"], c["steps_total"]) for c in cards])
    row("  source counts", [
        ", ".join(f"{k}:{v}" for k, v in sorted(c["source_counts"].items())) or "-"
        for c in cards
    ])

    print("")
    waits = sorted({wait for c in cards for wait in c["wait_total"]})
    if waits:
        row("LATENCY THRESHOLD - raw ghost coverage", ["" for _ in cards])
        for wait in waits:
            row(f"  visible ghost at {wait}ms", [
                pct(c["wait_visible"][wait], c["wait_total"][wait])
                for c in cards
            ])
        print("")

    row("LATENCY per typed char, ms", ["" for _ in cards])
    row("  all avg / p50", [format_lat(c["lat_all"]) for c in cards])
    row("  all p95 / max", [f"{percentile(c['lat_all'], 0.95)} / {max(c['lat_all']) if c['lat_all'] else 0}" for c in cards])
    row("  visible-only avg / p50", [format_lat(c["lat_visible"]) for c in cards])
    row("  mid-word p50", [percentile(c["lat_mid"], 0.5) for c in cards])
    row("  boundary/after-space p50", [percentile(c["lat_boundary"], 0.5) for c in cards])


if __name__ == "__main__":
    main()
