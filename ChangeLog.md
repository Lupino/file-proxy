# Changelog for file-proxy

## Unreleased changes

## v1.1.0.0 - 2026-07-04

### Changed

- Route path-bearing client operations through unique Periodic job names and
  carry file paths in JSON workloads instead of job names.
- Switch `get`, `put`, `upload-dir`, and `download-dir` to checksum-verified
  upload/download flows instead of raw single-shot file transfer functions.
- Remove obsolete `get-file` and `put-file` worker registrations.
- Allow `ls` on a file path to return file metadata through `entry` and a
  single-item `entries` array.
- Keep invalid JSON diagnostics from echoing raw response bodies that could
  contain parseable JSON fragments.

### Fixed

- Prevent expired or malformed worker responses from being written as downloaded
  file contents.
- Avoid path reuse as Periodic job names for file path operations, reducing the
  chance of stale or expired job results colliding with later requests.
- Ensure stdout remains reserved for final machine-readable JSON responses while
  transfer progress and diagnostics stay on stderr.

## v1.0.0.0 - 2026-07-03

### Added

- Add `file-proxy-client` for direct file operations without calling
  `periodic run` manually.
- Add client commands for `get`, `put`, `ls`, `stat`, `sha256`, `mkdir`, `mv`,
  `cp`, `rm`, `upload`, `download`, `upload-dir`, and `download-dir`.
- Add resumable upload support with chunk tracking, SHA-256 verification, and
  final publish only after checksum validation.
- Add resumable download support with partial files, progress metadata, resume
  handling, and final SHA-256 verification.
- Add recursive directory upload and download commands with optional hidden-file
  exclusion.
- Add worker APIs for path metadata, SHA-256 manifests, directory creation,
  move/copy/delete, resumable upload, and resumable download.
- Add configurable worker function prefixes through `--prefix` and
  `PERIODIC_FUNC_PREFIX`.
- Add Hspec coverage for path safety, file APIs, resumable transfers, client
  helper behavior, and function prefixing.

### Changed

- Split the package library into `FileProxy.Client` and `FileProxy.Worker`
  modules.
- Rename the worker executable entrypoint to `file-proxy-worker.hs` while
  keeping the `file-proxy` executable name.
- Default transfer chunk size to 1 MiB.
- Document JSON response formats, client commands, resumable transfer behavior,
  and worker/client prefix usage.
- Package both `file-proxy` and `file-proxy-client` in platform build outputs
  and macOS bundles.

### Fixed

- Make client transfer locks portable by using temporary-directory lock files.
- Improve resumable transfer stability for interrupted or repeated chunk
  operations.

## v0.1.0.0 - 2026-07-03

First release of `file-proxy`, a Periodic worker for exposing file operations
under a configured filesystem root.

### Added

- Register `get-file`, `put-file`, and `get-directory` worker functions.
- Add configurable filesystem root, Periodic host, and worker concurrency.
- Support plain socket transport and RSA-wrapped transport with selectable
  `Plain`, `RSA`, or `AES` modes.
- Support authenticated worker startup with `--client-name` and
  `--client-token`, also configurable through environment variables.
- Return directory listings as JSON with file and directory metadata.
- Add Stack/Cabal project metadata and README usage documentation.
- Add Nix packaging support, cross-platform build targets, and macOS bundle
  release packaging.
