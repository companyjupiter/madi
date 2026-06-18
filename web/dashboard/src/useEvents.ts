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

export type SourceMode = 'instant' | 'replay' | 'live'

// the live bridge (web/bridge/server.mjs) streams the same event contract via SSE
const BRIDGE = 'http://127.0.0.1:5274/events'

function bridgeUrl() {
  const u = new URL(BRIDGE)
  const qs = new URLSearchParams(window.location.search)
  const token = qs.get('bridgeToken') || window.localStorage.getItem('sovereignBridgeToken')
  if (token) {
    window.localStorage.setItem('sovereignBridgeToken', token)
    u.searchParams.set('token', token)
  }
  return u.toString()
}

export function useEvents(fixture: string, mode: SourceMode = 'instant') {
  const [state, setState] = useState<SessionState>(emptySession)
  const [loading, setLoading] = useState(true)
  const timer = useRef<number | null>(null)

  useEffect(() => {
    let cancelled = false
    if (timer.current) { clearInterval(timer.current); timer.current = null }
    setState(emptySession()); setLoading(true)

    if (mode === 'live') {
      // live: connect to the bridge SSE; it runs the engine and streams events
      setLoading(false)
      const es = new EventSource(bridgeUrl())
      es.onmessage = (m) => {
        try { const e = JSON.parse(m.data) as EngineEvent; setState((s) => reduce(s, e)) } catch { /* keepalive */ }
      }
      es.addEventListener('done', () => es.close())
      es.onerror = () => { /* bridge offline — stays empty */ }
      return () => es.close()
    }

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
