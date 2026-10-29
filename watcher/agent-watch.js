#!/usr/bin/env node
// agent-watch.js — single-process (libuv inotify) session-activity watcher.
//
// One process, no children, no shell forks per event: when the shell kills
// this it simply dies, and if it is ever orphaned it exits on its own. That is
// the whole reason this is not bash — the previous pipeline version leaked an
// inotifywait per reload.
//
// Sources are data, not code. SOURCES below is the built-in table; anything the
// table gets wrong can be corrected without touching this file:
//
//   ~/.config/omarchy/agent-watch/sources.json   {"extra":[{"id","label","dirs"}]}
//   AGENT_ORB_SOURCES="id=path,id2=path2"       ad-hoc, comma separated
//
// A source attaches to the first of its dirs that exists, so a source can list
// a precise session dir and fall back to its root. Sources that do not exist
// yet are retried every 15s, which is how a freshly installed agent gets picked
// up without a restart.
//
// Output: ~/.local/state/omarchy/agent-watch/state.json
//   { at, source, now, watching, sources, perSource, agents }
//   `agents` is the whole registry with labels, counts and last-seen times, so
//   a widget never has to duplicate this table.
'use strict'

const fs = require('fs')
const os = require('os')
const path = require('path')

const HOME = os.homedir()
const STATE_DIR = path.join(process.env.XDG_STATE_HOME || path.join(HOME, '.local/state'), 'omarchy/agent-watch')
const STATE_FILE = path.join(STATE_DIR, 'state.json')
const LOCK_FILE = path.join(STATE_DIR, 'watcher.pid')

fs.mkdirSync(STATE_DIR, { recursive: true, mode: 0o700 })
// mkdirSync does not change the mode of a directory that already exists, and
// earlier versions created this one 0755. The state file names the agents that
// are running and when, so another local account must not be able to read it.
try { fs.chmodSync(STATE_DIR, 0o700) } catch {}

// ---------------------------------------------------------------- singleton
try {
  const old = parseInt(fs.readFileSync(LOCK_FILE, 'utf8'), 10)
  if (old && old !== process.pid) {
    // alive and it is one of ours?
    let alive = false
    try { process.kill(old, 0); alive = true } catch {}
    if (alive) {
      let cmd = ''
      try { cmd = fs.readFileSync('/proc/' + old + '/cmdline', 'utf8') } catch {}
      if (cmd.includes('agent-watch')) process.exit(0)
    }
  }
} catch {}
fs.writeFileSync(LOCK_FILE, String(process.pid), { mode: 0o600 })

let cleaningUp = false
function cleanup() {
  if (cleaningUp) return
  cleaningUp = true
  try { if (fs.readFileSync(LOCK_FILE, 'utf8').trim() === String(process.pid)) fs.unlinkSync(LOCK_FILE) } catch {}
  process.exit(0)
}
process.on('SIGTERM', cleanup)
process.on('SIGINT', cleanup)
process.on('SIGHUP', cleanup)
process.on('exit', () => { try { if (fs.readFileSync(LOCK_FILE, 'utf8').trim() === String(process.pid)) fs.unlinkSync(LOCK_FILE) } catch {} })

