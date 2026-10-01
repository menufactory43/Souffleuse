#!/usr/bin/env python3
"""Run TextEdit ghost A/B sweeps against the Release Souffleuse app.

The runner launches the signed Release app with a chosen environment, drives
TextEdit through SouffleuseCotypistObserve accept mode, then reports:

  - visibility at the chosen wait budget,
  - exact target matches,
  - structurally plausible alternatives,
  - suspicious ghosts,
  - perceived key-to-paint latency by suggestion source.

It deliberately keeps two families separate:

  - beam/corpus knobs: active in the default Release path,
  - cascade branch/temp knobs: only active when beam core and long-ghost are
    forced off for A/B.
"""

from __future__ import annotations

import argparse
import bisect
import json
import os
import shutil
import signal
import statistics
import subprocess
import sys
import time
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import Iterable


REPO_ROOT = Path(__file__).resolve().parents[1]
SOUFFLEUSE_DIR = REPO_ROOT / "Souffleuse"
DEFAULT_APP = SOUFFLEUSE_DIR / "build/Build/Products/Release/Souffleuse.app"
DEFAULT_LATENCY_TRACE = Path("/tmp/souffleuse-latency.jsonl")
DEFAULT_OUT_ROOT = Path("/tmp/souffleuse-ghost-ab")

DEFAULT_PHRASES = [
    "Merci pour votre retour ",
    "Pouvez-vous confirmer le rendez-vous demain matin ",
    "Je te confirme que la facture sera envoyee cet apres-midi ",
    "Est-ce que tu peux me faire un retour rapide sur ce point ",
    "On peut probablement reduire la latence sans perdre la qualite ",
    "Je suis en train de preparer le compte rendu pour demain matin ",
]


@dataclass(frozen=True)
class Config:
    name: str
    env: dict[str, str]
    note: str


CONFIGS: dict[str, Config] = {
    "baseline": Config(
        "baseline",
        {},
        "Release default path.",
    ),
    "corpus12": Config(
        "corpus12",
        {"MW_STRONG_MINCHARS": "12"},
        "Strong corpus after-space threshold, conservative baseline.",
    ),
    "corpus8": Config(
        "corpus8",
        {"MW_STRONG_MINCHARS": "8"},
        "Strong corpus threshold lowered, moderate.",
    ),
    "corpus6": Config(
        "corpus6",
        {"MW_STRONG_MINCHARS": "6"},
        "Strong corpus threshold lowered, current promising setting.",
    ),
    "corpus4": Config(
        "corpus4",
        {"MW_STRONG_MINCHARS": "4"},
        "Aggressive corpus threshold, expected to expose word-jump risk.",
    ),
    "word": Config(
        "word",
        {"SOUFFLEUSE_WORDCOMPLETER": "1"},
        "Re-enable system word completer in front of the LLM.",
    ),
    "beam-k1": Config(
        "beam-k1",
        {"SOUFFLEUSE_BEAM_K": "1"},
        "Beam core width 1, closer to greedy.",
    ),
    "beam-k2": Config(
        "beam-k2",
        {"SOUFFLEUSE_BEAM_K": "2"},
        "Beam core width 2.",
    ),
    "beam-k3": Config(
        "beam-k3",
        {"SOUFFLEUSE_BEAM_K": "3"},
        "Beam core width 3.",
    ),
    "beam-exp0": Config(
        "beam-exp0",
        {"SOUFFLEUSE_BEAM_EXP": "0"},
        "No length normalization in beam ranking.",
    ),
    "beam-exp07": Config(
        "beam-exp07",
        {"SOUFFLEUSE_BEAM_EXP": "0.7"},
        "Mid length-normalization setting.",
    ),
    "beam-exp1": Config(
        "beam-exp1",
        {"SOUFFLEUSE_BEAM_EXP": "1"},
        "Stronger length normalization.",
    ),
    "beam-tok8": Config(
        "beam-tok8",
        {"SOUFFLEUSE_BEAM_MAXTOK": "8"},
        "Shorter beam decode budget.",
    ),
    "beam-words2": Config(
        "beam-words2",
        {"SOUFFLEUSE_BEAM_MAXWORDS": "2"},
        "Shorter ghost cap.",
    ),
    "beam-noreserve": Config(
        "beam-noreserve",
        {"SOUFFLEUSE_BEAM_RESERVE_OFF": "1"},
        "Disable rolling beam reserve; measures fresh-generation cost.",
    ),
    "cascade-temp-low": Config(
        "cascade-temp-low",
        {
            "SOUFFLEUSE_BEAM_CORE_OFF": "1",
            "SOUFFLEUSE_LONGGHOST_OFF": "1",
            "MW_ESC_K": "3",
            "MW_ESC_TEMP": "0.35",
            "MW_AGREE": "0.70",
        },
        "Old cascade branches, low temperature, strict agreement.",
    ),
    "cascade-temp-mid": Config(
        "cascade-temp-mid",
        {
            "SOUFFLEUSE_BEAM_CORE_OFF": "1",
            "SOUFFLEUSE_LONGGHOST_OFF": "1",
            "MW_ESC_K": "3",
            "MW_ESC_TEMP": "0.70",
            "MW_AGREE": "0.60",
        },
        "Old cascade branches, default-ish temperature/agreement.",
    ),
    "cascade-temp-high": Config(
        "cascade-temp-high",
        {
            "SOUFFLEUSE_BEAM_CORE_OFF": "1",
            "SOUFFLEUSE_LONGGHOST_OFF": "1",
            "MW_ESC_K": "3",
            "MW_ESC_TEMP": "0.95",
            "MW_AGREE": "0.55",
        },
        "Old cascade branches, higher temperature, looser agreement.",
    ),
    "cascade-k1": Config(
        "cascade-k1",
        {
            "SOUFFLEUSE_BEAM_CORE_OFF": "1",
            "SOUFFLEUSE_LONGGHOST_OFF": "1",
            "MW_ESC_K": "1",
            "MW_ESC_TEMP": "0.70",
            "MW_AGREE": "0.60",
        },
        "Old cascade with one branch.",
    ),
    "cascade-k5": Config(
        "cascade-k5",
        {
            "SOUFFLEUSE_BEAM_CORE_OFF": "1",
            "SOUFFLEUSE_LONGGHOST_OFF": "1",
            "MW_ESC_K": "5",
            "MW_ESC_TEMP": "0.70",
            "MW_AGREE": "0.65",
        },
        "Old cascade with more branches.",
    ),
}

