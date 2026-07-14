export type Entry = {
  name: string
  path: string
  type: 'file' | 'directory' | 'other'
  size?: number
  modifiedAt: string
  sha256?: string
  children?: Entry[]
}

type ApiResponse<T> = { ok: boolean; error?: { code: string; message: string } } & T

async function request<T>(url: string, init?: RequestInit): Promise<T> {
  const response = await fetch(url, init)
  if (!response.ok) throw new Error(`HTTP ${response.status}`)
  const value = await response.json() as ApiResponse<T>
  if (!value.ok) throw new Error(`${value.error?.code ?? 'request_failed'}: ${value.error?.message ?? 'request failed'}`)
  return value
}

export const list = (path: string) => request<{ entries: Entry[] }>(`/api/list?path=${encodeURIComponent(path)}`)
export const stat = (path: string) => request<{ entry: Entry }>(`/api/stat?path=${encodeURIComponent(path)}`)
export const mkdir = (path: string) => request(`/api/mkdir?path=${encodeURIComponent(path)}`, { method: 'POST' })
export const move = (from: string, to: string, overwrite = false) => request('/api/move', { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ from, to, overwrite }) })
export const copy = (from: string, to: string, overwrite = false, recursive = false) => request('/api/copy', { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ from, to, overwrite, recursive }) })
export const remove = (path: string, recursive = false) => request('/api/delete', { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ path, recursive }) })

export async function uploadFile(file: File, remotePath: string, onProgress: (value: number) => void) {
  const chunkSize = 1024 * 1024
  const sha256 = await digest(file)
  const begin = await request<{ uploadId: string; nextOffset: number }>('/api/upload/begin', { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ size: file.size, sha256, chunkSize, path: remotePath }) })
  let offset = begin.nextOffset
  while (offset < file.size) {
    const chunk = file.slice(offset, Math.min(file.size, offset + chunkSize))
    const bytes = new Uint8Array(await chunk.arrayBuffer())
    const chunkSha = await digest(bytes)
    const result = await request<{ nextOffset: number }>(`/api/upload/chunk/${begin.uploadId}/${offset}/${chunkSha}`, { method: 'PUT', body: bytes })
    offset = result.nextOffset > offset ? result.nextOffset : offset + bytes.byteLength
    onProgress(offset / file.size)
  }
  await request(`/api/upload/finish/${begin.uploadId}`, { method: 'POST' })
}

export function downloadUrl(path: string) { return `/api/download/info?path=${encodeURIComponent(path)}` }

export async function downloadFile(path: string, name: string) {
  const blob = await fetchFileBlob(path)
  const objectUrl = URL.createObjectURL(blob)
  const anchor = document.createElement('a')
  anchor.href = objectUrl
  anchor.download = name
  anchor.click()
  URL.revokeObjectURL(objectUrl)
}

export async function fetchFileBlob(path: string, onProgress?: (value: number) => void) {
  const info = await request<{ size: number }>(downloadUrl(path))
  const chunks: BlobPart[] = []
  const chunkSize = 1024 * 1024
  let downloaded = 0
  onProgress?.(0)
  for (let offset = 0; offset < info.size; offset += chunkSize) {
    const response = await fetch(`/api/download/chunk?path=${encodeURIComponent(path)}&offset=${offset}&size=${chunkSize}`)
    if (!response.ok) throw new Error(`HTTP ${response.status}`)
    const chunk = await response.blob()
    chunks.push(chunk)
    downloaded += chunk.size
    onProgress?.(Math.min(downloaded / info.size, 1))
  }
  onProgress?.(1)
  return new Blob(chunks)
}

async function digest(value: Blob | ArrayBuffer | Uint8Array): Promise<string> {
  const buffer: ArrayBuffer = value instanceof Blob ? await value.arrayBuffer() : value instanceof Uint8Array ? new Uint8Array(value).buffer : value
  const hash = await crypto.subtle.digest('SHA-256', buffer)
  return [...new Uint8Array(hash)].map(byte => byte.toString(16).padStart(2, '0')).join('')
}
