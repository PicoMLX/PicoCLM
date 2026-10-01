# Reproducible episode runner

`ContextEvaluate` runs original seeded retention or notebook-update streams in
isolated continuous sessions. It uses the same caller scope, incoming records,
task instructions and allowances for every policy. It rotates policy order across
seeds/repetitions; use a multiple of the policy count for full counterbalancing.
Runs are sequential and reuse one backend. Loading is excluded from episode time;
each model call still recomputes its exact prompt with fresh KV state.

## Without a model

```sh
swift test
swift run ContextEvaluate --output /tmp/picocontext-deterministic.json
```

The deterministic backend derives answers from the actual live notebook. Its
counter and usage units are UTF-8 bytes, not model tokens or model performance.
Default deterministic allowances are larger than the MLX token profile. An
explicit configuration is used exactly, including its limits, for either backend.

## With the existing model

No additional model is supported or downloaded by this runner. Supply the cached
Qwen3 1.7B directory already used by the example:

```sh
bash Scripts/run-evaluation.sh --backend mlx --model-directory /absolute/path/to/Qwen3-1.7B-4bit --config Examples/Evaluation/retention.json --output /tmp/picocontext-retention.json
```

The script reuses the existing Swift Build cache and packages its Metal resources.
It records git HEAD and compiler version. Caller-supplied local model files are explicitly marked `unverified-local-files`;
a directory name alone is not verified weight provenance.

Profiles in `Examples/Evaluation` cover retention, state updates/removal and a
longer pressure stream. JSON configuration fields specify seeds, repetitions,
steps, noise, ordered policies and token limits. Instances are validated before
inference; noise changes do not change task facts for a given seed. The batch
allows at most 128 planned steps, 32 steps per episode and 128 noise lines per
operation. This bounds trace size and avoids a new dependency or model matrix.

Exit 0 means every planned step passed. Exit 2 preserves a completed JSON report
containing semantic or runtime/budget failures. Exit 1 means setup/export failed.
No model output is repaired, no incoming operation is truncated, and later
correctness cannot erase a failed earlier step. A failed policy does not prevent
an isolated comparison policy from running.

## Reading reports

Schema version 1 records configuration/provenance, execution order, seed, repeat,
original/working contexts, every incoming operation, exact retained/answer grades,
model answers, decisions/rejections, all dispatched prompts and their token IDs,
and all dispatched input/generated usage. Planned-step denominators include steps
not reached after runtime failure. `failure == null` alone is not a passing grade.

`environmentPromptTokens` measures the completion-template footprint of initial
instructions plus the entire incoming stream, without generated answers. Dividing
it by the recorded context window gives an explicit local pressure proxy. This
includes template/instruction overhead and is **not** the paper's environment-token
pressure measure. Whole-episode input counts include decision/recovery calls,
while this environment footprint is prepared for measurement only and is never
dispatched. Prompt preparation for historical comparisons is not charged as a
model call. Elapsed episode time includes preparation, grading and delivery;
initial loading and batch export are excluded.

Reports do not yet measure FLOPs, prefix reuse, process/GPU peak memory, official
ContextBench scores or statistical accuracy. Task seeds are reproducible input
instances; repetitions expose order/timing effects under greedy inference, not
independent model sampling. Use separate held-out seeds before tuning prompts.
See [the roadmap](evaluation-plan.md) for benchmark protocols and later gates.
