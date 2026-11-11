/**
 * dsh-independent-input · 独立鼠标键盘
 *
 * 只做“输入”这一层：鼠标、键盘、滚轮、拖拽、截图定位。
 * 默认走 UIA / 窗口消息，不移动主人的真实光标、不抢键盘焦点；`mode:"physical"` 会动真实光标并抢焦点，主人一动就中止。
 */

import { readFile, writeFile, mkdir } from 'node:fs/promises'
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs'
import { homedir } from 'node:os'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { InputEngine } from './lib/engine.js'

export const name = 'independent-input-mod'
export const inject = ['tools', 'attachments', 'webServer']

const PLUGIN_DIR = dirname(fileURLToPath(import.meta.url))
const PREVIEW_DIR = join(PLUGIN_DIR, 'assets', 'previews')
const SETTINGS_FILE = join(homedir(), '.dsh', 'independent-input', 'settings.json')
const PHRASES_FILE = join(homedir(), '.dsh', 'independent-input', 'phrases.json')

// 面向主人的四句话。只开放这四句：它们是「语气」，不是协议。
// 其余提示都是给模型看的诊断信息，改了等于改协议。
const DEFAULT_PHRASES = {
  takeover: '需要 physical：我要接管真实鼠标了（Ctrl+Alt+Q 可暂停）',
  working: '还在处理…（没卡住，可以继续等）',
  moving: '正在操作…',
  idle: '我这边空下来了，还有要做的就说',
}

const PHRASE_PRESETS = {
  companion: { ...DEFAULT_PHRASES },
  plain: {
    takeover: '接管真实鼠标（Ctrl+Alt+Q 暂停）',
    working: '处理中…',
    moving: '操作中',
    idle: '空着',
  },
}

function readPhrases() {
  try {
    const raw = readFileSync(PHRASES_FILE, 'utf8')
    const obj = JSON.parse(raw)
    return normalizePhrases(obj, DEFAULT_PHRASES)
  } catch {
    return { ...DEFAULT_PHRASES }
  }
}

function normalizePhrases(input, base) {
  const pick = (key) => {
    const v = input?.[key]
    return typeof v === 'string' && v.trim() ? v : base[key]
  }
  return {
    takeover: pick('takeover'),
    working: pick('working'),
    moving: pick('moving'),
    idle: pick('idle'),
  }
}

function writePhrases(next) {
  mkdirSync(dirname(PHRASES_FILE), { recursive: true })
  writeFileSync(PHRASES_FILE, JSON.stringify(next, null, 2), 'utf8')
}
const STYLE_IDS = [
  'pointer', 'work', 'unavailiable', 'link', 'text',
  'cross', 'busy', 'move', 'vert', 'horz',
  'help', 'handwriting', 'dgn1', 'dgn2', 'alternate',
]

function toLosslessJson(value) {
  if (value === undefined || value === null) return null
  if (typeof value === 'number') return Number.isFinite(value) ? value : null
  if (typeof value === 'bigint') return Number(value)
  if (typeof value !== 'object') return value
  if (Array.isArray(value)) return value.map(toLosslessJson)
  const out = {}
  for (const [key, item] of Object.entries(value)) out[key] = toLosslessJson(item)
  return out
}

async function loadDefineTool() {
  try {
    const mod = await import('@deepseek-ai/dsh-tools')
    if (mod?.defineTool) return mod.defineTool
  } catch { /* 本地测试时走环境变量 */ }
  const override = process.env.DSH_TOOLS_PATH
  if (override) {
    const { pathToFileURL } = await import('node:url')
    const mod = await import(pathToFileURL(override).href)
    if (mod?.defineTool) return mod.defineTool
  }
  // 最小兜底：只在没有 DSH 的单元测试里用；真实宿主一定有 dsh-tools。
  return (definition) => definition
}

function statusText(s) {
  const paused = s?.paused ? `已暂停（${s.pauseReason || '主人接管'}）` : '运行中'
  const age = Number.isFinite(s?.lastUserInputAgeMs) && s.lastUserInputAgeMs >= 0
    ? `${Math.round(s.lastUserInputAgeMs)}ms 前`
    : '还没记录'
  const fg = s?.foreground?.title || s?.foreground?.className || '未知'
  const cursor = s?.cursor ? `(${s.cursor.x}, ${s.cursor.y})` : '未知'
  const mode = s?.cursorMode === 'clean'
    ? `整洁模式（动作后约 ${s?.cursorHoldMs || 2600}ms 收起，${s?.cursorSize || 64}px · ${s?.cursorState || 'pointer'}）`
    : `陪伴模式（一直显示，${s?.cursorSize || 64}px · ${s?.cursorState || 'pointer'}）`
  const lines = [
    `独立输入：${paused}`,
    `主人最近一次真实输入：${age}`,
    `真实光标：${cursor} · AI 光标：${s?.overlay ? (s?.overlayBusy ? '显示（干活中：图标在呼吸）' : '显示（待命：图标静止）') : '隐藏'} · ${mode}`,
    `前台窗口：${fg}`,
  ]
  if (s?.paused) {
    lines.push('⚠ 主人已经暂停/接管输入。不要继续操作；等主人说“继续”，再调用 action:"resume"。')
  } else if (s?.hotkeyRegistered === false) {
    lines.push(`⚠ ${s?.hotkey || 'Ctrl+Alt+Q'} 热键没注册上（多半是别的实例占着），主人仍可直接动键鼠接管。`)
  } else {
    lines.push(`主人随时可按 ${s?.hotkey || 'Ctrl+Alt+Q'} 暂停。`)
  }
  // D014：上一次「收尾」是什么时候。0 = 本进程还没收过尾。
  const doneAt = Number(s?.lastDoneAt)
  if (Number.isFinite(doneAt) && doneAt > 0) {
    const mins = Math.max(0, Math.round((Date.now() - doneAt) / 60000))
    const when = mins < 1 ? '刚刚' : (mins < 60 ? `${mins} 分钟前` : `${Math.round(mins / 60)} 小时前`)
    lines.push(`上次收尾（done）：${when}`)
  } else {
    lines.push('上次收尾（done）：本轮还没收过尾')
  }
  if (Number(s?.peers) > 0) {
    lines.push(`⚠ 还有 ${s.peers} 个 sidecar 进程在跑，热键和 overlay 会互相打架，建议先清理。`)
  }
  const env = s?.environment
  if (env && env.kind && env.kind !== 'unknown') {
    const kindName = { chromium: 'Chromium 系浏览器', explorer: '文件资源管理器', win32: '普通 Win32 窗口' }[env.kind] || env.kind
    const bits = [`前台是${kindName}`]
    if (env.verticalTabs) bits.push('垂直标签栏')
    lines.push(`环境：${bits.join(' · ')}`)
    if (env.note) lines.push(`   ${env.note}`)
  }
  // D022：CDP 通道状态。needAuth=true 就是在等人在弹窗上点「允许」，不用再猜。
  const cdp = s?.cdp
  if (cdp && cdp.listening) {
    const bits = []
    if (cdp.connected) bits.push(`已连接（${cdp.port}）`)
    else if (cdp.needAuth) bits.push(`⚠ 未连接（${cdp.port}）——浏览器可能在等你点「是否允许远程调试？」`)
    else bits.push(`未连接（${cdp.port}）`)
    lines.push(`浏览器通道 CDP：${bits.join('')}`)
  } else if (cdp) {
    lines.push(`浏览器通道 CDP：端口 ${cdp.port} 没开（Edge 未带调试参数，或没在 edge://inspect 里勾选）`)
  }
  const strikes = Number(s?.takeoverStrikes)
  if (Number.isFinite(strikes) && strikes > 0) {
    const limit = s?.takeoverLimit || 3
    lines.push(strikes >= limit
      ? `⛔ 事不过三已经用满（${strikes}/${limit}）：真实鼠标键盘已停手，AI 光标停在 help 图标等主人表态。要接着干先 action:"resume"。`
      : `⚠ 主人已经夺权 ${strikes}/${limit} 次；再来 ${limit - strikes} 次就彻底停手。`)
  }
  const evts = Array.isArray(s?.events) ? s.events : []
  if (evts.length) {
    const recent = evts.slice(-6)
    lines.push('')
    lines.push(`最近动作（共 ${s.eventCount ?? evts.length} 条，显示最后 ${recent.length} 条）：`)
    for (const e of recent) {
      const tag = e.ok ? '✓' : '✗'
      const lab = e.label ? `「${e.label}」` : ''
      const tgt = e.hwnd ? `hwnd ${e.hwnd}` : (e.x != null ? `(${e.x},${e.y})` : '')
      const via = e.via ? ` · ${e.via}` : ''
      lines.push(`  ${tag} ${e.at} ${e.action}${lab} ${tgt}${via} ${e.ms}ms`)
    }
  }
  return lines.join('\n')
}

