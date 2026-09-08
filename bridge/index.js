import 'dotenv/config'
import { Session, Poller, ready } from '@session.js/client'
import { InMemoryStorage } from '@session.js/client/storage'
import { BunNetwork } from '@session.js/bun-network'
import { spawn } from 'child_process'
import { writeFileSync, unlinkSync, existsSync, mkdirSync, readFileSync } from 'fs'
import { join } from 'path'

const MODEL = process.env.MODEL || 'opencode-go/deepseek-v4-flash'
const BACKEND = process.env.BACKEND || 'openclaw'
const HINT = 'Check your OPENCODE_API_KEY in .env'
const TIMEOUT = 300_000
const TMP = '/tmp/session-ai-agent'
const conversations = new Map()
const queues = new Map()

if (!existsSync(TMP)) mkdirSync(TMP, { recursive: true })

async function downloadAttachments(session, attachments) {
  const files = []
  for (const a of attachments) {
    try {
      const file = await Promise.race([
        session.getFile(a),
        new Promise((_, reject) => setTimeout(() => reject(new Error('download timeout')), 30000))
      ])
      const ext = (a.name || 'file').split('.').pop() || 'bin'
      const path = join(TMP, `${a.id}.${ext}`)
      writeFileSync(path, new Uint8Array(await file.arrayBuffer()))
      files.push({ path, type: a.metadata?.contentType || file.type, name: a.name })
    } catch (e) { console.error('download err:', e.message) }
  }
  return files
}

function buildPrompt(text, files) {
  if (!files.length) return text
  const parts = [text || '']
  for (const f of files) {
    const mime = f.type || 'application/octet-stream'
    if (mime.startsWith('image/')) {
      const buf = readFileSync(f.path)
      if (buf.length > 500_000) {
        parts.push(`\n[User sent an image (${(buf.length/1024).toFixed(0)}KB) - too large to display, filename: ${f.name}]`)
        continue
      }
      const b64 = buf.toString('base64')
      parts.push(`\n[image: data:${mime};base64,${b64}]`)
    } else if (mime.startsWith('audio/')) {
      parts.push(`\n[User sent audio: ${f.name}]`)
    } else if (mime.startsWith('video/')) {
      parts.push(`\n[User sent video: ${f.name}]`)
    } else {
      parts.push(`\n[User sent file: ${f.name}]`)
    }
  }
  return parts.join('')
}

function cleanup(files) {
  for (const f of files) unlinkSync(f.path)
}

function spawnAgent(sid, msg) {
  const env = { ...process.env, HOME: process.env.HOME, PATH: process.env.PATH || '/usr/local/bin:/usr/bin:/bin' }
  if (BACKEND === 'hermes') {
    const model = MODEL.includes('/') ? MODEL.split('/')[1] : MODEL
    return spawn('hermes', ['-z', msg, '--provider', 'ocgo', '--model', model], { env, stdio: ['ignore', 'pipe', 'pipe'] })
  }
  return spawn('openclaw', ['agent', '--local', '--session-id', sid, '--model', MODEL, '--message', msg, '--json'], { env, stdio: ['ignore', 'pipe', 'pipe'] })
}