PRESETS = {
    "quick": ["baseline", "corpus6", "word", "beam-k1", "beam-k3"],
    "corpus": ["baseline", "corpus12", "corpus8", "corpus6", "corpus4"],
    "beam": [
        "baseline",
        "beam-k1",
        "beam-k2",
        "beam-k3",
        "beam-exp0",
        "beam-exp07",
        "beam-exp1",
        "beam-tok8",
        "beam-words2",
        "beam-noreserve",
    ],
    "cascade-branches": [
        "cascade-k1",
        "cascade-temp-low",
        "cascade-temp-mid",
        "cascade-temp-high",
        "cascade-k5",
    ],
}
PRESETS["all"] = list(dict.fromkeys(PRESETS["corpus"] + PRESETS["beam"] + PRESETS["cascade-branches"]))


def load_jsonl(path: Path) -> list[dict]:
    rows: list[dict] = []
    if not path.exists():
        return rows
    with path.open(encoding="utf-8") as f:
        for line_no, line in enumerate(f, 1):
            line = line.strip()
            if not line:
                continue
            try:
                rows.append(json.loads(line))
            except json.JSONDecodeError as exc:
                raise SystemExit(f"{path}:{line_no}: invalid JSON: {exc}") from exc
    return rows


def is_word_char(ch: str) -> bool:
    return ch.isalpha() or ch.isdigit() or ch in ("'", "-", "\u2019")


def trailing_word(text: str) -> str:
    i = len(text)
    while i > 0 and is_word_char(text[i - 1]):
        i -= 1
    return text[i:]


def has_control_artifact(text: str) -> bool:
    return any(ch in "\t\n\r" or ord(ch) < 32 for ch in text)


