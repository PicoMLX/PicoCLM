# Evaluation plan and paper alignment

PRs [#1](https://github.com/PicoMLX/PicoCLM/pull/1),
[#2](https://github.com/PicoMLX/PicoCLM/pull/2) and
[#3](https://github.com/PicoMLX/PicoCLM/pull/3) are merged. The prototype, continuous
conversation loop and original retention/state diagnostics work. This roadmap is
audited against [Context Language Models, v1](https://arxiv.org/html/2609.37725v1),
especially [Section 4.1](https://arxiv.org/html/2609.37725v1#S4.SS1) and
[Appendix D](https://arxiv.org/html/2609.37725v1#A4). Checked October 1, 2026.

| Area | Paper | Current implementation | Remaining work |
|---|---|---|---|
| Editing | Context-as-file editing through Bash | Atomic native body replacements / complete unprotected group deletion; caller metadata protected | Retain this constrained adaptation; unrestricted file editing needs a separate scope decision |
| Timing | Agent may continue without editing | Explicit keep decision, with a decision call each turn | Headroom-based triggers and their overhead/correctness evaluation |
| Conversation | Incoming operations and generated output in one continuous conversation | Caller-owned append transactions; diagnostics deliver operations before calls and append successful answers | Longer reproducible streams and benchmark-specific operation adapters |
| Diagnostics | Four ContextBench tasks | Original four-turn retention and notebook updates, exact live-context and answer checks | Seeded instances, pressure sweeps, official integration when released |
| Measurement | Context pressure and trajectory prefix-reuse FLOPs | All dispatched input/output, edits, retries and elapsed time; fresh KV state | Batch exports, balanced order, summarization, memory measurements; tokens/time are not FLOPs |

## Current stack and next work

1. Validate merged main, correct stale status documents and preserve current model failures.
   Dependency-free and optional prompt tests pass locally on October 1. Minimum
   compiler/runtime execution and Xcode Cloud results remain unverified locally.
2. Implemented in the current stack: a reusable evaluation runner outside the core, with original seeded streams,
   bounded episode length/noise, matched budgets, balanced policy order and JSON
   reports with configuration, provenance, exact prompts, contexts and per-step
   correctness. Reuse the one cached model and build directory.
3. Implemented in the current stack: a constrained summarization baseline with the same stream, model, protection,
   scope, context window and token allowances. Charge every summary/recovery call.
   Describe its native-tool limitations; do not call it the paper's implementation.
4. Improve prompt reliability using development instances and untouched held-out
   seeds. Preserve exact values, updates and removals; generalize editing guidance
   beyond the current tool-result fixtures. Report failures rather than repair model output.
5. Add explicit edit timing/headroom policies and measure whether avoiding routine
   decision calls improves total cost without allowing incoming input to overflow.
6. Prepare ContextBench adapters and offload/retrieval boundaries, then integrate
   the official release as described below.
7. Improve the interactive app: caller edits, cancellation, progress, policy/budget
   controls and report export. Document public API usage and validate a separate
   consumer package before a release.

Additional MLX models are **on hold at the user's request** because disk space is
limited. Keep the pinned Qwen3 1.7B model; do not download model variants. Use the
existing Xcode Cloud workflow and register future dependent PRs as a native GitHub
stack. Do not merge PRs on the user's behalf.

## ContextBench integration

Meta's [repository](https://github.com/facebookresearch/context-language-models#coming-soon)
still lists ContextBench as coming soon at this check. The public tree has no
released task generators/data/evaluators. Original fixtures are development
diagnostics, never official ContextBench scores.

| Official task described in Appendix D | Adapter and validation needed |
|---|---|
| Needle Retention | Stream original operations; grade designated literal lines in final live context, without adding an answer query |
| Sudoku Sketchpad | Stream moves on a 16×16 board and grade every exact board version; this is state maintenance rather than Sudoku solving |
| KV Store | SET/GET operation adapter, bounded offload/retrieval facility and exact GET answers present in live context |
| Log Triage | Bounded log offload/retrieval, exact lookup/count queries and answers present in live context |

Prepare benchmark-specific adapters outside the Foundation-only runtime. Incoming
operations must enter live context before the agent acts, without truncation or
pre-emptive offloading by the harness. Map readiness explicitly (the paper uses
READY_FOR_NEXT_OP), validate seeded instances before use, and ensure each incoming
operation and required retained state fit the configured window/output margin.

Use identical task instructions and equivalent method-specific guidance. Include
below-window controls and pressure sweeps. Record the reference tokenizer/window
separately from the local model's actual tokens; the paper's reference window is
32,768 tokens with 2,048 reserved for output. Grade actual live context, including
caller-appended prior answers; a file-only answer does not count. An earlier failed
step must remain a trajectory failure.

When released, pin the official version and verify generator, data, evaluator and
license terms before importing anything. The snapshot persistence interface is
not an offload/retrieval facility. A separate bounded, caller-namespaced memory
interface can be explored before durable storage, without silently expanding model
permissions. Do not substitute unrelated projects with the same benchmark name,
or copy/translate Meta's noncommercial reference code, prompts or instances.

## Later, gated work

- Exact verified-prefix cache reuse after a correctness baseline; semantic/suffix
  reconstruction needs a separate decision revisiting the no-KV-splicing constraint.
- Durable transcript/revision/tombstone storage, recovery and migrations.
- Prompt/skill optimization with separate development and held-out instances.
- Reinforcement learning only after reliable evaluation, with correctness ahead of efficiency.
- PicoCore integration after the public append/edit/run API stabilizes, preserving caller scopes.
- Multi-writer, multi-agent and multimodal support after their semantics are specified.

Semantic cache reconstruction, RL, durable storage implementations and PicoCore
integration remain deferred by AGENTS.md.
