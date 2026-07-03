---
name: file-proxy
description: Use file-proxy through the Periodic client. Trigger when Codex needs to call file-proxy worker functions with periodic run, including file operations, sha256sum, and resumable upload commands.
---

# File Proxy Calls

Use this skill only for calling an already running `file-proxy` worker through `periodic`.

## Response Format

Most functions return JSON:

```json
{"ok":true}
```

or:

```json
{"ok":false,"error":{"code":"not_found","message":"path does not exist"}}
```

`get-file` returns raw file bytes on success.

## File Operations

Read a file:

```bash
periodic run get-file path/to/file.txt
```

Write a file:

```bash
periodic run put-file path/to/file.txt --workload @file-path --timeout 300
```

List a directory:

```bash
periodic run get-directory path/to/dir
periodic run get-directory path/to/dir --workload '{"recursive":true,"maxDepth":2}'
```

Get metadata or checksums:

```bash
periodic run stat-path path/to/file.txt
periodic run sha256sum path/to/file.txt
periodic run sha256sum path/to/dir --workload '{"recursive":true}'
```

Manage paths:

```bash
periodic run make-directory path/to/dir
periodic run move-path old/name.txt --workload '{"to":"new/name.txt","overwrite":false}'
periodic run copy-path src/name.txt --workload '{"to":"dst/name.txt","overwrite":false}'
periodic run delete-path path/to/file.txt
periodic run delete-path path/to/dir --workload '{"recursive":true}'
```

`delete-path` only works when the worker was started with `--allow-delete` or `FILE_PROXY_ALLOW_DELETE=true`.

## Resumable Upload

Use resumable upload for large files instead of a single `put-file`.

Begin or resume:

```bash
periodic run upload-begin remote/big.bin --workload '{"size":52428800,"sha256":"<full-file-sha256>","chunkSize":8388608}'
```

Upload a chunk:

```bash
periodic run upload-chunk '<uploadId>/<offset>/<chunk-sha256>' --workload @chunk.bin --timeout 300
```

Check status:

```bash
periodic run upload-status <uploadId>
```

Finish:

```bash
periodic run upload-finish <uploadId>
```

Abort:

```bash
periodic run upload-abort <uploadId>
```

Chunk uploads are idempotent when the same offset, size, and chunk SHA-256 are sent again. Conflicting overlapping chunks return `chunk_conflict`.

## Path Semantics

- Job names are paths relative to the worker root.
- Absolute paths, `..` traversal, and `.file-proxy` internals are rejected.
- `@file-path` is read by the local `periodic` client and sent as workload bytes.
- `periodic run` defaults to `--timeout 10`; set a larger timeout for `put-file` and `upload-chunk` with large payloads.
