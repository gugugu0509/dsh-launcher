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

// 结果文件路径（可选）：启动器传入，脚本原子写入该文件
const OUT_PATH = process.argv[2] || null
// token 汇总缓存：放在结果文件同目录，按会话文件 size+mtime 增量复用
const CACHE_PATH = OUT_PATH
  ? path.join(path.dirname(OUT_PATH), 'usage-cache.json')
  : path.join(__dirname, 'usage-cache.json')
const CACHE_VERSION = 1

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
//
// 每个会话文件单独缓存（按 size+mtime 判断是否变化），只有新增/改动的会话才重新
// 解压解析。sessions 目录可达上百 MB，全量解析要 7 秒以上；缓存后重复查询基本瞬时
// 完成（启动器约每 10 秒查一次），也避免拖长单次运行时间导致被调用方超时杀掉。
function readUsageCache() {
  try {
    const data = JSON.parse(fs.readFileSync(CACHE_PATH, 'utf8'))
    if (data && data.version === CACHE_VERSION && data.files) return data.files
  } catch (e) { /* 首次运行没有缓存 */ }
  return {}
}

function writeUsageCache(files) {
  try {
    const tmp = CACHE_PATH + '.tmp'
    fs.writeFileSync(tmp, JSON.stringify({ version: CACHE_VERSION, files }))
    fs.renameSync(tmp, CACHE_PATH)
  } catch (e) { /* 缓存写失败不影响本次结果 */ }
}

/** 解析一个会话日志，返回它的 token 分桶。 */
function tokensOfSession(file) {
  const totals = { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 }
  const text = decompressJsonl(file)
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
  return totals
}

function computeTokens() {
  const cache = readUsageCache()
  const nextCache = {}
  const totals = { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 }
  let sessionCount = 0

  function walk(dir) {
    let entries
    try { entries = fs.readdirSync(dir, { withFileTypes: true }) } catch (e) { return }
    for (const en of entries) {
      const p = path.join(dir, en.name)
      if (en.isDirectory()) { walk(p); continue }
      if (en.name !== 'session.jsonl.zstd') continue

      let st = null
      try { st = fs.statSync(p) } catch (e) { continue }
      sessionCount++

      const hit = cache[p]
      let buckets
      if (hit && hit.size === st.size && hit.mtimeMs === st.mtimeMs && hit.buckets) {
        buckets = hit.buckets
      } else {
        try { buckets = tokensOfSession(p) }
        catch (e) { buckets = { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 } }
      }
      nextCache[p] = { size: st.size, mtimeMs: st.mtimeMs, buckets }
      totals.input += buckets.input
      totals.output += buckets.output
      totals.cacheRead += buckets.cacheRead
      totals.cacheWrite += buckets.cacheWrite
    }
  }
  walk(SESSIONS_DIR)

  writeUsageCache(nextCache)
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

/** 原子写出结果（先写临时文件再改名），避免调用方读到半截 JSON。 */
function writeResult(result) {
  const json = JSON.stringify(result)
  if (OUT_PATH) {
    try {
      const tmp = OUT_PATH + '.tmp'
      fs.writeFileSync(tmp, json)
      fs.renameSync(tmp, OUT_PATH)
    } catch (e) { process.stdout.write(json) }
  } else {
    process.stdout.write(json)
  }
}

async function main() {
  const result = { balance: null, tokens: null, error: null }

  // 先查余额并立即落盘：余额接口只要 ~0.3 秒，绝不能排在耗时的 token 汇总后面
  // （会话日志上百 MB 时汇总要 7 秒以上，排在后面会让余额一起变慢/被超时打断）。
  const apiKey = readApiKey()
  if (apiKey) {
    try { result.balance = await fetchBalance(apiKey) }
    catch (e) { result.error = String(e && e.message || e) }
  } else {
    result.error = 'no api key'
  }
  writeResult(result)

  // 再汇总 token（有缓存，通常很快；首次或会话变动多时较慢）
  try { result.tokens = computeTokens() }
  catch (e) { if (!result.error) result.error = String(e && e.message || e) }
  writeResult(result)
}

main().catch((err) => {
  writeResult({ balance: null, tokens: null, error: String(err && err.message || err) })
})
