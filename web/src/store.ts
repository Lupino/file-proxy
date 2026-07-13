import { create } from 'zustand'
import * as api from './api'

export type UploadTask = {
  id: string
  name: string
  size: number
  progress: number
  status: 'queued' | 'uploading' | 'completed' | 'error'
  error?: string
}

type State = {
  path: string
  entries: api.Entry[]
  loading: boolean
  busy: 'open' | 'upload' | 'folder' | 'delete' | 'move' | null
  error: string | null
  uploadTasks: UploadTask[]
  uploadPanelOpen: boolean
  open: (path: string) => Promise<void>
  upload: (files: FileList | File[]) => Promise<void>
  createFolder: () => Promise<void>
  remove: (entry: api.Entry) => Promise<void>
  moveEntry: (entry: api.Entry, directory: string) => Promise<void>
  closeUploadPanel: () => void
  openUploadPanel: () => void
}

export const useFileStore = create<State>((set, get) => ({
  path: '.', entries: [], loading: false, busy: null, error: null, uploadTasks: [], uploadPanelOpen: false,
  open: async (path) => {
    set({ path, loading: true, busy: 'open', error: null })
    try { set({ entries: (await api.list(path)).entries, loading: false, busy: null }) }
    catch (error) { set({ loading: false, busy: null, error: error instanceof Error ? error.message : 'request failed' }) }
  },
  upload: async (files) => {
    const list = Array.from(files)
    const tasks = list.map((file, index) => ({ id: `${Date.now()}-${index}`, name: file.webkitRelativePath || file.name, size: file.size, progress: 0, status: 'queued' as const }))
    set({ busy: 'upload', error: null, uploadTasks: tasks, uploadPanelOpen: true })
    for (const [index, file] of list.entries()) {
      const task = tasks[index]
      set(state => ({ uploadTasks: state.uploadTasks.map(item => item.id === task.id ? { ...item, status: 'uploading' } : item) }))
      try {
        const relative = file.webkitRelativePath || file.name
        const remote = get().path === '.' ? relative : `${get().path}/${relative}`
        await api.uploadFile(file, remote, progress => set(state => ({ uploadTasks: state.uploadTasks.map(item => item.id === task.id ? { ...item, progress } : item) })))
        set(state => ({ uploadTasks: state.uploadTasks.map(item => item.id === task.id ? { ...item, progress: 1, status: 'completed' } : item) }))
      } catch (error) {
        set(state => ({ uploadTasks: state.uploadTasks.map(item => item.id === task.id ? { ...item, status: 'error', error: error instanceof Error ? error.message : 'upload failed' } : item) }))
      }
    }
    await get().open(get().path)
    set({ busy: null })
  },
  createFolder: async () => {
    const name = window.prompt('Folder name')?.trim()
    if (!name) return
    const target = get().path === '.' ? name : `${get().path}/${name}`
    set({ busy: 'folder', error: null })
    try { await api.mkdir(target); await get().open(get().path) }
    catch (error) { set({ error: error instanceof Error ? error.message : 'could not create folder' }) }
    finally { set({ busy: null }) }
  },
  remove: async (entry) => {
    if (!window.confirm(`Delete ${entry.path}?`)) return
    set({ busy: 'delete', error: null })
    try { await api.remove(entry.path, entry.type === 'directory'); await get().open(get().path) }
    catch (error) { set({ error: error instanceof Error ? error.message : 'delete failed' }) }
    finally { set({ busy: null }) }
  },
  moveEntry: async (entry, directory) => {
    const cleanDirectory = directory.trim().replace(/^\.\//, '').replace(/\/$/, '')
    const target = cleanDirectory && cleanDirectory !== '.' ? `${cleanDirectory}/${entry.name}` : entry.name
    set({ busy: 'move', error: null })
    try { await api.move(entry.path, target); await get().open(get().path) }
    catch (error) { set({ error: error instanceof Error ? error.message : 'move failed' }) }
    finally { set({ busy: null }) }
  },
  closeUploadPanel: () => set({ uploadPanelOpen: false }),
  openUploadPanel: () => set({ uploadPanelOpen: true }),
}))
