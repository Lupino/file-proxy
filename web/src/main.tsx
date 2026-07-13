import React from 'react'
import { createRoot } from 'react-dom/client'
import { useFileStore } from './store'
import { downloadFile, fetchFileBlob, list } from './api'
import type { Entry } from './api'
import type { UploadTask } from './store'
import './index.css'

type SortKey = 'name' | 'modified' | 'size'

function App() {
  const { path, entries, loading, busy, error, uploadTasks, uploadPanelOpen, open, openUploadPanel, upload, remove, moveEntry, createFolder, closeUploadPanel } = useFileStore()
  const [preview, setPreview] = React.useState<{ url: string; name: string } | null>(null)
  const [activeAction, setActiveAction] = React.useState<string | null>(null)
  const [uploadNotice, setUploadNotice] = React.useState<string | null>(null)
  const [movingEntry, setMovingEntry] = React.useState<Entry | null>(null)
  const [moveDirectory, setMoveDirectory] = React.useState('')
  const [sortKey, setSortKey] = React.useState<SortKey>('name')
  const [sortDescending, setSortDescending] = React.useState(false)
  React.useEffect(() => { void open('.') }, [open])
  React.useEffect(() => {
    if (busy !== 'upload' && uploadTasks.length > 0 && uploadTasks.every(task => task.status === 'completed' || task.status === 'error')) {
      const completed = uploadTasks.filter(task => task.status === 'completed').length
      const failed = uploadTasks.length - completed
      setUploadNotice(failed > 0 ? `${completed} uploaded, ${failed} failed` : `${completed} ${completed === 1 ? 'file' : 'files'} uploaded successfully`)
      const timer = window.setTimeout(() => setUploadNotice(null), 4500)
      return () => window.clearTimeout(timer)
    }
  }, [busy, uploadTasks])

  const parts = path === '.' ? [] : path.split('/')
  const navigate = (index: number) => void open(index < 0 ? '.' : parts.slice(0, index + 1).join('/'))
  const totalSize = entries.reduce((total, entry) => total + (entry.size ?? 0), 0)
  const sortedEntries = React.useMemo(() => [...entries].sort((left, right) => {
    let result = 0
    if (sortKey === 'name') result = left.name.localeCompare(right.name, undefined, { sensitivity: 'base' })
    if (sortKey === 'modified') result = new Date(left.modifiedAt).getTime() - new Date(right.modifiedAt).getTime()
    if (sortKey === 'size') result = (left.size ?? -1) - (right.size ?? -1)
    if (result === 0) result = left.name.localeCompare(right.name, undefined, { sensitivity: 'base' })
    return sortDescending ? -result : result
  }), [entries, sortDescending, sortKey])
  const changeSort = (key: SortKey) => {
    if (sortKey === key) setSortDescending(value => !value)
    else { setSortKey(key); setSortDescending(false) }
  }
  const sortLabel = sortKey === 'name' ? 'Name' : sortKey === 'modified' ? 'Modified' : 'Size'

  const showPreview = async (entry: Entry) => {
    setActiveAction(`preview:${entry.path}`)
    try {
      const blob = await fetchFileBlob(entry.path)
      setPreview(current => { if (current) URL.revokeObjectURL(current.url); return { url: URL.createObjectURL(blob), name: entry.name } })
    } catch (previewError) {
      useFileStore.setState({ error: previewError instanceof Error ? previewError.message : 'could not preview image' })
    } finally { setActiveAction(null) }
  }
  const download = async (entry: Entry) => {
    setActiveAction(`download:${entry.path}`)
    try { await downloadFile(entry.path, entry.name) }
    catch (downloadError) { useFileStore.setState({ error: downloadError instanceof Error ? downloadError.message : 'download failed' }) }
    finally { setActiveAction(null) }
  }
  const closePreview = () => { if (preview) URL.revokeObjectURL(preview.url); setPreview(null) }
  const submitMove = async (event: React.FormEvent) => {
    event.preventDefault()
    if (!movingEntry) return
    await moveEntry(movingEntry, moveDirectory)
    if (!useFileStore.getState().error) setMovingEntry(null)
  }

  return <><main className="min-h-screen bg-slate-100 px-4 py-6 text-slate-900 sm:px-8 lg:px-12">
    <header className="mx-auto mb-6 flex max-w-7xl items-start justify-between gap-4">
      <div className="flex items-center gap-3">
        <div className="grid h-12 w-12 place-items-center rounded-2xl bg-blue-600 text-2xl text-white shadow-lg shadow-blue-200">▦</div>
        <div><h1 className="text-2xl font-bold tracking-tight sm:text-3xl">File Proxy</h1><p className="mt-0.5 text-sm text-slate-500">Remote files, organized simply</p></div>
      </div>
      <div className="flex gap-2">
        {uploadTasks.length > 0 && <button className="button-quiet hidden sm:inline-flex" disabled={busy === 'upload'} onClick={openUploadPanel}>Uploads ({uploadTasks.length})</button>}
        <label className={`button-primary ${busy ? 'pointer-events-none opacity-60' : ''}`}><>{busy === 'upload' ? <Spinner /> : <span>↑</span>} {busy === 'upload' ? 'Uploading…' : 'Upload files'}</><input className="hidden" type="file" multiple disabled={busy !== null} onChange={event => event.target.files && void upload(event.target.files)} /></label>
        <label className={`button-secondary hidden sm:inline-flex ${busy ? 'pointer-events-none opacity-60' : ''}`}><>{busy === 'upload' ? <Spinner /> : <span>▣</span>} {busy === 'upload' ? 'Uploading…' : 'Upload folder'}</><input className="hidden" type="file" multiple disabled={busy !== null} {...({ webkitdirectory: '' } as React.InputHTMLAttributes<HTMLInputElement>)} onChange={event => event.target.files && void upload(event.target.files)} /></label>
      </div>
    </header>

    <section className="mx-auto max-w-7xl overflow-hidden rounded-2xl border border-slate-200 bg-white shadow-sm">
      <div className="border-b border-slate-200 px-5 py-4 sm:px-7">
        <div className="flex flex-wrap items-center justify-between gap-3">
          <nav className="flex min-w-0 items-center gap-1.5 text-sm font-medium" aria-label="Breadcrumb">
            <button className="breadcrumb-muted" disabled={busy !== null || activeAction !== null} onClick={() => void open('.')}>Home</button>
            {parts.map((part, index) => <React.Fragment key={`${part}-${index}`}><span className="text-slate-300">/</span><button disabled={busy !== null || activeAction !== null} className={index === parts.length - 1 ? 'breadcrumb-current' : 'breadcrumb-muted'} onClick={() => navigate(index)}>{part}</button></React.Fragment>)}
          </nav>
          <div className="flex items-center gap-2">
            <button className="button-quiet" disabled={busy !== null} onClick={() => void createFolder()}>{busy === 'folder' ? <Spinner /> : <span>＋</span>} {busy === 'folder' ? 'Creating…' : 'New folder'}</button>
            <button className="button-quiet" disabled={busy !== null} title="Refresh" onClick={() => void open(path)}>{busy === 'open' ? <Spinner /> : '↻'}</button>
          </div>
        </div>
        <div className="mt-4 flex items-center justify-between text-xs text-slate-400"><span>{entries.length} {entries.length === 1 ? 'item' : 'items'}{entries.length > 0 && ` · ${formatBytes(totalSize)}`}</span><span>Sorted by {sortLabel.toLowerCase()} {sortDescending ? '↓' : '↑'}</span></div>
      </div>

      {error && <div className="mx-5 mt-4 flex items-start justify-between gap-4 rounded-xl border border-red-100 bg-red-50 px-4 py-3 text-sm text-red-700 sm:mx-7"><span><strong className="mr-1">Something went wrong.</strong>{error}</span><button className="text-lg leading-none" aria-label="Dismiss" onClick={() => useFileStore.setState({ error: null })}>×</button></div>}
      {loading ? <div className="flex flex-col items-center gap-3 px-6 py-20 text-sm text-slate-400"><Spinner large />Loading files…</div> : entries.length ? <div className="px-3 pb-3 sm:px-5"><div className="file-table-header"><button className="table-sort text-left" disabled={busy !== null} onClick={() => changeSort('name')}>Name {sortKey === 'name' && (sortDescending ? '↓' : '↑')}</button><button className="table-sort text-left" disabled={busy !== null} onClick={() => changeSort('modified')}>Modified {sortKey === 'modified' && (sortDescending ? '↓' : '↑')}</button><button className="table-sort text-right" disabled={busy !== null} onClick={() => changeSort('size')}>Size {sortKey === 'size' && (sortDescending ? '↓' : '↑')}</button><span /></div>{sortedEntries.map(entry => <Row key={entry.path} entry={entry} open={open} remove={remove} move={entry => { setMovingEntry(entry); setMoveDirectory('') }} preview={showPreview} download={download} busy={busy !== null || activeAction !== null} activeAction={activeAction} />)}</div> : <EmptyState onUpload={() => document.querySelector<HTMLInputElement>('input[type=file]')?.click()} />}
    </section>
    <p className="mx-auto mt-4 max-w-7xl px-1 text-xs text-slate-400">Tip: click a folder name to open it. Files are uploaded with checksum verification.</p>
  </main>{uploadNotice && <div className="fixed bottom-5 right-5 z-20 flex items-center gap-3 rounded-xl bg-slate-900 px-4 py-3 text-sm font-medium text-white shadow-xl"><span className="grid h-6 w-6 place-items-center rounded-full bg-emerald-500">✓</span>{uploadNotice}</div>}{uploadPanelOpen && <UploadModal tasks={uploadTasks} busy={busy === 'upload'} close={closeUploadPanel} />}{movingEntry && <MoveModal entry={movingEntry} directory={moveDirectory} setDirectory={setMoveDirectory} busy={busy === 'move'} close={() => setMovingEntry(null)} submit={submitMove} />}{preview && <div className="fixed inset-0 z-10 grid place-items-center bg-slate-950/75 p-4" role="dialog" aria-modal="true" aria-label={`Preview ${preview.name}`} onClick={closePreview}><div className="relative max-h-[92vh] max-w-[92vw] rounded-2xl bg-white p-2 shadow-2xl" onClick={event => event.stopPropagation()}><button className="absolute right-3 top-3 z-10 grid h-9 w-9 place-items-center rounded-full bg-slate-900/70 text-xl text-white hover:bg-slate-900" aria-label="Close preview" onClick={closePreview}>×</button><img className="max-h-[85vh] max-w-[88vw] rounded-xl object-contain" src={preview.url} alt={preview.name} /><p className="px-2 pb-1 pt-2 text-sm font-medium text-slate-700">{preview.name}</p></div></div>}</>
}

