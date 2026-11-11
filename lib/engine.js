/**
 * dsh-independent-input · sidecar 客户端
 *
 * 一个常驻的 Windows PowerShell 5.1 进程（STA）负责：
 *   - UIA / 窗口消息（默认，不碰真实光标）
 *   - 物理输入回退（SendInput，主人一碰就暂停并还原光标）
 *   - 低级键鼠钩子 + Ctrl+Alt+Q 全局暂停
 *   - AI 光标覆盖层（点击穿透、不抢焦点）
 *
 * Node 侧只做一件事：按行发 JSON、按行收 JSON。sidecar 懒启动，
 * 第一次真正要用输入能力时才编译 C#，不拖慢 DSH 启动。
 */

import { spawn } from 'node:child_process'
import { existsSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const HERE = dirname(fileURLToPath(import.meta.url))
const SIDECAR = join(HERE, '..', 'sidecar.ps1')

function resolvePowerShell() {
  const explicit = process.env.DSH_INPUT_POWERSHELL
  if (explicit) return explicit
  const system = join(process.env.SystemRoot || 'C:\\Windows', 'System32', 'WindowsPowerShell', 'v1.0', 'powershell.exe')
  if (existsSync(system)) return system
  return 'powershell.exe'
}

export class InputEngine {
  constructor({ log = () => {}, cursorMode = 'companion', cursorHoldMs = 2600, cursorSize = 64, cursorState = 'pointer', slowMode = true, typingIntervalMs = 500, browserEnhance = true } = {}) {
    this.log = log
    this.cursorMode = cursorMode === 'clean' ? 'clean' : 'companion'
    this.cursorHoldMs = Number(cursorHoldMs) > 0 ? Number(cursorHoldMs) : 2600
    this.cursorSize = clampSize(cursorSize)
    this.cursorState = clampStyle(cursorState)
    this.slowMode = slowMode !== false
    this.typingIntervalMs = clampTyping(typingIntervalMs)
    this.browserEnhance = browserEnhance !== false
    this.proc = null
    this.ready = false
    this.starting = null
    this.seq = 0
    this.pending = new Map()
    this.buf = ''
    this.stderr = ''
    this.stopping = false
  }

  async setCursorMode(mode, holdMs) {
    if (mode === 'clean' || mode === 'companion') this.cursorMode = mode
    if (Number(holdMs) > 0) this.cursorHoldMs = Number(holdMs)
    if (this.ready && this.proc && this.proc.exitCode === null) {
      return this.request('setCursorMode', { mode: this.cursorMode, holdMs: this.cursorHoldMs })
    }
    return { ok: true, cursorMode: this.cursorMode, cursorHoldMs: this.cursorHoldMs, pending: true }
  }

  async setCursorSize(size) {
    this.cursorSize = clampSize(size)
    if (this.ready && this.proc && this.proc.exitCode === null) {
      return this.request('setCursorSize', { size: this.cursorSize })
    }
    return { ok: true, cursorSize: this.cursorSize, pending: true }
  }

  async setCursorState(state) {
    this.cursorState = clampStyle(state)
    if (this.ready && this.proc && this.proc.exitCode === null) {
      return this.request('setCursorStyle', { style: this.cursorState })
    }
    return { ok: true, cursorState: this.cursorState, pending: true }
  }

  async setCursorStyle(state) {
    return this.setCursorState(state)
  }

  async ensure() {
    if (this.ready && this.proc && this.proc.exitCode === null) return
    if (this.starting) return this.starting
    this.starting = this.start().finally(() => { this.starting = null })
    return this.starting
  }

  async start() {
    this.stopping = false
    this.stopProcess()
    this.ready = false
    this.buf = ''
    this.stderr = ''

    const ps = resolvePowerShell()
    const proc = spawn(ps, [
      '-NoLogo', '-NoProfile', '-NonInteractive', '-STA',
      '-ExecutionPolicy', 'Bypass', '-File', SIDECAR,
    ], {
      windowsHide: true,
      stdio: ['pipe', 'pipe', 'pipe'],
      env: {
        ...process.env,
        DSH_INPUT_CURSOR_MODE: this.cursorMode,
        DSH_INPUT_CURSOR_HOLD_MS: String(this.cursorHoldMs),
        DSH_INPUT_CURSOR_SIZE: String(this.cursorSize),
        DSH_INPUT_CURSOR_STYLE: this.cursorState,
      },
    })
    this.proc = proc

    proc.stdout.setEncoding('utf8')
    proc.stdout.on('data', (chunk) => this.onData(chunk))

    proc.stderr.setEncoding('utf8')
    proc.stderr.on('data', (chunk) => {
      this.stderr = (this.stderr + chunk).slice(-8000)
      this.log(`[sidecar stderr] ${chunk.trim()}`)
    })

    proc.on('error', (error) => {
      this.failAll(new Error(`输入 sidecar 启动失败：${error.message}`))
    })
    proc.on('exit', (code, signal) => {
      this.ready = false
      this.proc = null
      const detail = this.stderr ? `\n${this.stderr.slice(-1200)}` : ''
      this.failAll(new Error(`输入 sidecar 退出（code=${code} signal=${signal}）${detail}`))
    })

    const started = Date.now()
    while (true) {
      if (this.ready) return
      if (!this.proc || this.proc.exitCode !== null) {
        throw new Error(`输入 sidecar 没起来：${this.stderr.slice(-1500) || '进程已退出'}`)
      }
      if (Date.now() - started > 30000) {
        this.stopProcess()
        throw new Error(`输入 sidecar 启动超时：${this.stderr.slice(-1500) || '没有收到 ready'}`)
      }
      await sleep(80)
    }
  }

  onData(chunk) {
    this.buf += chunk
    let index
    while ((index = this.buf.indexOf('\n')) >= 0) {
      const line = this.buf.slice(0, index).trim()
      this.buf = this.buf.slice(index + 1)
      if (!line) continue
      let message
      try {
        message = JSON.parse(line)
      } catch {
        this.log(`[sidecar] 非 JSON 输出：${line.slice(0, 300)}`)
        continue
      }
      if (message.event === 'ready') {
        this.ready = true
        continue
      }
      const pending = this.pending.get(message.id)
      if (!pending) continue
      this.pending.delete(message.id)
      clearTimeout(pending.timer)
      if (message.ok) {
        const state = message.result?.cursorState
        if (typeof state === 'string' && state) this.cursorState = state
        pending.resolve(message.result)
      } else {
        pending.reject(new Error(message.error || 'sidecar 返回错误'))
      }
    }
  }

  failAll(error) {
    for (const [, pending] of this.pending) {
      clearTimeout(pending.timer)
      pending.reject(error)
    }
    this.pending.clear()
  }

  async request(cmd, args = {}, timeoutMs = 30000) {
    await this.ensure()
    const id = ++this.seq
    // 缓慢模式由引擎统一注入，调用方不用每个动作都传一遍
    const payload = { ...args }
    if (SLOW_AWARE.has(cmd)) {
      if (payload.slowMode === undefined) payload.slowMode = this.slowMode
      if (payload.typingIntervalMs === undefined) payload.typingIntervalMs = this.typingIntervalMs
    }
    // 浏览器增强走 CDP；设置里关掉后 sidecar 直接拒绝，不再尝试连 daemon
    if (cmd === 'browser' && payload.browserEnhance === undefined) payload.browserEnhance = this.browserEnhance
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(id)
        reject(new Error(`输入 sidecar 超时：${cmd}`))
      }, timeoutMs)
      this.pending.set(id, { resolve, reject, timer })
      try {
        this.proc.stdin.write(`${JSON.stringify({ id, cmd, ...payload })}\n`)
      } catch (error) {
        this.pending.delete(id)
        clearTimeout(timer)
        reject(error)
      }
    })
  }

  stopProcess() {
    const proc = this.proc
    this.proc = null
    this.ready = false
    if (!proc) return
    try { proc.stdin.end() } catch { /* ignore */ }
    try { proc.kill() } catch { /* ignore */ }
  }

  stop() {
    if (this.stopping) return
    this.stopping = true
    const proc = this.proc
    if (proc) {
      try {
        proc.stdin.write(`${JSON.stringify({ id: ++this.seq, cmd: 'shutdown' })}\n`)
      } catch { /* ignore */ }
      setTimeout(() => {
        try { proc.kill() } catch { /* ignore */ }
      }, 800).unref?.()
    }
    this.stopProcess()
  }
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms))
}

function clampSize(size) {
  const n = Number(size)
  if (!Number.isFinite(n)) return 64
  return Math.max(24, Math.min(192, Math.round(n)))
}

function clampTyping(ms) {
  const n = Number(ms)
  if (!Number.isFinite(n)) return 500
  return Math.max(100, Math.min(3000, Math.round(n)))
}

// 这些动作吃「缓慢模式」：移动有补间、打字一个字一个字冒
const SLOW_AWARE = new Set(['move', 'click', 'type', 'scroll', 'drag'])

const STYLES = new Set([
  'pointer', 'work', 'unavailiable', 'link', 'text',
  'cross', 'busy', 'move', 'vert', 'horz',
  'help', 'handwriting', 'dgn1', 'dgn2', 'alternate',
])

function clampStyle(style) {
  const s = String(style || '').toLowerCase()
  return STYLES.has(s) ? s : 'pointer'
}
