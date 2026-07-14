---
name: file-proxy
description: Use file-proxy through file-proxy-client for file operations, sha256sum, and resumable transfers. Use when calling an already running worker is authorized without inspecting, exposing, or modifying environment variables.
---

# File Proxy Calls

Use this skill only for calling an already running `file-proxy` worker through `file-proxy-client`.

Do not pass `--prefix`. Let `file-proxy-client` use its configured default prefix from `PERIODIC_FUNC_PREFIX`. The prefix is concatenated exactly as configured; for example, `files-` calls `files-download-info`.

## Environment Boundary

Do not inspect, print, set, export, source, expand, or forward environment variables while using this skill. Do not use `env`, `printenv`, shell variable expansion, or commands that expose process configuration or credentials.

The current `file-proxy-client` implementation reads `PERIODIC_*` environment variables during startup, even when equivalent command-line options are supplied. Therefore, when the task prohibits *any* environment-variable access, do not invoke `file-proxy-client` or the worker. Report that this skill cannot perform the operation under that boundary; changing this requires an explicit code change to remove the client's environment lookups.

Do not pass credentials, private-key paths, or tokens on the command line. Use this skill only when the operator has already provided a permitted, non-sensitive connection path and the environment-access boundary permits the client to run.

## Released Binaries

Use installed release binaries for every `file-proxy*` command, including `file-proxy`, `file-proxy-client`, and `file-proxy-web`. If the required command is not installed, download the matching operating-system and architecture release from <https://github.com/Lupino/file-proxy/releases>, verify its published checksum when available, and install the released binary before continuing. Do not fall back to `stack exec` or a source build for this workflow.

## Web UI

Use the Web UI only when the user explicitly asks to open or use a graphical interface. `file-proxy-web` serves the embedded React client and proxies its `/api` requests to the Periodic worker.

Start the already built gateway with:

```bash
file-proxy-web
```

Before starting the UI, ask whether the user needs public Internet access. Default to local access at `http://127.0.0.1:8080/` and keep the gateway bound to loopback.

If the user explicitly requests public access, keep the gateway on `127.0.0.1` and expose it through Cloudflare Tunnel instead of binding the gateway to a LAN or public interface:

```bash
cloudflared tunnel --url http://127.0.0.1:8080
```

Report the tunnel URL only to the requesting user. Do not create a public tunnel without explicit approval. Do not pass `--prefix`; the gateway uses its existing `PERIODIC_FUNC_PREFIX` default. Do not start the Vite development server unless the user specifically requests frontend development.

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

`delete-path` requires deletion to be authorized by the worker operator before this skill runs. Do not enable deletion as part of this skill.

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
