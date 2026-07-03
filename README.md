# file-proxy

`file-proxy` is a Periodic worker that exposes file operations under a configured filesystem root. `file-proxy-client` is the file-oriented client for calling that worker without using `periodic run` directly.

## Build

```bash
stack build --fast
```

Check CLI options:

```bash
stack exec file-proxy -- --help
stack exec file-proxy-client -- --help
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
file-proxy-client get path/to/file.txt ./local-file
file-proxy-client put ./local-file path/to/file.txt
file-proxy-client ls path/to/dir
file-proxy-client ls path/to/dir --recursive --max-depth 2
file-proxy-client stat path/to/file.txt
file-proxy-client sha256 path/to/file.txt
file-proxy-client sha256 path/to/dir --recursive
file-proxy-client download path/to/file.txt ./local-file
file-proxy-client mkdir path/to/dir
file-proxy-client mv old/name.txt new/name.txt --overwrite
file-proxy-client cp src/name.txt dst/name.txt --overwrite
file-proxy-client rm path/to/file.txt
file-proxy-client rm path/to/dir --recursive
```

Paths are relative to the worker root. Absolute paths, `..` traversal, and `.file-proxy` internals are rejected.

`delete-path` is disabled unless the worker is started with `--allow-delete` or `FILE_PROXY_ALLOW_DELETE=true`.

## Resumable Upload

Use `upload` for large files. It stores temporary state under the worker root in `.file-proxy/uploads/` and publishes the target file only after the final SHA-256 matches.

```bash
file-proxy-client upload ./big.bin remote/big.bin --chunk-size 8388608 --timeout 300
```

The client calls `upload-begin`, `upload-chunk`, and `upload-finish` internally. Chunk uploads remain idempotent when the same offset, size, and chunk SHA-256 are sent again. Conflicting overlapping chunks return `chunk_conflict`.

Use `--timeout` when sending large payloads.

## Resumable Download

Use `download` for large files. The client writes to `<local>.part`, resumes from that partial file if present, and verifies the completed local file against the server SHA-256 before renaming it into place.

```bash
file-proxy-client download remote/big.bin ./big.bin --chunk-size 8388608 --timeout 300
```

The worker still serves `download-info` and `download-chunk` internally. `download-chunk` returns raw file bytes on success. If a requested range extends past EOF, it returns the remaining bytes. Offsets past EOF are rejected with `range_out_of_bounds`.