function MoveModal({ entry, directory, setDirectory, busy, close, submit }: { entry: Entry; directory: string; setDirectory: (value: string) => void; busy: boolean; close: () => void; submit: (event: React.FormEvent) => void }) {
  const [browserPath, setBrowserPath] = React.useState('.')
  const [directories, setDirectories] = React.useState<Entry[]>([])
  const [loading, setLoading] = React.useState(true)
  const [loadError, setLoadError] = React.useState<string | null>(null)
  const loadDirectories = async (path: string) => {
    setLoading(true); setLoadError(null)
    try { setDirectories((await list(path)).entries.filter(item => item.type === 'directory')); setBrowserPath(path) }
    catch (error) { setLoadError(error instanceof Error ? error.message : 'could not load directories') }
    finally { setLoading(false) }
  }
  React.useEffect(() => { void loadDirectories('.') }, [])
  const parent = browserPath === '.' ? null : browserPath.split('/').slice(0, -1).join('/') || '.'
  const chooseCurrent = () => setDirectory(browserPath)
  return <div className="fixed inset-0 z-30 grid place-items-center bg-slate-950/40 p-4" role="dialog" aria-modal="true" aria-label="Move item"><form className="w-full max-w-md rounded-2xl bg-white p-5 shadow-2xl" onSubmit={submit}><div className="flex items-start justify-between"><div><h2 className="font-semibold text-slate-900">Move item</h2><p className="mt-1 max-w-xs truncate text-sm text-slate-500" title={entry.path}>{entry.name}</p></div><button type="button" className="text-2xl leading-none text-slate-400" disabled={busy} onClick={close}>×</button></div><label className="mt-5 block text-sm font-medium text-slate-700">Destination folder<input autoFocus className="mt-2 w-full rounded-xl border border-slate-300 px-3 py-2.5 outline-none focus:border-blue-500 focus:ring-2 focus:ring-blue-100" placeholder="e.g. archive/2026" value={directory} disabled={busy} onChange={event => setDirectory(event.target.value)} /></label><div className="mt-4 rounded-xl border border-slate-200"><div className="flex items-center justify-between border-b border-slate-100 px-3 py-2 text-xs"><button type="button" className="font-medium text-blue-600 disabled:text-slate-300" disabled={busy || !parent} onClick={() => parent && void loadDirectories(parent)}>← Back</button><span className="max-w-[14rem] truncate font-medium text-slate-500">{browserPath === '.' ? 'Home' : browserPath}</span><button type="button" className="font-medium text-blue-600" disabled={busy} onClick={chooseCurrent}>Choose</button></div><div className="max-h-36 overflow-y-auto p-2">{loading ? <div className="flex items-center gap-2 px-2 py-4 text-xs text-slate-400"><Spinner /> Loading folders…</div> : loadError ? <p className="px-2 py-4 text-xs text-red-500">{loadError}</p> : directories.length ? directories.map(folder => <button type="button" key={folder.path} className="flex w-full items-center gap-2 rounded-lg px-2 py-2 text-left text-sm text-slate-700 hover:bg-blue-50 hover:text-blue-700" disabled={busy} onClick={() => void loadDirectories(folder.path)}><span className="text-amber-500">▰</span>{folder.name}</button>) : <p className="px-2 py-4 text-xs text-slate-400">No subfolders here.</p>}</div></div><p className="mt-2 text-xs text-slate-400">The original file name will be kept.</p><div className="mt-5 flex justify-end gap-2"><button type="button" className="button-quiet" disabled={busy} onClick={close}>Cancel</button><button type="submit" className="button-primary" disabled={busy}>{busy ? <><Spinner /> Moving…</> : 'Move here'}</button></div></form></div>
}

