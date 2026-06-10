#!/usr/bin/env python3
"""Rapport de latence bout-en-bout du ghost Souffleuse.

Consomme /tmp/souffleuse-latency.jsonl (produit par l'app lancée avec
SOUFFLEUSE_LATENCY_TRACE=1) et ventile la latence perçue par SEGMENT et par
SOURCE de suggestion. Aucun texte utilisateur dans la trace : uniquement des
horodatages, des hash de préfixe (k) et des longueurs/codes (i).

Étapes émises par l'app :
  key_down        frappe physique (NSEvent global monitor) — k=0
  tick_prefix     1er tick (poll 80 ms) qui voit le nouveau préfixe — k=hash
  predict_begin   entrée de PVM.predict() après debounce — k=hash
  gen_begin/end   appel beam (generateGhostBeam) — k=hash
  suggestion_set  suggestion appliquée — k=hash, i=source (1 instant, 2 cache,
                  3 undo, 4 beam)
  refill_begin/end  rolling refill (extendGhost) — k=hash(texte visible)
  paint           REPAINT effectif de l'overlay (passé le guard) — k=0

Corrélation : par hash de préfixe pour les étapes du cycle predict ; par
adjacence temporelle pour key_down (dernier avant tick_prefix) et paint
(premier après suggestion_set / refill_end, fenêtre 400 ms).

Usage : python3 tools/latency_report.py [/tmp/souffleuse-latency.jsonl]
"""

import json
import statistics
import sys

PATH = sys.argv[1] if len(sys.argv) > 1 else "/tmp/souffleuse-latency.jsonl"
SOURCES = {1: "instant (L0/L1)", 2: "cache", 3: "undo-cache", 4: "beam"}
PAINT_WINDOW_MS = 400


def load(path):
    events = []
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                events.append(json.loads(line))
            except json.JSONDecodeError:
                continue
    events.sort(key=lambda e: e["t"])
    return events


def pct(values, q):
    if not values:
        return None
    values = sorted(values)
    idx = min(len(values) - 1, max(0, int(q * len(values))))
    return values[idx]


def fmt(values):
    if not values:
        return "      —"
    p50 = statistics.median(values)
    p95 = pct(values, 0.95)
    return f"n={len(values):4d}  p50={p50:6.0f} ms  p95={p95:6.0f} ms  max={max(values):6.0f} ms"


def main():
    events = load(PATH)
    if not events:
        print(f"Aucun événement dans {PATH} — lancer l'app avec SOUFFLEUSE_LATENCY_TRACE=1.")
        return

    key_downs = [e["t"] for e in events if e["e"] == "key_down"]
    paints = [e["t"] for e in events if e["e"] == "paint"]

    # Cycles predict : groupés par hash de préfixe, ancrés sur tick_prefix.
    # Un même hash peut revenir (backspace) : on segmente par tick_prefix.
    cycles = []
    open_by_key = {}
    for e in events:
        k = e.get("k", 0)
        if e["e"] == "tick_prefix":
            cycle = {"k": k, "tick": e["t"], "len": e.get("i", 0)}
            open_by_key[k] = cycle
            cycles.append(cycle)
        elif e["e"] in ("predict_begin", "gen_begin", "gen_end", "suggestion_set"):
            cycle = open_by_key.get(k)
            if cycle is None:
                continue
            name = {"predict_begin": "predict", "gen_begin": "gen0",
                    "gen_end": "gen1", "suggestion_set": "set"}[e["e"]]
            # Première occurrence seulement (un retick du même préfixe ne doit
            # pas écraser le timing du cycle).
            cycle.setdefault(name, e["t"])
            if e["e"] == "suggestion_set":
                cycle.setdefault("src", e.get("i", 0))

    # Joins temporels : key_down → tick ; set → paint.
    import bisect
    for c in cycles:
        i = bisect.bisect_left(key_downs, c["tick"]) - 1
        if i >= 0 and c["tick"] - key_downs[i] <= 120:   # > 120 ms = pas une frappe (clic, focus)
            c["key"] = key_downs[i]
        if "set" in c:
            j = bisect.bisect_left(paints, c["set"])
            if j < len(paints) and paints[j] - c["set"] <= PAINT_WINDOW_MS:
                c["paint"] = paints[j]

    # Segments.
    def seg(c, a, b):
        return (c[b] - c[a]) if (a in c and b in c) else None

    segments = {
        "frappe → tick (quantization poll)": [seg(c, "key", "tick") for c in cycles],
        "tick → predict (debounce + contexte)": [seg(c, "tick", "predict") for c in cycles],
        "predict → gen_begin (route/slots)": [seg(c, "predict", "gen0") for c in cycles],
        "génération beam (gen_begin → gen_end)": [seg(c, "gen0", "gen1") for c in cycles],
        "gen_end → suggestion": [seg(c, "gen1", "set") for c in cycles],
        "suggestion → paint (tick de rendu)": [seg(c, "set", "paint") for c in cycles],
        "TOTAL frappe → paint": [seg(c, "key", "paint") for c in cycles],
        "TOTAL tick → paint": [seg(c, "tick", "paint") for c in cycles],
    }

    print(f"— Rapport latence ghost — {len(cycles)} cycles, "
          f"{len(key_downs)} frappes, {len(paints)} repaints —\n")
    print("Par segment :")
    for name, values in segments.items():
        values = [v for v in values if v is not None and v >= 0]
        print(f"  {name:42s} {fmt(values)}")

    print("\nTOTAL frappe → paint, par source :")
    for code, label in SOURCES.items():
        values = [seg(c, "key", "paint") for c in cycles if c.get("src") == code]
        values = [v for v in values if v is not None and v >= 0]
        print(f"  {label:42s} {fmt(values)}")

    # Refills : durée begin→end + delta end→paint (adjacence temporelle).
    refill_durations = []
    refill_to_paint = []
    open_refills = {}
    for e in events:
        if e["e"] == "refill_begin":
            open_refills[e.get("k", 0)] = e["t"]
        elif e["e"] == "refill_end":
            t0 = open_refills.pop(e.get("k", 0), None)
            if t0 is not None:
                refill_durations.append(e["t"] - t0)
                j = bisect.bisect_left(paints, e["t"])
                if j < len(paints) and paints[j] - e["t"] <= PAINT_WINDOW_MS:
                    refill_to_paint.append(paints[j] - e["t"])

    print("\nRefill vivant :")
    print(f"  {'génération (refill_begin → end)':42s} {fmt(refill_durations)}")
    print(f"  {'refill_end → paint':42s} {fmt(refill_to_paint)}")

    # Cycles sans paint (gating/abstention) — le « ghost muet ».
    no_paint = sum(1 for c in cycles if "set" in c and "paint" not in c)
    no_set = sum(1 for c in cycles if "set" not in c)
    print(f"\nCycles sans suggestion : {no_set} · suggestion sans paint ≤{PAINT_WINDOW_MS} ms : {no_paint}")


if __name__ == "__main__":
    main()