function windowsText(r) {
  const list = Array.isArray(r?.windows) ? r.windows : []
  if (!list.length) return '没读到可用窗口。'
  const lines = list.slice(0, 24).map((w) => {
    const rect = w.rect ? `${w.rect.x},${w.rect.y} ${w.rect.w}x${w.rect.h}` : '?'
    const mark = w.foreground ? ' ★前台' : ''
    return `hwnd ${w.hwnd} · ${w.title} · ${rect} · ${w.process || ''}${mark}`.trim()
  })
  if (list.length > 24) lines.push(`……还有 ${list.length - 24} 个窗口未列出`)
  return lines.join('\n')
}

function environmentText(r) {
  if (!r || r.ok === false) {
    return `环境画像读取失败：${r?.error || r?.reason || '未知原因'}`
  }
  const p = r.profile || {}
  const kindName = { chromium: 'Chromium 系浏览器', explorer: '文件资源管理器', win32: '普通 Win32 窗口' }[p.kind] || p.kind || '未知'
  const lines = []
  if (r.op === 'save') {
    lines.push(`已保存环境画像到：${r.filePath}`)
  } else {
    lines.push(`环境画像（来源：${r.source === 'file+probe' ? '文件 + 本次探测' : '本次探测'}）`)
  }
  lines.push(`窗口类：${p.windowClass || '?'} · 类型：${kindName}`)
  lines.push(`垂直标签栏：${p.verticalTabs ? '是（标签竖排在左侧，落点要用 locator 现场算）' : '否'}`)
  if (p.note) lines.push(`说明：${p.note}`)
  if (p.notes) lines.push(`人工补充：${p.notes}`)
  lines.push(`文件：${r.filePath}${r.fileExists ? '（已存在）' : '（还没有，用 environmentOp:"save" 生成）'}`)
  return lines.join('\n')
}

function observeText(r) {
  if (!r || r.ok === false) {
    const why = r?.reason === 'window-not-found'
      ? '没找到这个窗口（hwnd 可能过期了，先用 windows 重新拿）'
      : r?.reason === 'uia-unavailable'
        ? 'UIA 没初始化'
        : r?.reason === 'enum-failed'
          ? `枚举失败：${r?.note || '未知'}`
          : r?.note || r?.reason || '未知原因'
    return `observe 失败：${why}`
  }
  const items = Array.isArray(r.items) ? r.items : []
  const head = `窗口「${r.title || '?'}」${r.hwnd ? `（hwnd ${r.hwnd}）` : '（前台）'} · 共枚举 ${r.total} 个控件，其中能操作的 ${items.length} 个`
  if (!items.length) {
    return `${head}\n没找到可操作控件。可能页面还在加载（先 waitFor 或稍等），或者这个窗口是自绘界面（退回 capture）。`
  }
  // 控件名可能带换行（浏览器按钮的提示文字就是多行的），压成一行再显示
  const clean = (s) => String(s ?? '').replace(/\s+/g, ' ').trim().slice(0, 80)
  const lines = [head]
  const sorted = [...items].sort((a, b) => (a.cy - b.cy) || (a.cx - b.cx))
  sorted.forEach((it, i) => {
    const flags = []
    if (it.focused) flags.push('★焦点')
    if (it.enabled === false) flags.push('已禁用')
    const f = flags.length ? ` · ${flags.join(' ')}` : ''
    // 有些元素（尤其是网页里的 div/span）没有 Name，只有 ClassName；这时把 class 显出来，
    // 否则模型看到「【Group】 · (x,y)」不知道拿什么去定位。
    const label = clean(it.name) || (it.className ? `class=${String(it.className).replace(/\s+/g, ' ').trim().slice(0, 48)}` : '（没有名字）')
    const refTag = it.ref ? `[${it.ref}] ` : ''
    const roleTag = it.role ? `${it.role}/${it.type}` : it.type
    lines.push(`${String(i + 1).padStart(2, ' ')}. ${refTag}【${it.roles}】${label} · (${it.cx},${it.cy}) ${it.w}×${it.h} · ${roleTag}${f}`)
  })
  if (r.truncated) lines.push(`……还有 ${Math.max(0, r.total - items.length)} 个没列（调大 observeMax，或加 observeFilter 过滤）`)
  lines.push('')
  lines.push('要操作某个控件，**直接用它的编号**：`locator: {ref:"e17"}`。不用抄名字、不用记坐标——名字会变（网页输入框的 Name 常常就是它当前的内容），编号不会。元素要是没了会明确报 stale，重新 observe 一次就有新编号。只有拿不到编号时才退回 `{name:"…"}` / `{className:"…"}` / `{controlType:"…"}`。')
  return lines.join('\n')
}

function actText(r) {
  if (!r || typeof r !== 'object') return 'act：没有结果'
  const steps = Array.isArray(r.steps) ? r.steps : []
  const clean = (s) => String(s ?? '').replace(/\s+/g, ' ').trim().slice(0, 60)
  const cleanWide = (s) => String(s ?? '').replace(/\s+/g, ' ').trim().slice(0, 160)
  const total = Number.isFinite(r.total) ? r.total : steps.length
  const failedCount = Number.isFinite(r.failedCount) ? r.failedCount : (r.ok ? 0 : 1)
  const head = r.ok
    ? `act：全部 ${steps.length} 步完成`
    : r.executed < total
      ? `act：第 ${r.failedAt} 步失败，后面 ${Math.max(0, total - (r.executed || 0))} 步没执行`
      : `act：${total} 步里 ${failedCount} 步没过（stopOnError=false，后面照跑了）`
  const lines = [head]
  steps.forEach((s) => {
    const bits = []
    if (s.via) bits.push(s.via)
    if (Number.isFinite(s.chars)) bits.push(`${s.chars} 字`)
    if (s.title) bits.push(`标题「${clean(s.title)}」`)
    if (s.value !== undefined && s.value !== '') bits.push(`读回「${clean(s.value)}」`)
    if (Number.isFinite(s.waitedMs)) bits.push(`等了 ${s.waitedMs}ms`)
    if (Number.isFinite(s.ms)) bits.push(`${s.ms}ms`)
    let line = `${String(s.i).padStart(2, ' ')}. ${s.do}`
    if (bits.length) line += ` · ${bits.join(' · ')}`
    line += ` ${s.ok ? '✓' : '✗'}`
    lines.push(line)
    // 效果证据：这一步前后界面真的变了什么。模型据此就不用自己再跑 windows/observe 复核。
    if (Array.isArray(s.changes) && s.changes.length) {
      s.changes.forEach((c) => lines.push(`    → ${cleanWide(c)}`))
    }
    if (s.outcome === 'unknown') {
      lines.push('    → 未证实：动作已投递，但窗口级的见证里没看到变化（页面内部的效果本来就看不着，属正常；要的是切窗口／开标签／改标题却没变，那多半没生效）')
    }
    if (!s.ok) {
      if (s.reason === 'expect-failed' && s.note) {
        lines.push(`    —— ${clean(s.note)}`)
      } else if (s.reason) {
        lines.push(`    —— 原因：${s.reason}${s.note ? '／' + clean(s.note) : ''}`)
      }
      const st = s.stateAfter
      if (st) {
        const foc = clean(st.focusName) || clean(st.focusType) || '无'
        lines.push(`    —— 当时界面：标题「${clean(st.title) || '?'}」，焦点「${foc}」`)
      }
      if (Array.isArray(s.checks)) {
        const bad = s.checks.filter((c) => !c.ok)
        if (bad.length) lines.push(`    —— 校验没过：${bad.map((c) => `${c.name}（实际 ${clean(c.got)}）`).join('；')}`)
      }
    }
  })
  if (Array.isArray(r.sideEffects) && r.sideEffects.length) {
    lines.push('')
    lines.push('整段下来：')
    r.sideEffects.forEach((c) => lines.push(`  · ${cleanWide(c)}`))
  }
  if (!r.ok && r.executed < total) {
    lines.push('')
    lines.push(`停在第 ${r.failedAt} 步。先看界面变成了什么样（observe 或 capture），再决定重试这一步、换 locator，还是放弃。`)
  }
  return lines.join('\n')
}