function UploadModal({ tasks, busy, close }: { tasks: UploadTask[]; busy: boolean; close: () => void }) {
  const completed = tasks.filter(task => task.status === 'completed').length
  const failed = tasks.filter(task => task.status === 'error').length
  const finished = !busy && tasks.length > 0 && completed + failed === tasks.length
  return <div className="fixed inset-0 z-30 flex items-center justify-center bg-slate-950/40 p-4" role="dialog" aria-modal="true" aria-label="Upload list"><div className="w-full max-w-xl overflow-hidden rounded-2xl bg-white shadow-2xl"><div className="flex items-start justify-between border-b border-slate-100 px-5 py-4"><div><h2 className="font-semibold text-slate-900">{finished ? 'Upload finished' : 'Uploading files'}</h2><p className="mt-1 text-sm text-slate-500">{finished ? `${completed} completed${failed ? ` · ${failed} failed` : ''}` : `${completed} of ${tasks.length} completed`}</p></div><button className="text-2xl leading-none text-slate-400 hover:text-slate-700 disabled:opacity-40" disabled={busy} aria-label="Close upload list" onClick={close}>×</button></div><div className="max-h-[55vh] space-y-2 overflow-y-auto p-4">{tasks.map(task => <UploadTaskRow key={task.id} task={task} />)}</div><div className="flex justify-end border-t border-slate-100 px-5 py-3"><button className="button-quiet" disabled={busy} onClick={close}>{finished ? 'Done' : 'Run in background'}</button></div></div></div>
}

