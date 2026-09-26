// ============================================================================
//  DSH 用量统计：查询 DeepSeek 余额 + 汇总所有会话的 token 用量
//  用法: node usage.js
//  输出: 单行 JSON 到 stdout
// ============================================================================
'use strict'

const fs = require('node:fs')
const path = require('node:path')
const os = require('node:os')
const { zstdDecompressSync } = require('node:zlib')

const DSH_HOME = process.env.DSH_HOME || path.join(os.homedir(), '.dsh')
const CRED_FILE = path.join(DSH_HOME, '.credentials.yaml')
const SESSIONS_DIR = path.join(DSH_HOME, 'sessions')
const BALANCE_URL = 'https://api.deepseek.com/user/balance'

// ---- 读取 API key ----
function readApiKey() {
  try {
    const text = fs.readFileSync(CRED_FILE, 'utf8')
    const m = text.match(/^\s*DEEPSEEK_API_KEY:\s*(\S+)/m)
    if (m) return m[1]
  } catch (e) { /* ignore */ }
  return process.env.DEEPSEEK_API_KEY || null
}

// ---- 扫描拼接的 zstd 帧（与 session-persistence-jsonl 同构）----
const ZSTD_MAGIC = 0xFD2FB528
function scanFrames(buf) {
  const frames = []
  let off = 0
  while (off + 4 <= buf.length) {
    const start = off
    if (buf.readUInt32LE(off) !== ZSTD_MAGIC) break
    off += 4
    if (off >= buf.length) break
    const desc = buf.readUInt8(off); off += 1
    const contentSizeFlag = desc >>> 6
    const singleSegment = (desc & 0x20) !== 0
    const checksum = (desc & 0x04) !== 0
    const dictFlag = desc & 0x03
    const dictBytes = dictFlag === 3 ? 4 : dictFlag
    const csBytes = contentSizeFlag === 0 ? (singleSegment ? 1 : 0) : (1 << contentSizeFlag)
    const rem = (singleSegment ? 0 : 1) + dictBytes + csBytes
    if (buf.length - off < rem) break
    off += rem
    for (;;) {
      if (buf.length - off < 3) { off = start; frames.length = 0; break }
      const bh = buf.readUIntLE(off, 3); off += 3
      const lastBlock = (bh & 1) !== 0
      const blockType = (bh >>> 1) & 0x03
      const blockSize = bh >>> 3
      const payload = blockType === 0x01 ? 1 : blockSize
      if (buf.length - off < payload) { off = start; frames.length = 0; break }
      off += payload
      if (lastBlock) break
    }
    if (checksum) { if (buf.length - off < 4) break; off += 4 }
    frames.push([start, off])
  }
  return frames
}

function decompressJsonl(file) {
  const buf = fs.readFileSync(file)
  const frames = scanFrames(buf)
  let text = ''
  for (const [s, e] of frames) {
    try { text += zstdDecompressSync(buf.subarray(s, e)).toString('utf8') }
    catch (err) { /* 跳过损坏帧 */ }
  }
  return text
}

// ---- 汇总 token 用量 ----
// 与 token-meter 的 usage 投影一致：同一 turn/step 的后一个采样替换前一个，
// 避免 usage 分块与最终 message 重复计数。
function computeTokens() {
  const totals = { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 }
  let sessionCount = 0

  function walk(dir) {
    let entries
    try { entries = fs.readdirSync(dir, { withFileTypes: true }) } catch (e) { return }
    for (const en of entries) {
      const p = path.join(dir, en.name)
      if (en.isDirectory()) walk(p)
      else if (en.name === 'session.jsonl.zstd') {
        sessionCount++
        const text = decompressJsonl(p)
        const last = new Map() // turn:step -> buckets
        for (const line of text.split('\n')) {
          if (!line.trim()) continue
          let ev
          try { ev = JSON.parse(line) } catch (e) { continue }
          let turn, step, usage
          if (ev.type === 'assistant/chunk' && ev.data && ev.data.chunk && ev.data.chunk.type === 'usage') {
            turn = ev.data.turn; step = ev.data.step; usage = ev.data.chunk.usage
          } else if (ev.type === 'assistant/message' && ev.data && ev.data.usage) {
            turn = ev.data.turn; step = ev.data.step; usage = ev.data.usage
          } else {
            continue
          }
          const buckets = {
            input: usage.inputTokens || 0,
            output: usage.outputTokens || 0,
            cacheRead: usage.cacheReadTokens || 0,
            cacheWrite: usage.cacheWriteTokens || 0,
          }
          const key = turn + ':' + step
          const prev = last.get(key)
          if (prev) {
            totals.input += buckets.input - prev.input
            totals.output += buckets.output - prev.output
            totals.cacheRead += buckets.cacheRead - prev.cacheRead
            totals.cacheWrite += buckets.cacheWrite - prev.cacheWrite
          } else {
            totals.input += buckets.input
            totals.output += buckets.output
            totals.cacheRead += buckets.cacheRead
            totals.cacheWrite += buckets.cacheWrite
          }
          last.set(key, buckets)
        }
      }
    }
  }
  walk(SESSIONS_DIR)

  totals.total = totals.input + totals.output + totals.cacheRead + totals.cacheWrite
  return { ...totals, sessions: sessionCount }
}

// ---- 查询余额 ----
async function fetchBalance(apiKey) {
  const res = await fetch(BALANCE_URL, {
    headers: { Authorization: 'Bearer ' + apiKey },
    signal: AbortSignal.timeout(8000),
  })
  if (!res.ok) throw new Error('balance HTTP ' + res.status)
  const json = await res.json()
  const info = (json.balance_infos && json.balance_infos[0]) || {}
  return {
    available: !!json.is_available,
    currency: info.currency || 'CNY',
    total: parseFloat(info.total_balance || '0'),
    granted: parseFloat(info.granted_balance || '0'),
    toppedUp: parseFloat(info.topped_up_balance || '0'),
  }
}

async function main() {
  const result = { balance: null, tokens: null, error: null }
  let tokens = null
  try { tokens = computeTokens() } catch (e) { result.error = String(e && e.message || e) }
  result.tokens = tokens

  const apiKey = readApiKey()
  if (apiKey) {
    try { result.balance = await fetchBalance(apiKey) }
    catch (e) { if (!result.error) result.error = String(e && e.message || e) }
  } else if (!result.error) {
    result.error = 'no api key'
  }

  const json = JSON.stringify(result)
  // 若传入输出文件路径，则原子写入（先写临时文件再改名），避免 GUI 读到半截数据
  const outPath = process.argv[2]
  if (outPath) {
    try {
      const tmp = outPath + '.tmp'
      fs.writeFileSync(tmp, json)
      fs.renameSync(tmp, outPath)
    } catch (e) { process.stdout.write(json) }
  } else {
    process.stdout.write(json)
  }
}

main().catch((err) => {
  const json = JSON.stringify({ balance: null, tokens: null, error: String(err && err.message || err) })
  const outPath = process.argv[2]
  if (outPath) {
    try {
      const tmp = outPath + '.tmp'
      fs.writeFileSync(tmp, json)
      fs.renameSync(tmp, outPath)
    } catch (e) { process.stdout.write(json) }
  } else {
    process.stdout.write(json)
  }
})
