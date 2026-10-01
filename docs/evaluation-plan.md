# Evaluation plan and paper alignment

Proposed next PR, stacked on prototype [PR #1](https://github.com/PicoMLX/PicoCLM/pull/1).
This plan audits the implementation against [Context Language Models, v1](https://arxiv.org/html/2609.37725v1),
particularly [Section 4.1](https://arxiv.org/html/2609.37725v1#S4.SS1) and
[Appendix D](https://arxiv.org/html/2609.37725v1#A4). Checked September 30, 2026.

The existing [design](design.md) cites the paper but omits ContextBench. The
prototype demonstrates edited history reaching the next inference call. Its
restricted protocol and single fixed-history task do not reproduce the full paper.

| Area | Paper | PicoContext today | Proposed direction |
|---|---|---|---|
| Editing | Unrestricted context-as-file editing through Bash | Replace/delete unprotected bodies by stable ID | Keep the original protected-role/scope constraints; describe this as a constrained adaptation |
| Edit timing | The model can continue without editing | An accepted edit is mandatory before completion in editable mode | Add an explicit continue-without-edit outcome, distinct from refusal or malformed output |
| Conversation | New operations stream through one conversation; generated output appends | Fixed input history; completion is returned without being appended | Add caller-owned append transactions and a sequential episode runner |
| Diagnostics | ContextBench: Needle Retention, Sudoku Sketchpad, KV Store, Log Triage | One lamp-order fixture and a substring answer check | Add exact live-context and state-update checks, then official benchmark integration |
| Measurement | Context pressure and trajectory-level prefix-reuse FLOPs | Fresh KV state; input/output tokens and elapsed time | Measure whole episodes and all edit/recovery overhead; keep token/time results distinct from FLOPs |

## Recommended stacked implementation

1. Extend the caller/runtime boundary to append records atomically with scope and
   revision checks, complete tool groups and stable metadata. Preserve the full
   original transcript separately from editable working state. Record generated
   answers only through an explicit caller transaction. A rejected append or save
   must leave both views unchanged.
2. Support a deliberate decision to keep the current context when it needs no
   change, without weakening validation of proposed edits. Run original,
   deterministic multi-turn diagnostic fixtures for exact retention
   and small state updates. Feed each operation into working context before the
   model acts. Grade the actual retained context and exact structured output;
   do not let a correct final answer conceal earlier information loss. Start with
   below-window controls, then bounded context pressure. Report budget failures
   rather than truncate incoming operations.
3. Compare append-only and editable policies with the same operation stream,
   model, sampling and budgets. Include a summarization baseline in a later
   comparison. Count every input, generated token, rejected edit and elapsed call.
   Distinguish deterministic protocol validation from live model measurements.

Repeating the same completion over a frozen history can measure a narrow
amortization scenario, but it cannot substitute for a streamed context-management
episode. The stacked PR should prioritize the sequential runtime and diagnostics.

## ContextBench integration milestone

Meta's [repository](https://github.com/facebookresearch/context-language-models#coming-soon)
currently lists ContextBench as coming soon. The public repository tree has no
ContextBench release files at this check. Do not substitute unrelated projects
with the same name or report original fixtures as official ContextBench scores.

When the official release is available, pin its version, verify dataset/generator
and evaluator licensing, and preserve its operation delivery and grading protocol.
Add benchmark-specific adapters outside the Foundation-only core. Check whether
offloading/retrieval is required before claiming support for the KV/log tasks;
the existing persistence hook only commits snapshots and supplies no model-owned
retrieval facility. Until then, use original fixtures and cite the research ideas
without copying its code, prompts or task instances.

## Scope decisions

The recommended path remains a constrained native Swift adaptation. Faithful
replication of unrestricted file editing would require revisiting the original
tool/protection constraints and is a separate product decision. No implementation
should silently broaden those constraints. Semantic cache reconstruction, RL,
durable storage and PicoCore integration remain deferred.