def plausible_ghost(prefix: str, ghost: str) -> tuple[bool, str]:
    if not ghost:
        return False, "empty"
    if has_control_artifact(ghost):
        return False, "control"
    if ghost.startswith(("  ", "\u00a0")):
        return False, "spacing"
    if ghost.lstrip().startswith(("#", "*", "_", "~")):
        return False, "markup"

    first = ghost[0]
    natural_start = first.isalpha() or first.isdigit() or first in ("'", "\u2019", '"')
    if not prefix or prefix[-1].isspace():
        return (True, "after-boundary") if natural_start else (False, "bad-start")

    if is_word_char(prefix[-1]):
        if is_word_char(first):
            typed = trailing_word(prefix).lower()
            lead = trailing_word(prefix + ghost).lower()
            if lead.startswith(typed) and len(lead) > len(typed):
                return True, "word-completion"
            return False, "word-jump"
        if first.isspace() or first in ",.!?;:":
            return True, "next-word"
        return False, "bad-midword-start"

    if first.isspace() or natural_start:
        return True, "after-punctuation"
    return False, "bad-start"


def percentile(values: list[float], q: float) -> float | None:
    if not values:
        return None
    values = sorted(values)
    return values[min(len(values) - 1, max(0, int(q * len(values))))]


def fmt_ms(values: list[float]) -> str:
    if not values:
        return "-"
    return f"{statistics.median(values):.0f}/{percentile(values, 0.95):.0f}"


def pct(num: int, den: int) -> str:
    if den == 0:
        return "-"
    return f"{100 * num / den:.0f}%"


def score_acceptance(rows: list[dict]) -> dict:
    total = 0
    visible = 0
    exact = 0
    plausible = 0
    suspicious = 0
    examples: list[tuple[str, str, str]] = []

    for row in rows:
        target = row.get("target") or ""
        prefix = row.get("prefix") or ""
        ghost = row.get("ghost") or row.get("inserted") or ""
        if ghost == "\t":
            ghost = ""
        if not target or not prefix:
            continue
        total += 1
        if not ghost:
            continue
        visible += 1
        truth = target[len(prefix):]
        if truth.startswith(ghost):
            exact += 1
        else:
            ok, reason = plausible_ghost(prefix, ghost)
            if ok:
                plausible += 1
            else:
                suspicious += 1
                if len(examples) < 4:
                    examples.append((prefix[-28:], ghost[:40], reason))

    return {
        "total": total,
        "visible": visible,
        "exact": exact,
        "plausible": plausible,
        "suspicious": suspicious,
        "examples": examples,
    }


def source_latency(trace_path: Path) -> dict[str, list[float]]:
    events = load_jsonl(trace_path)
    events.sort(key=lambda e: e.get("t", 0))
    key_downs = [e["t"] for e in events if e.get("e") == "key_down"]
    paints = [e["t"] for e in events if e.get("e") == "paint"]

    cycles: list[dict] = []
    open_by_key: dict[int, dict] = {}
    for event in events:
        name = event.get("e")
        key = int(event.get("k", 0))
        t = event.get("t")
        if not isinstance(t, int):
            continue
        if name == "tick_prefix":
            cycle = {"k": key, "tick": t}
            open_by_key[key] = cycle
            cycles.append(cycle)
        elif name in ("predict_begin", "gen_begin", "gen_end", "suggestion_set"):
            cycle = open_by_key.get(key)
            if cycle is None:
                continue
            slot = {
                "predict_begin": "predict",
                "gen_begin": "gen0",
                "gen_end": "gen1",
                "suggestion_set": "set",
            }[name]
            cycle.setdefault(slot, t)
            if name == "suggestion_set":
                cycle.setdefault("src", int(event.get("i", 0)))

    for cycle in cycles:
        i = bisect.bisect_left(key_downs, cycle["tick"]) - 1
        if i >= 0 and cycle["tick"] - key_downs[i] <= 120:
            cycle["key"] = key_downs[i]
        if "set" in cycle:
            j = bisect.bisect_left(paints, cycle["set"])
            if j < len(paints) and paints[j] - cycle["set"] <= 400:
                cycle["paint"] = paints[j]

    names = {1: "instant", 2: "cache", 3: "undo", 4: "beam"}
    out: dict[str, list[float]] = {name: [] for name in names.values()}
    out["total"] = []
    for cycle in cycles:
        if "key" not in cycle or "paint" not in cycle:
            continue
        value = cycle["paint"] - cycle["key"]
        if value < 0:
            continue
        out["total"].append(value)
        source = names.get(cycle.get("src"))
        if source:
            out[source].append(value)
    return out


