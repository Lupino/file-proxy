---
name: file-proxy
description: Use file-proxy through the Periodic client. Trigger when Codex needs to call file-proxy worker functions with periodic run, including get-file, put-file, and get-directory commands, job-name path semantics, workload file upload syntax, and get-directory JSON response interpretation.
---

# File Proxy Calls

Use this skill only for calling an already running `file-proxy` worker through `periodic`.

## Functions

`file-proxy` exposes three Periodic functions:

- `get-file`: read a file.
- `put-file`: write a file.
- `get-directory`: list one directory level.

The job name is the target path relative to the worker root.

## Commands

Read a file:

```bash
periodic run get-file path/to/file.txt
```

Write literal content:

```bash
periodic run put-file path/to/file.txt --workload 'content'
```

Write local file content:

```bash
periodic run put-file path/to/file.txt --workload @file-path
```

List a directory:

```bash
periodic run get-directory path/to/dir
```

## Path Semantics

- `path/to/file.txt` is the target path inside the file-proxy worker root.
- `@file-path` is read by the local `periodic` client and sent as workload bytes.
- Do not include `..` traversal assumptions; file-proxy normalizes paths before joining with its root.

## get-directory Response

`get-directory` returns direct children only, not recursive contents.

Directory entry:

```json
{
  "name": "src",
  "type": "directory",
  "modifiedAt": "2026-07-02T15:00:00Z",
  "fileCount": 1,
  "children": []
}
```

File entry:

```json
{
  "name": "README.md",
  "type": "file",
  "size": 13,
  "modifiedAt": "2026-07-02T15:00:00Z"
}
```

`fileCount` is the number of direct regular files inside that directory, not a recursive total.
