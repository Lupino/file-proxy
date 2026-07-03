# file-proxy

`file-proxy` is a Periodic worker that exposes file operations under a configured filesystem root.

## Build

```bash
stack build --fast
```

Check CLI options:

```bash
stack exec file-proxy -- --help
```

## Run

```bash
stack exec file-proxy -- --host unix:///tmp/periodic.sock --root /path/to/root
```

`--host` can also come from `PERIODIC_PORT`:

```bash
PERIODIC_PORT=unix:///tmp/periodic.sock stack exec file-proxy -- --root /path/to/root
```

## Options

- `-H, --host HOST`: Periodic socket/address. Env: `PERIODIC_PORT`. Default: `unix:///tmp/periodic.sock`.
- `-r, --root ROOT`: filesystem root. Default: `.`.
- `-t, --thread INT`: worker concurrency. Default: `10`.
- `--rsa-private-path PATH`: RSA private key. Env: `PERIODIC_RSA_PRIVATE_PATH`.
- `--rsa-public-path PATH`: server public key file or directory. Env: `PERIODIC_RSA_PUBLIC_PATH`. Default: `public_key.pem`.
- `--rsa-mode MODE`: `Plain`, `RSA`, or `AES`. Env: `PERIODIC_RSA_MODE`. Default: `AES`.
- `--client-name NAME`: auth client name. Env: `PERIODIC_CLIENT_NAME`.
- `--client-token TOKEN`: auth client token. Env: `PERIODIC_CLIENT_TOKEN`.
- `--allow-delete`: allow `delete-path`. Env: `FILE_PROXY_ALLOW_DELETE=true`. Default: disabled.

If `--rsa-private-path` is empty, the worker uses a plain socket transport. If it is non-empty, the worker wraps the socket with RSA using `--rsa-mode`, `--rsa-private-path`, and `--rsa-public-path`.

`--client-name` and `--client-token` must be provided together.

## Response Format

Non-binary functions return JSON:

```json
{"ok":true}
```

or:

```json
{"ok":false,"error":{"code":"not_found","message":"path does not exist"}}
```

`get-file` returns raw file bytes on success. Missing or invalid files fail the job instead of returning an error string as file content.

## File Functions

```bash
periodic run get-file path/to/file.txt
periodic run put-file path/to/file.txt --workload @local-file --timeout 300
periodic run get-directory path/to/dir
periodic run get-directory path/to/dir --workload '{"recursive":true,"maxDepth":2}'
periodic run stat-path path/to/file.txt
periodic run sha256sum path/to/file.txt
periodic run sha256sum path/to/dir --workload '{"recursive":true}'
periodic run make-directory path/to/dir
periodic run move-path old/name.txt --workload '{"to":"new/name.txt","overwrite":false}'
periodic run copy-path src/name.txt --workload '{"to":"dst/name.txt","overwrite":false}'
periodic run delete-path path/to/file.txt
periodic run delete-path path/to/dir --workload '{"recursive":true}'
```

Paths are relative to the worker root. Absolute paths, `..` traversal, and `.file-proxy` internals are rejected.

`delete-path` is disabled unless the worker is started with `--allow-delete` or `FILE_PROXY_ALLOW_DELETE=true`.

## Resumable Upload

Use `upload-*` for large files. It stores temporary state under the worker root in `.file-proxy/uploads/` and publishes the target file only after the final SHA-256 matches.

Start or resume a session:

```bash
periodic run upload-begin remote/big.bin \
  --workload '{"size":52428800,"sha256":"<full-file-sha256>","chunkSize":8388608}'
```

Upload chunks:

```bash
periodic run upload-chunk '<uploadId>/<offset>/<chunk-sha256>' \
  --workload @chunk.bin \
  --timeout 300
```

Check progress:

```bash
periodic run upload-status <uploadId>
```

Finish and verify:

```bash
periodic run upload-finish <uploadId>
```

Abort:

```bash
periodic run upload-abort <uploadId>
```

Chunk uploads are idempotent when the same offset, size, and chunk SHA-256 are sent again. Conflicting overlapping chunks return `chunk_conflict`.

`periodic run` defaults to `--timeout 10`. Set a larger timeout for `put-file` and `upload-chunk` when sending large payloads.