function UploadTaskRow({ task }: { task: UploadTask }) {
  const color = task.status === 'error' ? 'bg-red-500' : task.status === 'completed' ? 'bg-emerald-500' : 'bg-blue-600'
  return <div className="rounded-xl border border-slate-100 px-3 py-3"><div className="flex items-center gap-3"><span className={`grid h-8 w-8 shrink-0 place-items-center rounded-lg text-sm ${task.status === 'error' ? 'bg-red-50 text-red-500' : task.status === 'completed' ? 'bg-emerald-50 text-emerald-600' : 'bg-blue-50 text-blue-600'}`}>{task.status === 'completed' ? '✓' : task.status === 'error' ? '!' : <Spinner />}</span><div className="min-w-0 flex-1"><div className="flex justify-between gap-3 text-sm"><span className="truncate font-medium text-slate-700" title={task.name}>{task.name}</span><span className={`shrink-0 ${task.status === 'error' ? 'text-red-600' : task.status === 'completed' ? 'text-emerald-600' : 'text-slate-500'}`}>{task.status === 'error' ? 'Failed' : task.status === 'completed' ? 'Completed' : `${Math.round(task.progress * 100)}%`}</span></div><div className="mt-2 h-1.5 overflow-hidden rounded-full bg-slate-100"><div className={`h-full rounded-full transition-all ${color}`} style={{ width: `${task.progress * 100}%` }} /></div>{task.error && <p className="mt-1 truncate text-xs text-red-500" title={task.error}>{task.error}</p>}</div></div></div>
}

