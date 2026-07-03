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

If `--rsa-private-path` is empty, the worker uses a plain socket transport. If it is non-empty, the worker wraps the socket with RSA using `--rsa-mode`, `--rsa-private-path`, and `--rsa-public-path`.

`--client-name` and `--client-token` must be provided together.

## Functions

The worker registers:

- `get-file`
- `put-file`
- `get-directory`

Use the Periodic client to call them:

```bash
periodic run get-file path/to/file.txt
periodic run put-file path/to/file.txt --workload 'content'
periodic run put-file path/to/file.txt --workload @file-path
periodic run get-directory path/to/dir
```
