---
name: file-proxy
description: Use file-proxy through file-proxy-client. Trigger when Codex needs to call file-proxy worker functions, including file operations, sha256sum, and resumable upload/download commands.
---

# File Proxy Calls

Use this skill only for calling an already running `file-proxy` worker through `file-proxy-client`.

If the worker was started with `--prefix PREFIX` or `PERIODIC_FUNC_PREFIX`, pass the same prefix to `file-proxy-client` with `--prefix PREFIX` or the same environment variable. The prefix is concatenated exactly as provided, for example `--prefix files-` calls `files-download-info`.

## Response Format

Most functions return JSON:

```json
{"ok":true}
```

or:

```json
{"ok":false,"error":{"code":"not_found","message":"path does not exist"}}
```

`get` writes raw file bytes to the requested local path on success.

For files larger than 1 MiB, do not use one-shot transfer commands:

- Uploads larger than 1 MiB must use the resumable `upload-*` flow.
- Downloads larger than 1 MiB must use the ranged `download-*` flow.

## File Operations

Read a file up to 1 MiB:

```bash
file-proxy-client get path/to/file.txt ./local-file
```

Write a file up to 1 MiB:

```bash
file-proxy-client put ./local-file path/to/file.txt --timeout 300
```

List a directory:

```bash
file-proxy-client ls path/to/dir
file-proxy-client ls path/to/dir --recursive --max-depth 2
```

Get metadata or checksums:

```bash
file-proxy-client stat path/to/file.txt
file-proxy-client sha256 path/to/file.txt
file-proxy-client sha256 path/to/dir --recursive
```

Manage paths:

```bash
file-proxy-client mkdir path/to/dir
file-proxy-client mv old/name.txt new/name.txt --overwrite
file-proxy-client cp src/name.txt dst/name.txt --overwrite
file-proxy-client cp src/dir dst/dir --recursive
file-proxy-client rm path/to/file.txt
file-proxy-client rm path/to/dir --recursive
```

`delete-path` only works when the worker was started with `--allow-delete` or `FILE_PROXY_ALLOW_DELETE=true`.

## Directory Transfers

Use directory transfer commands for recursive trees:

```bash
file-proxy-client upload-dir ./local-dir remote/dir --exclude-hidden --timeout 300
file-proxy-client download-dir remote/dir ./local-dir --exclude-hidden --timeout 300
```

Directory transfers preserve relative paths under the directory argument. Files up to 1 MiB use one-shot transfer; larger files automatically use resumable transfer. Add `--exclude-hidden` to skip any path component whose name starts with `.`.

Directory transfer logs and large-file progress bars are written to stderr. The final stdout line remains JSON.

## Resumable Upload

Use resumable upload for every file larger than 1 MiB instead of a single `put`.

```bash
file-proxy-client upload ./big.bin remote/big.bin --chunk-size 1048576 --timeout 300
```

The client computes the full-file SHA-256, begins or resumes the upload, sends chunks, and finishes only after server-side verification passes.

Upload progress is written to stderr. The client prevents concurrent uploads to the same remote path on the same host with a lock under the system temporary directory.

## Large Downloads

Use a resumable/ranged download flow for every file larger than 1 MiB.

Read metadata before downloading chunks:

```bash
file-proxy-client download remote/big.bin ./big.bin --chunk-size 1048576 --timeout 300
```

The client writes to `./big.bin.part`, resumes from that partial file if present, and verifies SHA-256 before renaming it into place.

Download progress is written to stderr. The client prevents concurrent downloads to the same local path with a `<local>.part.lock` file.

## Path Semantics

- Job names are paths relative to the worker root.
- Absolute paths, `..` traversal, and `.file-proxy` internals are rejected.
- `file-proxy-client` defaults to `--timeout 300`; set a larger timeout for large payloads when needed.
