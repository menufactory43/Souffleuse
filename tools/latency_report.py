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

    # Ventilation des générations par CHEMIN servi (gen_path) et, pour les
    # seeds, par RÉUTILISATION du prefix-cache (seed_lcp / seed_prompt). C'est
    # la mesure qui départage « queue lourde = re-prefill post-wipe » (LCP ≈ 0
    # sur gros prompt) d'une autre cause.
    PATHS = {1: "advance HIT", 2: "advance REFILL", 3: "advance MISS",
             4: "seed (réserve)", 5: "seed (sans réserve)"}
    open_gens = {}
    gens = []
    last_len_by_key = {}
    for e in events:
        k = e.get("k", 0)
        if e["e"] == "tick_prefix":
            last_len_by_key[k] = e.get("i", 0)
        elif e["e"] == "gen_begin":
            open_gens[k] = {"t0": e["t"], "len": last_len_by_key.get(k)}
        elif e["e"] == "gen_path" and k in open_gens:
            open_gens[k]["path"] = e.get("i", 0)
        elif e["e"] == "seed_prompt" and k in open_gens:
            open_gens[k]["prompt"] = e.get("i", 0)
        elif e["e"] == "seed_lcp" and k in open_gens:
            open_gens[k]["lcp"] = e.get("i", 0)
        elif e["e"] == "seed_prefill_ms" and k in open_gens:
            open_gens[k]["prefill"] = e.get("i", 0)
        elif e["e"] == "seed_decode_ms" and k in open_gens:
            open_gens[k]["decode"] = e.get("i", 0)
        elif e["e"] == "gen_end" and k in open_gens:
            g = open_gens.pop(k)
            g["dur"] = e["t"] - g["t0"]
            gens.append(g)

    print("\nGénérations par chemin :")
    for code, label in PATHS.items():
        values = [g["dur"] for g in gens if g.get("path") == code]
        print(f"  {label:42s} {fmt(values)}")
    cancelled = [g["dur"] for g in gens if "path" not in g]
    print(f"  {'annulées / gatées (pas de chemin)':42s} {fmt(cancelled)}")

    def lcp_bucket(g):
        ratio = g.get("lcp", 0) / max(1, g.get("prompt", 0))
        if ratio < 0.1:
            return "froid (<10 % réutilisé)"
        return "chaud (≥90 % réutilisé)" if ratio >= 0.9 else "partiel"

    seeds = [g for g in gens if g.get("path") in (4, 5) and g.get("prompt", 0) > 0]
    print("\nSeeds par réutilisation du prefix-cache :")
    for b in ("froid (<10 % réutilisé)", "partiel", "chaud (≥90 % réutilisé)"):
        sel = [g for g in seeds if lcp_bucket(g) == b]
        values = [g["dur"] for g in sel]
        med_prompt = statistics.median([g["prompt"] for g in sel]) if sel else 0
        print(f"  {b:26s} prompt~{med_prompt:4.0f} tok  {fmt(values)}")

    # Décomposition INTERNE du seed (prefill vs boucle de décodage vs reste =
    # tokenisation/queue d'actor/ranking). C'est elle qui dit OÙ le seed paie :
    # decode qui grandit avec le contexte ↔ prefill froide ↔ attente hors moteur.
    timed = [g for g in seeds if "prefill" in g and "decode" in g]
    if timed:
        print("\nDécomposition interne des seeds (gen = attente + prefill + decode + reste) :")
        print(f"  {'prefill (llama_decode du delta prompt)':42s} {fmt([g['prefill'] for g in timed])}")
        print(f"  {'boucle de décodage (pas-à-pas)':42s} {fmt([g['decode'] for g in timed])}")
        print(f"  {'reste (tokenisation/ranking/attente)':42s} {fmt([g['dur'] - g['prefill'] - g['decode'] for g in timed])}")
        # Corrélation décode ↔ taille de prompt (effet contexte sur chaque pas).
        small = [g["decode"] for g in timed if g["prompt"] < 120]
        large = [g["decode"] for g in timed if g["prompt"] >= 120]
        print(f"  {'décode | prompt < 120 tok':42s} {fmt(small)}")
        print(f"  {'décode | prompt ≥ 120 tok':42s} {fmt(large)}")

    # Seeds POST-CONSOMMATION (éval 1, LATENCE-GHOST-HANDOFF §5) : un seed dont
    # le préfixe a sauté de > 3 chars depuis la génération précédente signe une
    # continuité cassée (userTail ≤ 3 dans generateGhostBeam) — typiquement la
    # live-consume qui a avancé le préfixe sans predict. On ventile le saut :
    # 4-24 chars = consommation probable ; > 24 = plutôt focus/collage.
    ordered = sorted([g for g in gens if g.get("len") is not None],
                     key=lambda g: g["t0"])
    prev_len = None
    for g in ordered:
        g["jump"] = (g["len"] - prev_len) if prev_len is not None else None
        prev_len = g["len"]
    seeds_j = [g for g in ordered
               if g.get("path") in (4, 5) and g.get("jump") is not None]
    if seeds_j:
        post = [g for g in seeds_j if g["jump"] > 3]
        conso = [g for g in post if g["jump"] <= 24]
        focus = [g for g in post if g["jump"] > 24]
        rest = [g for g in seeds_j if g["jump"] <= 3]
        print(f"\nSeeds post-consommation (saut de préfixe vs génération précédente) :")
        print(f"  seeds analysés : {len(seeds_j)} (sur {len([g for g in gens if g.get('path') in (4, 5)])} seeds)")
        print(f"  saut > 3 chars : {len(post)} ({100 * len(post) / len(seeds_j):.0f} % des seeds)")
        print(f"  {'saut ≤ 3 (continuité attendue)':42s} {fmt([g['dur'] for g in rest])}")
        print(f"  {'saut 4-24 (consommation probable)':42s} {fmt([g['dur'] for g in conso])}")
        print(f"  {'saut > 24 (focus/collage probable)':42s} {fmt([g['dur'] for g in focus])}")
        if conso:
            jumps = sorted(g["jump"] for g in conso)
            print(f"  sauts 4-24 : médiane {statistics.median(jumps):.0f} chars, "
                  f"min {jumps[0]}, max {jumps[-1]}")

    # Refills : durée begin→end + delta end→paint + réutilisation du cache.
    refill_durations = []
    refill_to_paint = []
    refills = []
    open_refills = {}
    for e in events:
        k = e.get("k", 0)
        if e["e"] == "refill_begin":
            open_refills[k] = {"t0": e["t"]}
        elif e["e"] == "refill_prompt" and k in open_refills:
            open_refills[k]["prompt"] = e.get("i", 0)
        elif e["e"] == "refill_lcp" and k in open_refills:
            open_refills[k]["lcp"] = e.get("i", 0)
        elif e["e"] == "refill_end":
            r = open_refills.pop(k, None)
            if r is not None:
                r["dur"] = e["t"] - r["t0"]
                refills.append(r)
                refill_durations.append(r["dur"])
                j = bisect.bisect_left(paints, e["t"])
                if j < len(paints) and paints[j] - e["t"] <= PAINT_WINDOW_MS:
                    refill_to_paint.append(paints[j] - e["t"])

    print("\nRefill vivant :")
    print(f"  {'génération (refill_begin → end)':42s} {fmt(refill_durations)}")
    print(f"  {'refill_end → paint':42s} {fmt(refill_to_paint)}")
    print("Refills par réutilisation du prefix-cache :")
    with_lcp = [r for r in refills if r.get("prompt", 0) > 0]
    for b in ("froid (<10 % réutilisé)", "partiel", "chaud (≥90 % réutilisé)"):
        sel = [r for r in with_lcp if lcp_bucket(r) == b]
        values = [r["dur"] for r in sel]
        med_prompt = statistics.median([r["prompt"] for r in sel]) if sel else 0
        print(f"  {b:26s} prompt~{med_prompt:4.0f} tok  {fmt(values)}")

    # Cycles sans paint (gating/abstention) — le « ghost muet ».
    no_paint = sum(1 for c in cycles if "set" in c and "paint" not in c)
    no_set = sum(1 for c in cycles if "set" not in c)
    print(f"\nCycles sans suggestion : {no_set} · suggestion sans paint ≤{PAINT_WINDOW_MS} ms : {no_paint}")


if __name__ == "__main__":
    main()