function Row({ entry, open, remove, move, preview, download, busy, activeAction }: { entry: Entry; open: (path: string) => Promise<void>; remove: (entry: Entry) => Promise<void>; move: (entry: Entry) => void; preview: (entry: Entry) => Promise<void>; download: (entry: Entry) => Promise<void>; busy: boolean; activeAction: string | null }) {
  const isDirectory = entry.type === 'directory'
  const image = isImageEntry(entry)
  const previewing = activeAction === `preview:${entry.path}`
  const downloading = activeAction === `download:${entry.path}`
  return <div className="file-row group"><button className={`flex min-w-0 items-center gap-3 text-left ${!isDirectory && !image ? 'cursor-default' : ''}`} disabled={busy} onClick={() => isDirectory ? void open(entry.path) : image && void preview(entry)}><FileIcon entry={entry} /><span className="min-w-0"><span className={`block truncate font-medium ${isDirectory ? 'text-slate-800' : 'text-slate-700'}`}>{entry.name}</span><span className="block truncate text-xs text-slate-400">{isDirectory ? 'Folder' : image ? 'Image · click to preview' : extensionLabel(entry.name)}</span></span></button><span className="hidden text-sm text-slate-500 md:block">{formatDate(entry.modifiedAt)}</span><span className="hidden text-right text-sm text-slate-500 sm:block">{isDirectory ? '—' : formatBytes(entry.size ?? 0)}</span><div className="flex items-center justify-end gap-1 text-sm">{image && <button className="action-button" disabled={busy} title="Preview image" onClick={() => void preview(entry)}>{previewing ? <><Spinner /> Loading…</> : 'Preview'}</button>}<button className="action-button" disabled={busy} title={isDirectory ? 'Open folder' : 'Download'} onClick={() => isDirectory ? void open(entry.path) : void download(entry)}>{downloading ? <><Spinner /> Downloading…</> : isDirectory ? 'Open' : 'Download'}</button><button className="action-button" disabled={busy} title="Move" onClick={() => move(entry)}>{busy && useFileStore.getState().busy === 'move' ? <><Spinner /> Moving…</> : 'Move'}</button><button className="action-button danger" disabled={busy} title="Delete" onClick={() => void remove(entry)}>{busy && useFileStore.getState().busy === 'delete' ? <><Spinner /> Deleting…</> : 'Delete'}</button></div></div>
}

function Spinner({ large = false }: { large?: boolean }) {
  return <span className={`inline-block animate-spin rounded-full border-2 border-current border-t-transparent ${large ? 'h-7 w-7' : 'h-3.5 w-3.5'}`} aria-hidden="true" />
}

function EmptyState({ onUpload }: { onUpload: () => void }) {
  return <div className="px-6 py-20 text-center"><div className="mx-auto grid h-14 w-14 place-items-center rounded-2xl bg-slate-100 text-2xl text-slate-400">□</div><h2 className="mt-4 font-semibold text-slate-700">This folder is empty</h2><p className="mt-1 text-sm text-slate-400">Upload a file to get started.</p><button className="button-primary mt-5" onClick={onUpload}>↑ Upload files</button></div>
}

function FileIcon({ entry }: { entry: Entry }) {
  if (entry.type === 'directory') return <span className="file-icon folder">▰</span>
  const extension = entry.name.split('.').pop()?.toLowerCase() ?? ''
  const kind = ['png', 'jpg', 'jpeg', 'gif', 'webp', 'svg'].includes(extension) ? 'image' : ['zip', 'gz', 'dmg', 'tar'].includes(extension) ? 'archive' : 'document'
  return <span className={`file-icon ${kind}`}>{kind === 'image' ? '▧' : kind === 'archive' ? '◇' : '≡'}</span>
}

function formatBytes(bytes: number) {
  if (bytes === 0) return '0 B'
  const units = ['B', 'KB', 'MB', 'GB', 'TB']
  const index = Math.min(Math.floor(Math.log(bytes) / Math.log(1024)), units.length - 1)
  const value = bytes / 1024 ** index
  return `${value >= 10 || index === 0 ? Math.round(value) : value.toFixed(1)} ${units[index]}`
}

function formatDate(value: string) {
  const date = new Date(value)
  return Number.isNaN(date.getTime()) ? '—' : new Intl.DateTimeFormat(undefined, { year: 'numeric', month: 'short', day: 'numeric' }).format(date)
}

function extensionLabel(name: string) {
  const extension = name.includes('.') ? name.split('.').pop()?.toUpperCase() : 'FILE'
  return `${extension} file`
}

function isImageEntry(entry: Entry) {
  return entry.type === 'file' && ['png', 'jpg', 'jpeg', 'gif', 'webp', 'svg', 'bmp', 'avif'].includes(entry.name.split('.').pop()?.toLowerCase() ?? '')
}

createRoot(document.getElementById('root')!).render(<React.StrictMode><App /></React.StrictMode>)
