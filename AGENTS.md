# PicoContext constraints

- Swift tools 6.2, Swift 6 language mode, macOS 15+ / iOS 18+. The example is macOS only.
- `PicoContext` imports Foundation only. Token preparation/counting, model execution and persistence use Sendable protocols. Keep MLX in the opt-in `PicoContextMLX` target.
- Preserve the original transcript. Apply edits atomically between calls; regenerate the exact next prompt. Never splice KV caches.
- IDs, roles, protection, tool relationships and user/conversation/branch scopes belong to the caller/runtime. Models may only replace bodies or delete complete unprotected groups. Reject stale revisions and cross-scope edits.
- Bound edits, recovery, input and output tokens. Report failures without truncating input or changing the last valid revision.
- Use deterministic Swift Testing tests without downloads/GPU: `swift test`. Run the live example with `bash Scripts/run-example.sh` (uses Swift Build for Metal shaders).
- Write original code, prompts and fixtures. Record research/dependency/model attribution in `docs/attribution.md`; do not copy Meta's noncommercial implementation.
- Defer semantic cache reconstruction, RL, durable storage implementations and PicoCore integration.