// ------------------------------------------------------------------ sources
// dirs are tried in order and the first existing one wins. Prefer the narrow
// session directory over the agent's home: ~/.claude and ~/.hermes are full of
// unrelated churn that would light the orb up for nothing.
const BUILTIN = [
  { id: 'opencode', label: 'opencode', dirs: ['.local/share/opencode'] },
  { id: 'claude',   label: 'claude',   dirs: ['.claude/projects'] },
  { id: 'codex',    label: 'codex',    dirs: ['.codex'] },
  { id: 'hermes',   label: 'hermes',   dirs: ['.hermes/sessions'] },
  { id: 'pi',       label: 'pi',       dirs: ['.pi/agent/sessions'] },

  // The rest of the field: all optional, all auto-detected.
  { id: 'gemini',   label: 'gemini',   dirs: ['.gemini/tmp', '.gemini'] },
  { id: 'antigravity', label: 'antigravity', dirs: ['.antigravity/tmp', '.antigravity'] },
  { id: 'qwen',     label: 'qwen',     dirs: ['.qwen/tmp', '.qwen'] },
  { id: 'kimi',     label: 'kimi',     dirs: ['.kimi/sessions', '.kimi'] },
  { id: 'grok',     label: 'grok',     dirs: ['.grok/sessions', '.grok'] },
  { id: 'copilot',  label: 'copilot',  dirs: ['.copilot/history-session-state', '.copilot'] },
  { id: 'goose',    label: 'goose',    dirs: ['.local/share/goose/sessions', '.local/state/goose/sessions', '.config/goose'] },
  { id: 'crush',    label: 'crush',    dirs: ['.local/share/crush', '.local/state/crush'] },
  { id: 'aider',    label: 'aider',    dirs: ['.aider'] },
  { id: 'amp',      label: 'amp',      dirs: ['.local/share/amp', '.amp'] },
  { id: 'cursor',   label: 'cursor',   dirs: ['.cursor'] },
  { id: 'kilocode', label: 'kilocode', dirs: ['.kilocode/sessions', '.kilocode'] },
  { id: 'continue', label: 'continue', dirs: ['.continue'] },
  { id: 'openhands', label: 'openhands', dirs: ['.openhands'] },
  { id: 'plandex',  label: 'plandex',  dirs: ['.plandex'] },
  { id: 'vibe',     label: 'vibe',     dirs: ['.vibe'] },
  { id: 'junie',    label: 'junie',    dirs: ['.junie'] },
  { id: 'openclaw', label: 'openclaw', dirs: ['.openclaw/sessions', '.openclaw'] },
]

function expand(p) {
  if (!p) return null
  return path.isAbsolute(p) ? p : path.join(HOME, p.replace(/^~(?=\/|$)/, ''))
}

function loadSources() {
  const list = BUILTIN.map(s => ({ id: s.id, label: s.label, dirs: s.dirs.slice() }))
  const seen = new Set(list.map(s => s.id))

  const add = s => {
    if (!s || !s.id || seen.has(s.id)) return
    if (!Array.isArray(s.dirs) || !s.dirs.length) return
    seen.add(s.id)
    list.push({ id: String(s.id), label: String(s.label || s.id), dirs: s.dirs.map(String) })
  }

  // User config file, then the environment. Both are additive.
  try {
    const f = path.join(process.env.XDG_CONFIG_HOME || path.join(HOME, '.config'),
                        'omarchy/agent-watch/sources.json')
    const cfg = JSON.parse(fs.readFileSync(f, 'utf8'))
    for (const s of (cfg.extra || [])) add(s)
  } catch {}

  const env = process.env.AGENT_ORB_SOURCES
  if (env) {
    for (const pair of env.split(',')) {
      const i = pair.indexOf('=')
      if (i < 1) continue
      add({ id: pair.slice(0, i).trim(), dirs: [pair.slice(i + 1).trim()] })
    }
  }

  return list
}

const SOURCES = loadSources()
const counts = {}
const perSource = {}
for (const s of SOURCES) { counts[s.id] = 0; perSource[s.id] = 0 }
const watchedIds = new Set()

// Noise we never count as agent activity.
//
// Anchored, because `filename` from fs.watch is relative to the watched root and
// has no leading slash — the old /\/shell\// pattern could never match anything.
//
// The sqlite sidecars are deliberately NOT filtered. Measured over 45s, an
// opencode session produced 0 sidecar writes/sec while idle and bursts of 3-34
// /sec while actually working, which makes them the best available work signal.
// The problem was never that they fire, it was that a single stray write was
// being treated as "the agent is busy" — see BURST below.
const IGNORE = new RegExp([
  '(^|/)log/',
  '(^|/)tool-output/',
  '(^|/)cache/',
  '\\.tmp$',
  '\\.lock$',
  '\\.pid$',
  '\\.log$',
  '\\.env',
  '\\.sock$',
  '/\\.git/',
].join('|'))

