# PicoContext

A standalone Swift package that lets a model edit the working history it receives
on its next call. The macOS SwiftUI example compares append-only and editable
context using a local MLX model: a lamp-order task and two four-turn notebook diagnostics.

The core uses Foundation only. `TokenCounting` prepares/counts the complete
prompt, `ContextModelBackend` consumes those exact token IDs, and
`ContextPersistence` is an optional commit interface. The demo keeps context in
memory. MLX is opt-in and absent from the default dependency graph.

## Build and test

Requires Swift 6.2 or later. Package deployment targets are macOS 15+ and iOS 18+.
The supplied app is macOS only; live MLX inference requires Apple silicon and a
full Xcode installation with Metal tools.

```sh
swift build
swift test
```

The Swift Testing suite uses deterministic test tokens and model responses;
it does not download weights or use a GPU. Test token counts are not live-model
measurements. It covers atomic validation, protected content, scopes, tool groups,
bounded recovery, budgets, persistence failure, concurrency, cancellation and
actual next-input propagation.

The opt-in adapter tests check prompt construction without loading weights or
running inference. They require the MLX source dependencies and Metal build tools:

```sh
PICO_CONTEXT_ENABLE_MLX=1 swift test --build-system swiftbuild --disable-index-store -j 2
```

## Run the example

From the repository root:

```sh
bash Scripts/run-example.sh
```

Click **Run comparison**. The first run downloads
`mlx-community/Qwen3-1.7B-4bit` (about 968 MB) into the upstream Hugging Face
cache under `~/Library/Caches`; later runs reuse the files. Model revision:
`3b1b1768f8f8cf8351c712464f906e86c2b8269e`. Downloads are the only external
service needed; inference and native context-tool execution run on this Mac.

The default **Exact retention** task streams four updates into one session and
checks the live notebook plus exact JSON answers after every call. **State updates**
adds overwrites and removal. **Lamp order** retains the original single-task demo.
Enable **Context pressure** for more incoming telemetry. The sequential tasks
use a 4,096-token window, 24,000-token per-turn allowance, 80,000-token whole-episode
allowance, four decision attempts of 1,024 output tokens, and 512 completion tokens.
Both policies receive the same operations and use the same sampling/budgets.
Budget failures stop explicitly; incoming records are never silently truncated.

These are original diagnostics inspired by the paper, **not official ContextBench
scores**. The exact-state grader folds `FACT key=value` and `REMOVE key` lines in
live record order. It does not credit facts appearing only in a generated JSON
answer. Each answer must match the complete expected string-valued dictionary;
substring matches cannot conceal missing or stale values. The UI shows per-step
checks, prompt counts, cumulative call usage, original/working records and exact inputs.
See [the evaluation plan](docs/evaluation-plan.md) for the official integration milestone.

The script enables the adapter, builds with Swift Build (including Metal shaders),
creates an ad-hoc signed development app at `.build/ContextPlayground.app`, and
launches it. The app is also launchable from Finder after packaging. To compile
without launching:

```sh
PICO_CONTEXT_ENABLE_MLX=1 swift build --build-system swiftbuild --product ContextPlayground --disable-index-store -j 2
```

