---
name: file-proxy
description: Upload or download files and directories with file-proxy; start a Periodic file worker; open the Web UI for an existing worker; or serve a local filesystem through the standalone Web UI. Trigger for requests to upload, download, transfer, copy, list, checksum, host, start, serve, or open file-proxy services. Choose file-proxy, file-proxy-client, file-proxy-web, or file-proxy-web-standalone by deployment model.
---

# File Proxy

Use this skill when the user asks to host, operate, or open a file proxy. Choose exactly one path below before issuing a command.

## Trigger Examples

Use this skill for requests such as "upload this file", "download this directory", "copy files to the worker", "list remote files", "calculate a remote SHA-256", "start a file-proxy worker", "open the file-proxy Web UI", or "serve this local directory in the standalone Web UI".

The user may also explicitly invoke it with `$file-proxy`.

## Command Selection

| User need | Command | Required dependency | Do not use when |
| --- | --- | --- | --- |
| Run the Periodic worker that owns a filesystem root | `file-proxy` | Periodic server and permitted connection configuration | The user only needs a local browser UI without Periodic |
| Script or perform a file operation against an existing worker | `file-proxy-client` | An already running `file-proxy` worker | The user asks to start a worker or use a graphical UI |
| Open a browser UI for an existing Periodic worker | `file-proxy-web` | An already running `file-proxy` worker | The user wants direct local-root access without Periodic |
| Open a browser UI directly over a local filesystem root | `file-proxy-web-standalone` | An explicit permitted local root; no Periodic services | The user needs to reach a remote or Periodic worker |

Do not start a long-running worker or Web service unless the user explicitly asks to start, host, serve, or open it. For a local filesystem service, require the user to provide the root path; do not infer it from the current directory.

## Released Binaries

Use installed release binaries for every command: `file-proxy`, `file-proxy-client`, `file-proxy-web`, and `file-proxy-web-standalone`. If the required command is not installed, download the matching operating-system and architecture release from <https://github.com/Lupino/file-proxy/releases>, verify its published checksum when available, and install the released binary before continuing. Do not fall back to `stack exec` or a source build for this workflow.

## Environment And Credentials

Do not inspect, print, set, export, source, expand, or forward environment variables while using this skill. Do not use `env`, `printenv`, shell variable expansion, or commands that expose process configuration or credentials.

All four binaries read environment-based defaults during startup. If the task prohibits any environment-variable access, do not invoke one of these binaries; report that the requested operation cannot run under that boundary.

Do not pass credentials, private-key paths, or tokens on the command line. Use a Periodic-backed command only when the operator has already provided a permitted, non-sensitive connection path and the environment-access boundary permits the command to run.

Do not pass `--prefix`. Periodic-backed commands use their configured `PERIODIC_FUNC_PREFIX` default. The prefix is concatenated exactly as configured; for example, `files-` calls `files-download-info`.

## Worker Service

Use `file-proxy` only to host filesystem operations through Periodic. It is the service that `file-proxy-client` and `file-proxy-web` reach; it is not a command for individual file operations.

After the user explicitly requests a worker and gives its permitted root, start it with:

```bash
file-proxy --root /path/to/root
```

Do not enable deletion while starting the worker. `--allow-delete` requires explicit user authorization for deletion, in addition to the request to start the service.

## Periodic Web UI

Use `file-proxy-web` only when the user explicitly asks for a graphical interface to an existing Periodic worker. Ensure the worker is already running before starting the gateway; do not replace this gateway with `file-proxy-web-standalone`.

Start the already built gateway with:

```bash
file-proxy-web
```

Default to local access at `http://127.0.0.1:8080/` and keep the gateway bound to loopback. Before starting the UI, ask whether the user needs public Internet access.

If the user explicitly requests public access, keep the gateway on `127.0.0.1` and expose it through Cloudflare Tunnel instead of binding the gateway to a LAN or public interface:

```bash
cloudflared tunnel --url http://127.0.0.1:8080
```

Report the tunnel URL only to the requesting user. Do not create a public tunnel without explicit approval. Do not start the Vite development server unless the user specifically requests frontend development.

## Standalone Web UI

Use `file-proxy-web-standalone` only when the user explicitly requests a graphical interface for a permitted local root and does not need Periodic. It serves the same embedded UI but calls the file APIs directly.

After the user provides the root, start it with:

```bash
file-proxy-web-standalone --root /path/to/root
```

It binds to `127.0.0.1:8080` by default. Apply the same local-only and explicit-Cloudflare-Tunnel policy as `file-proxy-web`. Do not enable `--allow-delete` without explicit user authorization. Never use this command to access a remote worker.

## Client Operations

Use `file-proxy-client` only for non-graphical operations against an already running `file-proxy` worker. It does not start the worker or provide a Web server.

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