// A source counts as working when either it has written a real (non-sidecar)
// file in the last 2.5s, or it has produced a burst of at least BURST_N events
// inside BURST_WINDOW. That rejects isolated noise while keeping the sqlite
// bursts, and is why the orb is still rather than permanently in motion.
const BUSY_WINDOW_MS = 2500
const BURST_N = 3
const BURST_WINDOW_MS = 1500

let at = 0
let lastSource = ''
let writePending = false
let lastBusySig = ''

// Recent event timestamps per source, and the last real (non-sidecar) one.
const recent = {}
const lastReal = {}
for (const s of SOURCES) { recent[s.id] = []; lastReal[s.id] = 0 }

function isSidecar(rel) { return /-wal$|-shm$|-journal$/.test(rel) }

function noteEvent(id, now, sidecar) {
  const a = recent[id]
  a.push(now)
  while (a.length && now - a[0] > 4000) a.shift()
  if (!sidecar) lastReal[id] = now
}

function isBusy(id) {
  const now = Date.now()
  if (now - lastReal[id] <= BUSY_WINDOW_MS) return true
  const a = recent[id]
  let n = 0
  for (let i = a.length - 1; i >= 0; i--) {
    if (now - a[i] > BURST_WINDOW_MS) break
    n++
  }
  return n >= BURST_N
}

function busySig() {
  return SOURCES.map(s => (isBusy(s.id) ? '1' : '0')).join('')
}

function agentList() {
  return SOURCES.map(s => ({
    id: s.id,
    label: s.label,
    count: counts[s.id],
    last: perSource[s.id],
    busy: isBusy(s.id),
    watched: watchedIds.has(s.id),
  }))
}

function writeState() {
  const now = Date.now()
  const sources = {}
  const last = {}
  const busy = {}
  for (const s of SOURCES) {
    sources[s.id] = counts[s.id]
    last[s.id] = perSource[s.id]
    busy[s.id] = isBusy(s.id)
  }
  const payload = JSON.stringify({
    at,
    source: lastSource,
    now,
    watching: [...watchedIds],
    sources,
    perSource: last,
    busy,
    agents: agentList(),
  })
  lastBusySig = busySig()
  const tmp = STATE_FILE + '.tmp'
  try {
    fs.writeFileSync(tmp, payload, { mode: 0o600 })
    fs.renameSync(tmp, STATE_FILE)   // atomic: the panel never reads a partial file
  } catch {}
}

function scheduleWrite() {
  if (writePending) return
  writePending = true
  setTimeout(() => { writePending = false; writeState() }, 120)
}

function onEvent(srcId, rel) {
  if (IGNORE.test(rel)) return
  const now = Date.now()
  at = now
  lastSource = srcId
  counts[srcId]++
  perSource[srcId] = now
  noteEvent(srcId, now, isSidecar(rel))
  scheduleWrite()
}

function attach(src) {
  if (watchedIds.has(src.id)) return
  // First existing candidate wins, so a precise session dir beats a root.
  const dir = src.dirs.map(expand).find(d => d && fs.existsSync(d))
  if (!dir) return
  try {
    fs.watch(dir, { recursive: true, persistent: true }, (event, filename) => {
      onEvent(src.id, filename || '')
    })
    watchedIds.add(src.id)
  } catch (e) {
    // recursive watch unsupported => fall back to the top level
    try {
      fs.watch(dir, { persistent: true }, (event, filename) => onEvent(src.id, filename || ''))
      watchedIds.add(src.id)
    } catch {}
  }
}

// Sources that appear later (e.g. a fresh Claude Code install) get picked up.
function scan() {
  const before = watchedIds.size
  for (const s of SOURCES) attach(s)
  if (watchedIds.size !== before) writeState()
}
scan()
writeState()
setInterval(scan, 15000).unref()

// Nothing writes on its own when an agent stops, so the busy flags would stay
// stuck true. Re-publish whenever one actually flips.
setInterval(() => {
  if (busySig() !== lastBusySig) writeState()
}, 1000).unref()

// Keep the process alive even if a watch is lost.
setInterval(() => {}, 1 << 30)