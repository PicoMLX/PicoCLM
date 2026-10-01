# Sequential diagnostic validation

The conversation runtime in [PR #2](https://github.com/PicoMLX/PicoCLM/pull/2)
supports original four-step retention and state-update fixtures in the separate
Foundation-only `PicoContextDiagnostics` target. They are not official ContextBench
tasks or scores. Research attribution and the future official integration milestone
are in [attribution](attribution.md) and [the evaluation plan](evaluation-plan.md).

Verified September 30, 2026 on the same Apple M1 Max / 32 GB / macOS 26.6.2 host
with installed Apple Swift 6.4. Tools 6.2, Swift 6 language mode, macOS 15+ and
iOS 18+ remain the declared requirements; those older runtime/compiler combinations
were not available for execution.

## Deterministic checks

`swift test` passes **42 core tests** and **11 diagnostic tests (34 cases)** with
zero external package dependencies, model downloads or GPU inference. Optional
MLX tests pass **7 tests (61 cases)** without loading weights. The diagnostic
library and core cross-build for `arm64-apple-ios18.0` with the installed SDK.
The macOS SwiftUI app and its Metal resources build with Swift Build.

Both modes receive each operation before inference in one continuous session;
successful answers append through caller-owned transactions. Tests check exact
next token IDs, preserved original data, tool relationships, prior answer delivery,
and every call's input/output accounting. A fault backend deliberately loses a
needle while producing scripted correct answers: the check before that answer
appends fails, and later recovery cannot hide the earlier failure. Literal retention
checks value survival independently of note style; state updates execute the
separate line-based notebook protocol. Earlier caller-appended answers are live history. Pressure tests show compaction continuing after append-only exceeds the
window, without truncating the incoming operation. A separate episode allowance
stops further generation once it cannot reserve the next response.
Regression checks reject punctuation/combining-mark extensions of literal values.
Empty or colliding caller answer IDs produce one failed step notification after
delivery fails, preserving the generated answer, token usage and valid transcript.

## Live model checks

Use the pinned `mlx-community/Qwen3-1.7B-4bit` model and dependency versions
documented in [the prototype validation](validation.md). Sampling is greedy and
each call uses fresh KV state. Both policies receive identical operations, model,
sampling and budgets. The below-window profile has 12 telemetry lines per update,
a 4,096-token window, 24,000 per-turn tokens, 80,000 whole-episode tokens, four
bounded decision attempts of 1,024 output tokens, and 512 completion tokens.

The recorded retention run passed all four literal-context and exact-answer checks
in both modes. The editable trajectory dispatched four accepted edits and used
11,580 input / 331 generated tokens in 51.37 seconds, versus 6,059 / 99 in
9.33 seconds for append-only. Its last completion prompt was 1,406 tokens versus
2,258 in append-only. Editing still cost more overall on this small fixture.
The [raw retention transcript](live-retention.txt) includes both policies, generated
edits and exact next inputs. This image is rendered by SwiftUI from those actual
reports, not a desktop capture.
Later deterministic regressions tightened literal framing and answer-delivery error
reporting; these model calls were not rerun for those changes.

![Actual four-turn retention run](images/sequential-retention.png)

The recorded state-update development run completed all four steps. Its request
text predates the latest explicit JSON shape and is preserved in the
[raw state transcript](live-state-updates.txt). Append-only retained the exact
live state and returned exact string-valued JSON at every step. Editable mode
returned three correct answers but failed all four live-context checks: it joined
multiple operation lines with semicolons, then invented a value during an update.
This is a model error detected by the diagnostic, not repaired or credited by the
runtime. The core validates structure/protection/scope; it cannot guarantee semantic
fidelity of an arbitrary replacement.

| State-update measurement | Append-only | Editable |
|---|---:|---:|
| Retained context checks | 4/4 | 0/4 |
| Exact answer checks | 4/4 | 3/4 |
| Whole-episode input tokens | 5,934 | 11,262 |
| Whole-episode generated tokens | 104 | 339 |
| Elapsed seconds | 8.09 | 69.74 |

These tiny fixed fixtures and one model are loop diagnostics, not accuracy or
performance benchmarks. Elapsed time includes episode bookkeeping, grading and
all decision/recovery calls, excludes initial model loading, and varies with host
load and background execution. Baseline runs first, so warm-up/order effects remain.
An earlier retention development run passed every context and answer check in both
modes and exercised three edits plus an explicit keep decision; its prompt schema
predated the final operation variants. The recorded development requests are preserved in their raw transcripts; the current fixture additionally supplies an explicit JSON answer shape.

## Reproduce

```sh
swift test
PICO_CONTEXT_ENABLE_MLX=1 swift test --build-system swiftbuild --disable-index-store -j 2
PICO_CONTEXT_SMOKE_REPORT=/tmp/picocontext-retention.txt PICO_CONTEXT_SMOKE_IMAGE=/tmp/picocontext-retention.png bash Scripts/run-example.sh --episode-smoke retention
PICO_CONTEXT_SMOKE_REPORT=/tmp/picocontext-state.txt bash Scripts/run-example.sh --episode-smoke stateUpdates
```

The app stays open with results. Interactive task selection includes the original
lamp comparison, both sequential tasks and a bounded pressure profile. It shows
original/working contexts, per-step scores and prompt counts, rejected decisions,
diffs and exact prepared inputs. The pressure profile is an exploration setting;
live success is not assumed. All failures remain visible.
