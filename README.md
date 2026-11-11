# dsh-independent-input

给 DSH 用的桌面操作插件：**AI 有一套自己的光标**，用它点、输、滚、拖，不动你的真实鼠标，也不抢你的键盘焦点。

你随时可以打断它——只要碰一下真的鼠标或键盘，正在执行的动作立刻停。

网页走 CDP（直接读页面结构，精确到元素），桌面原生控件走 UIA，只有前两条都不通时才降级到物理输入。

## 它能做什么

| 动作 | 做什么 | 走哪条通道 |
|---|---|---|
| `status` | 暂停状态、前台窗口、AI 光标在哪 | 只读 |
| `windows` | 列可见窗口（hwnd / 标题 / 矩形 / 进程 / 标签页） | 只读 |
| `capture` | 截窗口（前台走屏幕拷贝，后台走 PrintWindow） | 只读 |
| `observe` | 列窗口内可操作控件（带编号，供 `click` 用 `ref`） | UIA |
| `browser` | 直接读网页：`tabs` / `eval` / `click` / `text` / `fill` / `count` | CDP |
| `click` | 单击 / 双击 / 右键（坐标、locator 或 ref） | CDP → UIA → 窗口消息 |
| `type` | 输入文字（追加或覆盖） | UIA Value / 窗口消息 / 物理键盘 |
| `key` | 组合键（`ctrl+c`、`alt+tab`、`enter`…） | 窗口消息 → 物理键盘 |
| `scroll` | 滚轮 | 窗口消息 |
| `drag` | 拖拽 | 窗口消息 |
| `move` | 只移动 AI 光标，真实光标不动 | 覆盖层 |
| `act` | 连做多步（每步可带 `expect` 自校验） | 混合 |
| `waitFor` | 等元素出现/消失、标题变化、文字出现 | UIA |
| `activate` | 把某个窗口切到前台 | 系统 API |
| `done` | 收尾：光标现身 + 气泡播报 + 可选切回 DSH | 覆盖层 |
| `setScope` | 限定插件只能碰哪些窗口 | 本地状态 |
| `pause` / `resume` | 暂停 / 恢复 | 本地状态 |
| `overlay` | 显示 / 隐藏 / 换光标模式 | 覆盖层 |

## 三条通道，优先级从高到低

1. **CDP**（浏览器）：直接问浏览器要 DOM，找元素、读文字、填表单都不用猜坐标。需要浏览器开一次远程调试，**每次浏览器重启后授权一次**。
2. **UIA / 窗口消息**（桌面原生控件）：按控件树找按钮，向目标窗口发消息，**不移动真实光标、不抢焦点**。
3. **physical**（兜底）：真按真点。只在前两条都没辙时用——比如游戏、自绘界面、某些 Chromium 输入框。

`physical` 有个硬规则：**执行期间你一碰键鼠，动作立刻中止**。这是特性，不是 bug——你随时能打断它。

## AI 光标：陪伴 / 整洁

光标是插件自己的覆盖层窗口，置顶、点击穿透、不抢焦点。它是**执行者**，不是装饰：光标停在哪，就是程序执行到哪。

- **陪伴模式**（默认）：一直显示，随时能看见 AI 在干嘛。
- **整洁模式**：动作后停一会儿自动收起。

它按操作自动切换状态（`pointer` / `text` / `link` / `vert` / `busy` / `unavailiable` 等 15 种），不用手选。

**缓慢模式**是另一回事：它让光标移动有补间、打字逐字冒（间隔可调 100–3000ms），**侧重陪伴感**——慢慢做给你看，慢是故意的。要快就用快速模式——不逐字、不补间。

## 必须你做的三件事

| 事 | 频率 | 不做会怎样 |
|---|---|---|
| 杀毒软件放行插件目录 | 一次性 | 杀毒会把 `sidecar.ps1` 锁到读写都失败，插件起不来 |
| 浏览器开远程调试 | 浏览器重启后 | `browser` 报 `cdp-unavailable` |
| 点「允许」授权 | 浏览器重启后一次 | CDP 连不上，等 60 秒超时 |

开远程调试的地址：

- Edge：`edge://inspect#remote-debugging`
- Chrome / Brave / Vivaldi：`chrome://inspect#remote-debugging`

勾上「Allow remote debugging」，第一次连接时浏览器会弹「是否允许远程调试？」，点「允许」。

**排查口诀**：`browser` 超时先看屏幕有没有授权弹窗，再看代码。

## 安装

在 DSH 的 profile `package.json` 里加依赖：

```json
"dsh-independent-input": "link:/path/to/dsh-independent-input"
```

把插件加进 `dsh.profile.bundles`，然后：

```powershell
dsh plugin --profile desktop install
```

重启 DSH 后，会话里出现 `independent_input` 工具，设置页多一个「独立输入」。

## 做不到的

| 场景 | 为什么 |
|---|---|
| Firefox | 用另一套调试协议，CDP 不支持 |
| UAC / 管理员提权弹窗 | 安全桌面输入注入进不去 |
| 游戏 / 自绘界面 | 只有 physical，坐标对不对要截图量 |
| 跨虚拟桌面 / 多显示器 | 坐标支持了，但没实测过 |
| 截图里的文字 | 插件不做 OCR（质量不稳）。但 `capture` 把截图交给模型，多模态模型自己能看 |

## 许可

- **代码**：MIT，见 `LICENSE`。
- **光标美术**（`assets/cursors/`、`assets/previews/`）：第三方公开免费素材，**不是本项目原创**。版权归原作者，本项目不把这份美术按 MIT 再授权。详见 `NOTICE`。