def read_phrases(path: Path | None, max_phrases: int | None) -> list[str]:
    if path is None:
        phrases = list(DEFAULT_PHRASES)
    else:
        raw = path.read_text(encoding="utf-8")
        if path.suffix.lower() == ".json":
            loaded = json.loads(raw)
            if not isinstance(loaded, list):
                raise SystemExit(f"{path}: expected JSON array of phrases")
            phrases = [str(item) for item in loaded]
        else:
            phrases = [line.strip("\n") for line in raw.splitlines() if line.strip()]
    if max_phrases is not None:
        phrases = phrases[:max_phrases]
    return phrases


def parse_configs(args: argparse.Namespace) -> list[Config]:
    names: list[str] = []
    for preset in args.preset:
        if preset not in PRESETS:
            raise SystemExit(f"Unknown preset {preset!r}. Known: {', '.join(PRESETS)}")
        names.extend(PRESETS[preset])
    for item in args.config:
        names.extend(part.strip() for part in item.split(",") if part.strip())
    if not names:
        names = list(PRESETS["quick"])
    unique = list(dict.fromkeys(names))
    missing = [name for name in unique if name not in CONFIGS]
    if missing:
        raise SystemExit(f"Unknown configs: {', '.join(missing)}")
    return [CONFIGS[name] for name in unique]


def app_executable(app_path: Path) -> Path:
    exe = app_path / "Contents/MacOS/Souffleuse"
    if not exe.exists():
        raise SystemExit(f"Missing app executable: {exe}")
    return exe


def quit_souffleuse() -> None:
    subprocess.run(
        [
            "osascript",
            "-e",
            'tell application id "app.cocotypist.Souffleuse" to quit',
        ],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        check=False,
    )
    time.sleep(0.6)


def launch_app(app_path: Path, env_overrides: dict[str, str], startup_wait: float) -> subprocess.Popen:
    quit_souffleuse()
    if DEFAULT_LATENCY_TRACE.exists():
        DEFAULT_LATENCY_TRACE.unlink()
    env = os.environ.copy()
    env.update(env_overrides)
    env["SOUFFLEUSE_LATENCY_TRACE"] = "1"
    exe = app_executable(app_path)
    proc = subprocess.Popen(
        [str(exe)],
        cwd=str(app_path.parent),
        env=env,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        start_new_session=True,
    )
    time.sleep(startup_wait)
    return proc


