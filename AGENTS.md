# AGENTS.md

## Project overview

`file-proxy` is a Haskell/Stack project. It exposes filesystem operations
through Periodic worker RPCs and provides a command-line client.

Important areas:

- `src/FileProxy/Worker.hs`: worker options, RPC handlers, path validation,
  file operations, and resumable upload/download state.
- `src/FileProxy/Client.hs`: CLI parsing, RPC calls, directory transfers,
  progress reporting, locks, and resumable local files.
- `test/Spec.hs`: Hspec regression tests.
- `package.yaml`: primary package/dependency configuration.
- `file-proxy.cabal`: generated Cabal output; regenerate it from
  `package.yaml` when package metadata changes.

## Working principles

- Inspect the relevant implementation and tests before editing.
- State important assumptions when behavior is ambiguous; do not silently
  invent a new protocol or CLI contract.
- Make the smallest change that solves the request. Do not refactor unrelated
  code, rename public fields, or add speculative abstractions.
- Preserve existing CLI commands, RPC names, JSON fields, and error codes
  unless the request explicitly requires a compatibility change.
- Preserve user changes, including untracked files. Never use destructive git
  commands or remove build/output files unless explicitly requested.
- Every changed line should be directly related to the request. Remove only
  imports, bindings, or tests made obsolete by the change.

## Haskell workflow

- Match the existing Haskell style and language extensions.
- Prefer strict `ByteString` for bounded payloads and streaming or handle-based
  IO for large files.
- Keep pure validation and state calculations separate from filesystem and RPC
  effects when practical.
- Avoid broad exception swallowing. Return the existing structured API error
  when an operation is expected to fail; let unexpected failures remain
  visible in worker logs.
- After source or package changes, run:

  ```bash
  stack build --fast
  stack test --fast
  ```

- If validation cannot run because Stack, Nix, network, or cache permissions
  are unavailable, report the exact blocker and do not claim the change is
  verified.

## Filesystem security

- All client-supplied remote paths must go through the shared path-resolution
  path before filesystem access.
- Reject absolute paths, `..` traversal, and `.file-proxy` internals.
- When changing path handling, account for symlink escapes and TOCTOU races;
  lexical checks alone are not sufficient for a security-sensitive write or
  delete operation.
- Keep temporary upload state private to `.file-proxy/uploads/` and never make
  it visible through normal listing or user path operations.
- Deletion remains explicitly opt-in through the existing worker option and
  environment variable.

## Transfer correctness

- Resumable uploads must remain idempotent for an identical chunk and reject
  conflicting overlaps.
- An upload may replace the target only after size and SHA-256 verification
  succeeds; partial data must never be published as the final file.
- Download resume state must keep `.part` and its metadata consistent, verify
  the completed SHA-256, and publish the final file only after verification.
- Consider multiple clients and worker threads when changing upload session
  metadata, chunk files, or finalization. A client-side lock is not a
  server-side concurrency guarantee.
- Keep recovery behavior explicit for missing, truncated, malformed, or stale
  temporary state.

## Performance expectations

- Do not load an unbounded file or recursive directory tree into memory merely
  to copy or transfer it.
- Avoid repeated full-file hashing in one user operation when metadata or a
  verified transfer can be reused safely.
- Treat recursive listing, manifest generation, copy, and directory transfer as
  potentially large workloads; preserve deterministic ordering without making
  unnecessary extra passes.
- Keep upload-session state updates bounded. Do not repeatedly rewrite a large
  state document without measuring the cost and considering a more suitable
  representation.
- For an optimization, add a representative regression or benchmark scenario
  and compare correctness as well as resource usage.

## Testing requirements

Add or update focused tests for behavior changes. At minimum, consider:

- absolute paths, traversal, reserved paths, and symlink-based escapes;
- missing files, invalid ranges, malformed metadata, and stale partial files;
- duplicate and overlapping upload chunks, concurrent session updates, and
  interrupted finalization;
- checksum mismatch and successful atomic publication;
- empty files, boundary-sized chunks, large files, and recursive directories;
- preservation of existing CLI/RPC response shapes and error codes.

Prefer a small regression test that reproduces a bug before changing the
implementation. Keep integration tests deterministic and avoid relying on a
running external worker unless the test specifically covers the transport.

## Change checklist

Before finishing:

1. Review the diff and confirm that every change is in scope.
2. Check for unused imports, partial pattern matches, unchecked integer
   conversions, and lazy whole-file reads on large-file paths.
3. Run `stack build --fast` and `stack test --fast` when available.
4. Check `git status --short` and leave unrelated user files untouched.
5. Summarize changed behavior, compatibility impact, and validation results.
