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

const server = http.createServer((req, res) => {
  const url = new URL(req.url, 'http://127.0.0.1')
  if (url.pathname !== '/events') { res.writeHead(404); res.end(); return }

  res.writeHead(200, {
    'Content-Type': 'text/event-stream',
    'Cache-Control': 'no-cache',
    Connection: 'keep-alive',
    'Access-Control-Allow-Origin': '*',
  })
  res.write(`: live bridge connected\n\n`)

  const wav = url.searchParams.get('wav') || DEFAULT_WAV
  const lang = url.searchParams.get('lang') || '50264'
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

server.listen(5274, '127.0.0.1', () => console.log('live bridge → http://127.0.0.1:5274/events'))
