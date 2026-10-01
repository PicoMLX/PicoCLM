# Research and provenance

PicoContext implements the idea of a model editing the history supplied to its
next inference call. The research inspiration is Meta's **Context Language
Models**, [paper](https://arxiv.org/abs/2609.37725) and
[reference repository](https://github.com/facebookresearch/context-language-models/tree/c979956b75d16f4c734a778ad832cbbcd20d78f5),
as described in this repository's design proposal on September 30, 2026.
The reference implementation is
[CC BY-NC 4.0](https://github.com/facebookresearch/context-language-models/blob/c979956b75d16f4c734a778ad832cbbcd20d78f5/LICENSE).
No reference implementation code, prompts, fixtures or benchmark tasks are
included or translated here. The Swift implementation, context-tool instructions,
Lumen lamp fixture and documentation were written for this prototype. Original
contributions are MIT licensed; that does not relicense the research repository.

The adapter uses upstream public tokenizer, `ModelContainer`, `TokenIterator`
and `generateTask` APIs. It regenerates the entire revised prompt with fresh KV
state. It implements neither suffix cache reuse nor semantic cache reconstruction.
The research paper's benchmark numbers are not measurements of this package.

## Dependencies and model

- [mlx-swift-lm 2.31.3](https://github.com/ml-explore/mlx-swift-lm/tree/2.31.3)
  and [mlx-swift 0.31.3](https://github.com/ml-explore/mlx-swift/tree/0.31.3): MIT.
  Their code is consumed as an unmodified package dependency.
- Hugging Face swift-transformers / swift-huggingface / swift-jinja: Apache-2.0;
  Swift Numerics / Collections / Crypto / ASN.1: Apache-2.0 (including upstream
  runtime exceptions where applicable); EventSource / yyjson: MIT.
  `Package.resolved` records the complete tested dependency graph, also preserved
  in `docs/MLX-Package.resolved` for the dependency-free core configuration.
  See each upstream repository's license and notices for redistribution.
- [mlx-community/Qwen3-1.7B-4bit](https://huggingface.co/mlx-community/Qwen3-1.7B-4bit),
  revision `3b1b1768f8f8cf8351c712464f906e86c2b8269e`: Apache-2.0 model weights,
  converted from [Qwen/Qwen3-1.7B](https://huggingface.co/Qwen/Qwen3-1.7B).
  Weights/tokenizer files are downloaded separately, not committed or covered
  by PicoContext's MIT license.

The exact prompt protocol and validation policy are prototype design choices.
They are not a claim of benchmark equivalence to Meta's implementation.

## Sequential diagnostics and ContextBench

The paper's streamed context-management evaluation and its retention/state tasks
inspired the two original notebook diagnostics in `PicoContextDiagnostics`.
Their keys, values, telemetry, prompts, update sequences and strict graders were
written here. They are not copied task instances or official ContextBench scores.
The new runtime permits explicit no-edit decisions and caller-owned output appends;
its constrained body tools continue to differ from unrestricted file editing.

As checked October 1, 2026, Meta's repository lists ContextBench as coming soon.
The [evaluation plan](evaluation-plan.md) records a separate milestone to pin the
official release and verify generator/data/evaluator licensing and protocol before
integration. No unrelated project sharing the ContextBench name is substituted.


The seeded evaluation streams, deterministic notebook backend, JSON trace format
and runner prompts are original project contributions. SplitMix64 arithmetic is
used to identify reproducible synthetic task instances; seeds do not change
greedy model sampling. The runner uses the existing pinned model adapter only.
