# Merged-main validation

Checked October 1, 2026 at main commit
`5b7f9ca912644ff5e2be47d68697fc200cacd27f` (PRs #1–#3).

- `swift test`: 42 core and 16 diagnostic test functions passed, without external dependencies or GPU.
- `PICO_CONTEXT_ENABLE_MLX=1 swift test --build-system swiftbuild --disable-index-store -j 2`:
  the same suites and seven optional prompt test functions passed without loading weights.
- Host: Apple M1 Max, 32 GB, macOS 26.6.2, installed Apple Swift 6.4.
  Swift tools 6.2 / Swift 6 mode and macOS 15 / iOS 18 are declared; execution
  with those exact older compiler/runtime combinations remains unverified.
- GitHub did not expose Xcode Cloud status checks for the merged PRs. Local
  validation is not evidence that the configured cloud workflow passed.

Historical live results and their prompt-version limits remain preserved in
[sequential validation](sequential-validation.md). Current live runs and pressure
comparisons belong in reproducible evaluation reports, with failures retained.
No extra model weights, duplicate worktrees or second CI workflow are required.
