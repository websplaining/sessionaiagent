import 'dotenv/config'
import { Session, Poller, ready } from '@session.js/client'
import { InMemoryStorage } from '@session.js/client/storage'
import { BunNetwork } from '@session.js/bun-network'
import { spawn } from 'child_process'
import { writeFileSync, unlinkSync, existsSync, mkdirSync, readFileSync } from 'fs'
import { join } from 'path'

const MODEL = process.env.MODEL || 'opencode-go/deepseek-v4-pro'
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
    return spawn('hermes', ['-z', msg, '--provider', 'opencode-go', '--model', model], { env, stdio: ['ignore', 'pipe', 'pipe'] })
  }
  return spawn('openclaw', ['agent', '--local', '--session-id', sid, '--model', MODEL, '--message', msg, '--json'], { env, stdio: ['ignore', 'pipe', 'pipe'] })
}

function callAgent(sid, msg) {
  return new Promise((resolve, reject) => {
    const proc = spawnAgent(sid, msg)
    let killed = false
    const timer = setTimeout(() => { killed = true; proc.kill('SIGKILL'); reject(new Error('timed out')) }, TIMEOUT)
    let out = '', err = ''
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

async function processMessage(session, from, sid, msg) {
  const files = msg.attachments?.length ? await downloadAttachments(session, msg.attachments) : []
  const prompt = buildPrompt(msg.text, files)
  console.log(`[${from}]: ${(msg.text||'').slice(0,200)}${files.length ? ` +${files.length} files` : ''}`)

  try {
    const r = await callAgent(sid, prompt)
    if (files.length) cleanup(files)
    if (!r.text) return console.log('[warn] empty reply')
    await session.sendMessage({ to: from, text: r.text })
    console.log(`[reply]: ${r.text.slice(0, 100)}`)
  } catch (e) {
    if (files.length) try { cleanup(files) } catch {}
    console.error(`Error: ${e.message}`)
    const txt = e.message?.includes('auth') || e.message?.includes('API key')
      ? `AI not configured. ${HINT}`
      : `Error: ${sanitize(e.message)}`
    await session.sendMessage({ to: from, text: txt })
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
  const exit = () => { process.exit(0) }
  process.on('SIGINT', exit); process.on('SIGTERM', exit)
}

main()
