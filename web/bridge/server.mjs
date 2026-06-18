// server.mjs — live bridge: runs the engine on a wav and streams its structured
// events over SSE so the dashboard renders a session live (partials → words →
// segment → diarization). The dashboard's fixture replay and this live feed are
// interchangeable — both push the same EVENTS_FILE contract (docs/EVENTS.md).
//
// Run:  node web/bridge/server.mjs    (listens on 127.0.0.1:5274)
// Feed: GET /events?wav=<abs path>&lang=<token>  → text/event-stream
//
// No mic dependency: it streams a file through the engine's STREAM mode, which
// is the same code path live capture uses — so the live experience is faithful.
import http from 'node:http'
import { spawn } from 'node:child_process'
import crypto from 'node:crypto'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const HERE = path.dirname(fileURLToPath(import.meta.url))
const M = path.resolve(HERE, '../../metal')
const ENGINE = `${M}/out/transcribe`
const MODEL = `${M}/assets/model.safetensors`
const BPE = `${M}/assets/WHISPER_BPE.bin`
const DEFAULT_WAV = `${M}/bench/devops_ko.wav`
const PORT = Number(process.env.SOV_BRIDGE_PORT || 5274)
const TOKEN = process.env.SOV_BRIDGE_TOKEN || crypto.randomBytes(24).toString('base64url')
const ALLOWED_ORIGINS = new Set(
  (process.env.SOV_BRIDGE_ORIGINS || 'http://127.0.0.1:5273,http://localhost:5273')
    .split(',')
    .map((s) => s.trim())
    .filter(Boolean),
)
const WAV_ROOTS = (process.env.SOV_BRIDGE_WAV_ROOTS || M)
  .split(path.delimiter)
  .map((p) => path.resolve(p))

function deny(res, code, message) {
  res.writeHead(code, {
    'Content-Type': 'application/json',
    'Cache-Control': 'no-store',
  })
  res.end(JSON.stringify({ error: message }))
}

function corsHeaders(origin) {
  if (!origin) return {}
  if (!ALLOWED_ORIGINS.has(origin)) return null
  return {
    'Access-Control-Allow-Origin': origin,
    Vary: 'Origin',
  }
}

function allowedWavPath(input) {
  const requested = input || DEFAULT_WAV
  const resolved = fs.realpathSync(path.resolve(requested))
  const ok = WAV_ROOTS.some((root) => {
    const rel = path.relative(root, resolved)
    return rel === '' || (!rel.startsWith('..') && !path.isAbsolute(rel))
  })
  if (!ok) throw new Error(`wav path is outside allowed roots: ${resolved}`)
  return resolved
}

const server = http.createServer((req, res) => {
  const url = new URL(req.url, 'http://127.0.0.1')
  if (url.pathname !== '/events') { res.writeHead(404); res.end(); return }
  const cors = corsHeaders(req.headers.origin)
  if (cors == null) return deny(res, 403, 'origin is not allowed')
  if (url.searchParams.get('token') !== TOKEN) return deny(res, 401, 'bridge token required')
  let wav
  try {
    wav = allowedWavPath(url.searchParams.get('wav'))
  } catch (err) {
    return deny(res, 400, err.message)
  }
  const lang = url.searchParams.get('lang') || '50264'
  if (!/^\d+$/.test(lang)) return deny(res, 400, 'lang must be a numeric Whisper token id')

  res.writeHead(200, {
    'Content-Type': 'text/event-stream',
    'Cache-Control': 'no-cache',
    Connection: 'keep-alive',
    ...cors,
  })
  res.write(`: live bridge connected\n\n`)

  const evFile = path.join(os.tmpdir(), `sov_ev_${process.pid}_${Date.now()}.jsonl`)
  fs.writeFileSync(evFile, '')

  const eng = spawn(ENGINE, [MODEL, '/dev/null', BPE], {
    env: { ...process.env, STREAM: '1', EVENTS_FILE: evFile, PARTIALS: '1', WHISPER_LANG_ID: lang, DIAR: '1' },
  })
  let fed = false
  eng.stdout.on('data', (d) => {
    const s = d.toString()
    if (!fed && s.includes('[stream] ready')) {
      fed = true
      eng.stdin.write(`0.0 ${wav}\n`)
      // finalize after the job so diarization (diar/flush_end) is emitted too
      setTimeout(() => { try { eng.stdin.write('FLUSH\n') } catch {} }, 200)
    }
  })

  // tail the events file → SSE
  let pos = 0
  const pump = () => {
    let stat
    try { stat = fs.statSync(evFile) } catch { return }
    if (stat.size <= pos) return
    const buf = Buffer.alloc(stat.size - pos)
    const fd = fs.openSync(evFile, 'r')
    fs.readSync(fd, buf, 0, buf.length, pos)
    fs.closeSync(fd)
    pos = stat.size
    for (const line of buf.toString().split('\n')) {
      if (line.trim()) res.write(`data: ${line}\n\n`)
    }
  }
  const iv = setInterval(pump, 80)

  const cleanup = () => {
    clearInterval(iv)
    try { eng.kill() } catch {}
    try { fs.unlinkSync(evFile) } catch {}
  }
  req.on('close', cleanup)
  eng.on('exit', () => { pump(); setTimeout(() => { res.write('event: done\ndata: {}\n\n'); cleanup() }, 200) })
})

server.listen(PORT, '127.0.0.1', () => {
  console.log(`live bridge → http://127.0.0.1:${PORT}/events?token=${TOKEN}`)
  console.log(`allowed origins: ${[...ALLOWED_ORIGINS].join(', ')}`)
  console.log(`allowed wav roots: ${WAV_ROOTS.join(path.delimiter)}`)
})
