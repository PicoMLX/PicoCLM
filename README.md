# PicoContext

A standalone Swift package that lets a model edit the working history it receives
on its next call. The macOS SwiftUI example compares append-only and editable
context on an original synthetic lamp-order task using a local MLX model.

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

The image is rendered by SwiftUI from the actual completed live reports. The UI
shows the original and edited records, roles/protection, accepted or rejected
edits, the diff, final answer, exact decoded next input, and tokenizer counts.
Each comparison starts from the same fixture, with the same model and greedy
sampling. Both modes share an 8,192-token context window, 24,000 total-token
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

Complete assistant/tool groups must survive or be deleted together. Replacing a
body retains its role and links. A rejected edit leaves the last valid revision
intact. `ContextSession` bounds repair, validates the actual next prompt against
the budget before committing, and publishes a revision only after optional
persistence succeeds. A protected control exchange acknowledges the edit outside
the working history. The exact prepared token IDs are passed to generation;
MLX creates fresh KV state for every call.

Public caller edits are available through `ContextSession.apply(_:)`. They use
the same validation/persistence boundary; their token budget is checked when
`run` is invoked. The library assumes the host authorizes caller-supplied scopes;
these IDs are separation keys, not an authentication mechanism.

Token-limit failures, model refusal to edit and invalid tool calls are explicit
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