function resultTextRaw(action, r) {
  if (!r || typeof r !== 'object') return `已执行 ${action}。`
  if (r.paused) {
    return `⚠ 主人已经暂停/接管输入，动作没有执行。\n${r.note || '等主人说继续，再 action:"resume"。'}`
  }
  if (r.ok === false) {
    if (r.reason === 'user-takeover') {
      const n = Number.isFinite(r.strikes) ? `（连续第 ${r.strikes} 次）` : ''
      return `主人碰了键鼠，动作立刻中止在 (${r.atX ?? '?'}, ${r.atY ?? '?'})${n}——控制权已经回到主人手里。要不要继续，由主人决定。`
    }
    if (r.reason === 'takeover-limit') {
      return `⚠ 事不过三：主人已经连续 ${r.strikes ?? 3} 次把手夺回去，我不再动真实鼠标/键盘。
AI 光标已经换成 help 图标停在原地，表示“我不敢再动了，你是不是不想让我继续”。
要接着干，得主人明确说“继续”，然后 action:"resume" 清掉计数。`
    }
    const bits = [`未完成（${r.reason || '未知原因'}）`]
    if (r.name) bits.push(`目标：${r.name}`)
    if (r.type) bits.push(`类型：${r.type}`)
    if (r.note) bits.push(r.note)
    if (r.needsPhysical) bits.push('目标是自绘控件或 Chromium 输入框时，可改用 mode:"physical"（会动真实光标，主人一动就中止）。')
    if (r.strictNoRealMouse || r.strictNoFocusSteal) bits.push('已严格禁止真实鼠标 / 抢焦点。')
    return bits.join('\n')
  }
  if (action === 'capture') {
    if (r.ok === false) {
      const why = r.reason === 'window-minimized' ? '窗口最小化了，截不到内容（PrintWindow 会返回黑图）'
        : r.reason === 'printwindow-failed' ? 'PrintWindow 渲染失败，且窗口不在前台'
        : r.reason === 'no-window' ? '没有找到要截的窗口'
        : (r.reason || '未知原因')
      return `没截到：${why}。${r.note ? '\n' + r.note : ''}`
    }
    const bits = [`截图已保存：${r.path}`]
    if (r.source) {
      const srcName = r.source === 'window-printwindow' ? '按窗口渲染（PrintWindow，后台/被遮挡也能截到它自己的画面）'
        : r.source === 'window-screen-copy' ? '按窗口位置从屏幕拷贝（PrintWindow 失败，窗口必须可见）'
        : r.source === 'rect' ? '按矩形区域从屏幕拷贝'
        : '整屏拷贝'
      bits.push(`来源：${srcName}`)
    }
    if (r.imageSize?.w) bits.push(`图像尺寸：${r.imageSize.w}x${r.imageSize.h}（屏幕物理像素，click 的 x/y 同坐标系，不用换算）`)
    if (r.screenSize?.w) bits.push(`屏幕尺寸：${r.screenSize.w}x${r.screenSize.h}`)
    bits.push(r.attached ? '图已附在本条结果里。' : '用 read_image 看它。')
    return bits.join('\n')
  }
  if (action === 'waitFor') {
    if (r.ok === false && r.reason === 'wait-timeout') {
      const what = r.mode === 'titleChange' ? '窗口标题变化'
        : r.mode === 'disappear' ? '元素消失'
        : r.mode === 'textAppear' ? `文本「${r.text || '?'}」出现`
        : '元素出现'
      return `等了 ${r.waitedMs ?? '?'}ms 没等到${what}（超时 ${r.timeoutMs ?? '?'}ms）。可以调大 timeoutMs，或者换成更稳的定位器（name/className/controlType）。`
    }
    const el = r.element || {}
    const label = el.name ? `「${el.name}」` : ''
    const cls = el.className ? ` · class ${el.className}` : ''
    const where = Array.isArray(el.center) ? ` · 中心 (${el.center[0]}, ${el.center[1]})` : ''
    return `等到了${label}${cls}${where}（用了 ${r.waitedMs ?? '?'}ms）。可以直接把这个中心和 locator 交给 click/type。`
  }
  if (action === 'overlay') {
    if (r.visible === false) return 'AI 光标已隐藏；主人的真实光标没有移动。'
    const mode = r.cursorMode === 'clean' ? '整洁模式（一会儿自动收起）' : '陪伴模式（一直显示）'
    return `AI 光标已到 (${r.x ?? '?'}, ${r.y ?? '?'}) · ${mode} · ${r.cursorSize || 64}px · ${r.cursorState || 'pointer'}；主人的真实光标没有移动。`
  }
  if (action === 'activate') {
    const name = r.title ? `「${r.title}」` : ''
    const bits = [`已把 ${name}（hwnd ${r.hwnd}）切到前台。`]
    if (r.note) bits.push(r.note)
    bits.push(`全程没动真实光标、没按键；目标${r.via === 'title' ? '按标题找到的' : '按 hwnd 指定'}。`)
    return bits.join('\n')
  }
  if (action === 'setScope') {
    const list = Array.isArray(r.scope) ? r.scope : []
    if (!list.length) return '窗口限制已解除：任何窗口都能操作。'
    const ws = Array.isArray(r.windows) && r.windows.length ? r.windows.map((x) => String(x)).join('；') : list.join(', ')
    return `窗口作用域已设成 ${list.length} 个：${ws}\n白名单之外的窗口，click/type/key/scroll/act/activate 一律返回 out-of-scope，动作不会投递出去。`
  }
  if (action === 'browser') {
    const clean = (s) => String(s ?? '').replace(/\s+/g, ' ').trim().slice(0, 80)
    if (!r.ok) {
      const why = r.reason === 'cdp-unavailable'
        ? '没连上浏览器调试端口：Edge 要带 --remote-debugging-port=9222 和独立 --user-data-dir 启动'
        : r.reason === 'no-element'
          ? `选择器 ${r.selector || ''} 在页面上没找到元素（先 count 或换选择器）`
          : r.reason === 'js-error'
            ? `JS 报错：${clean(r.error || '')}`
            : clean(r.reason || r.error || '未知原因')
      return `browser 失败：${why}`
    }
    if (r.op === 'tabs' || Array.isArray(r.tabs)) {
      const ts = Array.isArray(r.tabs) ? r.tabs : []
      const lines = ts.map((t) => `· ${clean(t.title || '(无标题)')} — ${clean(t.url || '')}`)
      return `浏览器标签页 ${ts.length} 个：\n${lines.join('\n')}`
    }
    const tab = r.tab ? `（标签：${clean(r.tab.title || '')}）` : ''
    if (r.op === 'click') return `已用 CDP 点中 ${r.selector}${tab}。这是浏览器自己处理的原生点击，不是坐标点击。`
    if (r.op === 'fill') return `已用 CDP 往 ${r.selector} 填了「${clean(String(r.value || ''))}」${tab}。`
    if (r.op === 'count') return `${r.selector} 匹配 ${r.value} 个元素${tab}。`
    const v = typeof r.value === 'string' ? r.value : JSON.stringify(r.value)
    return `CDP 执行结果${tab}：\n${String(v).slice(0, 2000)}`
  }
  if (action === 'done') {
    const hold = Math.round((Number(r.holdMs) || 3000) / 100) / 10
    const bits = [`收尾了：AI 光标现身并说「${r.text || '这一轮做完了'}」，气泡停 ${hold} 秒。`]
    if (r.cursorShown) bits.push('（光标原来是收着的，这次重新点亮）')
    if (r.focused) bits.push(`已把窗口切到前台（hwnd ${r.focusHwnd}）。`)
    else if (r.focusHwnd) bits.push(`窗口找到了（hwnd ${r.focusHwnd}）但没能切到前台。`)
    else bits.push('没有切前台——你正在看的东西保持不动。')
    if (r.note) bits.push(r.note)
    return bits.join('\n')
  }
  if (action === 'move') {
    if (r.via === 'physical') {
      const from = Array.isArray(r.from) ? `从 (${r.from[0]}, ${r.from[1]}) ` : ''
      const back = r.restoreCursor ? '走完已放回原处。' : '现在停在目标位置。'
      return `真实光标${from}分步走到 (${r.x ?? '?'}, ${r.y ?? '?'})：动画 ${r.durationMs ?? '?'}ms、实际 ${r.elapsedMs ?? '?'}ms，AI 光标一路跟在右下角。${back}`
    }
    const mode = r.cursorMode === 'clean' ? '整洁模式（一会儿自动收起）' : '陪伴模式（一直显示）'
    const anim = r.durationMs > 0
      ? `补间动画 ${r.durationMs}ms，实际走了 ${r.elapsedMs ?? '?'}ms`
      : '瞬移'
    const from = Array.isArray(r.from) ? `从 (${r.from[0]}, ${r.from[1]}) ` : ''
    return `AI 光标${from}到 (${r.x ?? '?'}, ${r.y ?? '?'}) · ${anim} · ${mode}；主人的真实光标没有移动。`
  }
  const via = r.via || 'unknown'
  // P1：把"降级"这件事说给调用方听。以前只写"已执行/已投递"，
  // 实际通道可能根本没生效（D001/D004/D007），模型只能靠截图猜。
  const degrade = () => {
    if (!r.degradedFrom) return ''
    const map = {
      'uia-container': 'UIA 只找到可点的容器，是否生效无法确认',
      'message': '这条窗口消息通道对方可能不处理',
      'message-chromium': 'Chromium 不处理窗口消息，已直接升级为真实键盘',
      'message-game': '游戏/自绘窗口不处理窗口消息，已直接升级为真实键盘',
    }
    const head = map[r.degradedFrom] || `已从 ${r.degradedFrom} 降级`
    const sug = r.suggest === 'physical' ? '；要确保生效请加 mode:"physical" 或改用 locator' : ''
    return `　[降级：${head}${sug}]`
  }
  if (via === 'physical') {
    if (action === 'click') {
      const btn = r.button === 'right' ? '右键' : '左键'
      const stay = r.restoreCursor ? '点完已放回原处。' : '点完就停在原地（不再瞬移回去）。'
      return `真实鼠标分步走到 (${r.x ?? '?'}, ${r.y ?? '?'}) 并按下${btn} ${r.count || 1} 次（动画 ${r.durationMs ?? '?'}ms），AI 光标跟了一路。${stay}主人一动键鼠会立刻中止。`
    }
    if (action === 'scroll') {
      return `真实滚轮在 (${r.x ?? '?'}, ${r.y ?? '?'}) 滚了 ${r.delta ?? '?'}，AI 光标跟了一路。`
    }
    if (action === 'drag') {
      return `真实鼠标从 (${r.from?.[0] ?? '?'}, ${r.from?.[1] ?? '?'}) 拖到 (${r.to?.[0] ?? '?'}, ${r.to?.[1] ?? '?'})，AI 光标跟了一路。`
    }
    return `physical 动作已完成（${action}）。`
  }
  if (via === 'uia') {
    return `UIA 已执行（${r.pattern || 'pattern'}）${r.name ? `：${r.name}` : ''}${r.type ? ` · ${r.type}` : ''}${degrade()}`
  }
  if (via === 'bm_click') {
    return `已向按钮发 BM_CLICK；没有移动鼠标，也没有抢焦点。`
  }
  if (via === 'uia-hwnd') {
    return `目标窗口内 UIA 已执行（${r.pattern || 'pattern'}）${r.name ? `：${r.name}` : ''}${r.type ? ` · ${r.type}` : ''}${degrade()}`
  }
  if (via === 'physical-typing') {
    const dock = Array.isArray(r.dockedAt) ? `，AI 光标停在输入框右下 (${r.dockedAt[0]}, ${r.dockedAt[1]}) 直到打完` : ''
    return `真实键盘逐字敲了 ${r.chars ?? '?'} 个字（每字 ${r.intervalMs ?? '?'}ms）${dock}，窗口已切到前台。主人一动键鼠会立刻中止。`
  }
  if (via === 'physical-keys') {
    return `真实键盘按下了 ${r.keys ?? '?'}，窗口已切到前台。主人一动键鼠会立刻中止。${degrade()}`
  }
  if (via === 'wm_settext') {
    return `已直接写入控件${r.verified ? '（已回读确认）' : ''}；没有移动光标，也没有抢焦点。`
  }
  if (via === 'uia-focus+physical') {
    return `已切窗口并用真实鼠标完成动作；主人一动键鼠会立刻中止。`
  }
  if (via === 'uia+message') {
    return `已向目标窗口投递文字${r.verified ? '（已确认）' : '（需截图确认）'}；没有抢焦点。`
  }
  if (via === 'message-hwnd') {
    const target = r.title ? `“${r.title}”` : (r.hwnd ? `hwnd ${r.hwnd}` : '目标')
    return `已向 ${target} 投递窗口消息（消息发出去≠界面变了，窗口消息读不回结果；确认要看 observe/截图）。没有动真实鼠标。${degrade()}`
  }
  if (via === 'message') {
    const target = r.title ? `“${r.title}”` : (r.hwnd ? `hwnd ${r.hwnd}` : '目标')
    return `窗口消息已投递给 ${target}（消息发出去≠界面变了，读不回结果；确认要看 observe/截图）。${degrade()}`
  }
  if (via === 'physical') {
    return `physical 动作已完成（${action}）。`
  }
  return `已执行 ${action}：${JSON.stringify(r).slice(0, 600)}`
}

