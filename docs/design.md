# Context Language Models in Swift

Build a standalone Swift package, provisionally named `PicoContext`, with a minimal macOS SwiftUI example app. The demo should answer one question: can a local language model edit its working context, retain useful facts, and complete a task with less context or better results?

Keep the first implementation small enough to understand and share as a public repository. Use one model, native Swift context-editing tools and a bundled task. Broader framework features and application integrations can follow if the results justify them.

This proposal is based on Meta's [Context Language Models repository](https://github.com/facebookresearch/context-language-models/tree/c979956b75d16f4c734a778ad832cbbcd20d78f5), inspected on September 30, 2026. The package and example are unimplemented; no local model benchmarks were run.

## How CLMs work

A Context Language Model (CLM) can edit the history that the runtime supplies on its next model call. Meta's reference mirrors working history to a file; the model edits it using tools, and the runtime reconstructs subsequent input from the edited version. The model can remove stale results, replace passages with notes, or retain exact facts. Its system prompt and initial task remain protected. Edits take effect between model calls, without changing model weights or a running token stream. See the [context environment](https://github.com/facebookresearch/context-language-models/blob/c979956b75d16f4c734a778ad832cbbcd20d78f5/clm/clm_harness/context_env/env.py) and [agent loop](https://github.com/facebookresearch/context-language-models/blob/c979956b75d16f4c734a778ad832cbbcd20d78f5/clm/clm_harness/clm_agent/harness.py).

The essential feature is that an accepted edit changes the actual next prompt. An editable document or saved summary alone does not demonstrate CLM behavior. The Swift demo can implement that loop with a native tool that replaces or deletes selected context records; a general file editor or shell is unnecessary.

Training is optional for this prototype. Whether an existing small model uses context editing effectively is part of the experiment.

## Minimal package and app

Use a small core library and a thin adapter for local inference:

| Component | Initial scope |
|---|---|
| `PicoContext` | Context records, protected content, edit validation and working-context revisions |
| Optional `PicoContextMLX` | mlx-swift-lm adapter for prompt preparation, token counting, generation and context-tool dispatch |
| `Examples/ContextPlayground` | macOS SwiftUI app that runs one bundled task and displays edits and results |

The names are provisional. Use Swift 6.2, macOS 15+ and iOS 18+ as the package targets; ship only a macOS example initially. The core target depends on Foundation. MLX belongs in the adapter and example. Live inference requires Apple silicon; deterministic core tests must run without a GPU or model downloads.

Use native Swift context tools, with no shell runtime, Python process, MCP server or external service needed during execution. Choose one tool-capable local model during implementation and record its identifier and tested mlx-swift-lm version. Start with upstream public APIs and exact prompt evaluation. Avoid a custom inference fork.

Keep context state in memory for the first demo. A small backend interface is enough for real inference and a deterministic test implementation. Defer generic persistence, plugin systems and support for multiple inference frameworks.

## First working demonstration

Build one complete loop:

1. Load bundled conversation history containing verbose synthetic tool results, exact facts and information that becomes stale. Protect the initial instructions and task.
2. Let the model inspect its working context and call a native context-editing tool. Support replacing message bodies and deleting selected records by stable ID.
3. Validate the edit and commit a new working-context revision. Apply it after the tool phase completes and before the next generation call.
4. Prepare and count the revised prompt, then use it for the actual next model call. Reserve enough budget for completion and bounded edit recovery.
5. Ask the model to complete the task using retained facts. Check its answer against expected facts in the fixture.

Keep the original transcript available for inspection. Edits change the working context, without rewriting that transcript. Display the original and revised context, an edit diff, token counts and the final answer. Show enough of the actual next input to verify that the edit reached inference.

Preserve message roles and complete tool-call/result groups. Keep identity and role metadata runtime-owned; model-written text cannot become a system or developer instruction. Reject edits to protected content, unknown records, stale revisions or incomplete tool groups atomically. Bound edit calls and repair attempts. Retain the last valid revision on rejection and report an explicit failure if the budget cannot be satisfied.

These are the core correctness checks for the demo. Multimodal editing, durable history, authentication, shared sessions and concurrent branch management are deferred.

## Show whether it helps

Compare append-only history with editable context on the same fixture, model, sampling settings and task limits. Reset working context between runs. Count the overhead of editing calls as part of the editable run. If a run exceeds its budget, record that outcome rather than silently truncating its input. Summarization can be added as a third comparison after the first two modes work.

Report final-answer correctness, prompt size before and after editing, total input and generated tokens, edit-call count and elapsed time. A smaller final prompt alone does not establish faster execution or better task performance. Keep deterministic test output clearly labeled and separate from live model results.

The paper's untrained Qwen3.5-9B CLM scores 28.8% on BrowseComp-Plus versus 34.7% for summarization; RL raises CLM to 42.5%. These results motivate testing existing local models instead of assuming that context editing always helps. They are the authors' benchmark results, not measured Apple-silicon performance. See [Table 2](https://arxiv.org/html/2609.37725v1#S5).

A useful first result is a reproducible run that visibly edits the next input and reports whether facts survive and what the edit costs. Positive results, regressions and models that fail to use the tool are all worth reporting. Any public claim should stay within what this small demonstration measures.

## Defer approximate cache reuse

After an edit, reuse only a verified valid prefix or recompute the revised prompt. Do not add cache splicing to the first demo.

Meta's Suffix Cache Reuse retains surviving spans and adjusts cached key positions, but their states still encode the old preceding context. It is approximate, and removed information can continue to influence generation. An MLX implementation would need model-specific cache and state handling. See the [suffix-reuse design](https://github.com/facebookresearch/context-language-models/blob/c979956b75d16f4c734a778ad832cbbcd20d78f5/suffix_cache_reuse/README.md).

Defer this optimization, reinforcement learning and automated instruction evolution until ordinary context editing demonstrates enough value to pursue them.

## Shareable first delivery

Deliver the standalone package, focused Swift Testing tests for edit validation and next-input propagation, and the runnable example. Include a short README with verified build/run instructions, the tested model and dependency versions, known limits and a screenshot or recording of a real run. Keep contributor guidance in a concise `AGENTS.md`.

The repository should contain everything needed to understand and run the demonstration, apart from clearly documented tooling and model downloads. Keep production infrastructure, a large benchmark suite and release automation outside the first milestone.

## License and provenance

Meta's implementation is licensed [CC BY-NC 4.0](https://github.com/facebookresearch/context-language-models/blob/c979956b75d16f4c734a778ad832cbbcd20d78f5/LICENSE), with separately attributed material in [NOTICE](https://github.com/facebookresearch/context-language-models/blob/c979956b75d16f4c734a778ad832cbbcd20d78f5/NOTICE). A separate repository does not change the terms attached to copied or adapted material.

Write original Swift code, context-tool prompts, fixtures and documentation, and attribute the research. Select a permissive license for original contributions; MIT is a proposed default. Document dependency and model-weight licenses separately. Resolve licensing and record provenance before including any material copied or adapted from the reference implementation.
