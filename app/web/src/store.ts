import { create } from 'zustand'

export type ActionId = 'errors-10' | 'errors-30' | 'memory'

export interface ActivityLogEntry {
  id: string
  timestamp: string
  action: ActionId
  label: string
  success: boolean
  message: string
}

interface DemoStoreState {
  lastAction: ActionId | null
  inFlight: Partial<Record<ActionId, boolean>>
  activityLog: ActivityLogEntry[]
  startAction: (action: ActionId) => void
  finishAction: (
    action: ActionId,
    label: string,
    success: boolean,
    message: string
  ) => void
}

const MAX_LOG_ENTRIES = 20

export const useDemoStore = create<DemoStoreState>((set) => ({
  lastAction: null,
  inFlight: {},
  activityLog: [],
  startAction: (action) =>
    set((state) => ({
      lastAction: action,
      inFlight: { ...state.inFlight, [action]: true },
    })),
  finishAction: (action, label, success, message) =>
    set((state) => {
      const entry: ActivityLogEntry = {
        id: `${Date.now()}-${Math.random().toString(36).slice(2, 8)}`,
        timestamp: new Date().toISOString(),
        action,
        label,
        success,
        message,
      }
      return {
        inFlight: { ...state.inFlight, [action]: false },
        activityLog: [entry, ...state.activityLog].slice(0, MAX_LOG_ENTRIES),
      }
    }),
}))
