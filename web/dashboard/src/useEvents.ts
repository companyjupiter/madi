// useEvents.ts — the DATA SOURCE seam.
//
// Today: loads a checked-in fixture (.jsonl) and REPLAYS it event-by-event so
// the dashboard exercises the same incremental path a live session would. The
// replay cadence is cosmetic (the scaffold demoing "live" feel); a real session
// just pushes events as they arrive.
//
// Live bridge (future, documented seam — see README): run the engine with
// EVENTS_FILE pointed at a fifo/socket and stream lines over SSE/WebSocket;
// swap `loadFixture` for an EventSource. The reducer + panels never change.

import { useEffect, useRef, useState } from 'react'
import { EngineEvent, SessionState, emptySession, reduce } from './types'

export type SourceMode = 'instant' | 'replay'

export function useEvents(fixture: string, mode: SourceMode = 'instant') {
  const [state, setState] = useState<SessionState>(emptySession)
  const [loading, setLoading] = useState(true)
  const timer = useRef<number | null>(null)

  useEffect(() => {
    let cancelled = false
    if (timer.current) { clearInterval(timer.current); timer.current = null }
    setState(emptySession()); setLoading(true)

    fetch(`fixtures/${fixture}.events.jsonl`)
      .then((r) => r.text())
      .then((txt) => {
        if (cancelled) return
        const events: EngineEvent[] = txt
          .split('\n').filter(Boolean)
          .map((l) => { try { return JSON.parse(l) as EngineEvent } catch { return null } })
          .filter((e): e is EngineEvent => e != null)

        if (mode === 'instant') {
          // file-mode fixtures carry no seg_end/flush_end (stream-only) — mark
          // the fully-loaded session complete so the status badge reads 완료.
          const folded = events.reduce(reduce, emptySession())
          setState({ ...folded, ended: true })
          setLoading(false)
          return
        }
        // replay: fold one event per tick for a live-feeling demo
        let i = 0
        setLoading(false)
        timer.current = window.setInterval(() => {
          if (i >= events.length) { if (timer.current) clearInterval(timer.current); return }
          const e = events[i++]
          setState((s) => reduce(s, e))
        }, 18)
      })
      .catch(() => { if (!cancelled) setLoading(false) })

    return () => { cancelled = true; if (timer.current) clearInterval(timer.current) }
  }, [fixture, mode])

  return { state, loading }
}