def stop_app(proc: subprocess.Popen | None) -> None:
    if proc is None:
        return
    if proc.poll() is not None:
        return
    try:
        proc.terminate()
        proc.wait(timeout=3)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(proc.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
    finally:
        quit_souffleuse()


def build_app() -> None:
    subprocess.run(
        ["./make-app.sh"],
        cwd=str(SOUFFLEUSE_DIR),
        env={**os.environ, "CONFIGURATION": "Release"},
        check=True,
    )


def run_probe(phrase: str, delay_csv: str, typing_delay: int, out_path: Path, dry_run: bool) -> None:
    cmd = [
        "swift",
        "run",
        "-c",
        "release",
        "SouffleuseCotypistObserve",
        "accept",
        "--target",
        "souffleuse",
        "--delays",
        delay_csv,
        "--typing-delay",
        str(typing_delay),
        "--phrase",
        phrase,
        "--out",
        str(out_path),
    ]
    if dry_run:
        print(" ".join(cmd))
        return
    subprocess.run(cmd, cwd=str(SOUFFLEUSE_DIR), check=True)


def copy_latency_trace(dest: Path) -> None:
    if DEFAULT_LATENCY_TRACE.exists():
        shutil.copyfile(DEFAULT_LATENCY_TRACE, dest)


def compact_examples(examples: Iterable[tuple[str, str, str]]) -> str:
    parts = []
    for prefix, ghost, reason in examples:
        parts.append(f"{reason}: {prefix!r} -> {ghost!r}")
    return " | ".join(parts) if parts else "-"


def print_table(rows: list[dict]) -> None:
    headers = [
        "config",
        "visible",
        "exact",
        "exact+plaus",
        "susp",
        "total ms p50/p95",
        "instant p50/p95",
        "beam p50/p95",
        "examples",
    ]
    table = [headers]
    for row in rows:
        quality = row["quality"]
        latency = row["latency"]
        table.append(
            [
                row["config"],
                pct(quality["visible"], quality["total"]),
                pct(quality["exact"], quality["visible"]),
                pct(quality["exact"] + quality["plausible"], quality["visible"]),
                pct(quality["suspicious"], quality["visible"]),
                fmt_ms(latency.get("total", [])),
                fmt_ms(latency.get("instant", [])),
                fmt_ms(latency.get("beam", [])),
                compact_examples(quality["examples"]),
            ]
        )
    widths = [max(len(str(line[i])) for line in table) for i in range(len(headers))]
    for i, line in enumerate(table):
        print("  ".join(str(cell).ljust(widths[j]) for j, cell in enumerate(line)))
        if i == 0:
            print("  ".join("-" * w for w in widths))


def list_configs() -> None:
    print("Presets:")
    for name, configs in PRESETS.items():
        print(f"  {name}: {', '.join(configs)}")
    print("\nConfigs:")
    for name in sorted(CONFIGS):
        cfg = CONFIGS[name]
        env = " ".join(f"{k}={v}" for k, v in cfg.env.items()) or "(no env override)"
        print(f"  {name:18s} {env}")
        print(f"  {'':18s} {cfg.note}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, default=DEFAULT_APP)
    parser.add_argument("--build-app", action="store_true", help="Run CONFIGURATION=Release ./make-app.sh first.")
    parser.add_argument("--preset", action="append", default=[], help=f"Preset: {', '.join(PRESETS)}.")
    parser.add_argument("--config", action="append", default=[], help="Config name or comma-separated names.")
    parser.add_argument("--phrases-file", type=Path)
    parser.add_argument("--max-phrases", type=int)
    parser.add_argument("--delays", default="80", help="CSV wait budgets passed to accept probe.")
    parser.add_argument("--typing-delay", type=int, default=12)
    parser.add_argument("--startup-wait", type=float, default=8.0)
    parser.add_argument("--out-dir", type=Path)
    parser.add_argument("--list-configs", action="store_true")
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()

    if args.list_configs:
        list_configs()
        return 0

    configs = parse_configs(args)
    phrases = read_phrases(args.phrases_file, args.max_phrases)
    out_dir = args.out_dir or DEFAULT_OUT_ROOT / datetime.now().strftime("%Y%m%d-%H%M%S")
    out_dir.mkdir(parents=True, exist_ok=True)

    if args.build_app and not args.dry_run:
        build_app()
    if not args.app.exists() and not args.dry_run:
        raise SystemExit(f"Release app not found: {args.app}. Build with --build-app or ./Souffleuse/make-app.sh.")

    print(f"out={out_dir}")
    print(f"phrases={len(phrases)} delays={args.delays} typing_delay={args.typing_delay}ms")
    print(f"configs={', '.join(cfg.name for cfg in configs)}")

    summaries: list[dict] = []
    for cfg in configs:
        print(f"\n== {cfg.name} ==")
        print(cfg.note)
        print("env:", " ".join(f"{k}={v}" for k, v in cfg.env.items()) or "(default)")
        cfg_dir = out_dir / cfg.name
        cfg_dir.mkdir(exist_ok=True)

        if args.dry_run:
            for idx, phrase in enumerate(phrases):
                run_probe(phrase, args.delays, args.typing_delay, cfg_dir / f"phrase-{idx}.jsonl", True)
            continue

        proc: subprocess.Popen | None = None
        all_rows: list[dict] = []
        try:
            proc = launch_app(args.app, cfg.env, args.startup_wait)
            for idx, phrase in enumerate(phrases):
                out_path = cfg_dir / f"phrase-{idx}.jsonl"
                run_probe(phrase, args.delays, args.typing_delay, out_path, False)
                all_rows.extend(load_jsonl(out_path))
        finally:
            stop_app(proc)

        trace_copy = cfg_dir / "souffleuse-latency.jsonl"
        copy_latency_trace(trace_copy)
        quality = score_acceptance(all_rows)
        latency = source_latency(trace_copy)
        (cfg_dir / "summary.json").write_text(
            json.dumps(
                {
                    "config": cfg.name,
                    "env": cfg.env,
                    "note": cfg.note,
                    "quality": quality,
                    "latency": latency,
                },
                ensure_ascii=True,
                indent=2,
                sort_keys=True,
            ),
            encoding="utf-8",
        )
        summaries.append({"config": cfg.name, "quality": quality, "latency": latency})
        print_table([summaries[-1]])

    if summaries:
        print("\n== summary ==")
        print_table(summaries)
        (out_dir / "summary.json").write_text(
            json.dumps(summaries, ensure_ascii=True, indent=2, sort_keys=True),
            encoding="utf-8",
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