Use `--build-system swiftbuild` on Swift 6.2/6.3 so Metal resources are compiled.
This option is documented in [Swift Build](https://github.com/swiftlang/swift-build#with-swiftpm).
The legacy native SwiftPM build engine does not build MLX's Metal shaders.
Allow a few GB of disk space for dependency checkouts, compilation and weights.

For offline use after downloading the same model, set its local directory:

```sh
PICO_CONTEXT_MODEL_DIRECTORY=/absolute/path/to/Qwen3-1.7B-4bit bash Scripts/run-example.sh
```

For a reproducible automated run with a visible app and a text report:

```sh
PICO_CONTEXT_SMOKE_REPORT=/tmp/picocontext-live.txt PICO_CONTEXT_SMOKE_IMAGE=/tmp/picocontext-live.png bash Scripts/run-example.sh --smoke
```

For the sequential tasks, use `--episode-smoke retention` or
`--episode-smoke stateUpdates`, optionally followed by `--pressure`:

```sh
PICO_CONTEXT_SMOKE_REPORT=/tmp/picocontext-episode.txt PICO_CONTEXT_SMOKE_IMAGE=/tmp/picocontext-episode.png bash Scripts/run-example.sh --episode-smoke retention
```

The image is rendered by SwiftUI from the actual completed live reports. The UI
shows the original and edited records, roles/protection, accepted or rejected
edits, the diff, final answer, exact decoded next input, and tokenizer counts.
Each comparison starts from the same fixture, with the same model and greedy
sampling. The lamp-order modes share an 8,192-token context window, 24,000 total-token
allowance and 512-token completion cap; editing has at most two attempts of
1,024 generated tokens each. Edit input/output overhead is included in totals.
Elapsed inference time excludes initial model loading. The baseline runs first,
so warm-up and order effects prevent interpreting one run as a speed benchmark.

The Qwen adapter rejects structural chat and tool-wrapper delimiters in record
bodies and metadata before tokenization. Tool arguments encode literal `<` as a
JSON escape, preserving the argument value without introducing a wrapper boundary.

## The loop and its boundaries

`WorkingContext` preserves the original transcript and validates a candidate
revision atomically. A model tool payload contains `baseRevision` and body
replacement/deletion operations by stable record ID. It cannot supply scope,
IDs, roles, protection or tool-link metadata. The caller supplies an opaque
`ContextScope(userID:conversationID:branchID:)`; cross-scope and stale edits fail.
System/developer records and the initial user task are protected.

`ContextSession.originalContext` and `RunReport.original` expose the preserved
session transcript; the report's `diff` includes earlier committed edits.
`runStart` and `runStartPromptTokens` describe the working revision when that run
began, while `originalPromptTokens` counts the preserved transcript's completion
prompt. Token counts used for comparison are separate from actual call usage.
If the preserved history cannot be rendered after a caller repairs the working
context, `originalPromptTokens` is nil and `originalPromptFailure` explains why.
That historical comparison does not block a valid current prompt.

Complete assistant/tool groups must survive or be deleted together. Replacing a
body retains its role and links. Groups allow at most 31 tool calls so the
assistant and all results fit the 32-operation atomic edit limit. A rejected edit leaves the last valid revision
intact. `ContextSession` bounds repair, validates the actual next prompt against
the budget before committing, and publishes a revision only after optional
persistence succeeds. A protected control exchange acknowledges the edit outside
the working history. The exact prepared token IDs are passed to generation;
MLX creates fresh KV state for every call.
Rejected model arguments and error details remain in the report; retry prompts
contain only bounded runtime-authored guidance and the current revision.

Public caller edits are available through `ContextSession.apply(_:)`. They use
the same validation/persistence boundary; their token budget is checked when
`run` is invoked. The library assumes the host authorizes caller-supplied scopes;
these IDs are separation keys, not an authentication mechanism.

## Continue a conversation

`ContextSession.append(_:)` accepts a caller-owned `ContextAppend` with scope,
base revision and complete records. It appends to both the working context and
preserved transcript without restoring earlier edited bodies. IDs and tool-call
IDs cannot be reused after deletion. A failed validation or save changes neither
view. Transactions are limited to 64 records, 64,000 bytes per body and 128,000
encoded bytes including metadata. The next run checks the token budget without
truncating incoming records.

```swift
let current = await session.context
try await session.append(ContextAppend(
    scope: current.scope, baseRevision: current.revision,
    records: [ContextRecord(id: "follow-up", role: .user,
                            body: "What is the current warranty?", isProtected: true)]
))
let report = try await session.run()
if report.failure == nil {
    try await session.append(ContextAppend(
        scope: report.revised.scope, baseRevision: report.revised.revision,
        records: [ContextRecord(id: "reply-1", role: .assistant, body: report.answer)]
    ))
}
```

The caller chooses IDs, protection and whether to record a successful answer.
`run` never appends generated answers implicitly. Completion answers the latest
caller request while following protected instructions and the initial task.
The persistence hook stores the working snapshot only; restart recovery of the
full transcript is deferred with durable storage.

In editable mode, the model chooses one `edit_context` or `keep_context` call.
`keep_context` accepts only the current `baseRevision`, makes no mutation or save,
and prepares an exact completion prompt with a protected acknowledgement. Missing
tools, empty edits and malformed/stale keep decisions remain rejections.
`EditAttempt.outcome` distinguishes edited, kept and rejected attempts;
`editCallCount` and `keepCallCount` count dispatched decisions separately. All
decision/recovery input and output remains included in total usage.

`PicoContextDiagnostics` is a separate Foundation-only library for the original
fixtures, strict grading and sequential runner. It uses the runtime's public
append/run interfaces and keeps fixture policy out of `PicoContext`. Its runner
records successful answers through explicit caller transactions and enforces a
whole-episode token allowance in addition to per-turn limits. Semantic check
failures remain visible even if later answers are correct. Deterministic tests
include a backend that loses a retained fact but returns scripted correct answers,
and a bounded pressure case where append-only fails while compaction continues.

Token-limit failures, missing context decisions and invalid tool calls are explicit
report outcomes. There is no silent prompt truncation. The fixture correctness
check matches four expected fact strings and excludes the stale price; it is a
small demonstration check, not a general semantic evaluator. Shorter final
input alone does not prove faster execution, better accuracy or lower total cost.

Semantic cache reconstruction, suffix reuse, RL, PicoCore integration, durable
storage, multimodal editing and multi-writer branch coordination are deferred.

## Provenance

Original code, prompts, fixture and documentation are MIT licensed. Research
inspiration, upstream dependencies and model-weight licensing are recorded in
[docs/attribution.md](docs/attribution.md). MLX Swift LM is pinned to **2.31.3**,
MLX Swift to **0.31.3** in the manifest. The complete dependency graph used for
the live run is preserved in [docs/MLX-Package.resolved](docs/MLX-Package.resolved).
Enabling MLX creates a root `Package.resolved`; SwiftPM can remove that lockfile
when resolving the dependency-free core configuration.
See [docs/validation.md](docs/validation.md) for the locally verified build and run.