// dsh-cua 借鉴①：把 sidecar 打的 effect 标签翻成人话，追加在结果末尾。
// confirmed 只代表「界面这一层确实动了」，业务是否成功仍由调用方判断。
function resultText(action, r) {
  const text = resultTextRaw(action, r)
  if (!r || typeof r !== 'object' || !r.effect) return text
  const map = {
    confirmed: '✓ 效果已确认（有回读证据：界面这一层确实动了；业务是否成功还要看内容）',
    suspected: '? 效果未确认（动作已投递，但无法确认目标是否处理了它；需要复核就再 observe/截图，或改 mode:"physical"）',
    none: '✗ 明确没做成'
  }
  const line = map[r.effect]
  return line ? `${text}\n${line}` : text
}

function toolSpec() {
  return {
    name: 'independent_input',
    description:
      '独立鼠标键盘：默认用 UIA / 窗口消息操作屏幕，**不移动主人的真实光标、不抢键盘焦点**，所以主人随时可以继续用鼠标键盘、暂停或提意见。\n\n'
      + '**你只管说做什么**（点哪个控件、输什么字）——坐标、找元素、算落点都由工具在现场完成，不需要你计算或记忆。想得越少，做得越快。\n\n'
      + '用法顺序：\n'
      + '1. 先 `status` 看是否 paused、前台窗口、真实光标位置；paused 就停手，等主人说继续。\n'
      + '2. 先用 `windows` 拿目标窗口 `hwnd`；再 `observe` 一次拿到「能点的控件清单」。**坐标永远不用你算、也不要去记**——要动哪个控件就写 `locator`，工具在执行那一刻自己定位；你只管说「点哪个、输什么」。\n'
      + '3. 用 `click` / `type` / `key` / `scroll` / `drag`，**必须带目标 `hwnd`**，默认 `mode:"auto"`（目标窗口的 UIA / 窗口消息）；UIA 和窗口消息都无效时（游戏、自绘控件、部分 Chromium 输入框）才用 `mode:"physical"`：真实光标会分步走过去并按下，AI 图标一路跟随，主人一动键鼠立刻中止（reason=user-takeover）。\n'
      + '4. 动作的返回里带结果证据（点到了谁、写入后读回什么、按键后窗口有无反应）；只有证据不足时才截图确认，不要每个动作都截。\n\n'
      + '总开关：设置 → 独立输入 里的「启用独立输入」。关闭时本工具不执行任何动作；开启时 AI 光标和主人的鼠标完全分开。\n\n'
      + 'AI 光标：开始操作时用 `move` 让它出现。两种模式 —— `companion`（陪伴，默认，一直显示到收工）'
      + '和 `clean`（整洁，动作后约 2.6 秒自动收起）。插件 config 里改 `cursorMode` / `cursorSize`（24–192，默认 64）；'
      + '光标外观按操作**自动切换**（默认 pointer、输入 text、可点元素 link、滚动 vert、拖拽 move/dgn1/dgn2、精确点击 cross、暂停 unavailiable、失败 help），不用手选。'
      + '运行中也可以 `overlay({cursorMode:"clean", cursorSize:96})` 切换；收工用 `overlay({show:false})` 收起。\n\n'
      + '**你在干什么，要让人看得见**：这是陪伴型工具，主人是坐在旁边看屏幕的。想说话就用 `overlay({text:"…"})`，'
      + 'AI 光标旁边会冒一个气泡（默认停 4 秒，`holdMs` 可调）。\n'
      + '**这句话完全自由**——下面只是几个例子，不是选项清单：\n'
      + '· 进展：「我先看看这个页面」「找到输入框了，在右上」「第二个结果更像」「正在等页面加载」\n'
      + '· 异常：「这里有个弹窗挡住我了」「这页要登录，得你处理」「等 5 秒还没出来，我重试」\n'
      + '· 请求：「这里只能你真点，我点不动」「要不要我继续往下翻？」「这个按钮删文件，我没点」\n'
      + '· 收尾：「弄好了，回到 DSH」「三点结果都在这儿，你看哪个」\n'
      + '**一两句人话，别写成日志**——动作日志已经记了细节，气泡是说给主人听的。'
      + '（工具自己有兜底：每次 physical 前会强制提示，沉默 10 秒会自己发心跳，所以你不说话它也不会像死了；但那只是兜底，不是替你说。）\n\n'
      + 'physical 动作前工具会自动把光标滑到主人真实光标旁边预告 1 秒（Ctrl+Alt+Q 可暂停），不需要你另外打招呼。\n\n'
      + '安全规则：\n'
      + '- 启用后 **严格禁止动用真实鼠标、严格禁止抢输入焦点**：所有动作只向目标 `hwnd` 发消息。\n'
      + '- 主人在用键鼠不会自动暂停；只有显式暂停才停手。\n'
      + '- 主人按 **Ctrl+Alt+Q** 随时暂停；下一次动作会返回 paused，必须停下。\n'
      + '- 不要用这个工具做破坏性操作（删文件、关窗口、支付），除非主人明确要求。\n\n'
      + '**一次做完一件事**：先 `observe` 看清控件，然后把整件事写成 `act` 的 steps（例如「点搜索框 → 输词 → 回车 → 等结果页」四步一起给），'
      + '工具按顺序执行、每步自校验，失败就停在那一步并把当时的界面带回来。**不要走一步停下来问一次**——那是最慢的做法。\n\n'
      + 'actions: status / windows / observe / act / environment / capture / click / type / key / scroll / drag / move / waitFor / pause / resume / overlay / activate / done / setScope / browser。'
      + '**网页场景优先用 browser**（读 DOM、按选择器点），不要截图量坐标。',
    parameters: {
      action: {
        type: 'string',
        required: true,
        description:
          'status | windows | observe | act | environment | capture | click | type | key | scroll | drag | move | waitFor | pause | resume | overlay | activate | done | setScope | browser',
      },
      hwnds: {
        type: 'array',
        items: { type: 'number' },
        description: 'setScope：窗口白名单。传了就只允许操作这些窗口（click/type/key/scroll/act/activate 越界直接拒绝，reason=out-of-scope）；不传，或传 clear:true，解除限制',
      },
      clear: { type: 'boolean', description: 'setScope：true = 解除窗口限制，恢复成任何窗口都能操作' },
      op: {
        type: 'string',
        description: 'browser：tabs（列标签，默认）| eval（执行 expr）| click（点 selector）| text（读 selector 的文字）| fill（给 selector 填 value）| count（selector 数量）。网页场景优先走这条，不要截图量坐标',
      },
      selector: { type: 'string', description: 'browser：CSS 选择器，用于 click/text/fill/count' },
      expr: { type: 'string', description: 'browser + op:"eval"：要执行的 JS 表达式，返回值会原样带回来' },
      value: { type: 'string', description: 'browser + op:"fill"：要填进输入框的文字' },
      url: { type: 'string', description: 'browser：目标标签页的 URL 片段（不传则用第一个标签页）' },
      environmentOp: {
        type: 'string',
        description: 'environment：show（默认，读环境画像）| save（把当前探测结果落盘到 ~/.dsh/independent-input/environment.json）',
      },
      locator: {
        type: 'object',
        additionalProperties: true,
        description:
          '按 UIA 找元素。**首选 `{ref:"e17"}`**——编号直接抄自 observe 的列表，工具自己知道它指向哪个元素，界面变了也认得出；元素没了会明确报 stale，重新 observe 就有新编号。拿不到编号时才用 `{hwnd, name, className, automationId, controlType}`：name 必须精确、别猜（猜错代价是等 8 秒超时），而且网页输入框的 name 常常就是它当前的内容、会随输入变化，这种要用 className',
      },
      waitMode: {
        type: 'string',
        description:
          'waitFor：appear（默认，等元素出现）| disappear（等它消失）| titleChange（等窗口标题变化）| textAppear（等窗口文本包含 text）。**titleChange 等的是「从此刻起发生变化」**——如果你要等的那个变化已经发生了，它会一直等到超时；这种情况改用 locator 等元素出现，或把那步写成 act 里的 expect',
      },
      timeoutMs: { type: 'number', description: 'waitFor 超时（毫秒，默认 8000，上限 60000）' },
      pollMs: { type: 'number', description: 'waitFor 轮询间隔（毫秒，默认 400）' },
      x: { type: 'number', description: '屏幕绝对 x——**通常不用你填**：能用 locator 就用 locator，坐标由工具现场算。只有既没有可访问名字、又必须按位置操作时（自绘界面）才填。给 type 用时必须落在输入框内部' },
      y: { type: 'number', description: '屏幕绝对 y（同 x 的规则）' },
      toX: { type: 'number', description: 'drag 终点 x' },
      toY: { type: 'number', description: 'drag 终点 y' },
      button: { type: 'string', description: 'left（默认）或 right' },
      count: { type: 'integer', description: '点击次数，默认 1；2 = 双击' },
            text: { type: 'string', description: 'type 要输入的文字。**中文等非 ASCII 字符必须配 locator 用**——传了 locator，工具就能拿到那个元素、走 UIA ValuePattern（支持 Unicode，几个字几毫秒写完，还能读回校验）；只给 x/y 坐标时工具只能走窗口消息，而窗口消息不支持非 ASCII，会直接报 charset-needs-uia 拒绝写入。所以「输中文」这件事的正确写法是 locator + text，不是坐标 + text' },
      replace: { type: 'boolean', description: 'type：true 覆盖原内容，false（默认）追加' },
      keys: { type: 'string', description: 'key：组合键，如 "ctrl+c"、"alt+tab"、"enter"' },
      mode: {
        type: 'string',
        description: 'auto（默认）| uia | message | physical。physical 会真的使用系统鼠标/键盘（主人允许，但会抢焦点）；move/click/scroll/drag 支持，主人一碰键鼠就立刻中止（reason=user-takeover）',
      },
      restoreCursor: {
        type: 'boolean',
        description: 'physical 光标收尾：move 默认 true（走完放回原处）；click 默认 false（点完停在原地，观感更自然）。true = 放回动作开始的位置',
      },
      takeoverGraceMs: {
        type: 'number',
        description: 'physical 动作每帧检查"主人是否刚动过键鼠"的容差（毫秒，默认 120）；主人真实输入落在这个窗口内就中止动作',
      },
      delta: { type: 'number', description: 'scroll 滚轮量：正数向上、负数向下，默认 -120' },
      durationMs: { type: 'number', description: 'move/click/scroll/drag 的补间动画时长（毫秒，0=瞬移，默认 300，上限 4000）；一次调用走完，不要用多次 move 拼路径' },
      label: { type: 'string', description: '可选意图标签，会记进动作时间线（如「B站搜索按钮」），方便事后对账' },
      hwnd: { type: 'number', description: '目标窗口句柄（先用 windows 拿）。click/scroll/drag 必填；type/key 必填，但 mode:"physical" 时可省略。**act 时写在这里就够了：顶层 hwnd 会自动传给每一步，不用在 steps 里重复写**' },
      observeMax: { type: 'integer', description: 'observe：最多列多少个可操作控件（默认 60，上限 200）' },
      observeFilter: { type: 'string', description: 'observe：只列名称匹配这个正则的控件（如 "搜索|输入"），控件多时用来收窄。**注意：Chromium 网页里的输入框，它的 Name 常常就是它当前的内容**（空的时候才是 placeholder）——所以按「搜索」这类词过滤通常找不到搜索框，去掉 filter 看全量、再按 Edit 找更可靠' },
      steps: {
        type: 'array',
        description: 'act 的步骤数组（按顺序执行，最多 40 步）。**先把整件事想清楚再一次性给出**——不要走一步问一次。每步形如 {do:"click", locator:{name:"搜索"}}、{do:"type", locator:{name:"搜索"}, text:"大肥鱼", replace:true}、{do:"key", keys:"enter"}。可选 expect 让工具自己校验结果：{focus:"搜索"} 焦点是否到它、{titleChange:true} 标题是否变了、{value:"大肥鱼"} 读回的值对不对、{exists:{…}} / {gone:{…}} 元素出现或消失。**每步返回里会带「→ 观察到的变化」（窗口标题变了什么、焦点去了哪），那就是结果证据，不需要再自己调 windows / observe / capture 复核**；只有标了「没观察到变化」的步骤才值得怀疑',
        items: {
          type: 'object',
          additionalProperties: false,
          properties: {
            do: { type: 'string', required: true, enum: ['click', 'type', 'key', 'waitFor', 'scroll', 'drag'], description: '这一步做什么' },
            hwnd: { type: 'number', description: '这一步的目标窗口；省略则用顶层的 hwnd（tools 会兜底）' },
            locator: { type: 'object', additionalProperties: true, description: '同顶层 locator。**首选 `{ref:"e17"}`**（编号抄自 observe 的列表，工具自己找得到）；其次 {name,className,automationId,controlType,hwnd}' },
            x: { type: 'number', description: '坐标 x（没有 locator 时的备选；不要提前记坐标，界面会变）' },
            y: { type: 'number', description: '坐标 y' },
            toX: { type: 'number', description: 'drag：终点 x' },
            toY: { type: 'number', description: 'drag：终点 y' },
            text: { type: 'string', description: 'type：要输入的文字。**中文等非 ASCII 必须配 locator**——`{ref:"e17"}`（首选）或 `{className:"nav-search-input"}` 都行，这条路径走 UIA ValuePattern，支持 Unicode；只给 x/y 会走窗口消息，非 ASCII 直接拒绝' },
            keys: { type: 'string', description: 'key：组合键，如 "ctrl+t"、"enter"' },
            mode: { type: 'string', enum: ['auto', 'uia', 'message', 'physical'] },
            replace: { type: 'boolean', description: 'type：true 覆盖原内容' },
            waitMode: { type: 'string', enum: ['appear', 'disappear', 'titleChange', 'textAppear'], description: 'waitFor：等什么（同顶层 waitMode）。titleChange 只等「从现在起变化」——变化已经发生就会超时，改用 locator 或 expect' },
            timeoutMs: { type: 'number' },
            label: { type: 'string', description: '这一步的意图标签（如「B站搜索按钮」），进动作时间线，方便事后对账' },
            restoreCursor: { type: 'boolean', description: 'physical：动作后把真实光标放回原处（move 默认 true，click 默认 false）' },
            durationMs: { type: 'number', description: 'physical 的补间动画时长（毫秒，默认 300/400，0=瞬移）' },
            expect: {
              type: 'object',
              additionalProperties: true,
              description: '这一步成功的判据（可选，但强烈建议给）：{focus:"控件名或类型"} / {titleChange:true} / {value:"应读回的文字"} / {exists:{locator}} / {gone:{locator}}',
              properties: {
                focus: { type: 'string', description: '执行完焦点是否落在这个控件上（按名字或控件类型模糊匹配）' },
                titleChange: { type: 'boolean', description: '执行完窗口标题是否变了（导航、提交表单的标志）' },
                value: { type: 'string', description: '执行后从这步的 locator 读回的值是否等于它' },
                exists: { type: 'object', additionalProperties: true, description: '执行后这个元素应该出现' },
                gone: { type: 'object', additionalProperties: true, description: '执行后这个元素应该消失' },
              },
            },
          },
        },
      },
      stopOnError: { type: 'boolean', description: 'act：某步失败后是否停止（默认 true）。false 会继续跑，但失败步会标出来' },
      path: { type: 'string', description: 'capture 保存 PNG 的绝对路径；省略则自动放 ~/.dsh/independent-input/shots/' },
      rect: { type: 'string', description: 'capture 区域："x,y,w,h" 或 "full"；省略则截当前前台窗口' },
      includeOverlay: {
        type: 'boolean',
        description: 'capture 时是否把 AI 光标和气泡一起拍进去（默认 false：截图前会先把光标藏起来，免得挡住内容）。**要验证「屏幕上到底有没有那个箭头/气泡」时必须置 true**，否则拍不到它。',
      },
      show: { type: 'boolean', description: 'overlay：false 隐藏 AI 光标，true/省略 显示' },
      busyIdleMs: {
        type: 'number',
        description: 'overlay：多少毫秒没动静算「收工」（默认 45000，最短 500）。收工时 AI 光标会自己说一句「空下来了」，证明进程还活着。',
      },
      text: {
        type: 'string',
        description: 'overlay：让 AI 光标旁边冒一句人话。**这句话完全自由——想说什么就说什么，不是只能从几个固定句子里选**：'
          + '你正在干什么、发现了什么异常、要他看一眼什么、你在等什么、卡在哪一步。'
          + '默认停留 4000ms，`holdMs` 可调（最长 60000ms，长话给长一点）。'
          + '建议一两句，别写成日志（动作日志里已经有细节了）。',
      },
      holdMs: { type: 'number', description: 'overlay / done：这句话停留多久（毫秒，默认 4000 / 3000）' },
      focus: {
        type: 'string',
        description: 'done：收尾后把哪个窗口切到前台。`true`=按标题找 DSH（"DeepSeek Harness"）；'
          + '也可以传 hwnd 数字、或标题片段。**不传 = 不切前台**（默认，不打断主人正在看的东西）。',
      },
      title: {
        type: 'string',
        description: 'activate：按标题片段找窗口（不区分大小写）。和 hwnd 二选一，给 hwnd 时优先用 hwnd。',
      },
      cursorMode: {
        type: 'string',
        description: 'overlay：companion（陪伴，一直显示，默认）| clean（整洁，动作后自动收起）',
      },
      cursorSize: {
        type: 'number',
        description: 'overlay：AI 光标大小（像素，24–192，默认 64）',
      },
    },
    output: {
      schema: {
        type: 'object',
        additionalProperties: false,
        properties: {
            text: { type: 'string' },
          images: { type: 'array', items: { type: 'object', additionalProperties: true } },
          meta: { type: 'object', additionalProperties: true },
        },
      },
      render(_args, value) {
        const blocks = []
        for (const image of value.images || []) blocks.push({ type: 'image', attachment: image })
        blocks.push({ type: 'text', text: value.text })
        return blocks
      },
    },
    // act 一次可能要跑十几步（含逐字输入），整体给足 10 分钟
    timeoutMs: 600000,
    isConcurrencySafe() {
      return false
    },
  }
}

