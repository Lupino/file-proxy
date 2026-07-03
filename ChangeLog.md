# Changelog for file-proxy

## Unreleased changes

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