function callAgent(sid, msg) {
  return new Promise((resolve, reject) => {
    const proc = spawnAgent(sid, msg)
    let killed = false
    const timer = setTimeout(() => { killed = true; proc.kill('SIGKILL'); reject(new Error('timed out')) }, TIMEOUT)
    let out = '', err = ''
    proc.on('error', e => { clearTimeout(timer); reject(new Error(`${BACKEND} not found: ${e.message}`)) })
    proc.stdout.on('data', d => out += d)
    proc.stderr.on('data', d => err += d)
    proc.on('close', code => {
      clearTimeout(timer)
      if (killed) return
      if (code !== 0) {
        const detail = (err + out).replace(/\x1b\[[0-9;]*m/g, '').trim()
        return reject(new Error(detail.slice(0, 500) || `exit ${code}`))
      }
      out = out.replace(/\x1b\[[0-9;]*m/g, '').trim()
      try {
        const o = JSON.parse(out)
        resolve({ text: o?.payloads?.[0]?.text?.trim() || o?.text || o?.output || null })
      } catch {
        resolve({ text: out || null })
      }
    })
  })
}

function sanitize(s) { return (s || '').replace(/(sk-|sk-ant-|ollama-)[^\s]{4,}/g, '$1***') }

const ENV_FILE = join(process.cwd(), '.env')
const CFG_FILE = join(process.env.HOME || '/root', '.openclaw', 'openclaw.json')

function modelBare() { return MODEL.includes('/') ? MODEL.split('/')[1] : MODEL }

function run(cmd, args) {
  return new Promise(res => {
    const p = spawn(cmd, args, { stdio: ['ignore', 'ignore', 'pipe'] })
    let err = ''
    p.stderr.on('data', d => err += d)
    p.on('close', code => res({ code, err }))
    p.on('error', () => res({ code: -1, err: 'spawn failed' }))
  })
}

function envEntry(key) {
  try {
    if (!existsSync(ENV_FILE)) return null
    for (const line of readFileSync(ENV_FILE, 'utf8').split('\n')) {
      if (line.startsWith(key + '=')) return line.slice(key.length + 1)
    }
  } catch {}
  return null
}

function persistEnv(key, val) {
  try {
    const existing = existsSync(ENV_FILE) ? readFileSync(ENV_FILE, 'utf8') : ''
    const re = new RegExp(`^${key}=.*$`, 'm')
    const next = re.test(existing) ? existing.replace(re, `${key}=${val}`) : existing.trimEnd() + `\n${key}=${val}\n`
    writeFileSync(ENV_FILE, next)
  } catch (e) { console.error('[config] persist env failed:', e.message) }
}

async function openclawSelfHeal() {
  if (BACKEND !== 'openclaw') return
  let cfg = null
  try { cfg = JSON.parse(readFileSync(CFG_FILE, 'utf8')) } catch { return console.warn('[config] no openclaw.json — skipping self-heal') }
  const bare = modelBare()
  const prov = cfg?.models?.providers?.['opencode-go']
  const models = Array.isArray(prov?.models) ? prov.models : []
  const hasModel = models.some(m => (m.id || m.name) === bare)
  const hasHeader = !!prov?.headers?.['x-opencode-session']
  if (hasModel && hasHeader) return console.log(`[config] openclaw model+header OK (${bare})`)

  let sid = process.env.OPENCODE_SESSION || envEntry('OPENCODE_SESSION')
  if (!sid) {
    sid = (globalThis.crypto?.randomUUID?.() || `${Date.now().toString(16)}-${Math.random().toString(16).slice(2)}`)
    persistEnv('OPENCODE_SESSION', sid)
    console.log('[config] generated OPENCODE_SESSION')
  }
  const entry = { id: bare, name: bare, api: 'openai-completions', baseUrl: 'https://opencode.ai/zen/go/v1',
    reasoning: false, input: ['text'], cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 }, contextWindow: 200000, maxTokens: 8192 }
  const merged = models.some(m => (m.id || m.name) === bare) ? models : [...models.filter(m => m.id !== bare), entry]
  const patch = { models: { providers: { 'opencode-go': { models: merged, headers: { 'x-opencode-session': sid } } } } }
  const tmp = join(TMP, 'selfheal-patch.json')
  writeFileSync(tmp, JSON.stringify(patch))
  const res = await run('openclaw', ['config', 'patch', '--file', tmp])
  try { unlinkSync(tmp) } catch {}
  if (res.code === 0) console.log(`[config] self-heal applied (model=${hasModel ? 'ok' : 'missing'}, header=${hasHeader ? 'ok' : 'missing'})`)
  else console.error('[config] self-heal FAILED:', String(res.err).slice(0, 200))
}

async function checkCatalog(session) {
  try {
    const r = await fetch('https://opencode.ai/zen/go/v1/models', { signal: AbortSignal.timeout(10000) })
    const d = await r.json()
    const ids = Array.isArray(d?.data) ? d.data.map(m => m.id) : []
    if (!ids.length) return
    const bare = modelBare()
    if (!ids.includes(bare)) {
      console.error(`[catalog] ${MODEL} NOT in live catalog (${ids.length} models)`)
      const owner = process.env.OWNER_SESSION_ID
      if (owner) {
        try { await session.sendMessage({ to: owner, text: `⚠ Your Session AI Agent model (${MODEL}) is not in the current OpenCode Go catalog. Re-run the setup script and pick a new model.` }) } catch {}
      }
    } else console.log(`[catalog] ${bare} OK (${ids.length} models)`)
  } catch (e) { console.error('[catalog] check failed:', e.message) }
}

async function sendWithRetry(session, to, text, attempts = 3) {
  for (let i = 1; i <= attempts; i++) {
    try {
      await session.sendMessage({ to, text })
      return
    } catch (e) {
      if (i === attempts) throw e
      console.warn(`[send] attempt ${i} failed: ${e.message} - retrying`)
      await new Promise(r => setTimeout(r, 1000 * i))
    }
  }
}

async function processMessage(session, from, sid, msg) {
  const files = msg.attachments?.length ? await downloadAttachments(session, msg.attachments) : []
  const prompt = buildPrompt(msg.text, files)
  console.log(`[${from}]: ${(msg.text||'').slice(0,200)}${files.length ? ` +${files.length} files` : ''}`)

  let r
  try {
    r = await callAgent(sid, prompt)
  } catch (e) {
    if (files.length) try { cleanup(files) } catch {}
    console.error(`Error: ${e.message}`)
    const txt = e.message?.includes('auth') || e.message?.includes('API key')
      ? `AI not configured. ${HINT}`
      : `Error: ${sanitize(e.message)}`
    try {
      await sendWithRetry(session, from, txt)
    } catch (e2) {
      console.error(`[send] error relay failed: ${e2.message}`)
    }
    return
  }
  if (files.length) try { cleanup(files) } catch {}

  const reply = !r.text
    ? '(no response from backend — the engine replied empty. Check `journalctl -u claw-bridge` and re-run the setup script.)'
    : r.text
  if (!r.text) console.log('[warn] empty reply')

  try {
    await sendWithRetry(session, from, reply)
    console.log(`[reply]: ${reply.slice(0, 100)}`)
  } catch (e) {
    // Delivery failure (e.g. Session storage RPC blip) - log only, don't spam the user.
    console.error(`[send] failed after retries: ${e.message}`)
  }
}

async function drain(session, from) {
  const e = queues.get(from) || { q: [], busy: false }
  if (e.busy) return
  e.busy = true; queues.set(from, e)
  let sid = conversations.get(from)
  if (!sid) { sid = `s-${from.slice(0, 12)}`; conversations.set(from, sid) }
  while (e.q.length) await processMessage(session, from, sid, e.q.shift()).catch(() => {})
  e.busy = false
  if (e.q.length) drain(session, from)
}

async function main() {
  await ready
  if (!process.env.SESSION_MNEMONIC) { console.error('SESSION_MNEMONIC missing'); process.exit(1) }
  const session = new Session({ storage: new InMemoryStorage(), network: new BunNetwork() })
  session.setMnemonic(process.env.SESSION_MNEMONIC, 'Session AI Agent')
  console.log(`SESSION_ID ${session.getSessionID()}`)
  writeFileSync(join(TMP, 'session-id.txt'), session.getSessionID())
  console.log(`Model: ${MODEL}  Backend: ${BACKEND}`)

  session.addPoller(new Poller({ interval: 3000 }))
  session.on('message', m => {
    if (m.type !== 'private' || m.from === session.getSessionID() || !m.text && !m.attachments?.length) return
    const owner = process.env.OWNER_SESSION_ID
    if (owner && m.from !== owner) return console.log(`[blocked] ${m.from}`)
    const e = queues.get(m.from) || { q: [], busy: false }
    e.q.push(m); queues.set(m.from, e); drain(session, m.from)
  })

  console.log('ready')
  openclawSelfHeal().catch(e => console.error('[config] self-heal error:', e.message))
  checkCatalog(session).catch(e => console.error('[catalog] check error:', e.message))
  const exit = () => { process.exit(0) }
  process.on('SIGINT', exit); process.on('SIGTERM', exit)
}

main()
