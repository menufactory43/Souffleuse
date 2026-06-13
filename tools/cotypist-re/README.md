# Cotypist Dynamic Lab

This directory prepares a disposable copy of Cotypist for local LLDB observation.
It never modifies `/Applications/Cotypist.app`.

The debug lab uses the distinct bundle ID `app.cocotypist.CotypistLab`, a
separate HOME under `/tmp`, and a read-only link to the static 1B model. It does
not copy Cotypist history or its database, and training collection is disabled.

Set `COTYPIST_LAB_SIGN_IDENTITY` to a local development certificate when the
lab needs a stable signing requirement for Accessibility permission. The
default remains an ad-hoc signature.

## Prepare

```bash
chmod +x tools/cotypist-re/prepare-lab.sh
tools/cotypist-re/prepare-lab.sh
```

Example with a development certificate:

```bash
COTYPIST_LAB_SIGN_IDENTITY="Apple Development: Name (TEAMID)" \
tools/cotypist-re/prepare-lab.sh
```

## Launch under LLDB

```bash
lldb \
  -s tools/cotypist-re/llama-kv.lldb \
  /tmp/CotypistLab.app/Contents/MacOS/Cotypist
```

Launch it with the isolated HOME:

```bash
HOME=/tmp/CotypistLabHome \
CFFIXED_USER_HOME=/tmp/CotypistLabHome \
CFPREFERENCES_AVOID_DAEMON=1 \
lldb -s tools/cotypist-re/llama-kv.lldb \
  /tmp/CotypistLab.app/Contents/MacOS/Cotypist
```

Use synthetic text only. The first pass logs decode calls and the ARM64 argument
registers for `llama_memory_seq_cp`, `llama_memory_seq_rm`, and
`llama_memory_seq_keep`.

Register mapping follows the exported llama.cpp C API:

- `seq_cp(memory, src, dst, p0, p1)`: `x1=src`, `x2=dst`, `x3=p0`, `x4=p1`
- `seq_rm(memory, seq, p0, p1)`: `x1=seq`, `x2=p0`, `x3=p1`
- `seq_keep(memory, seq)`: `x1=seq`

The lab copy has an ad-hoc signature, so macOS may request fresh Accessibility
permission for **Cotypist Lab**. This does not change the permission of the
installed Cotypist app.

The ad-hoc signature can also make Cotypist disable normal completion features.
That is not evidence that the model is missing. The verified official path is:

```text
~/Library/Application Support/app.cotypist.Cotypist/Models/
  gemma-3-1b.i1-Q5_K_M.gguf
```

On the tested machine, the official signed process mapped that file successfully
from an isolated HOME. Attaching LLDB to the official process was rejected by
the hardened runtime. Therefore, exported symbols and static callsites prove
that sequence-copy/remove/keep support exists, but do not prove how often the
ghost path activates it.

## Branch width and pruning

The Swift field metadata can be extracted without launching Cotypist:

```bash
node tools/cotypist-re/swift-field-layout.mjs
```

The current binary reconstructs the branch configuration as:

- `maxSearchWidth = 9`, with an enforced maximum of 9;
- `maxResultWidth = 9`, with an enforced maximum of 9;
- `minBranchProbability = 0.05`;
- `relativeCutoff = 1e-10`.

Static anchors for Cotypist 2026.1.1 (74):

| Address / file offset | Role |
| --- | --- |
| `0x10009ea48` | Initializes both widths to 9 and the probability configuration |
| `0x10030c63c` | Orchestrator that validates widths and passes search K |
| `0x100318238` | Pools scores, computes the Kth threshold, and prunes |
| `0x1003113c8` | Descending score sort helper |
| `0x100351270` | Absolute and relative probability pre-filters |
| `0x7b9fe4` | `SequenceCandidate` Swift field descriptor |
| `0x7ba748` | Probability configuration Swift field descriptor |
| `0x7ba770` | Active sequence state Swift field descriptor |

The pruning function pools active and freshly completed candidates, selects one
of the four cumulative metrics (`total`/`average` x `logit`/`logprob`), sorts
scores descending, then keeps every candidate whose score is at least the
`K - 1` threshold. Ties can therefore leave more than K survivors.

`branch-lab.sh` builds an injected ARM64 hardware-breakpoint probe without
patching Cotypist's executable pages:

```bash
chmod +x tools/cotypist-re/branch-lab.sh
COTYPIST_LAB_SIGN_IDENTITY="Apple Development: Name (TEAMID)" \
tools/cotypist-re/branch-lab.sh
```

When the generation path is reached, `/tmp/cotypist-branch.log` records the
configured K, active and freshly completed array counts, and the two metric
mode flags. On the tested machine, the re-signed lab loaded the probe but did
not reach completion generation because its signing requirement did not retain
the official app's Accessibility authorization. This is a runtime measurement
gap, not a gap in the statically reconstructed pruning formula.

## Signed black-box + sampling lab

The official signed binary remains functional with the isolated HOME and can be
observed with Apple's `sample` profiler without attaching a debugger:

```bash
HOME=/tmp/CotypistLabHome \
CFFIXED_USER_HOME=/tmp/CotypistLabHome \
CFPREFERENCES_AVOID_DAEMON=1 \
/Applications/Cotypist.app/Contents/MacOS/Cotypist

chmod +x tools/cotypist-re/midword-lab.sh
tools/cotypist-re/midword-lab.sh
```

The harness creates a synthetic TextEdit document and compares two edits against
the expected ghost `Paris.`:

- matching `P`: the visible suffix becomes `aris.` without tokenization or decode;
- divergent `X`: the stale suffix is removed and the process runs
  `llama_vocab::tokenize`, `llama_decode`, and a KV sequence removal path.

The output contains screenshots and `sample` reports under
`/tmp/cotypist-midword-run`. The script refuses to run against the real HOME
unless `COTYPIST_ALLOW_REAL_HOME=1` is explicitly set.

## Targeted Ghidra export

`ghidra/DumpTargetFunctions.java` exports pseudo-code and call references for
addresses identified by `sample`. This is faster and more reliable than waiting
for a complete analysis of the stripped Swift binary.

Delete `/tmp/CotypistLab.app` and `/tmp/CotypistLabHome` after the experiment.