function normalizeSettings(input, fallback = {}) {
  const merged = { ...(fallback || {}), ...(input || {}) }
  const mode = merged.cursorMode === 'clean' ? 'clean' : 'companion'
  const hold = Number(merged.cursorHoldMs)
  const size = Number(merged.cursorSize)
  const typing = Number(merged.typingIntervalMs)
  return {
    enabled: typeof merged.enabled === 'boolean' ? merged.enabled : true,
    cursorMode: mode,
    cursorHoldMs: Number.isFinite(hold) ? Math.max(300, Math.min(10000, Math.round(hold))) : 2600,
    cursorSize: Number.isFinite(size) ? Math.max(24, Math.min(192, Math.round(size))) : 64,
    slowMode: typeof merged.slowMode === 'boolean' ? merged.slowMode : true,
    typingIntervalMs: Number.isFinite(typing) ? Math.max(100, Math.min(3000, Math.round(typing))) : 500,
    browserEnhance: typeof merged.browserEnhance === 'boolean' ? merged.browserEnhance : true,
  }
}

async function loadSavedSettings(log = () => {}) {
  try {
    const raw = await readFile(SETTINGS_FILE, 'utf8')
    const parsed = JSON.parse(raw)
    return parsed && typeof parsed === 'object' ? parsed : {}
  } catch {
    return {}
  }
}

