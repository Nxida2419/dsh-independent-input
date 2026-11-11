// 设置 → 独立输入：AI 光标样式 / 大小 / 陪伴或整洁。
// 纯手写客户端 chunk，格式与官方客户端插件一致；不需要构建。
window.__ModuleLoader__.load({
  id: 'dsh-independent-input-mod',
  factory(require) {
    const React = require('react')
    const { useEffect, useState } = React
    const h = React.createElement

    const API = '/dsh-independent-input-mod/api'
    const ASSET = '/dsh-independent-input-mod/assets'

    const C = {
      text: 'var(--dsw-alias-label-primary, #e8e8ee)',
      sub: 'var(--dsw-alias-label-secondary, #b8b8c4)',
      faint: 'var(--dsw-alias-label-tertiary, #8d8d9c)',
      border: 'var(--dsw-alias-border-primary, rgba(255,255,255,.12))',
      bg: 'var(--dsw-alias-bg-secondary, #191920)',
      input: 'var(--dsw-alias-bg-primary, #101016)',
      accent: 'var(--dsw-alias-brand-primary, #6aa9ff)',
      danger: 'var(--dsw-alias-state-error-primary, #ff6b6b)',
      ok: 'var(--dsw-alias-state-success-primary, #59d18b)',
    }

    const S = {
      page: { maxWidth: '780px', color: C.text },
      lead: { fontSize: '12px', color: C.sub, lineHeight: 1.8, marginBottom: '14px' },
      card: { border: `1px solid ${C.border}`, borderRadius: '12px', padding: '14px', background: C.bg, marginBottom: '12px' },
      title: { fontSize: '13px', fontWeight: 700, color: C.text, marginBottom: '4px' },
      hint: { fontSize: '11px', color: C.faint, lineHeight: 1.7, marginBottom: '10px' },
      row: { display: 'flex', gap: '8px', alignItems: 'center', flexWrap: 'wrap' },
      modeBtn: (on) => ({
        border: `1px solid ${on ? C.accent : C.border}`,
        background: on ? C.accent : 'transparent',
        color: on ? '#08111f' : C.text,
        borderRadius: '8px',
        padding: '7px 12px',
        fontSize: '12px',
        cursor: 'pointer',
        fontWeight: on ? 700 : 400,
      }),
      grid: { display: 'grid', gridTemplateColumns: 'repeat(5, minmax(0, 1fr))', gap: '8px' },
      stateGrid: { display: 'grid', gridTemplateColumns: 'repeat(2, minmax(0, 1fr))', gap: '4px 16px' },
      stateItem: { display: 'flex', alignItems: 'center', gap: '8px', padding: '3px 0', minWidth: 0 },
      stateThumb: {
        width: '30px',
        height: '30px',
        imageRendering: 'pixelated',
        background: '#20242c',
        borderRadius: '6px',
        display: 'block',
        flex: '0 0 30px',
      },
      stateName: { fontSize: '12px', color: C.text, lineHeight: 1.35 },
      stateWhy: { fontSize: '10.5px', color: C.faint, lineHeight: 1.35, whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' },
      range: { width: '100%', accentColor: C.accent, cursor: 'pointer' },
      num: { width: '76px', background: C.input, color: C.text, border: `1px solid ${C.border}`, borderRadius: '7px', padding: '6px 8px', fontSize: '12px' },
      field: { width: '100%', boxSizing: 'border-box', background: C.input, color: C.text, border: `1px solid ${C.border}`, borderRadius: '7px', padding: '6px 8px', fontSize: '12px', fontFamily: 'inherit' },
      label: { fontSize: '11px', color: C.sub, margin: '8px 0 3px', display: 'block' },
      btn: { border: `1px solid ${C.border}`, background: 'transparent', color: C.text, borderRadius: '8px', padding: '7px 12px', fontSize: '12px', cursor: 'pointer' },
      primary: { border: `1px solid ${C.accent}`, background: C.accent, color: '#08111f', borderRadius: '8px', padding: '7px 14px', fontSize: '12px', cursor: 'pointer', fontWeight: 700 },
      note: { fontSize: '12px', color: C.ok, minHeight: '18px', lineHeight: 1.6 },
      error: { fontSize: '12px', color: C.danger, minHeight: '18px', lineHeight: 1.6 },
    }

    const STATE_ROWS = [
      ['pointer', '指针', '默认 / 移动 / 普通点击'],
      ['link', '链接', '点到可点的按钮或链接'],
      ['text', '文本', '输入文字 / 按键'],
      ['vert', '上下', '上下滚动 / 竖向拖拽'],
      ['horz', '左右', '左右滚动 / 横向拖拽'],
      ['move', '移动', '拖动'],
      ['dgn1', '斜向1', '斜向拖拽（正斜率）'],
      ['dgn2', '斜向2', '斜向拖拽（负斜率）'],
      ['cross', '十字', '精确物理点击'],
      ['unavailiable', '禁止', '暂停 / 主人接管'],
      ['help', '帮助', '没点中 / 需要处理'],
      ['work', '工作', '执行中（预留）'],
      ['busy', '忙碌', '等待中（预留）'],
      ['handwriting', '手写', '手写（预留）'],
      ['alternate', '备用', '兜底状态'],
    ]

    async function api(path, options = {}) {
      const init = {
        method: options.method || 'GET',
        headers: { 'content-type': 'application/json' },
        cache: 'no-store',
      }
      if (options.body !== undefined) init.body = JSON.stringify(options.body)
      let response
      try {
        response = await fetch(`${API}${path}`, init)
      } catch {
        throw new Error('连不上独立输入插件（sidecar 可能还没起来）')
      }
      const raw = await response.text().catch(() => '')
      let data = null
      try { data = raw ? JSON.parse(raw) : null } catch { throw new Error('后端返回的不是 JSON') }
      if (!data?.ok) throw new Error(data?.error || `请求失败 ${response.status}`)
      return data
    }

    function Page() {
      const [settings, setSettings] = useState(null)
      const [note, setNote] = useState('')
      const [error, setError] = useState('')
      const [busy, setBusy] = useState(false)
      const [previewOn, setPreviewOn] = useState(false)
      const [env, setEnv] = useState(null)
      const [envNote, setEnvNote] = useState('')
      const [phrases, setPhrases] = useState(null)
      const [phrasesNote, setPhrasesNote] = useState('')

      const applyResult = (data) => {
        if (data?.settings) setSettings(data.settings)
      }

      const load = async () => {
        const data = await api('/settings')
        applyResult(data)
      }


      useEffect(() => {
        load().catch((e) => setError(e.message))
        loadEnvironment()
        loadPhrases()
      }, [])

      const loadEnvironment = async () => {
        setEnvNote('')
        try {
          const data = await api('/environment')
          setEnv(data?.result?.ok === false ? null : (data?.result || null))
          if (data?.result?.ok === false) setEnvNote(String(data.result?.error || '读不到环境画像'))
        } catch (e) { setEnv(null); setEnvNote(e.message) }
      }

      const saveEnvironment = async () => {
        setEnvNote('')
        try {
          const data = await api('/environment/save', { method: 'POST', body: {} })
          if (data?.result?.ok === false) { setEnvNote(String(data.result?.error || '保存失败')); return }
          setEnv(data?.result || null)
          setEnvNote('已写入文件。以后每次启动都读它，你也可以手动编辑这个文件。')
        } catch (e) { setEnvNote(e.message) }
      }

      // ── 光标说的话（四句）──────────────────────────────────────────
      // 只开放这四句。它们是"语气"；其余提示都是给模型看的诊断，改了等于改协议。
      const PRESET_COMPANION = {
        takeover: '需要 physical：我要接管真实鼠标了（Ctrl+Alt+Q 可暂停）',
        working: '还在处理…（没卡住，可以继续等）',
        moving: '正在操作…',
        idle: '我这边空下来了，还有要做的就说',
      }
      const PRESET_PLAIN = {
        takeover: '接管真实鼠标（Ctrl+Alt+Q 暂停）',
        working: '处理中…',
        moving: '操作中',
        idle: '空着',
      }

      const loadPhrases = async () => {
        setPhrasesNote('')
        try {
          const data = await api('/phrases')
          setPhrases(data?.phrases || null)
        } catch (e) { setPhrases(null); setPhrasesNote(e.message) }
      }

      const savePhrases = async () => {
        if (!phrases) return
        setPhrasesNote('')
        try {
          const data = await api('/phrases', { method: 'POST', body: phrases })
          setPhrases(data?.phrases || phrases)
          setPhrasesNote('已保存。光标下一句话就用新文案，不需要重启。')
        } catch (e) { setPhrasesNote(e.message) }
      }

      const setPhrase = (key, value) => setPhrases((cur) => (cur ? { ...cur, [key]: value } : cur))
      const applyPreset = (preset) => setPhrases((cur) => (cur ? { ...cur, ...preset } : cur))

      const update = (patch) => setSettings((current) => current ? { ...current, ...patch } : current)

      const save = async () => {
        if (!settings) return
        setBusy(true); setError(''); setNote('')
        try {
          const data = await api('/settings', { method: 'POST', body: settings })
          applyResult(data)
          setNote('已保存并立即生效，不需要重启。')
        } catch (e) {
          setError(e.message)
        } finally {
          setBusy(false)
        }
      }

      const toggleEnabled = async () => {
        if (!settings) return
        const next = { ...settings, enabled: !settings.enabled }
        setSettings(next)
        setBusy(true); setError(''); setNote('')
        try {
          const data = await api('/settings', { method: 'POST', body: next })
          applyResult(data)
          setNote(next.enabled ? '已启用：之后所有点击只用 AI 光标，不碰真实鼠标。' : '已关闭：插件动作全部停用。')
        } catch (e) {
          setError(e.message)
        } finally {
          setBusy(false)
        }
      }

      const reset = async () => {
        const defaults = { cursorMode: 'companion', cursorHoldMs: 2600, cursorSize: 64 }
        setSettings((current) => current ? { ...current, ...defaults } : defaults)
        setBusy(true); setError(''); setNote('')
        try {
          const data = await api('/settings', { method: 'POST', body: defaults })
          applyResult(data)
          setNote('已恢复默认：陪伴 · 64px。')
        } catch (e) {
          setError(e.message)
        } finally {
          setBusy(false)
        }
      }

      const hideCursor = async () => {
        setError('')
        try {
          await api('/hide', { method: 'POST', body: {} })
          setPreviewOn(false)
          setNote('AI 光标已收起；再点“在屏幕上试一下”可以叫出来。')
        } catch (e) {
          setError(e.message)
        }
      }

      const showCursor = async () => {
        setError('')
        try {
          await api('/show', { method: 'POST', body: {} })
          setPreviewOn(true)
          setNote('已把 AI 光标放到屏幕上；真实鼠标没有移动。')
        } catch (e) {
          setError(e.message)
        }
      }

      if (!settings) {
        return h('div', { style: S.page },
          h('div', { style: S.lead }, error ? `加载失败：${error}` : '正在读取独立输入设置……'),
          h('button', {
            type: 'button',
            style: S.btn,
            onClick: () => { setError(''); load().catch((e) => setError(e.message)) },
          }, '重试'),
        )
      }

      const isClean = settings.cursorMode === 'clean'

      return h('div', { style: S.page },
        h('div', { style: S.title }, '独立输入 · AI 光标'),
        h('div', { style: S.lead },
          '这里调 AI 光标的显示方式和大小；外观会像正常鼠标一样，按当前操作自动切换。默认不移动你的真实光标、不抢键盘焦点，保存后立即生效。'),

        h('div', { style: S.card },
          h('div', { style: S.title }, '总开关'),
          h('div', { style: S.hint },
            settings.enabled
              ? '已启用：所有点击只用 AI 光标（UIA / 窗口消息），严格禁止动用真实鼠标。'
              : '已关闭：插件不执行任何动作，也不会显示 AI 光标。'),
          h('div', { style: S.row },
            h('button', {
              type: 'button',
              style: S.modeBtn(settings.enabled),
              disabled: busy,
              onClick: toggleEnabled,
            }, settings.enabled ? '已启用（点此关闭）' : '已关闭（点此启用）'),
          ),
        ),

        h('div', { style: S.card },
          h('div', { style: S.title }, '显示方式'),
          h('div', { style: S.hint }, '陪伴 = 一直显示到收工；整洁 = 每次动作后约 ' + (settings.cursorHoldMs || 2600) + 'ms 自动收起。'),
          h('div', { style: S.row },
            h('button', { type: 'button', style: S.modeBtn(!isClean), onClick: () => update({ cursorMode: 'companion' }) }, '陪伴（一直显示）'),
            h('button', { type: 'button', style: S.modeBtn(isClean), onClick: () => update({ cursorMode: 'clean' }) }, '整洁（动作后收起）'),
          ),
          isClean ? h('div', { style: { ...S.row, marginTop: '10px' } },
            h('span', { style: S.hint }, '收起前停留'),
            h('input', {
              type: 'number', min: 300, max: 10000, step: 100,
              style: S.num,
              value: settings.cursorHoldMs,
              onChange: (e) => update({ cursorHoldMs: Math.max(300, Math.min(10000, Number(e.target.value) || 2600)) }),
            }),
            h('span', { style: S.hint }, 'ms'),
          ) : null,
        ),

        h('div', { style: S.card },
          h('div', { style: S.title }, '缓慢模式（更有“人味”）'),
          h('div', { style: S.hint }, settings.slowMode !== false
            ? `已开启：AI 光标移动有补间动画，打字一个字一个字冒（每 ${settings.typingIntervalMs || 500}ms 一个字）。`
            : '已关闭：直接瞬移、整段写入，动作快但没有过程。'),
          h('div', { style: S.row },
            h('button', { type: 'button', style: S.modeBtn(settings.slowMode !== false), onClick: () => update({ slowMode: true }) }, '缓慢（默认）'),
            h('button', { type: 'button', style: S.modeBtn(settings.slowMode === false), onClick: () => update({ slowMode: false }) }, '极速（无动画）'),
          ),
          settings.slowMode !== false ? h('div', { style: { ...S.row, marginTop: '10px' } },
            h('span', { style: S.hint }, '每个字的间隔'),
            h('input', {
              type: 'number', min: 100, max: 3000, step: 100,
              style: S.num,
              value: settings.typingIntervalMs || 500,
              onChange: (e) => update({ typingIntervalMs: Math.max(100, Math.min(3000, Number(e.target.value) || 500)) }),
            }),
            h('span', { style: S.hint }, 'ms'),
          ) : null,
        ),

        h('div', { style: S.card },
          h('div', { style: S.title }, '浏览器增强（CDP）'),
          h('div', { style: S.hint }, settings.browserEnhance !== false
            ? '已开启：AI 能直接读网页结构（找元素、读文字、填表单），比截图量坐标可靠得多；网页操作会优先走这条。'
            : '已关闭：网页操作只能靠 UIA / 窗口消息 / 截图。网页元素复杂、要读文字内容或填表单时，建议打开。'),
          h('div', { style: S.hint }, '适用于 Chromium 系浏览器：Edge / Chrome / Brave / Vivaldi 等。Firefox 不支持这条通道。'),
          h('div', { style: S.row },
            h('button', { type: 'button', style: S.modeBtn(settings.browserEnhance !== false), onClick: () => update({ browserEnhance: true }) }, '开启（推荐）'),
            h('button', { type: 'button', style: S.modeBtn(settings.browserEnhance === false), onClick: () => update({ browserEnhance: false }) }, '关闭'),
          ),
          h('div', { style: S.hint },
            '开启前提（按你用的浏览器选地址）：① 地址栏打开 edge://inspect#remote-debugging（Chrome / Brave / Vivaldi 用 chrome://inspect#remote-debugging），勾选 Allow remote debugging；② 首次连接浏览器会弹「是否允许远程调试」，点「允许」；③ 浏览器重启后要再点一次。'),
        ),

        h('div', { style: S.card },
          h('div', { style: S.title }, '环境画像（这台机器长什么样）'),
          h('div', { style: S.hint },
            '工具会探测前台窗口的类型和布局特征，写进本机的一个 JSON 文件。'
            + '模型不需要“记住”它，每次由工具告知——换机器、换浏览器都自动更新。'
            + '文件也可以手动编辑：工具探不到的（域策略、多 profile 等）写进 profile.notes 即可。'),
          env && env.profile
            ? h('div', { style: { marginTop: '8px' } },
                h('div', { style: S.hint }, `来源：${env.source === 'file+probe' ? '文件 + 本次探测' : '这次探测'}${env.fileExists ? '（文件已存在）' : '（还没有文件）'}`),
                h('div', { style: { ...S.hint, marginTop: '4px' } },
                  `窗口类：${env.profile.windowClass || '?'} · 类型：${{ chromium: 'Chromium 系浏览器', explorer: '文件资源管理器', win32: '普通 Win32 窗口' }[env.profile.kind] || env.profile.kind || '未知'}`),
                h('div', { style: { ...S.hint, marginTop: '4px' } },
                  `垂直标签栏：${env.profile.verticalTabs ? '是（标签竖排在左侧）' : '否'}`),
                env.profile.note ? h('div', { style: { ...S.hint, marginTop: '4px' } }, String(env.profile.note)) : null,
                env.profile.notes ? h('div', { style: { ...S.hint, marginTop: '4px' } }, `人工补充：${String(env.profile.notes)}`) : null,
                h('div', { style: { ...S.hint, marginTop: '6px', fontFamily: 'ui-monospace, SFMono-Regular, Menlo, monospace', fontSize: '11px', wordBreak: 'break-all' } }, String(env.filePath || '')),
              )
            : h('div', { style: S.hint }, envNote || '正在读取环境画像……'),
          h('div', { style: S.row },
            h('button', { type: 'button', style: S.btn, onClick: () => { loadEnvironment() } }, '重新探测'),
            h('button', { type: 'button', style: S.primary, onClick: () => { saveEnvironment() } }, '保存到文件'),
          ),
          envNote && env && env.profile ? h('div', { style: S.hint }, envNote) : null,
        ),

        h('div', { style: S.card },
          h('div', { style: S.title }, '光标说的话（四句）'),
          h('div', { style: S.hint },
            '这是 AI 光标旁边气泡里的话。只开放这四句——它们是「语气」，不是协议；'
            + '其余提示（locator 失败原因之类）是给模型看的诊断信息，改了等于改协议，所以不开放。'
            + '改完光标下一句话就用新文案，不需要重启。'),
          phrases ? h('div', {},
            h('div', { style: S.label }, '接管真实鼠标前（可用 {keys} 表示这次要按的键）'),
            h('input', {
              style: S.field,
              value: phrases.takeover || '',
              spellCheck: false,
              onChange: (e) => setPhrase('takeover', e.target.value),
            }),
            h('div', { style: S.label }, '等待 / 干活中（心跳，忙且 10 秒没说话时自动冒一句）'),
            h('input', {
              style: S.field,
              value: phrases.working || '',
              spellCheck: false,
              onChange: (e) => setPhrase('working', e.target.value),
            }),
            h('div', { style: S.label }, '移动光标时（安静时每次移动最多补一句）'),
            h('input', {
              style: S.field,
              value: phrases.moving || '',
              spellCheck: false,
              onChange: (e) => setPhrase('moving', e.target.value),
            }),
            h('div', { style: S.label }, '收工后（干完活静下来时必说一句，不依赖模型自觉）'),
            h('input', {
              style: S.field,
              value: phrases.idle || '',
              spellCheck: false,
              onChange: (e) => setPhrase('idle', e.target.value),
            }),
          ) : h('div', { style: S.hint }, '正在读取……'),
          h('div', { style: { ...S.row, marginTop: '8px' } },
            h('button', { type: 'button', style: S.btn, onClick: () => applyPreset(PRESET_PLAIN) }, '简洁风格'),
            h('button', { type: 'button', style: S.btn, onClick: () => applyPreset(PRESET_COMPANION) }, '陪伴风格'),
            h('button', { type: 'button', style: S.primary, onClick: () => { savePhrases() } }, '保存'),
          ),
          phrasesNote ? h('div', { style: S.hint }, phrasesNote) : null,
        ),

        h('div', { style: S.card },
          h('div', { style: S.title }, '光标状态（自动切换）'),
          h('div', { style: S.hint }, '这些是同一只光标的 15 个状态，不是样式；不用手选，插件按操作自动切。'),
          h('div', { style: S.stateGrid },
            STATE_ROWS.map(([id, label, why]) => h('div', { key: id, style: S.stateItem },
              h('img', { src: `${ASSET}/${id}.png`, alt: id, style: S.stateThumb }),
              h('div', { style: { minWidth: 0 } },
                h('div', { style: S.stateName }, label),
                h('div', { style: S.stateWhy }, why),
              ),
            )),
          ),
        ),

        h('div', { style: S.card },
          h('div', { style: S.title }, '光标大小'),
          h('div', { style: S.hint }, `当前 ${settings.cursorSize}px；暂停时会自动变成红色“禁止”。`),
          h('div', { style: S.row },
            h('input', {
              type: 'range', min: 24, max: 192, step: 4,
              style: S.range,
              value: settings.cursorSize,
              onChange: (e) => update({ cursorSize: Number(e.target.value) || 64 }),
            }),
            h('input', {
              type: 'number', min: 24, max: 192, step: 4,
              style: S.num,
              value: settings.cursorSize,
              onChange: (e) => update({ cursorSize: Math.max(24, Math.min(192, Number(e.target.value) || 64)) }),
            }),
            h('span', { style: S.hint }, 'px'),
          ),
          h('div', { style: { ...S.row, marginTop: '8px' } },
            [48, 64, 96, 128].map((n) => h('button', {
              key: n, type: 'button', style: S.btn,
              onClick: () => update({ cursorSize: n }),
            }, `${n}px`)),
          ),
        ),

        h('div', { style: S.row },
          h('button', { type: 'button', style: S.primary, disabled: busy, onClick: save }, busy ? '保存中…' : '保存并生效'),
          h('button', { type: 'button', style: S.btn, disabled: busy, onClick: reset }, '恢复默认'),
          h('button', { type: 'button', style: S.btn, onClick: previewOn ? hideCursor : showCursor }, previewOn ? '收起光标' : '在屏幕上试一下'),
        ),
        h('div', { style: S.note }, note),
        h('div', { style: S.error }, error),
      )
    }

    // 注册写法（对照两个真实样板）：
    //   · exports.inject 保持 []，用 ctx.inject(['slots'], scope => …) 等 slots 服务就绪
    //     （@liustack/modsearch/dsh/client.js 的写法；直接 ctx.slots 会拿到 undefined）
    //   · 三个 slot 都试一遍，哪个宿主认就用哪个：
    //       settings.section      官方 settings-plugins 在用 → 设置页左栏一整个 section
    //       settings.plugin.item  modsearch 在用 → 设置页插件条目
    //       plugins.bundle.config modsearch 在用 → 插件页配置区
    //     宿主不认识某个 slot 时 slots.inject 不会回调，所以多注册几个没有副作用。
    var PACKAGE_NAME = 'dsh-independent-input-mod'

    function registerCards(ctx) {
      if (typeof ctx.inject !== 'function') {
        throw new Error('ctx.inject 不可用（宿主版本过旧）')
      }
      ctx.inject(['slots'], (scope) => {
        var slots = scope.slots
        // 1) 设置页左栏：最接近用户期待的「设置 → 独立输入」
        slots.inject('settings.section', function* () {
          yield slots.register(
            {
              name: 'settings.section',
              id: PACKAGE_NAME,
              order: 90,
              label: function () { return '独立输入' },
            },
            Page,
          )
        })
        // 2) 设置页插件条目 / 3) 插件页配置区
        slots.inject('settings.plugin.item', function* () {
          yield slots.register(
            { name: 'settings.plugin.item', id: PACKAGE_NAME, key: PACKAGE_NAME, order: 70 },
            Page,
          )
        })
        slots.inject('plugins.bundle.config', function* () {
          yield slots.register({ name: 'plugins.bundle.config', key: PACKAGE_NAME }, Page)
        })
      })
    }

    return {
      inject: [],
      apply(ctx) {
        // 设置页只是锦上添花：注册失败也绝不能让 web boot 起不来。
        // （宿主不认识某个 slot 时 slots.inject 根本不回调，所以这里抛错基本只发生在
        //   ctx.inject 本身不可用的老宿主上。）
        try {
          registerCards(ctx)
        } catch (error) {
          console.error('[independent-input-mod] settings card skipped:', error)
        }
      },
    }
  },
})