async function persistSettings(settings) {
  await mkdir(dirname(SETTINGS_FILE), { recursive: true })
  await writeFile(SETTINGS_FILE, `${JSON.stringify(settings, null, 2)}\n`, 'utf8')
}

function json(res, status, value) {
  const body = JSON.stringify(value)
  res.statusCode = status
  res.setHeader('content-type', 'application/json; charset=utf-8')
  res.setHeader('cache-control', 'no-store')
  res.setHeader('content-length', Buffer.byteLength(body))
  res.end(body)
}

function readBody(req) {
  return new Promise((resolve, reject) => {
    const chunks = []
    let size = 0
    req.on('data', (chunk) => {
      size += chunk.length
      if (size > 64 * 1024) {
        reject(new Error('请求体太大'))
        req.destroy()
        return
      }
      chunks.push(chunk)
    })
    req.on('end', () => {
      const raw = Buffer.concat(chunks).toString('utf8').trim()
      if (!raw) return resolve({})
      try { resolve(JSON.parse(raw)) } catch { reject(new Error('请求不是合法 JSON')) }
    })
    req.on('error', reject)
  })
}

export async function apply(ctx, rawConfig = {}) {
  const defineTool = await loadDefineTool()
  const log = (message) => { try { ctx?.logger?.info?.(`[independent-input] ${message}`) } catch { /* ignore */ } }
  const saved = await loadSavedSettings(log)
  let current = normalizeSettings(saved, normalizeSettings(rawConfig))
  const engine = new InputEngine({ log, ...current })
  const toolConfig = toolSpec()

  const tool = {
    ...toolConfig,
    async execute(args = {}) {
      const action = String(args.action || 'status').toLowerCase()
      try {
        if (!current.enabled) {
          return toLosslessJson({
            text: '独立输入已关闭：请到 设置 → 独立输入 打开「启用独立输入」总开关。',
            meta: { ok: false, enabled: false },
          })
        }
        if (action === 'status') {
          const s = await engine.request('status', {}, 10000)
          return toLosslessJson({ text: statusText(s), meta: s })
        }
        if (action === 'windows') {
          const r = await engine.request('windows', {}, 15000)
          return toLosslessJson({ text: windowsText(r), meta: r })
        }
        if (action === 'observe') {
          const r = await engine.request('observe', {
            hwnd: args.hwnd, max: args.observeMax, filter: args.observeFilter,
          }, 25000)
          return toLosslessJson({ text: observeText(r), meta: r })
        }
        if (action === 'act') {
          const steps = Array.isArray(args.steps) ? args.steps : []
          if (!steps.length) throw new Error('act 需要 steps 数组，每步一个 {do, …}')
          const r = await engine.request('act', {
            steps, stopOnError: args.stopOnError, hwnd: args.hwnd,
          }, 600000)
          return toLosslessJson({ text: actText(r), meta: r })
        }
        if (action === 'environment') {
          const op = args.environmentOp === 'save' ? 'save' : 'show'
          const r = await engine.request('environment', { op, hwnd: args.hwnd }, 20000)
          return toLosslessJson({ text: environmentText(r), meta: r })
        }
        if (action === 'pause') {
          const s = await engine.request('pause', {}, 10000)
          return toLosslessJson({ text: `已暂停。\n${statusText(s)}`, meta: s })
        }
        if (action === 'resume') {
          const s = await engine.request('resume', {}, 10000)
          return toLosslessJson({ text: `已恢复。\n${statusText(s)}`, meta: s })
        }
        if (action === 'move') {
          const r = await engine.request('move', {
            x: args.x, y: args.y, durationMs: args.durationMs, label: args.label,
            mode: args.mode, restoreCursor: args.restoreCursor, takeoverGraceMs: args.takeoverGraceMs,
          }, 30000)
          const meta = { ...r, cursorMode: engine.cursorMode, cursorSize: engine.cursorSize, cursorState: engine.cursorState }
          return toLosslessJson({ text: resultText('move', meta), meta })
        }
        if (action === 'overlay') {
          let modeResult = null
          let sizeResult = null
          if (args.cursorMode) {
            if (args.cursorMode !== 'clean' && args.cursorMode !== 'companion') {
              throw new Error('cursorMode 只能是 clean 或 companion')
            }
            modeResult = await engine.setCursorMode(args.cursorMode)
          }
          if (args.cursorSize !== undefined) {
            sizeResult = await engine.setCursorSize(args.cursorSize)
          }
          const mode = modeResult?.cursorMode || engine.cursorMode
          const size = sizeResult?.cursorSize || engine.cursorSize
          if (args.show === false) {
            const r = await engine.request('overlay', { show: false }, 10000)
            return toLosslessJson({ text: resultText('overlay', { ...r, cursorMode: mode, cursorSize: size, cursorState: engine.cursorState }), meta: { ...r, ...modeResult, ...sizeResult } })
          }
          if (Number.isFinite(args.x) && Number.isFinite(args.y)) {
            const r = await engine.request('overlay', { show: true, x: args.x, y: args.y, text: args.text, holdMs: args.holdMs, busyIdleMs: args.busyIdleMs }, 10000)
            return toLosslessJson({ text: resultText('overlay', { ...r, cursorMode: mode, cursorSize: size, cursorState: engine.cursorState }), meta: { ...r, ...modeResult, ...sizeResult } })
          }
          if (modeResult || sizeResult) {
            const modeZh = mode === 'clean'
              ? `整洁模式：动作后约 ${modeResult?.cursorHoldMs || engine.cursorHoldMs}ms 自动收起`
              : '陪伴模式：一直显示到收工'
            return toLosslessJson({
              text: `AI 光标已切换：${modeZh} · ${size}px。`,
              meta: { ...(modeResult || {}), ...(sizeResult || {}), cursorMode: mode, cursorSize: size, cursorState: engine.cursorState, ok: true },
            })
          }
          const r = await engine.request('overlay', { show: true, text: args.text, holdMs: args.holdMs, busyIdleMs: args.busyIdleMs }, 10000)
          return toLosslessJson({ text: resultText('overlay', { ...r, cursorMode: mode, cursorSize: size, cursorState: engine.cursorState }), meta: { ...r, cursorMode: mode, cursorSize: size, cursorState: engine.cursorState } })
        }
        if (action === 'activate') {
          const r = await engine.request('activate', { hwnd: args.hwnd, title: args.title }, 15000)
          return toLosslessJson({ text: resultText('activate', r), meta: r })
        }
        if (action === 'done') {
          const r = await engine.request('done', {
            text: args.text, holdMs: args.holdMs, focus: args.focus,
          }, 15000)
          return toLosslessJson({ text: resultText('done', r), meta: r })
        }
        if (action === 'setScope') {
          const r = await engine.request('setScope', { hwnds: args.hwnds, clear: !!args.clear }, 10000)
          return toLosslessJson({ text: resultText('setScope', r), meta: r })
        }
        if (action === 'browser') {
          const r = await engine.request('browser', {
            op: args.op, selector: args.selector, expr: args.expr, value: args.value, url: args.url,
          }, 20000)
          return toLosslessJson({ text: resultText('browser', r), meta: r })
        }
        if (action === 'click') {
          const r = await engine.request('click', {
            x: args.x, y: args.y, button: args.button, count: args.count, mode: args.mode, hwnd: args.hwnd,
            locator: args.locator,
            durationMs: args.durationMs, label: args.label, takeoverGraceMs: args.takeoverGraceMs,
            restoreCursor: args.restoreCursor,
          }, 30000)
          return toLosslessJson({ text: resultText('click', r), meta: r })
        }
        if (action === 'waitfor') {
          const waitTimeout = Number.isFinite(args.timeoutMs) ? args.timeoutMs : 8000
          const r = await engine.request('waitFor', {
            locator: args.locator, mode: args.waitMode, hwnd: args.hwnd,
            timeoutMs: args.timeoutMs, pollMs: args.pollMs, text: args.text, label: args.label,
          }, Math.min(65000, waitTimeout + 6000))
          return toLosslessJson({ text: resultText('waitFor', r), meta: r })
        }
        if (action === 'type') {
          const r = await engine.request('type', {
            x: args.x, y: args.y, text: args.text, replace: args.replace,
            mode: args.mode, hwnd: args.hwnd, takeoverGraceMs: args.takeoverGraceMs,
            holdAfterTypingMs: args.holdAfterTypingMs, locator: args.locator,
          }, 60000)
          return toLosslessJson({ text: resultText('type', r), meta: r })
        }
        if (action === 'key') {
          const r = await engine.request('key', {
            keys: args.keys, mode: args.mode, hwnd: args.hwnd, takeoverGraceMs: args.takeoverGraceMs, label: args.label,
          }, 30000)
          return toLosslessJson({ text: resultText('key', r), meta: r })
        }
        if (action === 'scroll') {
          const r = await engine.request('scroll', {
            x: args.x, y: args.y, delta: args.delta, mode: args.mode, hwnd: args.hwnd,
            label: args.label, takeoverGraceMs: args.takeoverGraceMs,
          }, 30000)
          return toLosslessJson({ text: resultText('scroll', r), meta: r })
        }
        if (action === 'drag') {
          const r = await engine.request('drag', {
            x: args.x, y: args.y, toX: args.toX, toY: args.toY,
            durationMs: args.durationMs, mode: args.mode, hwnd: args.hwnd,
            label: args.label, takeoverGraceMs: args.takeoverGraceMs,
          }, 90000)
          return toLosslessJson({ text: resultText('drag', r), meta: r })
        }
        if (action === 'capture') {
          return await capture(ctx, engine, args)
        }
        return {
          text: '未知 action。可用：status / windows / capture / click / type / key / scroll / drag / move / waitFor / pause / resume / overlay。',
          meta: { ok: false, action },
        }
      } catch (error) {
        return toLosslessJson({
          text: `独立输入没完成：${error?.message || error}`,
          meta: { ok: false, action },
        })
      }
    },
  }

  const dispose = ctx.tools.register(defineTool(tool))

  const applySettings = async (next) => {
    if (!next.enabled) {
      engine.stop()
      return
    }
    engine.slowMode = next.slowMode !== false
    engine.typingIntervalMs = next.typingIntervalMs
    engine.browserEnhance = next.browserEnhance !== false
    await engine.setCursorSize(next.cursorSize)
    await engine.setCursorMode(next.cursorMode, next.cursorHoldMs)
  }

  const API_PREFIX = '/dsh-independent-input-mod/api'
  const ASSET_PREFIX = '/dsh-independent-input-mod/assets'

  const apiHandler = async (req, res, next) => {
    const url = new URL(req.url, 'http://127.0.0.1')
    if (!url.pathname.startsWith(API_PREFIX)) {
      if (typeof next === 'function') return next()
      return json(res, 404, { ok: false, error: 'not found' })
    }
    const route = url.pathname.slice(API_PREFIX.length) || '/'
    if (req.method === 'OPTIONS') {
      res.statusCode = 204
      return res.end()
    }
    try {
      if (req.method === 'GET' && route === '/settings') {
        return json(res, 200, { ok: true, settings: current })
      }
      if (req.method === 'GET' && route === '/environment') {
        const r = await engine
          .request('environment', { op: 'show' }, 20000)
          .catch((error) => ({ ok: false, error: String(error?.message || error) }))
        return json(res, 200, { ok: true, result: r })
      }
      if (req.method === 'GET' && route === '/phrases') {
        return json(res, 200, { ok: true, phrases: readPhrases() })
      }
      if (req.method === 'POST' && route === '/phrases') {
        const body = await readBody(req)
        const next = normalizePhrases(body, readPhrases())
        writePhrases(next)
        // 推给正在跑的 sidecar（它也会按 mtime 自己重读，这里只是让它更快点）
        await engine
          .request('phrases', { phrases: next }, 10000)
          .catch(() => undefined)
        return json(res, 200, { ok: true, phrases: next })
      }
      if (req.method === 'POST' && route === '/environment/save') {
        const body = await readBody(req)
        const r = await engine
          .request('environment', { op: 'save', hwnd: body?.hwnd }, 20000)
          .catch((error) => ({ ok: false, error: String(error?.message || error) }))
        return json(res, 200, { ok: true, result: r })
      }
      if (req.method === 'POST' && route === '/settings') {
        const body = await readBody(req)
        const nextSettings = normalizeSettings(body, current)
        await applySettings(nextSettings)
        await persistSettings(nextSettings)
        current = nextSettings
        return json(res, 200, { ok: true, settings: current })
      }
      if (req.method === 'POST' && route === '/hide') {
        if (!current.enabled) return json(res, 200, { ok: true, enabled: false })
        await engine.request('overlay', { show: false }, 15000)
        return json(res, 200, { ok: true })
      }
      if (req.method === 'POST' && route === '/show') {
        if (!current.enabled) return json(res, 409, { ok: false, error: '独立输入已关闭，先在设置里启用总开关。' })
        await engine.request('overlay', { show: true }, 30000)
        return json(res, 200, { ok: true })
      }
      return json(res, 404, { ok: false, error: 'not found' })
    } catch (error) {
      log(`http ${req.method} ${route}: ${error?.message || error}`)
      return json(res, 500, { ok: false, error: String(error?.message || error) })
    }
  }

  const assetHandler = async (req, res, next) => {
    const url = new URL(req.url, 'http://127.0.0.1')
    if (!url.pathname.startsWith(ASSET_PREFIX)) {
      if (typeof next === 'function') return next()
      return json(res, 404, { ok: false, error: 'not found' })
    }
    if (req.method === 'OPTIONS') {
      res.statusCode = 204
      return res.end()
    }
    try {
      const name = url.pathname.slice(ASSET_PREFIX.length).replace(/^\//, '').replace(/\.png$/i, '').toLowerCase()
      if (!STYLE_IDS.includes(name)) return json(res, 404, { ok: false, error: 'unknown style' })
      const buffer = await readFile(join(PREVIEW_DIR, `${name}.png`))
      res.statusCode = 200
      res.setHeader('content-type', 'image/png')
      res.setHeader('cache-control', 'public, max-age=3600')
      res.setHeader('content-length', buffer.length)
      return res.end(buffer)
    } catch (error) {
      log(`asset ${url.pathname}: ${error?.message || error}`)
      return json(res, 404, { ok: false, error: 'not found' })
    }
  }

  try {
    if (ctx?.webServer && typeof ctx.effect === 'function') {
      ctx.effect(() => ctx.webServer.register({ kind: 'prefix', path: API_PREFIX, handler: apiHandler }), 'independent-input: api')
      ctx.effect(() => ctx.webServer.register({ kind: 'prefix', path: ASSET_PREFIX, handler: assetHandler }), 'independent-input: assets')
    } else {
      log('webServer 不可用：设置页 API 没挂上')
    }
  } catch (error) {
    log(`设置页 API 挂载失败：${error?.message || error}`)
  }

  return () => {
    try { dispose?.() } catch { /* ignore */ }
    engine.stop()
  }
}

async function capture(ctx, engine, args) {
  const path = args.path || join(homedir(), '.dsh', 'independent-input', 'shots', `shot-${Date.now()}.png`)
  await mkdir(dirname(path), { recursive: true })

  const req = { path, includeOverlay: args.includeOverlay === true }
  if (args.hwnd) {
    // D008：按窗口截。sidecar 用 PrintWindow 渲染，窗口在后台也能拿到它自己的画面
    req.hwnd = args.hwnd
  } else {
    let rect = typeof args.rect === 'string' ? args.rect.trim() : ''
    if (rect.toLowerCase() === 'full' || rect === '0,0,0,0') rect = '0,0,0,0'
    if (!rect) {
      const status = await engine.request('status', {}, 10000)
      const hwnd = status?.foreground?.hwnd
      if (hwnd) {
        const info = await engine.request('winInfo', { hwnd }, 10000)
        const r = info?.rect
        if (r && r.w > 0 && r.h > 0) rect = `${r.x},${r.y},${r.w},${r.h}`
      }
      if (!rect) rect = '0,0,0,0'
    }
    req.rect = rect
  }

  const saved = await engine.request('capture', req, 30000)

  let images = []
  try {
    const data = await readFile(path)
    const svc = ctx?.attachments
    if (svc?.saveImage) {
      const ref = await svc.saveImage.call(svc, {
        data,
        mediaType: 'image/png',
        name: `independent-input-${Date.now()}.png`,
      })
      images = [ref]
    }
  } catch (error) {
    ctx?.logger?.warn?.(`[independent-input] 截图读不回来：${error?.message || error}`)
  }

  const meta = {
    ok: true,
    path: saved.path,
    source: saved.source,
    imageSize: saved.imageSize,
    screenSize: saved.screenSize,
    capturedRect: saved.capturedRect,
    attached: images.length > 0,
  }
  return toLosslessJson({
    text: resultText('capture', meta),
    images,
    meta,
  })
}
