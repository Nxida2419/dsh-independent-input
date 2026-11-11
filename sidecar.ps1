# dsh-independent-input sidecar
# Windows PowerShell 5.1, STA. 一条 JSON 一行请求/响应。
# 设计目标：默认不碰主人的真实光标和键盘焦点（UIA / 窗口消息），
# 物理输入只作为显式回退，并且主人一碰鼠标键盘就立刻暂停、还原光标。

$ErrorActionPreference = 'Stop'
# stdin/stdout 一律走显式 UTF-8 流。PS 5.1 在 stdin/stdout 被重定向时，
# 设 [Console]::InputEncoding 会静默失效（中文按 ANSI/OEM 解码），所以这里
# 自己包一层 StreamReader/StreamWriter，绕开控制台编码。
$script:utf8 = New-Object System.Text.UTF8Encoding($false)
$script:stdin = $null
$script:stdout = $null
try {
  [Console]::OutputEncoding = $script:utf8
  [Console]::InputEncoding = $script:utf8
  $OutputEncoding = $script:utf8
} catch { }
try {
  $script:stdin = New-Object System.IO.StreamReader([Console]::OpenStandardInput(), $script:utf8)
  $script:stdout = New-Object System.IO.StreamWriter([Console]::OpenStandardOutput(), $script:utf8)
  $script:stdout.AutoFlush = $true
} catch { }

# AI 光标模式：companion = 一直陪着；clean = 用一下就收。
# 插件 config / 环境变量都可以改，运行中还能用 setCursorMode 切换。
$script:cursorMode = if ($env:DSH_INPUT_CURSOR_MODE -eq 'clean') { 'clean' } else { 'companion' }
# D014：上一次「收尾」（done）发生在什么时候，epoch 毫秒；0 = 这个进程里还没收过尾。
# 只活在内存里——sidecar 重启后归零，因为「本进程做过什么」本来就不跨进程。
$script:lastDoneAt = 0
# dsh-cua 借鉴②：窗口作用域。$null = 不限制；设成数组则只允许这些 hwnd。
$script:scopeHwnds = $null
$script:cursorHoldMs = 2600
if ($env:DSH_INPUT_CURSOR_HOLD_MS) {
  try { $script:cursorHoldMs = [int]$env:DSH_INPUT_CURSOR_HOLD_MS } catch { }
}
# AI 光标大小（像素，24–192）。素材是 64×64，按最近邻放大/缩小。
$script:cursorSize = 64
if ($env:DSH_INPUT_CURSOR_SIZE) {
  try { $script:cursorSize = [int]$env:DSH_INPUT_CURSOR_SIZE } catch { }
}
if ($script:cursorSize -lt 24) { $script:cursorSize = 24 }
if ($script:cursorSize -gt 192) { $script:cursorSize = 192 }
# AI 光标样式：主人给的 15 只光标里选一只。
$script:styleNames = @('pointer','work','unavailiable','link','text','cross','busy','move','vert','horz','help','handwriting','dgn1','dgn2','alternate')
$script:cursorStyle = 'pointer'
if ($env:DSH_INPUT_CURSOR_STYLE) {
  $wanted = ([string]$env:DSH_INPUT_CURSOR_STYLE).ToLower()
  if ($script:styleNames -contains $wanted) { $script:cursorStyle = $wanted }
}

# ---------------------------------------------------------------- 事不过三（抢占预算）
# physical 动作每被主人打断一次记一笔；连续 3 笔就停手，换 help 图标对主人表示疑问：
# "我不敢再动了，是不是点到你不想要的地方了？"
# 只有"成功完成一次真实动作"或"主人让继续（action:'resume'）"才清零。
$script:takeoverStrikes = 0
$script:takeoverLimit = 3
# 调试用：预置已成次数，方便离线验证"到数就停手"这条路径
if ($env:DSH_INPUT_TAKEOVER_STRIKES) {
  try { $script:takeoverStrikes = [int]$env:DSH_INPUT_TAKEOVER_STRIKES } catch { }
}

# ---------------------------------------------------------------- 事件时间线
# 每次动作打一条：谁、在哪、干了什么、结果如何、花了多久。
# 环形缓冲，最多 $script:eventCap 条；status 读回最近 N 条。
# 刻意不记录键鼠字符内容（只记动作类型与目标），避免变成键盘记录器。
$script:eventLog = New-Object System.Collections.ArrayList
$script:eventSeq = 0
$script:eventCap = 300




function Add-DshEvent([string]$action, $req, $result, [double]$ms) {
  $script:eventSeq++
  $evt = [ordered]@{
    seq = $script:eventSeq
    at = (Get-Date).ToString('HH:mm:ss.fff')
    action = $action
    label = if ($null -ne $req.label) { [string]$req.label } else { '' }
    ok = [bool]$result.ok
    ms = [int]$ms
    hwnd = if ($null -ne $req.hwnd) { [long]$req.hwnd } else { $null }
    x = if ($null -ne $req.x) { [int]$req.x } else { $null }
    y = if ($null -ne $req.y) { [int]$req.y } else { $null }
    via = if ($null -ne $result.via) { [string]$result.via } else { '' }
    note = if ($null -ne $result.reason) { [string]$result.reason } else { '' }
  }
  if ($script:eventLog.Count -ge $script:eventCap) { $script:eventLog.RemoveAt(0) | Out-Null }
  $script:eventLog.Add($evt) | Out-Null
}

# ---------------------------------------------------------------- 时间线落盘
# 内存环形缓冲只够 status 当场看；评测要的是"事后可查的流水"。
# 每个请求结束后，把 C# 侧攒的动作 drain 出来追加到 JSONL：
#   ~/.dsh/independent-input/timeline.jsonl
# 行格式：{"ms":<epoch毫秒>,"kind":"move.start","x":..,"y":..,"dur":..}
$script:tracePath = Join-Path $env:USERPROFILE '.dsh\independent-input\timeline.jsonl'
$script:traceMaxBytes = 8MB

function Write-TraceDrain {
  try {
    $items = [DshOverlay]::DrainTrace()
    if ($null -eq $items -or $items.Count -eq 0) { return }
    $dir = Split-Path -Parent $script:tracePath
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    try {
      $fi = New-Object System.IO.FileInfo($script:tracePath)
      if ($fi.Exists -and $fi.Length -gt $script:traceMaxBytes) { Move-Item -Force $script:tracePath ($script:tracePath + '.1') }
    } catch { }
    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($it in $items) {
      $lines.Add((@{ ms = $it.ms; kind = $it.kind; x = $it.x; y = $it.y; dur = $it.dur } | ConvertTo-Json -Compress))
    }
    [System.IO.File]::AppendAllLines($script:tracePath, [string[]]$lines, $script:utf8)
  } catch { }
}

# 先声明 DPI 感知，再加载 WinForms / UIA。否则高 DPI 屏上截图坐标和
# UIA FromPoint 会差一个缩放比，点不中目标。
$dpiCode = @'
using System;
using System.Runtime.InteropServices;
public static class DshDpiBootstrap {
  [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr value);
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
  public static void Apply() {
    try { if (SetProcessDpiAwarenessContext(new IntPtr(-4))) return; } catch { }
    try { SetProcessDPIAware(); } catch { }
  }
}
'@
try { Add-Type -TypeDefinition $dpiCode; [DshDpiBootstrap]::Apply() } catch { }

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
$script:uia = $true
try {
  Add-Type -AssemblyName WindowsBase
  Add-Type -AssemblyName UIAutomationClient
  Add-Type -AssemblyName UIAutomationTypes
} catch {
  $script:uia = $false
}

$refs = @(
  [System.Windows.Forms.Form].Assembly.Location,
  [System.Drawing.Bitmap].Assembly.Location,
  [System.Drawing.Point].Assembly.Location
)

$cs = @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Windows.Forms;

public static class DshInput
{
    public const int WH_KEYBOARD_LL = 13;
    public const int WH_MOUSE_LL = 14;

    public const int WM_KEYDOWN = 0x0100;
    public const int WM_KEYUP = 0x0101;
    public const int WM_CHAR = 0x0102;
    public const uint WM_SETTEXT = 0x000C;
    public const int WM_SYSKEYDOWN = 0x0104;
    public const int WM_SYSKEYUP = 0x0105;
    public const int WM_MOUSEMOVE = 0x0200;
    public const int WM_LBUTTONDOWN = 0x0201;
    public const int WM_LBUTTONUP = 0x0202;
    public const int WM_LBUTTONDBLCLK = 0x0203;
    public const int WM_RBUTTONDOWN = 0x0204;
    public const int WM_RBUTTONUP = 0x0205;
    public const int WM_RBUTTONDBLCLK = 0x0206;
    public const int WM_MOUSEWHEEL = 0x020A;
    public const int WM_HOTKEY = 0x0312;
    public const int WM_QUIT = 0x0012;

    public const int MK_LBUTTON = 0x0001;
    public const int MK_RBUTTON = 0x0002;

    public const int GW_OWNER = 4;
    public const int GA_ROOT = 2;
    public const int GWL_STYLE = -16;

    public const int SM_XVIRTUALSCREEN = 76;
    public const int SM_YVIRTUALSCREEN = 77;
    public const int SM_CXVIRTUALSCREEN = 78;
    public const int SM_CYVIRTUALSCREEN = 79;

    public const int SW_RESTORE = 9;
    public const int SW_MAXIMIZE = 3;
    public const int SWP_NOACTIVATE = 0x0010;
    public const int SWP_SHOWWINDOW = 0x0040;
    public static readonly IntPtr HWND_TOPMOST = new IntPtr(-1);

    public const uint INPUT_MOUSE = 0;
    public const uint INPUT_KEYBOARD = 1;

    public const uint KEYEVENTF_EXTENDEDKEY = 0x0001;
    public const uint KEYEVENTF_KEYUP = 0x0002;
    public const uint KEYEVENTF_UNICODE = 0x0004;

    public const uint MOUSEEVENTF_MOVE = 0x0001;
    public const uint MOUSEEVENTF_LEFTDOWN = 0x0002;
    public const uint MOUSEEVENTF_LEFTUP = 0x0004;
    public const uint MOUSEEVENTF_RIGHTDOWN = 0x0008;
    public const uint MOUSEEVENTF_RIGHTUP = 0x0010;
    public const uint MOUSEEVENTF_WHEEL = 0x0800;
    public const uint MOUSEEVENTF_ABSOLUTE = 0x8000;
    public const uint MOUSEEVENTF_VIRTUALDESK = 0x4000;

    public const uint LLMHF_INJECTED = 0x00000001;
    public const uint LLKHF_INJECTED = 0x00000010;

    public const int MOD_ALT = 0x0001;
    public const int MOD_CONTROL = 0x0002;
    public const int MOD_NOREPEAT = 0x4000;
    public const int VK_MENU = 0x12;
    public const int VK_Q = 0x51;
    public const int HOTKEY_ID = 0x4453;

    [StructLayout(LayoutKind.Sequential)]
    public struct POINT { public int X; public int Y; }

    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }

    [StructLayout(LayoutKind.Sequential)]
    public struct LASTINPUTINFO { public uint cbSize; public uint dwTime; }

    [StructLayout(LayoutKind.Sequential)]
    public struct MSG { public IntPtr hwnd; public uint message; public IntPtr wParam; public IntPtr lParam; public uint time; public POINT pt; }

    [StructLayout(LayoutKind.Sequential)]
    public struct MSLLHOOKSTRUCT { public POINT pt; public uint mouseData; public uint flags; public uint time; public IntPtr dwExtraInfo; }

    [StructLayout(LayoutKind.Sequential)]
    public struct KBDLLHOOKSTRUCT { public uint vkCode; public uint scanCode; public uint flags; public uint time; public IntPtr dwExtraInfo; }

    [StructLayout(LayoutKind.Sequential)]
    public struct GUITHREADINFO
    {
        public uint cbSize;
        public uint flags;
        public IntPtr hwndActive;
        public IntPtr hwndFocus;
        public IntPtr hwndCapture;
        public IntPtr hwndMenuOwner;
        public IntPtr hwndMoveSize;
        public IntPtr hwndCaret;
        public RECT rcCaret;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct MOUSEINPUT { public int dx; public int dy; public uint mouseData; public uint dwFlags; public uint time; public IntPtr dwExtraInfo; }

    [StructLayout(LayoutKind.Sequential)]
    public struct KEYBDINPUT { public ushort wVk; public ushort wScan; public uint dwFlags; public uint time; public IntPtr dwExtraInfo; }

    [StructLayout(LayoutKind.Sequential)]
    public struct HARDWAREINPUT { public uint uMsg; public ushort wParamL; public ushort wParamH; }

    [StructLayout(LayoutKind.Explicit)]
    public struct INPUTUNION
    {
        [FieldOffset(0)] public MOUSEINPUT mi;
        [FieldOffset(0)] public KEYBDINPUT ki;
        [FieldOffset(0)] public HARDWAREINPUT hi;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct INPUT { public uint type; public INPUTUNION u; }

    public delegate IntPtr LowLevelProc(int nCode, IntPtr wParam, IntPtr lParam);
    public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern IntPtr SetWindowsHookEx(int idHook, LowLevelProc lpfn, IntPtr hMod, uint dwThreadId);
    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool UnhookWindowsHookEx(IntPtr hhk);
    [DllImport("user32.dll")]
    public static extern IntPtr CallNextHookEx(IntPtr hhk, int nCode, IntPtr wParam, IntPtr lParam);
    [DllImport("kernel32.dll")]
    public static extern IntPtr GetModuleHandle(string lpModuleName);
    [DllImport("kernel32.dll")]
    public static extern uint GetCurrentThreadId();
    [DllImport("user32.dll")]
    public static extern int GetMessage(out MSG lpMsg, IntPtr hWnd, uint wMsgFilterMin, uint wMsgFilterMax);
    [DllImport("user32.dll")]
    public static extern bool TranslateMessage(ref MSG lpMsg);
    [DllImport("user32.dll")]
    public static extern IntPtr DispatchMessage(ref MSG lpMsg);
    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool PostThreadMessage(uint idThread, uint Msg, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool RegisterHotKey(IntPtr hWnd, int id, uint fsModifiers, uint vk);
    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool UnregisterHotKey(IntPtr hWnd, int id);

    [DllImport("user32.dll")]
    public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")]
    public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")]
    public static extern bool BringWindowToTop(IntPtr hWnd);
    [DllImport("user32.dll")]
    public static extern bool AttachThreadInput(uint idAttach, uint idAttachTo, bool fAttach);
    [DllImport("user32.dll")]
    public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
    [DllImport("user32.dll")]
    public static extern bool IsIconic(IntPtr hWnd);
    [DllImport("user32.dll")]
    public static extern bool IsZoomed(IntPtr hWnd);
    [DllImport("user32.dll")]
    public static extern bool IsWindowVisible(IntPtr hWnd);
    [DllImport("user32.dll")]
    public static extern bool EnumWindows(EnumWindowsProc lpEnumFunc, IntPtr lParam);
    [DllImport("user32.dll")]
    public static extern int GetWindowTextLengthW(IntPtr hWnd);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern int GetWindowTextW(IntPtr hWnd, StringBuilder lpString, int nMaxCount);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern int GetClassNameW(IntPtr hWnd, StringBuilder lpClassName, int nMaxCount);
    [DllImport("user32.dll")]
    public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out int lpdwProcessId);
    [DllImport("user32.dll")]
    public static extern IntPtr GetWindow(IntPtr hWnd, uint uCmd);
    [DllImport("user32.dll")]
    public static extern IntPtr GetAncestor(IntPtr hwnd, uint gaFlags);
    [DllImport("user32.dll")]
    public static extern bool GetClientRect(IntPtr hWnd, out RECT lpRect);
    [DllImport("user32.dll")]
    public static extern bool ClientToScreen(IntPtr hWnd, ref POINT lpPoint);
    [DllImport("user32.dll")]
    public static extern bool IsWindow(IntPtr hWnd);
    [DllImport("user32.dll")]
    public static extern IntPtr ChildWindowFromPointEx(IntPtr hWnd, POINT pt, uint flags);
    [DllImport("user32.dll")]
    public static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);
    [DllImport("dwmapi.dll")]
    public static extern int DwmGetWindowAttribute(IntPtr hwnd, int dwAttribute, out RECT pvAttribute, int cbAttribute);
    [DllImport("user32.dll")]
    public static extern IntPtr WindowFromPoint(POINT point);
    [DllImport("user32.dll")]
    public static extern bool ScreenToClient(IntPtr hWnd, ref POINT lpPoint);
    [DllImport("user32.dll")]
    public static extern bool GetCursorPos(out POINT lpPoint);
    [DllImport("user32.dll")]
    public static extern bool SetCursorPos(int X, int Y);
    [DllImport("user32.dll")]
    public static extern bool GetLastInputInfo(ref LASTINPUTINFO plii);
    [DllImport("kernel32.dll")]
    public static extern ulong GetTickCount64();
    [DllImport("user32.dll")]
    public static extern bool GetGUIThreadInfo(uint idThread, ref GUITHREADINFO lpgui);
    [DllImport("user32.dll")]
    public static extern int GetSystemMetrics(int nIndex);
    [DllImport("user32.dll", SetLastError = true)]
    public static extern uint MapVirtualKey(uint uCode, uint uMapType);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern uint SendInput(uint nInputs, INPUT[] pInputs, int cbSize);
    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool PostMessage(IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern IntPtr SendMessageW(IntPtr hWnd, uint Msg, IntPtr wParam, string lParam);

    [DllImport("user32.dll")]
    public static extern bool SetProcessDPIAware();
    [DllImport("user32.dll")]
    public static extern bool SetProcessDpiAwarenessContext(IntPtr dpiContext);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool SetWindowPos(IntPtr hWnd, IntPtr hWndInsertAfter, int X, int Y, int cx, int cy, uint uFlags);
    [DllImport("user32.dll")]
    public static extern IntPtr GetWindowLongPtrW(IntPtr hWnd, int nIndex);
    [DllImport("user32.dll")]
    public static extern IntPtr SetWindowLongPtrW(IntPtr hWnd, int nIndex, IntPtr dwNewLong);
    [DllImport("user32.dll")]
    public static extern IntPtr GetParent(IntPtr hWnd);

    static readonly DateTime StartTime = DateTime.UtcNow;
    static long lastUserInputTicks = 0;
    static long lastInjectedTick = 0;

    public static volatile bool Paused = false;
    public static volatile bool PhysicalActive = false;
    public static string PauseReason = "";
    public static int UserActiveMs = 800;
    static bool AllowPhysicalMouse = false;

    static readonly object heldLock = new object();
    static readonly List<ushort> heldKeys = new List<ushort>();
    static bool leftDown = false;
    static bool rightDown = false;

    static POINT savedCursor;
    static bool hasSavedCursor = false;

    static IntPtr mouseHook = IntPtr.Zero;
    static IntPtr keyHook = IntPtr.Zero;
    static Thread hookThread = null;
    static uint hookThreadId = 0;
    static Thread hotkeyThread = null;
    static uint hotkeyThreadId = 0;
    static ManualResetEvent hotkeyDone = new ManualResetEvent(false);
    static LowLevelProc mouseProc = MouseHookProc;
    static LowLevelProc keyProc = KeyHookProc;
    public static bool HotkeyRegistered = false;

    static DshInput()
    {
        try { SetProcessDpiAwarenessContext(new IntPtr(-4)); }
        catch { try { SetProcessDPIAware(); } catch { } }
        int size = Marshal.SizeOf(typeof(INPUT));
        if (IntPtr.Size == 8 && size != 40) throw new Exception("INPUT size " + size + " is not 40");
    }

    public static long LastUserInputAgeMs()
    {
        try
        {
            LASTINPUTINFO info = new LASTINPUTINFO();
            info.cbSize = (uint)Marshal.SizeOf(typeof(LASTINPUTINFO));
            if (GetLastInputInfo(ref info))
            {
                uint now = (uint)(GetTickCount64() & 0xFFFFFFFF);
                return (long)((now - info.dwTime) & 0xFFFFFFFF);
            }
        }
        catch { }
        long last = Interlocked.Read(ref lastUserInputTicks);
        if (last == 0) return -1;
        return (long)((DateTime.UtcNow.Ticks - last) / TimeSpan.TicksPerMillisecond);
    }

    public static int[] CursorPos()
    {
        POINT p;
        GetCursorPos(out p);
        return new int[] { p.X, p.Y };
    }

    // 只认 low-level hook 记到的真实用户输入：注入事件在 HookProc 里已被
    // LLMHF_INJECTED / LLKHF_INJECTED 过滤，所以这个值不会被 SendInput 自己污染，
    // 比 GetLastInputInfo 更适合判断"主人是不是刚伸手"。
    public static long UserInputAgeMsByHook()
    {
        long last = Interlocked.Read(ref lastUserInputTicks);
        if (last == 0) return long.MaxValue;
        return (long)((DateTime.UtcNow.Ticks - last) / TimeSpan.TicksPerMillisecond);
    }

    public static bool UserTakeover(int graceMs)
    {
        return UserInputAgeMsByHook() <= Math.Max(0, graceMs);
    }

    public static void SetAllowPhysical(bool on)
    {
        AllowPhysicalMouse = on;
    }

    // 动作开始那一刻的输入时间戳：只有"这之后又来了新输入"才算主人插手，
    // 否则主人刚划过鼠标的那一下会让 AI 永远动不了。
    public static long UserInputBaseline()
    {
        return Interlocked.Read(ref lastUserInputTicks);
    }

    public static bool UserTakeoverSince(long baseline, int graceMs)
    {
        long now = Interlocked.Read(ref lastUserInputTicks);
        if (now == baseline) return false;
        return UserInputAgeMsByHook() <= Math.Max(0, graceMs);
    }

    public static void SetUserActiveMs(int ms)
    {
        if (ms < 0) ms = 0;
        UserActiveMs = ms;
    }

    static void TouchUserInput()
    {
        Interlocked.Exchange(ref lastUserInputTicks, DateTime.UtcNow.Ticks);
    }

    public static void SimulateUserInput()
    {
        TouchUserInput();
    }

    static IntPtr MouseHookProc(int nCode, IntPtr wParam, IntPtr lParam)
    {
        if (nCode >= 0)
        {
            MSLLHOOKSTRUCT data = (MSLLHOOKSTRUCT)Marshal.PtrToStructure(lParam, typeof(MSLLHOOKSTRUCT));
            if ((data.flags & LLMHF_INJECTED) == 0)
            {
                TouchUserInput();
            }
        }
        return CallNextHookEx(mouseHook, nCode, wParam, lParam);
    }

    static IntPtr KeyHookProc(int nCode, IntPtr wParam, IntPtr lParam)
    {
        if (nCode >= 0)
        {
            KBDLLHOOKSTRUCT data = (KBDLLHOOKSTRUCT)Marshal.PtrToStructure(lParam, typeof(KBDLLHOOKSTRUCT));
            if ((data.flags & LLKHF_INJECTED) == 0)
            {
                TouchUserInput();
            }
        }
        return CallNextHookEx(keyHook, nCode, wParam, lParam);
    }

    public static void StartHotkey()
    {
        if (hotkeyThread != null) { hotkeyDone.WaitOne(600); return; }
        hotkeyThread = new Thread(HotkeyThreadProc);
        hotkeyThread.IsBackground = true;
        hotkeyThread.SetApartmentState(ApartmentState.STA);
        hotkeyThread.Start();
        // 等注册结果落地，否则 status 可能在注册完成前就报到 false
        hotkeyDone.WaitOne(600);
    }

    static void HotkeyThreadProc()
    {
        hotkeyThreadId = GetCurrentThreadId();
        try
        {
            HotkeyRegistered = RegisterHotKey(IntPtr.Zero, HOTKEY_ID, MOD_CONTROL | MOD_ALT | MOD_NOREPEAT, VK_Q);
        }
        catch { HotkeyRegistered = false; }
        hotkeyDone.Set();
        MSG msg;
        while (GetMessage(out msg, IntPtr.Zero, 0, 0) > 0)
        {
            if (msg.message == WM_HOTKEY && msg.wParam.ToInt32() == HOTKEY_ID)
            {
                TogglePause("hotkey");
            }
            TranslateMessage(ref msg);
            DispatchMessage(ref msg);
        }
        UnregisterHotKey(IntPtr.Zero, HOTKEY_ID);
        hotkeyThreadId = 0;
    }

    public static void StopHotkey()
    {
        if (hotkeyThreadId != 0)
        {
            PostThreadMessage(hotkeyThreadId, WM_QUIT, IntPtr.Zero, IntPtr.Zero);
            hotkeyThreadId = 0;
        }
        hotkeyThread = null;
    }

    public static void StartHooks()
    {
        if (hookThread != null) return;
        hookThread = new Thread(HookThreadProc);
        hookThread.IsBackground = true;
        hookThread.SetApartmentState(ApartmentState.STA);
        hookThread.Start();
    }

    static void HookThreadProc()
    {
        hookThreadId = GetCurrentThreadId();
        IntPtr hmod = GetModuleHandle(null);
        mouseHook = SetWindowsHookEx(WH_MOUSE_LL, mouseProc, hmod, 0);
        if (mouseHook == IntPtr.Zero) mouseHook = SetWindowsHookEx(WH_MOUSE_LL, mouseProc, IntPtr.Zero, 0);
        keyHook = SetWindowsHookEx(WH_KEYBOARD_LL, keyProc, hmod, 0);
        if (keyHook == IntPtr.Zero) keyHook = SetWindowsHookEx(WH_KEYBOARD_LL, keyProc, IntPtr.Zero, 0);

        MSG msg;
        while (GetMessage(out msg, IntPtr.Zero, 0, 0) > 0)
        {
            TranslateMessage(ref msg);
            DispatchMessage(ref msg);
        }
        if (mouseHook != IntPtr.Zero) { UnhookWindowsHookEx(mouseHook); mouseHook = IntPtr.Zero; }
        if (keyHook != IntPtr.Zero) { UnhookWindowsHookEx(keyHook); keyHook = IntPtr.Zero; }
        hookThreadId = 0;
    }

    public static void StopHooks()
    {
        if (hookThreadId != 0)
        {
            PostThreadMessage(hookThreadId, WM_QUIT, IntPtr.Zero, IntPtr.Zero);
            hookThreadId = 0;
        }
        hookThread = null;
    }

    public static void TogglePause(string reason)
    {
        if (Paused) Resume();
        else Pause(reason);
    }

    public static void Pause(string reason)
    {
        Paused = true;
        PauseReason = reason;
        ReleaseAll();
        DshOverlay.SetPaused(true);
    }

    public static void Resume()
    {
        Paused = false;
        PauseReason = "";
        DshOverlay.SetPaused(false);
    }

    public static void ReleaseAll(bool restoreCursor = true)
    {
        lock (heldLock)
        {
            for (int i = heldKeys.Count - 1; i >= 0; i--)
            {
                try { SendKeyRaw(heldKeys[i], false, false); } catch { }
            }
            heldKeys.Clear();
            if (leftDown) { try { SendMouseRaw(MOUSEEVENTF_LEFTUP, 0, 0, 0); } catch { } leftDown = false; }
            if (rightDown) { try { SendMouseRaw(MOUSEEVENTF_RIGHTUP, 0, 0, 0); } catch { } rightDown = false; }
        }
        // 调用方自己管光标归位时传 false，否则这里会把"点完停在原地"又拉回去。
        if (restoreCursor) RestoreCursor();
    }

    static void SaveCursor()
    {
        if (!hasSavedCursor)
        {
            POINT p;
            if (GetCursorPos(out p))
            {
                savedCursor = p;
                hasSavedCursor = true;
            }
        }
    }

    static void RestoreCursor()
    {
        if (hasSavedCursor)
        {
            try { SetCursorPos(savedCursor.X, savedCursor.Y); } catch { }
            hasSavedCursor = false;
        }
    }

    static void CheckReadyForPhysical()
    {
        // 主人和 AI 可以同时操作；只认显式暂停（Ctrl+Alt+Q / pause），
        // 不再因为检测到主人在动鼠标键盘就拒绝 physical。
        if (Paused) throw new Exception("paused: " + PauseReason);
    }

    static void MoveRaw(int x, int y, bool pauseAfter = true)
    {
        int left = GetSystemMetrics(SM_XVIRTUALSCREEN);
        int top = GetSystemMetrics(SM_YVIRTUALSCREEN);
        int width = Math.Max(1, GetSystemMetrics(SM_CXVIRTUALSCREEN));
        int height = Math.Max(1, GetSystemMetrics(SM_CYVIRTUALSCREEN));
        int nx = (int)Math.Round((x - left) * 65535.0 / Math.Max(1, width - 1));
        int ny = (int)Math.Round((y - top) * 65535.0 / Math.Max(1, height - 1));
        SendMouseRaw(MOUSEEVENTF_MOVE | MOUSEEVENTF_ABSOLUTE | MOUSEEVENTF_VIRTUALDESK, nx, ny, 0);
        if (pauseAfter) Thread.Sleep(12);
    }

    // 分步移动真实光标：一次调用走完整条路径，easeOutCubic，16ms 一拍。
    // graceMs >= 0 时逐帧检查主人有没有在这之后伸手——一碰就抛 user-takeover，
    // 保证控制权永远能立刻被夺回（配合 Ctrl+Alt+Q 的显式暂停）。
    // 用 Stopwatch 对齐节拍，总时长才和 durationMs 对得上，不会因为每步开销拖慢。
    static void MoveRawAnimated(int x1, int y1, int x2, int y2, int durationMs, int graceMs)
    {
        if (durationMs <= 0) { MoveRaw(x2, y2); return; }
        long baseline = UserInputBaseline();
        int steps = Math.Max(6, Math.Min(300, durationMs / 16));
        System.Diagnostics.Stopwatch sw = System.Diagnostics.Stopwatch.StartNew();
        for (int i = 1; i <= steps; i++)
        {
            if (Paused) throw new Exception("paused: " + PauseReason);
            if (graceMs >= 0 && UserTakeoverSince(baseline, graceMs)) throw new Exception("user-takeover");
            double t = (double)i / steps;
            double e = 1 - Math.Pow(1 - t, 3);
            MoveRaw(x1 + (int)Math.Round((x2 - x1) * e), y1 + (int)Math.Round((y2 - y1) * e), false);
            int wait = (int)((long)i * durationMs / steps - sw.ElapsedMilliseconds);
            if (wait > 0) Thread.Sleep(wait);
        }
    }

    static void SendMouseRaw(uint flags, int dx, int dy, int data)
    {
        INPUT input = new INPUT();
        input.type = INPUT_MOUSE;
        input.u.mi.dx = dx;
        input.u.mi.dy = dy;
        input.u.mi.mouseData = (uint)data;
        input.u.mi.dwFlags = flags;
        input.u.mi.time = 0;
        input.u.mi.dwExtraInfo = IntPtr.Zero;
        INPUT[] inputs = new INPUT[] { input };
        if (SendInput(1, inputs, Marshal.SizeOf(typeof(INPUT))) != 1)
            throw new Exception("SendInput mouse failed");
        Interlocked.Exchange(ref lastInjectedTick, (long)(GetTickCount64() & 0xFFFFFFFF));
    }

    static void SendKeyRaw(ushort vk, bool down, bool extended)
    {
        INPUT input = new INPUT();
        input.type = INPUT_KEYBOARD;
        input.u.ki.wVk = vk;
        // 只填 wVk、不填 scan code 时 Chromium/Electron 认不出修饰键：
        // 实测 ctrl+t 变成「只打出一个 t」，ctrl 的按下被忽略。补上 scan code 才稳。
        input.u.ki.wScan = (ushort)MapVirtualKey(vk, 0);
        input.u.ki.dwFlags = (down ? 0u : KEYEVENTF_KEYUP) | (extended ? KEYEVENTF_EXTENDEDKEY : 0u);
        input.u.ki.time = 0;
        input.u.ki.dwExtraInfo = IntPtr.Zero;
        INPUT[] inputs = new INPUT[] { input };
        if (SendInput(1, inputs, Marshal.SizeOf(typeof(INPUT))) != 1)
            throw new Exception("SendInput keyboard failed");
        Interlocked.Exchange(ref lastInjectedTick, (long)(GetTickCount64() & 0xFFFFFFFF));
    }

    static void SendUnicodeChar(char ch)
    {
        INPUT down = new INPUT();
        down.type = INPUT_KEYBOARD;
        down.u.ki.wVk = 0;
        down.u.ki.wScan = (ushort)ch;
        down.u.ki.dwFlags = KEYEVENTF_UNICODE;
        INPUT up = down;
        up.u.ki.dwFlags = KEYEVENTF_UNICODE | KEYEVENTF_KEYUP;
        INPUT[] inputs = new INPUT[] { down, up };
        if (SendInput(2, inputs, Marshal.SizeOf(typeof(INPUT))) != 2)
            throw new Exception("SendInput unicode failed");
        Interlocked.Exchange(ref lastInjectedTick, (long)(GetTickCount64() & 0xFFFFFFFF));
    }

    // 逐字真实键入：走 SendInput 的 Unicode 通道，中文也能打；每字之间可中断。
    // 这是"看得见的手"在打字——字真的从键盘事件里冒出来，不是整段塞进控件。
    public static int TypeUnicodeSlow(string text, int intervalMs, int graceMs)
    {
        if (!AllowPhysicalMouse) throw new Exception("physical-mouse-forbidden");
        if (text == null || text.Length == 0) return 0;
        CheckReadyForPhysical();
        StartHooks();
        PhysicalActive = true;
        long baseline = UserInputBaseline();
        int typed = 0;
        System.Diagnostics.Stopwatch sw = System.Diagnostics.Stopwatch.StartNew();
        try
        {
            foreach (char ch in text)
            {
                if (Paused) throw new Exception("paused: " + PauseReason);
                if (graceMs >= 0 && UserTakeoverSince(baseline, graceMs)) throw new Exception("user-takeover");
                SendUnicodeChar(ch);
                typed++;
                if (typed < text.Length && intervalMs > 0)
                {
                    long target = (long)typed * intervalMs;
                    while (sw.ElapsedMilliseconds < target - 20)
                    {
                        if (Paused) throw new Exception("paused: " + PauseReason);
                        if (graceMs >= 0 && UserTakeoverSince(baseline, graceMs)) throw new Exception("user-takeover");
                        System.Threading.Thread.Sleep(20);
                    }
                }
            }
            return typed;
        }
        finally
        {
            PhysicalActive = false;
        }
    }

    // 真实按下一组键（Enter / Tab / ctrl+c 这类只能走这条）
    public static void PressComboSlow(int[] vks, int graceMs)
    {
        if (!AllowPhysicalMouse) throw new Exception("physical-mouse-forbidden");
        if (vks == null || vks.Length == 0) return;
        CheckReadyForPhysical();
        StartHooks();
        PhysicalActive = true;
        long baseline = UserInputBaseline();
        try
        {
            foreach (int vk in vks)
            {
                if (Paused) throw new Exception("paused: " + PauseReason);
                if (graceMs >= 0 && UserTakeoverSince(baseline, graceMs)) throw new Exception("user-takeover");
                SendKeyRaw((ushort)vk, true, false);
                System.Threading.Thread.Sleep(30);
            }
            System.Threading.Thread.Sleep(40);
            for (int i = vks.Length - 1; i >= 0; i--)
            {
                SendKeyRaw((ushort)vks[i], false, false);
                System.Threading.Thread.Sleep(20);
            }
        }
        finally
        {
            PhysicalActive = false;
        }
    }

    // restore=false（默认）：点完把真实光标留在目标位置，不再瞬移回原处——观感上"手停在这里"；
    // restore=true：放回动作开始时的位置（不想弄乱主人光标时用）。
    public static void PhysicalClick(int x, int y, bool right, int count, int durationMs, int graceMs, bool restore)
    {
        if (!AllowPhysicalMouse) throw new Exception("physical-mouse-forbidden");
        if (count < 1) count = 1;
        CheckReadyForPhysical();
        StartHooks();
        SaveCursor();
        PhysicalActive = true;
        long baseline = UserInputBaseline();
        try
        {
            if (durationMs > 0)
            {
                POINT from;
                GetCursorPos(out from);
                MoveRawAnimated(from.X, from.Y, x, y, durationMs, graceMs);
            }
            else
            {
                MoveRaw(x, y);
            }
            if (graceMs >= 0 && UserTakeoverSince(baseline, graceMs)) throw new Exception("user-takeover");
            // D017：按下之前回读光标。声明点 A 实际在 B 时宁可报错，也不要盲点——
            // 盲点的后果是「6 次点击全部静默落空，只能靠页面变化反推」。
            POINT now;
            if (!GetCursorPos(out now)) throw new Exception("cursor-read-failed");
            if (Math.Abs(now.X - x) > 1 || Math.Abs(now.Y - y) > 1)
                throw new Exception("cursor-mismatch: requested (" + x + "," + y + ") actual (" + now.X + "," + now.Y + ")");
            for (int i = 0; i < count; i++)
            {
                if (Paused) throw new Exception("paused: " + PauseReason);
                if (right)
                {
                    SendMouseRaw(MOUSEEVENTF_RIGHTDOWN, 0, 0, 0);
                    rightDown = true;
                    Thread.Sleep(30);
                    SendMouseRaw(MOUSEEVENTF_RIGHTUP, 0, 0, 0);
                    rightDown = false;
                }
                else
                {
                    SendMouseRaw(MOUSEEVENTF_LEFTDOWN, 0, 0, 0);
                    leftDown = true;
                    Thread.Sleep(30);
                    SendMouseRaw(MOUSEEVENTF_LEFTUP, 0, 0, 0);
                    leftDown = false;
                }
                Thread.Sleep(80);
            }
        }
        finally
        {
            PhysicalActive = false;
            if (restore) { RestoreCursor(); } else { hasSavedCursor = false; }
            ReleaseAll(false);
            StopHooks();
        }
    }

    // 把真实光标动画移到 (x,y)：看得见"手走过去"，不点击。
    // restore=false 就停在目标位置（演示用）；true 则在结束时放回原处。
    public static long[] PhysicalMove(int x, int y, int durationMs, int graceMs, bool restore)
    {
        if (!AllowPhysicalMouse) throw new Exception("physical-mouse-forbidden");
        CheckReadyForPhysical();
        StartHooks();
        SaveCursor();
        PhysicalActive = true;
        System.Diagnostics.Stopwatch sw = System.Diagnostics.Stopwatch.StartNew();
        try
        {
            POINT from;
            GetCursorPos(out from);
            MoveRawAnimated(from.X, from.Y, x, y, durationMs, graceMs);
            sw.Stop();
            return new long[] { from.X, from.Y, sw.ElapsedMilliseconds };
        }
        finally
        {
            if (restore) { RestoreCursor(); } else { hasSavedCursor = false; }
            PhysicalActive = false;
            ReleaseAll(false);
            StopHooks();
        }
    }

    public static void PhysicalText(string text)
    {
        CheckReadyForPhysical();
        StartHooks();
        PhysicalActive = true;
        try
        {
            int i = 0;
            foreach (char ch in text)
            {
                if (Paused) throw new Exception("paused: " + PauseReason);
                SendUnicodeChar(ch);
                i++;
                if ((i % 24) == 0) Thread.Sleep(4);
            }
        }
        finally
        {
            PhysicalActive = false;
            StopHooks();
        }
    }

    public static void PhysicalKeySequence(ushort[] keys)
    {
        if (keys == null || keys.Length == 0) throw new Exception("keys required");
        CheckReadyForPhysical();
        StartHooks();
        PhysicalActive = true;
        try
        {
            lock (heldLock)
            {
                for (int i = 0; i < keys.Length; i++)
                {
                    if (Paused) throw new Exception("paused: " + PauseReason);
                    SendKeyRaw(keys[i], true, false);
                    heldKeys.Add(keys[i]);
                    Thread.Sleep(15);
                }
            }
            Thread.Sleep(35);
        }
        finally
        {
            PhysicalActive = false;
            ReleaseAll();
            StopHooks();
        }
    }

    public static void PhysicalScroll(int x, int y, int delta)
    {
        if (!AllowPhysicalMouse) throw new Exception("physical-mouse-forbidden");
        CheckReadyForPhysical();
        StartHooks();
        SaveCursor();
        PhysicalActive = true;
        try
        {
            MoveRaw(x, y);
            SendMouseRaw(MOUSEEVENTF_WHEEL, 0, 0, delta);
            Thread.Sleep(90);
        }
        finally
        {
            PhysicalActive = false;
            RestoreCursor();
            StopHooks();
        }
    }

    public static void PhysicalDrag(int x1, int y1, int x2, int y2, int durationMs, int graceMs = -1)
    {
        if (!AllowPhysicalMouse) throw new Exception("physical-mouse-forbidden");
        CheckReadyForPhysical();
        StartHooks();
        SaveCursor();
        PhysicalActive = true;
        long baseline = UserInputBaseline();
        try
        {
            MoveRaw(x1, y1);
            SendMouseRaw(MOUSEEVENTF_LEFTDOWN, 0, 0, 0);
            leftDown = true;
            int steps = Math.Max(8, Math.Min(250, durationMs / 16));
            for (int i = 1; i <= steps; i++)
            {
                if (Paused) throw new Exception("paused: " + PauseReason);
                if (graceMs >= 0 && UserTakeoverSince(baseline, graceMs)) throw new Exception("user-takeover");
                int x = x1 + (x2 - x1) * i / steps;
                int y = y1 + (y2 - y1) * i / steps;
                MoveRaw(x, y);
                Thread.Sleep(16);
            }
            SendMouseRaw(MOUSEEVENTF_LEFTUP, 0, 0, 0);
            leftDown = false;
            Thread.Sleep(60);
        }
        finally
        {
            PhysicalActive = false;
            ReleaseAll();
            RestoreCursor();
            StopHooks();
        }
    }

    public static IntPtr FocusWindow(IntPtr hwnd)
    {
        IntPtr prev = GetForegroundWindow();
        if (hwnd == IntPtr.Zero) return prev;
        if (IsIconic(hwnd)) ShowWindow(hwnd, SW_RESTORE);
        SendKeyRaw(VK_MENU, true, false);
        try { SetForegroundWindow(hwnd); }
        finally { SendKeyRaw(VK_MENU, false, false); }
        Thread.Sleep(70);
        return prev;
    }

    // D014：把窗口切到前台，不动键盘、不动鼠标。
    // 和 FocusWindow 的区别：这里靠 AttachThreadInput 借前台线程的输入队列，
    // 不走「按一下 Alt」的老技巧，所以不会产生真实按键事件。
    // 注意：只有最小化的窗口才 SW_RESTORE；最大化的窗口保持最大化（SW_RESTORE
    //        会把最大化的 Edge 变成普通窗口，实测踩过）。
    public static bool ActivateWindow(IntPtr hwnd)
    {
        if (hwnd == IntPtr.Zero) return false;
        if (GetForegroundWindow() == hwnd) return true;
        if (IsIconic(hwnd)) ShowWindow(hwnd, SW_RESTORE);
        else if (IsZoomed(hwnd)) ShowWindow(hwnd, SW_MAXIMIZE);

        uint me = GetCurrentThreadId();
        int dummy;
        IntPtr fg = GetForegroundWindow();
        uint fgThread = fg == IntPtr.Zero ? 0 : GetWindowThreadProcessId(fg, out dummy);

        bool attached = false;
        if (fgThread != 0 && fgThread != me) attached = AttachThreadInput(me, fgThread, true);
        try
        {
            // 只靠 SetForegroundWindow 不够：它会返回 true 但系统仍按前台锁定压着不动，
            // 所以这里再 BringWindowToTop 一次，并且**以后台真实状态为准**轮询验证。
            BringWindowToTop(hwnd);
            SetForegroundWindow(hwnd);
            for (int i = 0; i < 12; i++)
            {
                if (GetForegroundWindow() == hwnd) return true;
                Thread.Sleep(30);
            }
            return false;
        }
        finally
        {
            if (attached) AttachThreadInput(me, fgThread, false);
        }
    }

    public static IntPtr GetFocusWindow()
    {
        GUITHREADINFO gti = new GUITHREADINFO();
        gti.cbSize = (uint)Marshal.SizeOf(typeof(GUITHREADINFO));
        if (GetGUIThreadInfo(0, ref gti))
        {
            if (gti.hwndFocus != IntPtr.Zero) return gti.hwndFocus;
            if (gti.hwndActive != IntPtr.Zero) return gti.hwndActive;
        }
        return GetForegroundWindow();
    }

    public static IntPtr WindowAt(int x, int y)
    {
        POINT p;
        p.X = x;
        p.Y = y;
        return WindowFromPoint(p);
    }

    public static IntPtr RootOf(IntPtr hwnd)
    {
        if (hwnd == IntPtr.Zero) return IntPtr.Zero;
        IntPtr root = GetAncestor(hwnd, (uint)GA_ROOT);
        return root == IntPtr.Zero ? hwnd : root;
    }

    public static IntPtr ChildAt(IntPtr hwnd, int screenX, int screenY)
    {
        if (hwnd == IntPtr.Zero) return IntPtr.Zero;
        POINT p;
        p.X = screenX;
        p.Y = screenY;
        if (!ScreenToClient(hwnd, ref p)) return hwnd;
        IntPtr child = ChildWindowFromPointEx(hwnd, p, 0x0001 | 0x0002);
        return child == IntPtr.Zero ? hwnd : child;
    }

    public static string WindowTitle(IntPtr hwnd)
    {
        int length = GetWindowTextLengthW(hwnd);
        if (length <= 0) return "";
        StringBuilder sb = new StringBuilder(length + 2);
        GetWindowTextW(hwnd, sb, sb.Capacity);
        return sb.ToString();
    }

    public static string WindowClass(IntPtr hwnd)
    {
        StringBuilder sb = new StringBuilder(512);
        GetClassNameW(hwnd, sb, sb.Capacity);
        return sb.ToString();
    }

    public static int WindowPid(IntPtr hwnd)
    {
        int pid;
        GetWindowThreadProcessId(hwnd, out pid);
        return pid;
    }

    public static int[] WindowRect(IntPtr hwnd)
    {
        RECT r;
        if (DwmGetWindowAttribute(hwnd, 9, out r, Marshal.SizeOf(typeof(RECT))) != 0)
        {
            if (!GetWindowRect(hwnd, out r)) return new int[] { 0, 0, 0, 0 };
        }
        return new int[] { r.Left, r.Top, r.Right - r.Left, r.Bottom - r.Top };
    }

    public static long WindowExStyle(IntPtr hwnd)
    {
        return (long)GetWindowLongPtrW(hwnd, -20);
    }

    public static IntPtr[] EnumTopWindows()
    {
        List<IntPtr> list = new List<IntPtr>();
        EnumWindows(delegate(IntPtr h, IntPtr l) { list.Add(h); return true; }, IntPtr.Zero);
        return list.ToArray();
    }

    public static void PostMouseClick(IntPtr hwnd, int x, int y, bool right, int count)
    {
        if (count < 1) count = 1;
        POINT p;
        p.X = x;
        p.Y = y;
        if (!ScreenToClient(hwnd, ref p)) throw new Exception("ScreenToClient failed");
        int lp = (p.Y << 16) | (p.X & 0xFFFF);
        uint down = right ? (uint)WM_RBUTTONDOWN : (uint)WM_LBUTTONDOWN;
        uint up = right ? (uint)WM_RBUTTONUP : (uint)WM_LBUTTONUP;
        uint dbl = right ? (uint)WM_RBUTTONDBLCLK : (uint)WM_LBUTTONDBLCLK;
        int mk = right ? MK_RBUTTON : MK_LBUTTON;
        PostMessage(hwnd, WM_MOUSEMOVE, IntPtr.Zero, new IntPtr(lp));
        Thread.Sleep(8);
        for (int i = 0; i < count; i++)
        {
            uint msg = (i == 1) ? dbl : down;
            if (!PostMessage(hwnd, msg, new IntPtr(mk), new IntPtr(lp))) throw new Exception("PostMessage down failed");
            Thread.Sleep(28);
            if (!PostMessage(hwnd, up, IntPtr.Zero, new IntPtr(lp))) throw new Exception("PostMessage up failed");
            Thread.Sleep(55);
        }
    }

    public static void PostMouseScroll(IntPtr hwnd, int x, int y, int delta)
    {
        int lp = (y << 16) | (x & 0xFFFF);
        int wp = (delta << 16);
        if (!PostMessage(hwnd, WM_MOUSEWHEEL, new IntPtr(wp), new IntPtr(lp))) throw new Exception("PostMessage wheel failed");
    }

    public static void PostMouseDrag(IntPtr hwnd, int x1, int y1, int x2, int y2, int steps)
    {
        if (steps < 2) steps = 2;
        POINT a;
        a.X = x1;
        a.Y = y1;
        if (!ScreenToClient(hwnd, ref a)) throw new Exception("ScreenToClient failed");
        int lp1 = (a.Y << 16) | (a.X & 0xFFFF);
        PostMessage(hwnd, WM_MOUSEMOVE, IntPtr.Zero, new IntPtr(lp1));
        PostMessage(hwnd, WM_LBUTTONDOWN, new IntPtr(MK_LBUTTON), new IntPtr(lp1));
        for (int i = 1; i <= steps; i++)
        {
            int sx = x1 + (x2 - x1) * i / steps;
            int sy = y1 + (y2 - y1) * i / steps;
            POINT p;
            p.X = sx;
            p.Y = sy;
            if (!ScreenToClient(hwnd, ref p)) continue;
            int lp = (p.Y << 16) | (p.X & 0xFFFF);
            PostMessage(hwnd, WM_MOUSEMOVE, new IntPtr(MK_LBUTTON), new IntPtr(lp));
            Thread.Sleep(16);
        }
        POINT b;
        b.X = x2;
        b.Y = y2;
        if (ScreenToClient(hwnd, ref b))
        {
            int lp2 = (b.Y << 16) | (b.X & 0xFFFF);
            PostMessage(hwnd, WM_LBUTTONUP, IntPtr.Zero, new IntPtr(lp2));
        }
    }

    public static void PostKey(IntPtr hwnd, int vk, bool down, bool extended, bool sys)
    {
        int scan = (int)MapVirtualKey((uint)vk, 0);
        int lParam = 1 | (scan << 16);
        if (extended) lParam |= (1 << 24);
        if (!down) lParam |= (1 << 30);
        if (!down) lParam |= unchecked((int)(1u << 31));
        uint msg = down ? (sys ? (uint)WM_SYSKEYDOWN : (uint)WM_KEYDOWN) : (sys ? (uint)WM_SYSKEYUP : (uint)WM_KEYUP);
        if (!PostMessage(hwnd, msg, new IntPtr(vk), new IntPtr(lParam))) throw new Exception("PostMessage key failed");
    }

    public static void PostText(IntPtr hwnd, string text)
    {
        foreach (char ch in text)
        {
            if (!PostMessage(hwnd, WM_CHAR, new IntPtr((int)ch), new IntPtr(1))) throw new Exception("PostMessage char failed");
            Thread.Sleep(2);
        }
    }

    public static string GetWindowText(IntPtr hwnd)
    {
        return WindowTitle(hwnd);
    }

    public static bool SetTextMessage(IntPtr hwnd, string text)
    {
        SendMessageW(hwnd, WM_SETTEXT, IntPtr.Zero, text);
        return true;
    }

    public static string CapturePng(string path, int x, int y, int w, int h)
    {
        if (w <= 0 || h <= 0)
        {
            x = GetSystemMetrics(SM_XVIRTUALSCREEN);
            y = GetSystemMetrics(SM_YVIRTUALSCREEN);
            w = GetSystemMetrics(SM_CXVIRTUALSCREEN);
            h = GetSystemMetrics(SM_CYVIRTUALSCREEN);
        }
        using (Bitmap bmp = new Bitmap(w, h, PixelFormat.Format32bppArgb))
        {
            using (Graphics g = Graphics.FromImage(bmp))
            {
                g.CopyFromScreen(x, y, 0, 0, new Size(w, h), CopyPixelOperation.SourceCopy);
            }
            bmp.Save(path, ImageFormat.Png);
        }
        return path;
    }

    [DllImport("user32.dll")]
    static extern bool PrintWindow(IntPtr hwnd, IntPtr hdcBlt, uint nFlags);

    // 虚拟屏幕（所有显示器合起来的边界）尺寸，单位就是截图用的物理像素
    public static int ScreenWidth() { return GetSystemMetrics(SM_CXVIRTUALSCREEN); }
    public static int ScreenHeight() { return GetSystemMetrics(SM_CYVIRTUALSCREEN); }

    // 截指定窗口，不管它在前台还是被别的窗口盖住。
    // 返回 usedPrintWindow=true 表示像素由 PrintWindow(PW_RENDERFULLCONTENT) 渲染，
    // 说明即使窗口被遮挡/最小化，图也是该窗口自己的内容；
    // false 表示 PrintWindow 失败、退回了屏幕拷贝——这时窗口必须真的可见，否则截到的是别的东西。
    public static string CaptureWindowPng(string path, long hwnd, out bool usedPrintWindow)
    {
        usedPrintWindow = false;
        IntPtr h = new IntPtr(hwnd);
        RECT r;
        if (!GetWindowRect(h, out r)) throw new Exception("GetWindowRect failed for hwnd " + hwnd);
        int w = r.Right - r.Left;
        int ht = r.Bottom - r.Top;
        if (w <= 0 || ht <= 0) throw new Exception("window has no visible size: " + w + "x" + ht);
        using (Bitmap bmp = new Bitmap(w, ht, PixelFormat.Format32bppArgb))
        {
            using (Graphics g = Graphics.FromImage(bmp))
            {
                IntPtr hdc = g.GetHdc();
                bool ok = false;
                try { ok = PrintWindow(h, hdc, 2); } catch { ok = false; }
                g.ReleaseHdc(hdc);
                usedPrintWindow = ok;
            }
            if (!usedPrintWindow)
            {
                using (Graphics g2 = Graphics.FromImage(bmp))
                {
                    g2.CopyFromScreen(r.Left, r.Top, 0, 0, new Size(w, ht), CopyPixelOperation.SourceCopy);
                }
            }
            bmp.Save(path, ImageFormat.Png);
        }
        return path;
    }

    // 客户区在屏幕上的位置与尺寸。GetClientRect + ClientToScreen 都不需要窗口激活，
    // 后台窗口也算得准（D016 / docs/design/COORDS.md 的「工件坐标系」原点就靠它）。
    public static int[] ClientRectInScreen(long hwnd)
    {
        IntPtr h = new IntPtr(hwnd);
        RECT rc;
        if (!GetClientRect(h, out rc)) throw new Exception("GetClientRect failed for hwnd " + hwnd);
        POINT p = new POINT(); p.X = 0; p.Y = 0;
        if (!ClientToScreen(h, ref p)) throw new Exception("ClientToScreen failed for hwnd " + hwnd);
        return new int[] { p.X, p.Y, rc.Right - rc.Left, rc.Bottom - rc.Top };
    }

    // 客户区坐标 → 屏幕坐标（供 click 的 frame:"client" 用）
    public static int[] ClientToScreenPoint(long hwnd, int cx, int cy)
    {
        IntPtr h = new IntPtr(hwnd);
        POINT p = new POINT(); p.X = cx; p.Y = cy;
        if (!ClientToScreen(h, ref p)) throw new Exception("ClientToScreen failed for hwnd " + hwnd);
        return new int[] { p.X, p.Y };
    }

    // 该窗口（含其根窗口）是不是当前前台
    public static bool IsForeground(long hwnd)
    {
        IntPtr h = new IntPtr(hwnd);
        try { return GetForegroundWindow() == RootOf(h); } catch { return false; }
    }
}

public static class DshOverlay
{
    static Thread thread = null;
    static OverlayForm form = null;
    static ManualResetEvent ready = new ManualResetEvent(false);
    static bool pausedState = false;
    static readonly Dictionary<string, Image> styleImages = new Dictionary<string, Image>(StringComparer.OrdinalIgnoreCase);
    public static bool LastSetWindowPosOk = false;
    public static int LastSetWindowPosError = 0;
    public static int LastX = 0;
    public static int LastY = 0;
    public static bool HasLast = false;
    // D019：主人显式要求隐藏时置位。只有它挡住 Ensure-CursorVisible 的自动复活；
    // 任何一次显式 Show（ShowAtCore）都会把它清掉，所以 move/click 之后光标照常出现。
    public static bool Suppressed = false;
    static string cursorStyle = "pointer";
    static string cursorMode = "companion";
    static int cursorHoldMs = 2600;
    static int cursorSize = 64;

    // ---- 时间线打点（第 0 轮可观测性）----
    // 只记"动作发生在哪/多久/什么种类"，不记文字内容：见 RULES.md「不做键盘记录器」。
    // C# 侧先攒内存，PowerShell 每个请求结束后 drain 一次落成 JSONL。
    // 评测判"光标常驻/缓动/气泡"靠的就是这些时间戳，不再靠截图。
    public struct TraceItem { public long ms; public string kind; public int x, y, dur; }
    static readonly List<TraceItem> traceBuf = new List<TraceItem>();
    static readonly object traceGate = new object();
    public static void AddTrace(string kind, int x, int y, int dur)
    {
        lock (traceGate)
        {
            traceBuf.Add(new TraceItem {
                ms = (long)(DateTime.UtcNow - new DateTime(1970, 1, 1)).TotalMilliseconds,
                kind = kind, x = x, y = y, dur = dur });
            if (traceBuf.Count > 4000) traceBuf.RemoveRange(0, traceBuf.Count - 4000);
        }
    }
    public static TraceItem[] DrainTrace()
    {
        lock (traceGate) { TraceItem[] a = traceBuf.ToArray(); traceBuf.Clear(); return a; }
    }

    // 面向主人的四句话，可以在设置里改（phrases.json）。
    // 只开放这四句：它们是你和这个工具"相处"的语气；其余提示都是给模型看的诊断，
    // 改文案等于改协议，不能让人随手改。
    static string phraseTakeover = "需要 physical：马上接管真实鼠标（Ctrl+Alt+Q 可暂停）";
    static string phraseWorking = "还在处理…（没卡住，可以继续等）";
    static string phraseMoving = "正在操作…";
    // 收工报告：不干活了主动说一句。这句是机制保证的（不进 idle 就必响），
    // 不依赖模型自觉——模型不知道「光标现在是不是看起来像挂了」。
    static string phraseIdle = "我这边空下来了，还有要做的就说";

    public static void SetPhrases(string takeover, string working, string moving)
    {
        SetPhrases(takeover, working, moving, null);
    }

    public static void SetPhrases(string takeover, string working, string moving, string idle)
    {
        if (!string.IsNullOrEmpty(takeover)) phraseTakeover = takeover;
        if (!string.IsNullOrEmpty(working)) phraseWorking = working;
        if (!string.IsNullOrEmpty(moving)) phraseMoving = moving;
        if (!string.IsNullOrEmpty(idle)) phraseIdle = idle;
    }

    // 接管前的这句可以带 {keys}，替换成这次要按的键（click 之类没有键，留空）
    public static string PhraseTakeover(string keys)
    {
        string k = string.IsNullOrEmpty(keys) ? "" : keys;
        return phraseTakeover.Replace("{keys}", k);
    }

    public static string PhraseWorking() { return phraseWorking; }
    public static string PhraseMoving() { return phraseMoving; }
    public static string PhraseIdle() { return phraseIdle; }

    static readonly string[] StyleNames = {
        "pointer", "work", "unavailiable", "link", "text",
        "cross", "busy", "move", "vert", "horz",
        "help", "handwriting", "dgn1", "dgn2", "alternate"
    };

    public static void ConfigureStyles(string assetDir)
    {
        styleImages.Clear();
        for (int i = 0; i < StyleNames.Length; i++)
        {
            string name = StyleNames[i];
            string path = System.IO.Path.Combine(assetDir, name + ".png");
            if (!System.IO.File.Exists(path)) continue;
            try { styleImages[name] = Image.FromFile(path); } catch { }
        }
    }

    public static void Start()
    {
        if (thread != null) return;
        thread = new Thread(ThreadProc);
        thread.IsBackground = true;
        thread.SetApartmentState(ApartmentState.STA);
        thread.Start();
        ready.WaitOne(5000);
    }

    static void ThreadProc()
    {
        try
        {
            Application.EnableVisualStyles();
            Application.SetUnhandledExceptionMode(UnhandledExceptionMode.CatchException);
            Application.ThreadException += delegate(object sender, ThreadExceptionEventArgs e)
            {
                try { Console.Error.WriteLine("overlay: " + e.Exception); } catch { }
            };
            AppDomain.CurrentDomain.UnhandledException += delegate(object sender, UnhandledExceptionEventArgs e)
            {
                try { Console.Error.WriteLine("overlay fatal: " + e.ExceptionObject); } catch { }
            };
            form = new OverlayForm();
            form.LoadSprites(styleImages);
            form.ApplyStyle(cursorStyle);
            form.Paused = pausedState;
            form.ApplyMode(cursorMode, cursorHoldMs);
            form.ApplySize(cursorSize);
            // D012：恢复位置发生在 form 创建之前时，这里补同步，保证首帧起点不是 (0,0)
            if (restorePending && HasLast) form.SyncLast(restoreX, restoreY);
            form.Location = new Point(-10000, -10000);
            form.Show();
            form.Hide();
            ready.Set();
            try { Application.Run(); }
            catch (Exception ex) { try { Console.Error.WriteLine("overlay run: " + ex); } catch { } }
        }
        catch { ready.Set(); }
    }

    static bool Run(Action action, int timeoutMs)
    {
        if (form == null) return false;
        try
        {
            using (ManualResetEvent done = new ManualResetEvent(false))
            {
                form.BeginInvoke(new Action(delegate() { try { action(); } finally { done.Set(); } }));
                return done.WaitOne(timeoutMs);
            }
        }
        catch { return false; }
    }

    // 每次移动都至少说一句：光标是主人在 DSH 窗口之外唯一看得见的线索。
    // 它动一下却不吭声，主人就分不清「它在想」还是「它死了」。
    // quietMs 内的发言不算数，避免每 200ms 挪一下就刷屏。
    public static void TalkIfQuiet(string msg, int quietMs)
    {
        if (form == null) return;
        long now = (DateTime.Now.Ticks / 10000);
        if (form.lastTalkAt > 0 && now - form.lastTalkAt < quietMs) return;
        try { ShowHeartbeat(msg); } catch { }
    }

    public static void ShowAt(int x, int y) { ShowAtCore(x, y, true); }

    // 不说话版：调用方紧接着要自己说一句（physical 预告），别让两句抢麦。
    public static void ShowAtQuiet(int x, int y) { ShowAtCore(x, y, false); }

    static void ShowAtCore(int x, int y, bool talk)
    {
        Suppressed = false;
        LastX = x;
        LastY = y;
        HasLast = true;
        AddTrace("cursor.show", x, y, 0);
        Start();
        Run(delegate() { form.DisplayAt(x, y); }, 900);
        if (talk) TalkIfQuiet(phraseMoving, 4000);
    }

    public static void MoveTo(int x, int y, int durationMs) { MoveToCore(x, y, durationMs, true); }

    // 不说话版：physical 预告用。滑过去之后再让调用方 ShowBadge，
    // 否则 TalkIfQuiet 的「正在操作…」会比缓动动画先冒出来。
    public static void MoveToQuiet(int x, int y, int durationMs) { MoveToCore(x, y, durationMs, false); }

    static void MoveToCore(int x, int y, int durationMs, bool talk)
    {
        if (!HasLast)
        {
            // 第一次出现：从主人的真实光标位置"长出来"，再走到目标，绝不凭空现身
            int sx = x, sy = y;
            try
            {
                int[] cp = DshInput.CursorPos();
                if (cp != null && cp.Length >= 2) { sx = cp[0]; sy = cp[1]; }
            }
            catch { }
            Start();
            Run(delegate() { form.DisplayAt(sx, sy); }, 900);
            DshOverlay.AddTrace("cursor.show", sx, sy, 0);
            HasLast = true;
            LastX = sx;
            LastY = sy;
            int dur = durationMs > 0 ? durationMs : 500;
            Run(delegate() { form.DisplayAtAnimated(x, y, dur); }, 4000);
            LastX = x;
            LastY = y;
            if (talk) TalkIfQuiet(phraseMoving, 4000);
            return;
        }
        LastX = x;
        LastY = y;
        Start();
        Run(delegate() { form.DisplayAtAnimated(x, y, durationMs); }, 4000);
        if (talk) TalkIfQuiet(phraseMoving, 4000);
    }

    // 迁移：把上次会话的光标位置接上（跨进程也能从原处继续走）
    public static void RestoreLast(int x, int y)
    {
        LastX = x;
        LastY = y;
        HasLast = true;
        // 注意：这里必须把恢复值单独存一份。LastX 是共享可变状态，下一次 MoveToCore
        // 进 Start() 之前就会把它改成目标点；overlay 线程如果启动得晚，补同步时读
        // LastX 会拿到目标位置而不是上次位置（D012 的第二次踩坑）。
        restoreX = x;
        restoreY = y;
        restorePending = true;
        // form 可能还没建好（overlay 线程异步启动）；建好时在 Run() 里补同步
        if (form != null) form.SyncLast(x, y);
    }

    // D012：恢复位置时 form 还没创建的情况，等它创建后补一刀（用 restoreX/Y 的原始值）
    static int restoreX = 0;
    static int restoreY = 0;
    static bool restorePending = false;

    static System.Windows.Forms.ToolTip badgeTip = null;
    // 当前气泡的到期时刻：holdMs 说得越久，心跳就越不能抢它的话。
    // （以前不记这个，overlay{text, holdMs:60000} 的文案会在 10 秒后被心跳顶掉。）
    static long BadgeUntil = 0;

    // 在 AI 光标上方弹一个小气泡，用来解释"我现在要按什么键"。
    // 纯键盘动作屏幕上没有手的痕迹，气泡就是那只手。
    public static void ShowBadge(string text, int holdMs)
    {
        if (form == null) return;
        string t = text ?? "";
        if (t.Length == 0) return;
        int hold = Math.Max(800, holdMs);
        form.lastTalkAt = (DateTime.Now.Ticks / 10000);
        BadgeUntil = form.lastTalkAt + hold;
        AddTrace("bubble.show", LastX, LastY, hold);
        Run(delegate()
        {
            if (!form.Visible && HasLast) form.DisplayAt(LastX, LastY);
            if (!form.Visible) return;
            if (badgeTip == null)
            {
                badgeTip = new System.Windows.Forms.ToolTip();
                badgeTip.InitialDelay = 0;
                badgeTip.ReshowDelay = 0;
                badgeTip.ShowAlways = true;
                badgeTip.UseFading = false;
                badgeTip.UseAnimation = false;
            }
            badgeTip.Show(t, form, 8, -32, hold);
        }, 600);
    }

    // 心跳气泡：忙但长时间没说话时由定时器调用，告诉主人「我还在，没死」。
    // 刻意做得很轻——不抢焦点、不改光标位置，只借已有 ToolTip 说一句。
    public static void ShowHeartbeat() { ShowHeartbeat(phraseWorking); }

    public static void ShowHeartbeat(string text) { ShowHeartbeat(text, 3000); }

    public static void ShowHeartbeat(string text, int holdMs)
    {
        if (form == null) return;
        string msg = string.IsNullOrEmpty(text) ? "还在处理…" : text;
        int hold = Math.Max(800, holdMs);
        // 记账放在 Run 外面：气泡有没有被真正画出来是 UI 线程的事，
        // 但"决定要说这句"是同步发生的，时间线必须记到这一下。
        form.lastTalkAt = (DateTime.Now.Ticks / 10000);
        BadgeUntil = form.lastTalkAt + hold;
        AddTrace("bubble.show", LastX, LastY, hold);
        Run(delegate()
        {
            // 以前这里直接 return：光标不可见就不说话。结果陪伴模式下光标本来就没点亮，
            // 于是一路"该说话的时候一句都没有"（D010）。现在先让它现身，再说。
            if (!form.Visible && HasLast) form.DisplayAt(LastX, LastY);
            if (!form.Visible) return;
            if (badgeTip == null)
            {
                badgeTip = new System.Windows.Forms.ToolTip();
                badgeTip.InitialDelay = 0;
                badgeTip.ReshowDelay = 0;
                badgeTip.ShowAlways = true;
                badgeTip.UseFading = false;
                badgeTip.UseAnimation = false;
            }
            badgeTip.Show(msg, form, 8, -32, hold);
        }, 800);
    }

    public static bool IsMoving { get { return form != null && form.IsMovingNow; } }

    public static bool IsBusy { get { return form != null && form.IsBusy; } }

    public static void SetBusyIdleMs(int ms)
    {
        if (form == null) return;
        Run(delegate() { form.SetBusyIdleMs(ms); }, 400);
    }

    public static void SetMode(string mode, int holdMs)
    {
        cursorMode = (mode == "clean") ? "clean" : "companion";
        cursorHoldMs = holdMs > 0 ? holdMs : 2600;
        if (form == null) return;
        Run(delegate() { form.ApplyMode(cursorMode, cursorHoldMs); }, 400);
    }

    public static void SetSize(int size)
    {
        cursorSize = Math.Max(24, Math.Min(192, size));
        if (form == null) return;
        Run(delegate() { form.ApplySize(cursorSize); }, 900);
    }

    public static void SetStyle(string style)
    {
        string key = string.IsNullOrEmpty(style) ? "pointer" : style.ToLowerInvariant();
        bool known = false;
        for (int i = 0; i < StyleNames.Length; i++) { if (StyleNames[i] == key) { known = true; break; } }
        cursorStyle = known ? key : "pointer";
        if (form == null) return;
        Run(delegate() { form.ApplyStyle(cursorStyle); }, 500);
    }

    public static void SetPaused(bool paused)
    {
        pausedState = paused;
        if (form == null) return;
        Run(delegate() { form.Paused = paused; }, 400);
    }

    // physical 期间让 AI 光标贴在真实光标右下角一起走：主人一眼能看出
    // "现在这只指针是 AI 在拽着走"，它自己并不占用系统输入。
    public static void FollowCursor(bool on)
    {
        Start();
        Run(delegate() { form.FollowCursorNow(on); }, 500);
    }

    public static void Hide()
    {
        // 抑制位必须先于 form 判空：新进程里 form 还没创建时也要记住"主人要求隐藏"，
        // 否则第一次 hide 会被静默吞掉，下个请求又把它点亮（D019 实测到的形态）。
        Suppressed = true;
        if (form == null) return;
        AddTrace("cursor.hide", LastX, LastY, 0);
        // 图标和气泡是两个窗口：只隐藏图标的话 ToolTip 会继续挂在屏幕上，
        // capture 想拍干净画面就拍不干净。
        // ToolTip 必须在 UI 线程上操作，从调用线程直接 Hide 会被静默吞掉。
        Run(delegate()
        {
            if (badgeTip != null) { try { badgeTip.Hide(form); badgeTip.SetToolTip(form, ""); } catch { } }
            form.HideNow();
        }, 900);
    }

    public static bool VisibleNow()
    {
        if (form == null) return false;
        try { return form.Visible; } catch { return false; }
    }

    public static int[] Bounds()
    {
        if (form == null) return new int[] { 0, 0, 0, 0 };
        try { return new int[] { form.Left, form.Top, form.Width, form.Height }; } catch { return new int[] { 0, 0, 0, 0 }; }
    }

    public static long HandleId()
    {
        if (form == null) return 0;
        try { return (long)form.Handle; } catch { return 0; }
    }

    public static void Stop()
    {
        if (form == null) return;
        Run(delegate() { form.HideNow(); Application.ExitThread(); }, 800);
    }

    sealed class OverlayForm : Form
    {
        const int Cell = 64;
        const int Cols = 8;
        readonly System.Windows.Forms.Timer animTimer;
        readonly System.Windows.Forms.Timer hideTimer;
        readonly System.Windows.Forms.Timer moveTimer;
        readonly System.Windows.Forms.Timer followTimer;
        bool following = false;
        int mvFromX, mvFromY, mvToX, mvToY, mvStart, mvDur, mvLastX, mvLastY;
        string mode = "companion";
        int holdMs = 2600;
        Image sprite;
        Dictionary<string, Image> sprites;
        string baseStyle = "pointer";
        int displaySize = 64;
        int lastX = 0;
        int lastY = 0;

        // D012：跨进程恢复时 DshOverlay.LastX 已经接上了上次的位置，但 form 自己的
        // lastX/lastY 还是 0 —— 于是新进程第一次 move 会从屏幕左上角起飞。
        // 恢复位置时必须把这两个字段一起同步，否则最后一帧的起点还是 (0,0)。
        public void SyncLast(int x, int y)
        {
            lastX = x;
            lastY = y;
        }
        int frame = 0;
        int frameCount = 1;
        bool paused = false;
        // busy 状态灯：动作期间 + 之后一段"余温"内图标原地呼吸，告诉主人"它还在干活"；
        // 余温耗尽自动停=收工。只改绘制，不碰窗口属性（Opacity 会和 TransparencyKey 互斥）。
        readonly System.Windows.Forms.Timer busyTimer;
        readonly System.Windows.Forms.Timer idleTimer;
        bool busy = false;
        double busyPhase = 0;
        int busyIdleMs = 45000;

        public OverlayForm()
        {
            FormBorderStyle = FormBorderStyle.None;
            ShowInTaskbar = false;
            TopMost = true;
            StartPosition = FormStartPosition.Manual;
            Size = new Size(displaySize, displaySize);
            BackColor = Color.Fuchsia;
            TransparencyKey = Color.Fuchsia;
            Visible = false;
            SetStyle(ControlStyles.SupportsTransparentBackColor | ControlStyles.AllPaintingInWmPaint | ControlStyles.UserPaint | ControlStyles.OptimizedDoubleBuffer, true);
            animTimer = new System.Windows.Forms.Timer();
            animTimer.Interval = 60;
            animTimer.Tick += delegate { if (frameCount > 1) { frame = (frame + 1) % frameCount; ApplyFrameRegion(); Invalidate(); } };
            hideTimer = new System.Windows.Forms.Timer();
            hideTimer.Tick += delegate { hideTimer.Stop(); HideNow(); };
            moveTimer = new System.Windows.Forms.Timer();
            moveTimer.Interval = 16;
            followTimer = new System.Windows.Forms.Timer();
            followTimer.Interval = 16;
            followTimer.Tick += delegate {
                if (!following) { followTimer.Stop(); return; }
                Point p = Cursor.Position;
                int fx = p.X + 14;
                int fy = p.Y + 14;
                if (fx != lastX || fy != lastY)
                {
                    lastX = fx; lastY = fy;
                    Location = new Point(fx, fy);
                    DshInput.SetWindowPos(Handle, DshInput.HWND_TOPMOST, fx, fy, displaySize, displaySize,
                        (uint)(DshInput.SWP_NOACTIVATE | DshInput.SWP_SHOWWINDOW));
                }
            };
            moveTimer.Tick += delegate {
                // 整个 Tick 包 try/catch：WinForms Timer 的 Tick 抛异常后 Timer 仍保持
                // Enabled，于是 IsMoving 永远为真，呼叫方的 while 会死循环——主循环是
                // 单线程同步的，一卡就再也不响应任何请求（含 pause/shutdown）。
                try {
                    int t = unchecked(Environment.TickCount - mvStart);
                    if (t < 0) { moveTimer.Stop(); return; } // TickCount 49.7 天回绕
                    double p = Math.Min(1.0, (double)t / mvDur);
                    double e = 1 - Math.Pow(1 - p, 3); // easeOutCubic：先快后慢，像手甩过去
                    int nx = mvFromX + (int)Math.Round((mvToX - mvFromX) * e);
                    int ny = mvFromY + (int)Math.Round((mvToY - mvFromY) * e);
                    if (nx != mvLastX || ny != mvLastY)
                    {
                        mvLastX = nx; mvLastY = ny;
                        Location = new Point(nx, ny);
                        DshInput.SetWindowPos(Handle, DshInput.HWND_TOPMOST, nx, ny, displaySize, displaySize,
                            (uint)(DshInput.SWP_NOACTIVATE | DshInput.SWP_SHOWWINDOW));
                    }
                    if (p >= 1.0)
                    {
                        moveTimer.Stop();
                        lastX = mvToX; lastY = mvToY;
                        DshOverlay.AddTrace("move.end", mvToX, mvToY, mvDur);
                        if (mode == "clean") { hideTimer.Interval = holdMs; hideTimer.Start(); }
                    }
                } catch { try { moveTimer.Stop(); } catch { } }
            };
            busyTimer = new System.Windows.Forms.Timer();
            busyTimer.Interval = 50;
            busyTimer.Tick += delegate {
                busyPhase += 0.11;
                if (busyPhase > 1000) busyPhase -= 1000;
                if (Visible) Invalidate();
                // 心跳：还在干活但已经 10 秒没吭声，就自己说一句，证明进程没死。
                // DSH 窗口不在前台时，这个光标是主人唯一能看见的线索；它一动不动
                // 又不说话，主人只能猜「是在想，还是挂了」。
                if (busy && Visible)
                {
                    long nowMs = (DateTime.Now.Ticks / 10000);
                    if (lastHeartbeatAt == 0) lastHeartbeatAt = nowMs;
                    if (nowMs - lastHeartbeatAt > 10000 && nowMs > DshOverlay.BadgeUntil)
                    {
                        lastHeartbeatAt = nowMs;
                        try { DshOverlay.ShowHeartbeat(); } catch { }
                    }
                }
            };
            idleTimer = new System.Windows.Forms.Timer();
            idleTimer.Tick += delegate { idleTimer.Stop(); SetBusy(false); };
        }

        public void SetBusyIdleMs(int ms) { busyIdleMs = ms > 0 ? Math.Min(600000, ms) : 45000; }

        // 上一次「说话」的时间（气泡），心跳靠它判断该不该吭声
        public long lastTalkAt = 0;
        // 上一次「心跳发言」的时间。必须和 lastTalkAt 分开：
        // 以前心跳拿 lastTalkAt 当基准，一启动就把它设成 now，
        // 结果紧接着的 move 被判成"刚说过话"，4 秒静默期内一句不说（D010）。
        public long lastHeartbeatAt = 0;

        public bool IsBusy { get { return busy; } }

        // 有任何动作就"充电"：亮起呼吸灯，并把收工计时器往后推。
        public void TouchActivity()
        {
            SetBusy(true);
            idleTimer.Stop();
            idleTimer.Interval = busyIdleMs;
            idleTimer.Start();
        }

        void SetBusy(bool on)
        {
            if (on == busy) return;
            busy = on;
            busyPhase = 0;
            if (on) busyTimer.Start(); else busyTimer.Stop();
            // 待命态只靠「说一句」表达，不碰窗口透明度：
            // 试过 Opacity=0.55，实测光标在屏幕上几乎消失（sprite 自身 alpha 只有
            // 71%，再乘 0.55 约 39%，叠在深色背景上就看不见了）。色键透明与 alpha
            // 本身是可以共存的（不是互斥），纯粹是"淡过头了"。这里不再用透明度表达状态。
            // 收工必须报告。这是机制保证的，不是模型自觉：
            // 模型不会知道「光标停在那里一声不吭，看起来像进程挂了」。
            if (!on)
            {
                // 光标从没显示过（HasLast=false）时别现身：lastX/lastY 还是 0，
                // 会在屏幕左上角莫名闪一下。这种情况只报告、不显示。
                if (!Visible && HasLast)
                {
                    // clean 模式下光标早就隐身了。收工这句必须让他看得见，否则
                    // "活干完了"这件事永远没人知道。先在上次位置现身，说完再收起。
                    try { Location = new Point(lastX, lastY); Visible = true; Invalidate(); } catch { }
                }
                try { DshOverlay.ShowHeartbeat(DshOverlay.PhraseIdle(), 9000); } catch { }
                if (mode == "clean") { try { hideTimer.Interval = 3000; hideTimer.Start(); } catch { } }
            }
            if (Visible) Invalidate();
        }

        public void ApplyMode(string m, int h)
        {
            mode = (m == "clean") ? "clean" : "companion";
            holdMs = h > 0 ? h : 2600;
            if (mode == "clean" && Visible)
            {
                hideTimer.Stop();
                hideTimer.Interval = holdMs;
                hideTimer.Start();
            }
            else
            {
                hideTimer.Stop();
            }
        }

        public void LoadSprites(Dictionary<string, Image> images)
        {
            sprites = images != null ? images : new Dictionary<string, Image>();
            if (!sprites.ContainsKey(baseStyle))
            {
                string first = null;
                foreach (string key in sprites.Keys) { first = key; break; }
                baseStyle = first != null ? first : "pointer";
            }
            if (sprites.ContainsKey(baseStyle)) ApplySprite(sprites[baseStyle]);
        }

        public void ApplyStyle(string style)
        {
            if (sprites == null || sprites.Count == 0) return;
            string key = string.IsNullOrEmpty(style) ? "pointer" : style.ToLowerInvariant();
            if (!sprites.ContainsKey(key)) key = sprites.ContainsKey("pointer") ? "pointer" : baseStyle;
            baseStyle = key;
            if (!paused && sprites.ContainsKey(key)) ApplySprite(sprites[key]);
        }

        void ApplySprite(Image img)
        {
            if (img == null) return;
            sprite = img;
            frame = 0;
            frameCount = Math.Max(1, (img.Width / Cell) * (img.Height / Cell));
            Invalidate();
        }

        public void ApplySize(int size)
        {
            size = Math.Max(24, Math.Min(192, size));
            if (size == displaySize && Width == size && Height == size) return;
            displaySize = size;
            Size = new Size(size, size);
            ApplySprite(sprite);
            if (Visible)
            {
                Location = new Point(lastX, lastY);
                DshInput.SetWindowPos(Handle, DshInput.HWND_TOPMOST, lastX, lastY, size, size,
                    (uint)(DshInput.SWP_NOACTIVATE | DshInput.SWP_SHOWWINDOW));
            }
        }

        void ApplyFrameRegion()
        {
            // color-key 透明方案不需要 Region；保留空方法避免大改调用点。
        }

        public bool Paused
        {
            get { return paused; }
            set
            {
                paused = value;
                if (sprites == null) return;
                if (paused && sprites.ContainsKey("unavailiable")) ApplySprite(sprites["unavailiable"]);
                else if (sprites.ContainsKey(baseStyle)) ApplySprite(sprites[baseStyle]);
            }
        }

        protected override bool ShowWithoutActivation { get { return true; } }

        protected override CreateParams CreateParams
        {
            get
            {
                CreateParams cp = base.CreateParams;
                cp.ExStyle |= 0x00000020; // WS_EX_TRANSPARENT
                cp.ExStyle |= 0x08000000; // WS_EX_NOACTIVATE
                cp.ExStyle |= 0x00000080; // WS_EX_TOOLWINDOW
                return cp;
            }
        }

        public void DisplayAt(int x, int y)
        {
            TouchActivity();
            // 素材热点是 (0,0)：箭头尖就是点击点，所以光标窗口左上角对准 (x,y)
            lastX = x;
            lastY = y;
            Location = new Point(x, y);
            if (!Visible) Show();
            TopMost = false;
            TopMost = true;
            BringToFront();
            bool ok = DshInput.SetWindowPos(Handle, DshInput.HWND_TOPMOST, x, y, displaySize, displaySize,
                (uint)(DshInput.SWP_NOACTIVATE | DshInput.SWP_SHOWWINDOW));
            DshOverlay.LastSetWindowPosOk = ok;
            DshOverlay.LastSetWindowPosError = Marshal.GetLastWin32Error();
            frame = 0;
            ApplyFrameRegion();
            animTimer.Start();
            hideTimer.Stop();
            if (mode == "clean")
            {
                hideTimer.Interval = holdMs;
                hideTimer.Start();
            }
            Invalidate();
            Update();
        }

        // 呼叫方用它等动画走完。这里必须自带时限：动画一旦因异常/TickCount 回绕
        // 没被 Stop，IsMoving 会永远为真，而主循环是单线程同步的，一卡就死。
        public bool IsMovingNow
        {
            get
            {
                if (!moveTimer.Enabled) return false;
                int t = unchecked(Environment.TickCount - mvStart);
                if (t < 0 || t > mvDur + 3000) { try { moveTimer.Stop(); } catch { } return false; }
                return true;
            }
        }

        // 从当前位置补间到 (x,y)：一次调用走完，不占用调用方的轮询。
        public void DisplayAtAnimated(int x, int y, int durationMs)
        {
            TouchActivity();
            if (durationMs <= 0)
            {
                DisplayAt(x, y);
                return;
            }
            if (!Visible)
            {
                // 先在上次停留的位置现身，再走过去；直接跳终点会显得"凭空冒出来"
                // 注意用 form 自己的 lastX（它记的才是"上次真正显示的位置"）；
                // 不能读 DshOverlay.LastX——MoveToCore 进这里前已把它改成目标点了。
                DisplayAt(lastX, lastY);
                DshOverlay.AddTrace("cursor.show", lastX, lastY, 0);
            }
            if (x == lastX && y == lastY)
            {
                DisplayAt(x, y);
                return;
            }
            if (!moveTimer.Enabled)
            {
                mvFromX = lastX; mvFromY = lastY;
            }
            else
            {
                mvFromX = mvLastX; mvFromY = mvLastY;
            }
            mvToX = x; mvToY = y;
            mvLastX = mvFromX; mvLastY = mvFromY;
            mvStart = Environment.TickCount;
            mvDur = durationMs;
            hideTimer.Stop();
            moveTimer.Stop();
            moveTimer.Start();
            DshOverlay.AddTrace("move.start", x, y, durationMs);
        }

        public void FollowCursorNow(bool on)
        {
            following = on;
            if (on)
            {
                TouchActivity();
                moveTimer.Stop();
                hideTimer.Stop();
                Point p = Cursor.Position;
                lastX = p.X + 14;
                lastY = p.Y + 14;
                if (!Visible) { Location = new Point(lastX, lastY); Show(); }
                TopMost = false;
                TopMost = true;
                DshInput.SetWindowPos(Handle, DshInput.HWND_TOPMOST, lastX, lastY, displaySize, displaySize,
                    (uint)(DshInput.SWP_NOACTIVATE | DshInput.SWP_SHOWWINDOW));
                followTimer.Start();
                Invalidate();
            }
            else
            {
                followTimer.Stop();
                HideNow();
            }
        }

        public void HideNow()
        {
            hideTimer.Stop();
            animTimer.Stop();
            Hide();
        }

        protected override void OnPaintBackground(PaintEventArgs e)
        {
            e.Graphics.Clear(BackColor);
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            if (sprite != null)
            {
                int col = frame % Cols;
                int row = frame / Cols;
                if (row * Cell + Cell <= sprite.Height)
                {
                    // busy：以中心为基准做 0~3px 呼吸缩放。肉眼能看出"它在动"，但几乎不占视线。
                    int inset = 0;
                    if (busy) { inset = (int)Math.Round(3.0 * (0.5 - 0.5 * Math.Cos(busyPhase))); }
                    e.Graphics.InterpolationMode = InterpolationMode.NearestNeighbor;
                    e.Graphics.PixelOffsetMode = PixelOffsetMode.Half;
                    e.Graphics.DrawImage(sprite, new Rectangle(inset, inset, displaySize - inset * 2, displaySize - inset * 2),
                        new Rectangle(col * Cell, row * Cell, Cell, Cell), GraphicsUnit.Pixel);
                    return;
                }
            }
            e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
            Color ring = Paused ? Color.Orange : Color.DeepSkyBlue;
            using (Pen pen = new Pen(ring, 3))
            {
                e.Graphics.DrawEllipse(pen, 8, 8, Width - 17, Height - 17);
            }
            using (SolidBrush dot = new SolidBrush(Color.White))
            {
                e.Graphics.FillEllipse(dot, Width / 2 - 3, Height / 2 - 3, 6, 6);
            }
        }
    }
}

'@

Add-Type -TypeDefinition $cs -ReferencedAssemblies $refs

# ---------------------------------------------------------------- UIA helpers

function Get-UiaElementAt([int]$x, [int]$y) {
  if (-not $script:uia) { return $null }
  try {
    $pt = [System.Windows.Point]::new([double]$x, [double]$y)
    return [System.Windows.Automation.AutomationElement]::FromPoint($pt)
  } catch { return $null }
}

function Get-UiaName($el) {
  try { return [string]$el.Current.Name } catch { return '' }
}

function Get-UiaType($el) {
  try { return [string]$el.Current.ControlType.ProgrammaticName } catch { return '' }
}

# 按定位器找元素：name / className / automationId / controlType / scope / hwnd。
# 存在性判断只看有没有找到，不关心它能不能点——waitFor 要的是"它出现了"。
function Find-UiaByLocator($loc) {
  if (-not $script:uia -or $null -eq $loc) { return $null }
  # ref 优先：observe 发出去的编号，直接查会话级句柄表，不重新遍历树。
  # 这是「抄编号」比「抄名字」稳的根本原因——名字会变，句柄不会。
  if ($null -ne $loc -and -not [string]::IsNullOrWhiteSpace([string]$loc.ref)) {
    return (Resolve-ObserveRef ([string]$loc.ref))
  }
  $root = $null
  if ($loc.hwnd) {
    try { $root = [System.Windows.Automation.AutomationElement]::FromHandle([IntPtr][long]$loc.hwnd) } catch { return $null }
  } else {
    try { $root = [System.Windows.Automation.AutomationElement]::RootElement } catch { return $null }
  }
  if ($null -eq $root) { return $null }
  $conds = New-Object System.Collections.ArrayList
  if ($loc.name) {
    [void]$conds.Add((New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::NameProperty, [string]$loc.name)))
  }
  if ($loc.className) {
    [void]$conds.Add((New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ClassNameProperty, [string]$loc.className)))
  }
  if ($loc.automationId) {
    [void]$conds.Add((New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::AutomationIdProperty, [string]$loc.automationId)))
  }
  if ($loc.controlType) {
    try {
      # ControlType.Button 这些是静态字段，不是属性——GetProperty 永远返回 null。
      $flags = [System.Reflection.BindingFlags]::Public -bor [System.Reflection.BindingFlags]::Static -bor [System.Reflection.BindingFlags]::IgnoreCase
      $field = [System.Windows.Automation.ControlType].GetField([string]$loc.controlType, $flags)
      if ($null -eq $field) { return $null }
      [void]$conds.Add((New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ControlTypeProperty, $field.GetValue($null))))
    } catch { return $null }
  }
  $cond = $null
  if ($conds.Count -eq 0) { $cond = [System.Windows.Automation.Condition]::TrueCondition }
  elseif ($conds.Count -eq 1) { $cond = $conds[0] }
  else { $cond = New-Object System.Windows.Automation.AndCondition ([System.Windows.Automation.Condition[]]$conds.ToArray()) }
  try {
    $scope = if ($loc.scope -eq 'children') { [System.Windows.Automation.TreeScope]::Children } else { [System.Windows.Automation.TreeScope]::Descendants }
    $hit = $root.FindFirst($scope, $cond)
    if ($null -ne $hit) { $script:lastLocatorMatch = 'exact'; return $hit }
  } catch { return $null }

  # 精确匹配没中时，如果给了 name，再试一次「包含匹配」。
  # 存在的理由：UI 里的名字常带动态前后缀——「子智能体」的真实名字是「查看 子智能体」，
  # 「鼠标插件功能展示」的真实名字是「进行中 鼠标插件功能展示 1分钟」。
  # 精确匹配一个都点不到，模型只能去截图抄全名，而那个全名下一分钟就变了。
  # 安全边界：**唯一命中才用**。命中多个就返回 null，把 ambiguous 记在 hint 里，
  # 让调用方报「名字不唯一」而不是赌一个。
  if (-not [string]::IsNullOrWhiteSpace([string]$loc.name)) {
    $needle = [string]$loc.name
    $wantType = $null
    if ($loc.controlType) { $wantType = 'ControlType.' + [string]$loc.controlType }
    # 注意：不能用 $matches —— 那是 PowerShell 的自动变量（-match 的结果），会被覆盖。
    $hits = New-Object System.Collections.ArrayList
    try {
      $all = $root.FindAll($scope, [System.Windows.Automation.Condition]::TrueCondition)
      foreach ($el2 in $all) {
        try {
          $nm2 = $el2.Current.Name
          if ([string]::IsNullOrWhiteSpace($nm2)) { continue }
          if ($nm2.IndexOf($needle, [System.StringComparison]::OrdinalIgnoreCase) -lt 0) { continue }
          if ($wantType) {
            if ($el2.Current.ControlType.ProgrammaticName -ne $wantType) { continue }
          }
          [void]$hits.Add($el2)
          if ($hits.Count -ge 4) { break }
        } catch { }
      }
    } catch { }
    if ($hits.Count -eq 1) { $script:lastLocatorMatch = 'contains'; return $hits[0] }
    if ($hits.Count -gt 1) {
      # 命中多个：不赌，但把候选报回去——模型看一眼就知道该把名字写多长，或者干脆用 ref。
      $script:lastLocatorMatch = 'ambiguous'
      $cands = New-Object System.Collections.ArrayList
      foreach ($h4 in $hits) {
        try {
          $nm4 = [string]$h4.Current.Name
          $ty4 = [string]$h4.Current.ControlType.ProgrammaticName.Replace('ControlType.', '')
          if ($nm4.Length -gt 40) { $nm4 = $nm4.Substring(0, 40) + '…' }
          [void]$cands.Add($nm4 + ' [' + $ty4 + ']')
        } catch { }
      }
      $script:lastLocatorCandidates = @($cands)
      return $null
    }
  }
  $script:lastLocatorMatch = 'miss'
  return $null
}

# 精确/包含/不唯一/没找到——调用方据此说明「这个名字是怎么命中的」。
function Get-LocatorMatchNote {
  $nm = [string]$script:lastLocatorMatch
  if ($nm -eq 'contains') { return '（名字是包含匹配到的：你要的名字只是真实名字的一部分，已自动放宽）' }
  if ($nm -eq 'ambiguous') { return '（这个名字能匹配到不止一个元素，没有赌，改用 ref 或更完整的名字）' }
  return ''
}

# 元素矩形与中心点：waitFor 必须把它带回去，调用方才能直接拿来点，省一次查找。
function Get-UiaRect($el) {
  if ($null -eq $el) { return $null }
  try {
    $r = $el.Current.BoundingRectangle
    if ($r.IsEmpty) { return $null }
    return @{
      x = [int]$r.X; y = [int]$r.Y; w = [int]$r.Width; h = [int]$r.Height
      cx = [int]($r.X + $r.Width / 2); cy = [int]($r.Y + $r.Height / 2)
    }
  } catch { return $null }
}

function Get-UiaIsPassword($el) {
  if ($null -eq $el) { return $false }
  try { return [bool]$el.Current.IsPassword } catch { return $false }
}

function Get-UiaClassName($el) {
  if ($null -eq $el) { return '' }
  try { return [string]$el.Current.ClassName } catch { return '' }
}

# 缓存属性读取：元素不支持某个属性时返回默认值，不炸掉整轮遍历。
function Get-CachedStr($el, $prop) {
  try { return [string]$el.GetCachedPropertyValue($prop) } catch { return '' }
}
function Get-CachedBool($el, $prop) {
  try { return [bool]$el.GetCachedPropertyValue($prop) } catch { return $false }
}

# observe 的会话级句柄表：ref -> AutomationElement。
# sidecar 是常驻进程，UIA 元素对象可以直接留着用，动作时不需要再按名字找一遍。
# 这正是「索引化寻址」的关键：模型抄编号，工具自己知道编号指向哪个元素。
if ($null -eq $script:observeMap) { $script:observeMap = @{} }
if ($null -eq $script:observeSeq) { $script:observeSeq = 0 }
if ($null -eq $script:lastLocatorMatch) { $script:lastLocatorMatch = '' }
if ($null -eq $script:lastLocatorCandidates) { $script:lastLocatorCandidates = @() }

# 给元素提炼一个语义角色。
# 判定思路移植自 browser-use 的 ClickableElementDetector.is_interactive
# （MIT License, Copyright (c) 2024 Gregor Zunic），这里只取与「认得出、说得清」
# 最相关的几条：搜索类信号 + 控件类型映射。
function Get-ObserveRole($type, $name, $className, $aid) {
  $sig = ([string]$className + ' ' + [string]$aid + ' ' + [string]$name).ToLower()
  # 搜索类信号：网页搜索框的 className 往往是 nav-search-input / search-btn 这种，
  # 而它的 Name 是当前输入内容（不可靠）。靠 class 里的词认它最稳。
  if ($sig -match 'search|magnify|glass|lookup|query|searchbox') { return 'searchbox' }
  switch ($type) {
    'Edit' { return 'textbox' }
    'Document' { return 'textbox' }
    'Button' { return 'button' }
    'TabItem' { return 'tab' }
    'ListItem' { return 'listitem' }
    'TreeItem' { return 'listitem' }
    'MenuItem' { return 'menuitem' }
    'CheckBox' { return 'checkbox' }
    'RadioButton' { return 'radio' }
    'ComboBox' { return 'combobox' }
    'Slider' { return 'slider' }
    'Spinner' { return 'spinbutton' }
    'Hyperlink' { return 'link' }
    'Image' { return 'image' }
    'Text' { return 'text' }
  }
  return ''
}

# 按 ref 取回元素；元素已失效时抛异常，由调用方转成 stale。
function Resolve-ObserveRef([string]$ref) {
  $key = ([string]$ref).Trim().TrimStart('[').TrimEnd(']')
  if (-not $script:observeMap.ContainsKey($key)) { return $null }
  $el = $script:observeMap[$key]
  try { $null = $el.Current.Name; return $el } catch { return $null }
}

# 元素属于哪个顶层窗口。
# 用 ref（编号）定位时请求里没有 hwnd，但 click/type 拿不到 hwnd 就不肯动
# （防止点到主人正在用的窗口）。所以沿 ControlView 向上找第一个有 NativeWindowHandle 的祖先。
function Get-ElementWindowHwnd($el) {
  if ($null -eq $el) { return 0 }
  $cur = $el
  for ($i = 0; $i -lt 16 -and $null -ne $cur; $i++) {
    try {
      $h = [int]$cur.Current.NativeWindowHandle
      if ($h -ne 0) { return $h }
    }
    catch { return 0 }
    try { $cur = [System.Windows.Automation.TreeWalker]::ControlViewWalker.GetParent($cur) }
    catch { return 0 }
  }
  return 0
}

# ---------------------------------------------------------------- observe
# 一次遍历把窗口里「能操作的控件」列成结构化文本，代替截图：
# 模型不看图就知道能点什么、输入框在哪、谁有焦点、当前值是什么。
# 用 CacheRequest 把属性一次取回（实测 186ms vs 逐元素 416ms）。
function Invoke-Observe($req) {
  if (-not $script:uia) { return @{ ok = $false; reason = 'uia-unavailable'; note = 'UIA 没初始化' } }
  $AE = [System.Windows.Automation.AutomationElement]
  $hwnd = 0
  if ($null -ne $req.hwnd) { $hwnd = [long]$req.hwnd }
  $maxItems = 60
  if ($null -ne $req.max) { $maxItems = [Math]::Max(1, [Math]::Min(200, [int]$req.max)) }
  $filter = ''
  if ($null -ne $req.filter) { $filter = [string]$req.filter }
  $root = $null
  if ($hwnd -gt 0) {
    try { $root = $AE::FromHandle([IntPtr]$hwnd) } catch { $root = $null }
  } else {
    try { $root = $AE::RootElement } catch { $root = $null }
  }
  if ($null -eq $root) { return @{ ok = $false; reason = 'window-not-found'; hwnd = $hwnd } }

  $title = ''
  $cls = ''
  try { $title = [string]$root.Current.Name } catch { }
  try { $cls = [string]$root.Current.ClassName } catch { }

  $creq = New-Object System.Windows.Automation.CacheRequest
  $want = @(
    $AE::NameProperty, $AE::ClassNameProperty, $AE::ControlTypeProperty,
    $AE::BoundingRectangleProperty, $AE::AutomationIdProperty,
    $AE::IsOffscreenProperty, $AE::IsEnabledProperty, $AE::HasKeyboardFocusProperty,
    $AE::IsInvokePatternAvailableProperty, $AE::IsTogglePatternAvailableProperty,
    $AE::IsSelectionItemPatternAvailableProperty, $AE::IsValuePatternAvailableProperty,
    $AE::IsExpandCollapsePatternAvailableProperty, $AE::IsRangeValuePatternAvailableProperty,
    $AE::IsScrollPatternAvailableProperty
  )
  foreach ($p in $want) { [void]$creq.Add($p) }
  $creq.TreeFilter = [System.Windows.Automation.Automation]::ControlViewCondition

  $items = New-Object System.Collections.ArrayList
  $seen = @{}
  $total = 0
  $creq.Push()
  try {
    $all = $root.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)
    $total = $all.Count
    $scan = [Math]::Min($total, 4000)
    for ($i = 0; $i -lt $scan; $i++) {
      if ($items.Count -ge $maxItems) { break }
      $el = $all.Item($i)
      try {
        if (Get-CachedBool $el $AE::IsOffscreenProperty) { continue }
        $ct = ''
        try { $ct = [string]$el.GetCachedPropertyValue($AE::ControlTypeProperty).ProgrammaticName } catch { }
        $type = $ct -replace '^ControlType\.', ''
        $nm = Get-CachedStr $el $AE::NameProperty
        $aid = Get-CachedStr $el $AE::AutomationIdProperty
        $cc = Get-CachedStr $el $AE::ClassNameProperty
        $roles = New-Object System.Collections.ArrayList
        if (Get-CachedBool $el $AE::IsInvokePatternAvailableProperty) { [void]$roles.Add('可点') }
        if (Get-CachedBool $el $AE::IsTogglePatternAvailableProperty) { [void]$roles.Add('可切换') }
        if (Get-CachedBool $el $AE::IsSelectionItemPatternAvailableProperty) { [void]$roles.Add('可选') }
        if (Get-CachedBool $el $AE::IsValuePatternAvailableProperty) { [void]$roles.Add('可输入') }
        if (Get-CachedBool $el $AE::IsExpandCollapsePatternAvailableProperty) { [void]$roles.Add('可展开') }
        if (Get-CachedBool $el $AE::IsRangeValuePatternAvailableProperty) { [void]$roles.Add('可拖') }
        if (Get-CachedBool $el $AE::IsScrollPatternAvailableProperty) { [void]$roles.Add('可滚') }
        if ($roles.Count -eq 0) {
          # 有些控件不暴露模式，但类型本身可输入（Chromium 的编辑框常见）
          if ($type -eq 'Edit' -or $type -eq 'Document' -or $type -eq 'ComboBox' -or $type -eq 'Spinner') { [void]$roles.Add('可输入') }
          else { continue }
        }
        $r = $null
        try { $r = $el.GetCachedPropertyValue($AE::BoundingRectangleProperty) } catch { $r = $null }
        if ($null -eq $r -or $r.IsEmpty) { continue }
        if ($r.Width -le 0 -or $r.Height -le 0) { continue }
        $label = $nm
        if ([string]::IsNullOrWhiteSpace($label)) { $label = $aid }
        if ([string]::IsNullOrWhiteSpace($label)) { $label = $cc }
        if ([string]::IsNullOrWhiteSpace($label)) { $label = $type }
        if ($filter -and ($label -notmatch $filter)) { continue }
        # 去重：同位置同尺寸同名字的重复元素只留一个。
        # Chromium 的可访问树里经常「一个按钮被 Group 和 Button 各报一次」，
        # 全部列出来会让模型面对两条一样的选择，还要自己赌哪条能点。
        $dupKey = ([int]$r.X).ToString() + ',' + ([int]$r.Y).ToString() + ',' + ([int]$r.Width).ToString() + ',' + ([int]$r.Height).ToString() + ',' + $nm
        if ($seen.ContainsKey($dupKey)) { continue }
        $seen[$dupKey] = $true
        $script:observeSeq++
        $ref = 'e' + $script:observeSeq
        $script:observeMap[$ref] = $el
        [void]$items.Add(@{
          ref = $ref
          role = (Get-ObserveRole $type $label $cc $aid)
          type = $type
          name = $label
          className = $cc
          cx = [int]($r.X + $r.Width / 2)
          cy = [int]($r.Y + $r.Height / 2)
          w = [int]$r.Width
          h = [int]$r.Height
          roles = ($roles -join '·')
          focused = (Get-CachedBool $el $AE::HasKeyboardFocusProperty)
          enabled = (Get-CachedBool $el $AE::IsEnabledProperty)
        })
      } catch { }
    }
  } catch {
    $msg = $_.Exception.Message
    try { $creq.Pop() } catch { }
    return @{ ok = $false; reason = 'enum-failed'; note = $msg }
  }
  try { $creq.Pop() } catch { }

  return @{
    ok = $true
    hwnd = $hwnd
    title = $title
    className = $cls
    total = $total
    shown = $items.Count
    truncated = ($total -gt $maxItems)
    items = $items
  }
}

# ---------------------------------------------------------------- act 批量
# 一次调用执行多步：模型一次性给出完整计划，工具逐步执行、每步自校验，
# 失败即停并把「停在哪一步、当时界面什么样」带回去。
# 目的是把「走一步想一步」压成「想清楚全部，一口气做完」。
function Get-ActState {
  $fg = [IntPtr]::Zero
  try { $fg = [DshInput]::GetForegroundWindow() } catch { }
  $title = ''
  if ($fg -ne [IntPtr]::Zero) { try { $title = [DshInput]::GetWindowText($fg) } catch { } }
  $fn = ''
  $ft = ''
  if ($script:uia) {
    try {
      $foc = [System.Windows.Automation.AutomationElement]::FocusedElement
      if ($null -ne $foc) { $fn = Get-UiaName $foc; $ft = Get-UiaType $foc }
    } catch { }
  }
  # 刻意不从窗口标题里解析标签页数：实测标题里的「和另外 N 个页面」与标签栏实际数量不符
  # （Edge 垂直标签栏场景下恒少 2）。给错的证据比不给更糟——模型会据此误判，
  # 实测它因此不敢信返回值、反而退回去截图确认。
  # 注意：「少 2」是恒定偏移，所以 N 的**变化**仍然可信（1 → 2 就是多开了一个标签），
  # 模型从标题变化里读这个就够了，不需要再给一个绝对数字。
  return @{ title = $title; focusName = $fn; focusType = $ft }
}

# 标签页数量：试过两种算法都不准，**已放弃**（不要复活它）。
#   1) 解析窗口标题的「和另外 N 个页面」→ 实测比标签栏实际数量恒少 2；
#   2) 数 UIA 里的 TabItem（加位置过滤后仍然）→ 这台机器上同样少算。
# 给错的证据比不给更糟：模型会据错误数字误判「误开了标签」，然后退回去截图确认。
# 需要判断标签是否增减时，直接看窗口标题里「和另外 N 个页面」的 N 有没有变——它本身不可靠，
# 但「变了」这个事实是可靠的。

# 比对两步之间的可观测变化，给 act 的每一步当「效果证据」。
# 这是 act 的返回值能自证的关键：模型不必再自己调 windows/observe 去验证。
# 只放**可靠**的信号：窗口标题、焦点。不可靠的一律不报（宁缺勿错）。
function Get-ActChanges($before, $after) {
  $c = New-Object System.Collections.ArrayList
  if ($before.title -ne $after.title) {
    [void]$c.Add("窗口标题变了：「$($before.title)」→「$($after.title)」")
  }
  if ($before.focusName -ne $after.focusName -or $before.focusType -ne $after.focusType) {
    $b = if ([string]::IsNullOrEmpty($before.focusName) -and [string]::IsNullOrEmpty($before.focusType)) { '（无）' } else { "$($before.focusType)「$($before.focusName)」" }
    $a = if ([string]::IsNullOrEmpty($after.focusName) -and [string]::IsNullOrEmpty($after.focusType)) { '（无）' } else { "$($after.focusType)「$($after.focusName)」" }
    [void]$c.Add("焦点：$b → $a")
  }
  return $c
}

# 校验一步的 expect；没写 expect 就跳过（checked=false）
function Test-ActExpect($step, $result, $before, $after) {
  $expect = $step.expect
  if ($null -eq $expect) { return @{ ok = $true; checked = $false; checks = @() } }
  $checks = New-Object System.Collections.ArrayList
  $allOk = $true

  if ($null -ne $expect.focus) {
    $want = [string]$expect.focus
    $hit = ($after.focusName -like "*$want*") -or ($after.focusType -like "*$want*")
    # Chromium 网页内部的焦点不以 UIA 元素的形式暴露，常报成整页的 Document。
    # 这种情况判不了，按通过处理并说明——判不了就说判不了，不能当成失败（实测误报过）。
    if (-not $hit -and $after.focusType -like '*Document*') {
      [void]$checks.Add(@{ name = 'focus'; ok = $true; got = '网页（Document）：UIA 看不到网页内部的焦点，这条判不了，按通过算' })
    } else {
      [void]$checks.Add(@{ name = 'focus'; ok = $hit; got = ($after.focusType + '「' + $after.focusName + '」') })
      if (-not $hit) { $allOk = $false }
    }
  }
  if ($null -ne $expect.titleChange) {
    $hit = ($before.title -ne $after.title)
    $got = $after.title
    # Chromium 的导航是异步的：enter 之后标题往往要几百毫秒到两秒才变。
    # 只比一次就会把「动作成功、标题还没变」判成失败（实测过：动作没问题，校验误报）。
    if (-not $hit) {
      $tHwnd = [IntPtr]::Zero
      if ($null -ne $step.hwnd) { try { $tHwnd = [IntPtr][long]$step.hwnd } catch { } }
      $deadline = [DateTime]::UtcNow.AddMilliseconds(3000)
      while ([DateTime]::UtcNow -lt $deadline) {
        Start-Sleep -Milliseconds 120
        $w = $tHwnd
        if ($w -eq [IntPtr]::Zero) { try { $w = [DshInput]::GetForegroundWindow() } catch { } }
        $t2 = ''
        if ($w -ne [IntPtr]::Zero) { try { $t2 = [DshInput]::GetWindowText($w) } catch { } }
        if (-not [string]::IsNullOrEmpty($t2) -and $t2 -ne $before.title) { $hit = $true; $got = $t2; break }
      }
    }
    [void]$checks.Add(@{ name = 'titleChange'; ok = $hit; got = $got })
    if (-not $hit) { $allOk = $false }
  }
  if ($null -ne $expect.value) {
    $want = [string]$expect.value
    $el = $null
    $got = ''
    if ($step.locator) { $el = Find-UiaByLocator $step.locator }
    if ($null -ne $el) { $got = Get-UiaTextFromElement $el }
    # 读不到时退回动作自己的读回值：Chromium 地址栏不暴露 ValuePattern，
    # 但 type 自己已经读回写入结果，不退回就会把「已经写进去了」误判成失败。
    if ([string]::IsNullOrEmpty($got) -and $null -ne $result -and $null -ne $result.value) { $got = [string]$result.value }
    if ([string]::IsNullOrEmpty($got) -and $null -eq $el) {
      [void]$checks.Add(@{ name = 'value'; ok = $false; got = '（locator 没找到元素，动作本身也没有读回值）'; want = $want })
      $allOk = $false
    } else {
      $hit = ($got -eq $want)
      [void]$checks.Add(@{ name = 'value'; ok = $hit; got = $got; want = $want })
      if (-not $hit) { $allOk = $false }
    }
  }
  if ($null -ne $expect.exists) {
    $el = Find-UiaByLocator $expect.exists
    # 点完之后目标往往要几百毫秒才渲染出来（页面切换、列表懒加载）。
    # 只查一次会把「动作对了、界面还没画完」判成失败（实测过：点插件后立刻查「子智能体」，报空）。
    if ($null -eq $el) {
      $deadlineE = [DateTime]::UtcNow.AddMilliseconds(3000)
      while ([DateTime]::UtcNow -lt $deadlineE) {
        Start-Sleep -Milliseconds 150
        $el = Find-UiaByLocator $expect.exists
        if ($null -ne $el) { break }
      }
    }
    $hit = ($null -ne $el)
    [void]$checks.Add(@{ name = 'exists'; ok = $hit })
    if (-not $hit) { $allOk = $false }
  }
  if ($null -ne $expect.gone) {
    $el = Find-UiaByLocator $expect.gone
    # 同理：消失也可能是异步的（关面板、切页），给它一点时间。
    if ($null -ne $el) {
      $deadlineG = [DateTime]::UtcNow.AddMilliseconds(3000)
      while ([DateTime]::UtcNow -lt $deadlineG) {
        Start-Sleep -Milliseconds 150
        $el = Find-UiaByLocator $expect.gone
        if ($null -eq $el) { break }
      }
    }
    $hit = ($null -eq $el)
    [void]$checks.Add(@{ name = 'gone'; ok = $hit })
    if (-not $hit) { $allOk = $false }
  }
  return @{ ok = $allOk; checked = $true; checks = $checks }
}

function Invoke-Act($req) {
  $steps = @($req.steps)
  if ($steps.Count -eq 0) { return @{ ok = $false; reason = 'no-steps'; note = 'act 需要 steps 数组' } }
  if ($steps.Count -gt 40) { return @{ ok = $false; reason = 'too-many-steps'; note = '一次最多 40 步' } }
  $stopOnError = if ($null -ne $req.stopOnError) { [bool]$req.stopOnError } else { $true }
  $baseHwnd = if ($null -ne $req.hwnd) { [long]$req.hwnd } else { 0 }
  $actStartTitle = ''
  $actStartState = $null
  if ($baseHwnd -gt 0) { try { $actStartTitle = [DshInput]::GetWindowText([IntPtr]$baseHwnd) } catch { } }
  try { $actStartState = Get-ActState } catch { }
  $out = New-Object System.Collections.ArrayList
  $failedAt = 0
  $failedCount = 0
  $firstFailedAt = 0
  $failure = $null

  for ($i = 0; $i -lt $steps.Count; $i++) {
    $step = $steps[$i]
    $do = [string]$step.do
    $entry = @{ i = $i + 1; do = $do; ok = $false }
    if ([string]::IsNullOrWhiteSpace($do)) {
      $entry.reason = 'no-do'
      [void]$out.Add($entry)
      $failedCount++
      $failedAt = $i + 1; $failure = $entry; break
    }
    $sub = @{ cmd = $do }
    foreach ($k in @('x','y','text','keys','locator','mode','hwnd','replace','button','count','delta','toX','toY','timeoutMs','pollMs','durationMs','label','takeoverGraceMs','holdAfterTypingMs','restoreCursor')) {
      $v = $step."$k"
      if ($null -ne $v) { $sub[$k] = $v }
    }
    if ($null -eq $sub['hwnd'] -and $baseHwnd -gt 0) { $sub['hwnd'] = $baseHwnd }
    if ($do -eq 'waitFor' -and $null -ne $step.'waitMode') { $sub['mode'] = $step.'waitMode' }

    # waitFor titleChange 的「已经变过了」短路：如果标题在 act 里更早的步骤就变了，
    # 这一步的基线是「变化之后」的标题，正常会一路等到超时（实测白等 8 秒）。
    # 用户的本意是「确认它变了」，所以当场通过。
    if ($do -eq 'waitFor' -and $step.'waitMode' -eq 'titleChange' -and $actStartTitle -ne '') {
      $hwForTitle = if ($null -ne $sub['hwnd']) { [long]$sub['hwnd'] } else { 0 }
      if ($hwForTitle -gt 0) {
        $titleNowT = ''
        try { $titleNowT = [DshInput]::GetWindowText([IntPtr]$hwForTitle) } catch { }
        if ($titleNowT -ne '' -and $titleNowT -ne $actStartTitle) {
          [void]$out.Add(@{ i = $i + 1; do = 'waitFor'; ok = $true; via = 'already-changed'; waitedMs = 0; ms = 0; title = $titleNowT
            note = "标题在这步之前就已经变了（「$actStartTitle」→「$titleNowT」），立刻通过" })
          continue
        }
      }
    }

    $before = Get-ActState
    $stepSw = [System.Diagnostics.Stopwatch]::StartNew()
    $r = $null
    # 子请求必须传 PSCustomObject：hashtable 的 .Keys 是内置属性，会盖掉自定义的 keys 键，
    # 让 key 步骤收到 "hwnd cmd" 这种假按键名。
    try { $r = Invoke-RequestCore ([pscustomobject]$sub) } catch { $r = @{ ok = $false; reason = 'exception'; note = $_.Exception.Message } }
    $stepSw.Stop()
    $after = Get-ActState
    # 有界等待：动作刚投递时界面常常还没反应过来，立刻取状态会把「慢」误判成「没生效」。
    # 只对动作类步骤、且确实还没看到任何变化时补等，最多约 0.75 秒，一变就停。
    # 这是「把 sleep 从模型手里拿走」的那一步：模型不用自己再调 windows 确认。
    if ($r -is [hashtable] -and $r['ok'] -eq $true -and @('click', 'type', 'key', 'scroll', 'drag') -contains $do) {
      $sameNow = ($before.title -eq $after.title) -and ($before.focusName -eq $after.focusName) -and ($before.focusType -eq $after.focusType)
      if ($sameNow) {
        for ($wt = 0; $wt -lt 3; $wt++) {
          Start-Sleep -Milliseconds 250
          $probe = Get-ActState
          if ($probe.title -ne $after.title -or $probe.focusName -ne $after.focusName -or $probe.focusType -ne $after.focusType) { $after = $probe; break }
        }
      }
    }
    # waitFor titleChange 的容忍：如果标题在 act 里更早的步骤就已经变了，这步的基线是「变化之后」
    # 的标题，会一路等到超时。用户写它的本意是「确认变了」，所以按通过算并说清楚。
    if ($r -is [hashtable] -and $r['reason'] -eq 'wait-timeout' -and $r['mode'] -eq 'titleChange' -and $actStartTitle -ne '' -and $after.title -ne '' -and $after.title -ne $actStartTitle) {
      $r['ok'] = $true
      $r['note'] = "标题在这步之前就已经变了（「$actStartTitle」→「$($after.title)」），按通过算"
      $r['title'] = $after.title
    }

    if ($null -ne $r -and $r.ok -eq $true) { $entry.ok = $true }
    if ($null -ne $r) {
      foreach ($k in @('reason','note','via','chars','found','title','value','waitedMs','x','y')) {
        if ($null -ne $r[$k]) { $entry[$k] = $r[$k] }
      }
    }
    $chk = Test-ActExpect $step $r $before $after
    $entry['checked'] = $chk.checked
    if ($chk.checked) {
      $entry['checks'] = $chk.checks
      if (-not $chk.ok) {
        $bad = @($chk.checks | Where-Object { -not $_.ok } | ForEach-Object { $_.name }) -join '、'
        $entry.ok = $false
        if (-not $entry['reason']) { $entry['reason'] = 'expect-failed' }
        $entry['note'] = "动作执行了，但结果不符合 expect（$bad）。当前：" + (($chk.checks | Where-Object { -not $_.ok } | ForEach-Object { $_.got }) -join ' / ')
      }
    }
    $entry['ms'] = [int]$stepSw.ElapsedMilliseconds
    $entry['stateAfter'] = $after
    # 效果见证（三值）。这是「工具不许撒谎」的核心：
    #   effective —— 找到了独立于「调用返回成功」的见证（标题/焦点真的变了）
    #   no_effect —— 有明确的期望却没达成（expect 失败）
    #   unknown   —— 没看到变化，但也不知道是「本来就没副作用」还是「没作用到目标上」
    # 默认 unknown，绝不把「动作已投递」冒充成「结果已发生」。
    $chg = @()
    try { $chg = @(Get-ActChanges $before $after) } catch { $chg = @() }
    $chan = @()
    try {
      if ($before.title -ne $after.title) { $chan += 'title' }
      if ($before.focusName -ne $after.focusName -or $before.focusType -ne $after.focusType) { $chan += 'focus' }
    } catch { }
    if ($chg.Count -gt 0) {
      $entry['changes'] = $chg
      $entry['outcome'] = 'effective'
      $entry['witness'] = @{ channel = ($chan -join '+'); changed = $true }
    } elseif ($entry.ok -eq $true) {
      $entry['outcome'] = 'unknown'
      $entry['witness'] = @{ channel = 'none'; changed = $false }
      if (@('click', 'type', 'key', 'scroll', 'drag') -contains $do) {
        $entry['note'] = '动作已投递，但窗口级的见证里没看到变化（标题、焦点都没动）。如果这一步要的是页面内部的效果（网页里的输入框、页面内的按钮），这是正常的；如果要的是切窗口/开标签/改标题，那多半没生效'
      }
    } else {
      $entry['outcome'] = 'no_effect'
      $entry['witness'] = @{ channel = 'none'; changed = $false }
    }
    [void]$out.Add($entry)

    if (-not $entry.ok) {
      $failedCount++
      if ($firstFailedAt -eq 0) { $firstFailedAt = $i + 1; $failure = $entry }
      if ($stopOnError) { $failedAt = $i + 1; break }
    }
    if ($entry['reason'] -eq 'paused' -or $entry['reason'] -eq 'user-takeover' -or $entry['reason'] -eq 'takeover-limit') { $failedAt = $i + 1; break }
  }

  $firstAt = if ($failedAt -gt 0) { $failedAt } else { $firstFailedAt }
  $note = if ($failedCount -eq 0) {
    "全部 $($out.Count) 步完成"
  } elseif ($failedAt -gt 0) {
    "第 $failedAt 步失败，后面没执行"
  } else {
    "$($out.Count) 步里有 $failedCount 步失败（stopOnError=false，后面照跑了）"
  }

  # act 整体的副作用：开头状态 vs 结束时状态（只比可靠信号：窗口标题、焦点）。
  $side = @()
  if ($null -ne $actStartState) {
    $last = $null
    if ($out.Count -gt 0) { $last = $out[$out.Count - 1] }
    $endState = $null
    if ($null -ne $last -and $null -ne $last['stateAfter']) { $endState = $last['stateAfter'] }
    if ($null -ne $endState) {
      try { $side = @(Get-ActChanges $actStartState $endState) } catch { $side = @() }
    }
  }

  return @{
    ok = ($failedCount -eq 0)
    steps = $out
    total = $steps.Count
    executed = $out.Count
    failedAt = $firstAt
    failedCount = $failedCount
    failure = $failure
    sideEffects = $side
    note = $note
  }
}


function Invoke-UiaClick([int]$x, [int]$y) {
  $el = Get-UiaElementAt $x $y
  if ($null -eq $el) { return @{ ok = $false; reason = 'uia-no-element' } }
  $name = Get-UiaName $el
  $type = Get-UiaType $el
  $walker = [System.Windows.Automation.TreeWalker]::ControlViewWalker
  $cur = $el
  for ($i = 0; $i -lt 6 -and $null -ne $cur; $i++) {
    $n = Get-UiaName $cur
    $t = Get-UiaType $cur
    try {
      $p = $cur.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern)
      $p.Invoke()
      return @{ ok = $true; via = 'uia'; pattern = 'Invoke'; name = $n; type = $t }
    } catch { }
    try {
      $p = $cur.GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern)
      $p.Toggle()
      return @{ ok = $true; via = 'uia'; pattern = 'Toggle'; name = $n; type = $t }
    } catch { }
    try {
      $p = $cur.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern)
      $p.Select()
      return @{ ok = $true; via = 'uia'; pattern = 'Select'; name = $n; type = $t }
    } catch { }
    try { $cur = $walker.GetParent($cur) } catch { $cur = $null }
  }
  return @{ ok = $false; reason = 'uia-no-pattern'; name = $name; type = $type }
}

# 对一个「已经用定位器找到的元素」直接执行 UIA 动作。
# 为什么不能省这一步：Invoke-UiaClick 是按坐标 FromPoint 重新找元素的，而定位器找到的
# Button 上面往往盖着一层透明容器（Group/Pane），FromPoint 拿到的是那个容器，于是 Invoke
# 打在错的元素上——界面毫无反应，却报「已执行」。给了 locator 就应该直接用那个元素。
function Invoke-UiaElementByPattern($el) {
  if ($null -eq $el) { return @{ ok = $false; reason = 'uia-no-element' } }
  $walker = [System.Windows.Automation.TreeWalker]::ControlViewWalker
  $cur = $el
  for ($i = 0; $i -lt 6 -and $null -ne $cur; $i++) {
    $n = Get-UiaName $cur
    $t = Get-UiaType $cur
    $isContainer = ($t -match 'Group|Pane|Custom|Document|Window|List|Tree|Table|DataGrid|MenuBar|ToolBar|StatusBar|ScrollBar|TitleBar')
    $res = $null
    try { $p = $cur.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern); $p.Invoke(); $res = @{ ok = $true; via = 'uia-element'; pattern = 'Invoke'; name = $n; type = $t; verified = (-not $isContainer) } } catch { }
    if ($null -eq $res) { try { $p = $cur.GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern); $p.Toggle(); $res = @{ ok = $true; via = 'uia-element'; pattern = 'Toggle'; name = $n; type = $t; verified = (-not $isContainer) } } catch { } }
    if ($null -eq $res) { try { $p = $cur.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern); $p.Select(); $res = @{ ok = $true; via = 'uia-element'; pattern = 'Select'; name = $n; type = $t; verified = (-not $isContainer) } } catch { } }
    if ($null -ne $res) {
      if ($isContainer) { $res['degradedFrom'] = 'uia-container'; $res['suggest'] = 'physical'; $res['note'] = ('UIA 只找到可点的容器（' + $t + '），已发出但界面是否变化无法确认；没反应就改 mode:"physical"') }
      return $res
    }
    try { $cur = $walker.GetParent($cur) } catch { $cur = $null }
  }
  return @{ ok = $false; reason = 'uia-no-pattern'; name = (Get-UiaName $el); type = (Get-UiaType $el) }
}

function Invoke-UiaClickInWindow([IntPtr]$hwnd, [int]$x, [int]$y) {
  if (-not $script:uia -or $hwnd -eq [IntPtr]::Zero) { return @{ ok = $false; reason = 'uia-no-window' } }
  try {
    $root = [System.Windows.Automation.AutomationElement]::FromHandle($hwnd)
    if ($null -eq $root) { return @{ ok = $false; reason = 'uia-no-window' } }
    $all = $root.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)
    $limit = [Math]::Min($all.Count, 4000)
    # 先把落在 (x,y) 上的元素全收下来，不要边找边点。
    # 树序是"外层在前、内层在后"，边找边点会拿到可点的容器（Group），
    # Invoke 它页面毫无反应——这是实际踩出来的（D001）。收完再按"越具体越优先"排序。
    $cands = New-Object System.Collections.ArrayList
    for ($i = 0; $i -lt $limit; $i++) {
      $cur = $all.Item($i)
      try {
        $r = $cur.Current.BoundingRectangle
        if ($r.IsEmpty) { continue }
        if ($x -lt $r.Left -or $x -gt $r.Right -or $y -lt $r.Top -or $y -gt $r.Bottom) { continue }
        $null = $cands.Add(@{ el = $cur; area = ([double]$r.Width * [double]$r.Height); type = (Get-UiaType $cur); name = (Get-UiaName $cur) })
      } catch { continue }
    }
    if ($cands.Count -eq 0) { return @{ ok = $false; reason = 'uia-no-element' } }
    # 容器类排在后面；同档里面积小的更具体（List/Tree/Table 也是容器：Invoke 它们通常是 no-op，D020）
    $sorted = $cands | Sort-Object @{ Expression = { if ($_.type -match 'Group|Pane|Custom|Document|Window|List|Tree|Table|DataGrid|MenuBar|ToolBar|StatusBar|ScrollBar|TitleBar') { 1 } else { 0 } } }, @{ Expression = { $_.area } }
    foreach ($c in $sorted) {
      $cur = $c.el
      $n = $c.name
      $t = $c.type
      $isContainer = ($t -match 'Group|Pane|Custom|Document|Window|List|Tree|Table|DataGrid|MenuBar|ToolBar|StatusBar|ScrollBar|TitleBar')
      try {
        $p = $cur.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern)
        $p.Invoke()
        $res = @{ ok = $true; via = 'uia-hwnd'; pattern = 'Invoke'; name = $n; type = $t; verified = (-not $isContainer) }
        if ($isContainer) {
          $res['degradedFrom'] = 'uia-container'
          $res['suggest'] = 'physical'
          $res['note'] = ('UIA 只找到可点的容器（' + $t + '），Invoke 已发出但界面是否变化无法确认；没反应就改 mode:"physical"')
        }
        return $res
      } catch { }
      try {
        $p = $cur.GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern)
        $p.Toggle()
        $res = @{ ok = $true; via = 'uia-hwnd'; pattern = 'Toggle'; name = $n; type = $t; verified = (-not $isContainer) }
        if ($isContainer) { $res['degradedFrom'] = 'uia-container'; $res['suggest'] = 'physical'; $res['note'] = 'UIA 只找到可点的容器（Toggle），是否生效无法确认' }
        return $res
      } catch { }
      try {
        $p = $cur.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern)
        $p.Select()
        $res = @{ ok = $true; via = 'uia-hwnd'; pattern = 'Select'; name = $n; type = $t; verified = (-not $isContainer) }
        if ($isContainer) { $res['degradedFrom'] = 'uia-container'; $res['suggest'] = 'physical'; $res['note'] = 'UIA 只找到可点的容器（Select），是否生效无法确认' }
        return $res
      } catch { }
    }
  } catch { }
  return @{ ok = $false; reason = 'uia-no-element'; suggest = 'physical' }
}

# 在 UIA 树里找包含指定文字的 Text 节点。窗口标题往往不含正文（浏览器尤其如此），
# 只查 GetWindowText 的 textAppear 等于永远等不到网页里的字。
function Test-UiaContainsText([IntPtr]$hwnd, [string]$needle) {
  if (-not $script:uia -or $hwnd -eq [IntPtr]::Zero -or [string]::IsNullOrEmpty($needle)) { return $false }
  try {
    $rootEl = [System.Windows.Automation.AutomationElement]::FromHandle($hwnd)
    if ($null -eq $rootEl) { return $false }
    $cond = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ControlTypeProperty, [System.Windows.Automation.ControlType]::Text)
    $els = $rootEl.FindAll([System.Windows.Automation.TreeScope]::Descendants, $cond)
    $lim = [Math]::Min($els.Count, 800)
    for ($i = 0; $i -lt $lim; $i++) {
      try {
        $n = $els.Item($i).Current.Name
        if ($n -and $n.IndexOf($needle, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) { return $true }
      } catch { }
    }
  } catch { }
  return $false
}

# 在窗口的整棵 UIA 树里按坐标反查可编辑元素并设值。
# Chromium / Electron 把网页输入框挂在根窗口的树里，而 ChildAt 拿到的是渲染子窗口，
# 从子窗口往下永远找不到那个 Edit —— 必须换这条路。
# 写进去的文字算不算成功。严格相等太苛刻：浏览器的地址栏会把
# 「https://www.bilibili.com」补成带末尾斜杠或补上 spm 参数的形式，
# 那是浏览器自己加的，不是我们没写进去——以前这里判失败，于是工具明明
# 写对了却去试下一条通道，一条 URL 试三遍、白花十几秒。
function Test-TextWritten([string]$actual, [string]$want) {
  if ($actual -eq $want) { return $true }
  if ($null -eq $actual) { $actual = '' }
  if ($null -eq $want) { $want = '' }
  $a = $actual.TrimEnd('/')
  $w = $want.TrimEnd('/')
  if ($a -ceq $w) { return $true }
  if ($a -ieq $w) { return $true }
  return $false
}

function Set-UiaTextInWindowByPoint([IntPtr]$hwnd, [int]$x, [int]$y, [string]$text, [bool]$replace) {
  if (-not $script:uia -or $hwnd -eq [IntPtr]::Zero) { return @{ ok = $false; reason = 'uia-no-window' } }
  try {
    $rootEl = [System.Windows.Automation.AutomationElement]::FromHandle($hwnd)
    if ($null -eq $rootEl) { return @{ ok = $false; reason = 'uia-no-window' } }

    # 快路径：FromPoint 直接拿到坐标上的元素，再向上找最多 8 层有 ValuePattern 的。
    # Edge 整棵树里支持 ValuePattern 的元素可能上千个（网页里每个 input 都算），
    # 全树遍历要 6 秒以上；FromPoint 是毫秒级。命中就不必往下走。
    try {
      $ptHit = New-Object System.Windows.Point($x, $y)
      $hitEl = [System.Windows.Automation.AutomationElement]::FromPoint($ptHit)
      $walk = $hitEl
      for ($up = 0; $up -lt 8 -and $null -ne $walk; $up++) {
        $vpH = $null
        try { $vpH = $walk.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern) } catch { $vpH = $null }
        if ($null -ne $vpH -and -not $vpH.Current.IsReadOnly) {
          $baseH = if ($replace) { '' } else { [string]$vpH.Current.Value }
          $wantH = $baseH + $text
          $vpH.SetValue($wantH)
          try { $walk.SetFocus() } catch { }
          Start-Sleep -Milliseconds 70
          $afterH = [string]$vpH.Current.Value
          if (Test-TextWritten $afterH $wantH) {
            return @{
              ok = $true; via = 'uia-point-fast'; pattern = 'Value'
              name = (Get-UiaName $walk); type = (Get-UiaType $walk); cls = (Get-UiaClassName $walk)
              verified = $true; scanned = 0
            }
          }
        }
        try { $walk = [System.Windows.Automation.TreeWalker]::ControlViewWalker.GetParent($walk) } catch { break }
      }
    }
    catch { }

    # 慢路径：按坐标在整棵树里反查（快路径没命中时兜底）。
    # 只要「支持 ValuePattern」的元素，把候选缩小一个数量级。
    $condVp = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::IsValuePatternAvailableProperty, $true)
    $all = $rootEl.FindAll([System.Windows.Automation.TreeScope]::Descendants, $condVp)
    $limit = [Math]::Min($all.Count, 6000)
    $script:lastByPointScanned = $all.Count
    for ($i = 0; $i -lt $limit; $i++) {
      $cur = $all.Item($i)
      try {
        $r = $cur.Current.BoundingRectangle
        if ($r.IsEmpty) { continue }
        if ([double]::IsInfinity($r.X) -or [double]::IsInfinity($r.Y)) { continue }
        if ($x -lt $r.Left -or $x -gt $r.Right -or $y -lt $r.Top -or $y -gt $r.Bottom) { continue }
      } catch { continue }
      try {
        $vp = $cur.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern)
        if ($null -eq $vp) { continue }
        if ($vp.Current.IsReadOnly) { continue }
        $base = if ($replace) { '' } else { [string]$vp.Current.Value }
        $wantV = $base + $text
        $vp.SetValue($wantV)
        # 写完把焦点留给这个控件：否则紧随其后的 Enter 会落在页面上（地址栏导航就是这么丢的）
        try { $cur.SetFocus() } catch { }
        Start-Sleep -Milliseconds 70
        $after = [string]$vp.Current.Value
        return @{
          ok = $true; via = 'uia-point'; pattern = 'Value'
          name = (Get-UiaName $cur); type = (Get-UiaType $cur); cls = (Get-UiaClassName $cur)
          verified = (Test-TextWritten $after $wantV)
        }
      } catch { continue }
    }
  } catch { }
  return @{ ok = $false; reason = 'uia-no-editable-at-point' }
}

function Set-UiaTextInWindow([IntPtr]$hwnd, [string]$text, [bool]$replace) {
  if (-not $script:uia -or $hwnd -eq [IntPtr]::Zero) { return @{ ok = $false; reason = 'uia-no-window' } }
  try {
    $el = [System.Windows.Automation.AutomationElement]::FromHandle($hwnd)
    if ($null -eq $el) { return @{ ok = $false; reason = 'uia-no-element' } }
    $vp = $el.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern)
    if ($replace) { $vp.SetValue($text) }
    else { $vp.SetValue([string]$vp.Current.Value + $text) }
    return @{ ok = $true; via = 'uia-hwnd'; pattern = 'Value'; name = (Get-UiaName $el); type = (Get-UiaType $el) }
  } catch {
    return @{ ok = $false; reason = 'uia-no-value' }
  }
}

# 直接对已找到的元素设值：不经过 HWND 子窗口层级，也不依赖 ChildAt 能不能命中。
# 现代记事本这类 WinUI 应用，edit 区不是 Win32 Edit 子窗口，只有这条路稳。
function Set-UiaTextOnElement($el, [string]$text, [bool]$replace) {
  if ($null -eq $el) { return @{ ok = $false; reason = 'no-element' } }
  try {
    $vp = $el.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern)
    if ($null -eq $vp) { return @{ ok = $false; reason = 'no-value-pattern' } }
    $base = if ($replace) { '' } else { [string]$vp.Current.Value }
    $wantV = $base + $text
    $vp.SetValue($wantV)
    Start-Sleep -Milliseconds 60
    $nowV = [string]$vp.Current.Value
    return @{ ok = $true; via = 'uia-value'; value = $nowV; verified = (Test-TextWritten $nowV $wantV) }
  } catch {
    return @{ ok = $false; reason = 'value-set-failed'; detail = $_.Exception.Message }
  }
}

function Get-UiaTextFromElement($el) {
  if ($null -eq $el) { return $null }
  try {
    $vp = $el.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern)
    return [string]$vp.Current.Value
  } catch { }
  try {
    $tp = $el.GetCurrentPattern([System.Windows.Automation.TextPattern]::Pattern)
    return [string]$tp.DocumentRange.GetText(-1)
  } catch { }
  # 记事本的编辑区在 UIA 里是 Pane，文本只挂在 Name 上。
  try {
    $n = [string]$el.Current.Name
    if ($n -ne '') { return $n }
  } catch { }
  return $null
}

# 读窗口里的文本，只用于写后校验与追加时的基线。
# 现代记事本的 WM_GETTEXT 返回空，GetWindowText 拿不到内容，
# 必须走 UIA，否则「写成功」会被判成失败，接着再写一遍。
function Get-UiaTextOfWindow([IntPtr]$hwnd) {
  if (-not $script:uia -or $hwnd -eq [IntPtr]::Zero) { return $null }
  try {
    $el = [System.Windows.Automation.AutomationElement]::FromHandle($hwnd)
    if ($null -eq $el) { return $null }
    $t = Get-UiaTextFromElement $el
    if ($null -ne $t) { return $t }
    $c1 = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ControlTypeProperty, [System.Windows.Automation.ControlType]::Edit)
    $c2 = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ControlTypeProperty, [System.Windows.Automation.ControlType]::Document)
    $cond = New-Object System.Windows.Automation.OrCondition($c1, $c2)
    $child = $el.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $cond)
    if ($null -ne $child) { return (Get-UiaTextFromElement $child) }
  } catch { }
  return $null
}

function Set-UiaText([int]$x, [int]$y, [string]$text, [bool]$replace) {
  $el = Get-UiaElementAt $x $y
  if ($null -eq $el) { return @{ ok = $false; reason = 'uia-no-element' } }
  $name = Get-UiaName $el
  $type = Get-UiaType $el
  try {
    $vp = $el.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern)
    if ($replace) { $vp.SetValue($text) }
    else { $vp.SetValue([string]$vp.Current.Value + $text) }
    return @{ ok = $true; via = 'uia'; pattern = 'Value'; name = $name; type = $type }
  } catch { }
  try {
    $legacy = $el.GetCurrentPattern([System.Windows.Automation.LegacyIAccessiblePattern]::Pattern)
    $legacy.SetValue($text)
    return @{ ok = $true; via = 'uia'; pattern = 'LegacyValue'; name = $name; type = $type }
  } catch { }
  return @{ ok = $false; reason = 'uia-no-value'; name = $name; type = $type }
}

function Set-UiaFocus([int]$x, [int]$y) {
  $el = Get-UiaElementAt $x $y
  if ($null -eq $el) { return @{ ok = $false; reason = 'uia-no-element' } }
  $name = Get-UiaName $el
  $type = Get-UiaType $el
  try {
    $el.SetFocus()
    return @{ ok = $true; via = 'uia'; pattern = 'Focus'; name = $name; type = $type }
  } catch {
    return @{ ok = $false; reason = 'uia-no-focus'; name = $name; type = $type }
  }
}

function Invoke-UiaScroll([int]$x, [int]$y, [int]$delta) {
  $el = Get-UiaElementAt $x $y
  if ($null -eq $el) { return @{ ok = $false; reason = 'uia-no-element' } }
  $name = Get-UiaName $el
  $type = Get-UiaType $el
  $amount = if ($delta -gt 0) { [System.Windows.Automation.ScrollAmount]::SmallIncrement } else { [System.Windows.Automation.ScrollAmount]::SmallDecrement }
  try {
    $sp = $el.GetCurrentPattern([System.Windows.Automation.ScrollPattern]::Pattern)
    $sp.Scroll([System.Windows.Automation.ScrollAmount]::NoAmount, $amount)
    return @{ ok = $true; via = 'uia'; pattern = 'Scroll'; name = $name; type = $type }
  } catch { }
  try {
    $si = $el.GetCurrentPattern([System.Windows.Automation.ScrollItemPattern]::Pattern)
    $si.ScrollIntoView()
    return @{ ok = $true; via = 'uia'; pattern = 'ScrollItem'; name = $name; type = $type }
  } catch { }
  return @{ ok = $false; reason = 'uia-no-scroll'; name = $name; type = $type }
}

# ---------------------------------------------------------------- window list

function Get-WindowTabs([long]$h) {
  $out = @()
  try {
    $root = [System.Windows.Automation.AutomationElement]::FromHandle([IntPtr]$h)
    $tabItemCond = New-Object System.Windows.Automation.PropertyCondition(
      [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
      [System.Windows.Automation.ControlType]::TabItem)
    $tabCond = New-Object System.Windows.Automation.PropertyCondition(
      [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
      [System.Windows.Automation.ControlType]::Tab)
    # 浏览器标签栏本身是一个 Tab 容器（Edge 叫"标签页栏"），而网页内部的 tab 控件
    # 也在这棵 UIA 树里——只在"标签栏"容器下取 TabItem，避免把页面内 tab 混进来
    $bars = $root.FindAll([System.Windows.Automation.TreeScope]::Descendants, $tabCond)
    $items = @()
    foreach ($bar in $bars) {
      try {
        $bn = $bar.Current.Name
        if ($bn -match '标签页栏|标签栏|Tab bar|Tabs') {
          $items += $bar.FindAll([System.Windows.Automation.TreeScope]::Descendants, $tabItemCond)
        }
      } catch { }
    }
    if ($items.Count -eq 0) {
      $items = $root.FindAll([System.Windows.Automation.TreeScope]::Descendants, $tabItemCond)
    }
    foreach ($it in $items) {
      try {
        $nm = $it.Current.Name
        if ([string]::IsNullOrWhiteSpace($nm)) { continue }
        $sel = $false
        try { $sel = $it.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern).Current.IsSelected } catch { }
        $out += @{ name = $nm; selected = $sel; offscreen = $it.Current.IsOffscreen }
      } catch { }
    }
  } catch { }
  return ,$out
}

function Get-WindowsList {
  $result = @()
  $foreground = [long][DshInput]::GetForegroundWindow()
  foreach ($h in [DshInput]::EnumTopWindows()) {
    try {
      if (-not [DshInput]::IsWindowVisible($h)) { continue }
      # D013：辅助窗口不是"窗口"。tooltip / 输入法 / 桌面 / 任务栏 都是系统或框架的
      # 实现细节，列出来只会让调用方以为多了一个可操作目标。
      $cls = [DshInput]::WindowClass($h)
      if ($cls -match 'tooltips_class32|MSCTFIME|^IME$|Ghost|^Progman$|^Shell_TrayWnd$|^WorkerW$|^TaskListThumbnailWnd$') { continue }
      $title = [DshInput]::WindowTitle($h)
      if ([string]::IsNullOrWhiteSpace($title)) { continue }
      $pid2 = [DshInput]::WindowPid($h)
      $procName = ''
      try { $procName = (Get-Process -Id $pid2 -ErrorAction Stop).ProcessName } catch { }
      # 输入法宿主：TextInputHost 的窗口没有可操作内容，但会带一个像模像样的标题
      if ($procName -eq 'TextInputHost') { continue }
      $rect = [DshInput]::WindowRect($h)
      $entry = @{
        hwnd = [long]$h
        title = $title
        className = $cls
        process = $procName
        pid = $pid2
        rect = @{ x = $rect[0]; y = $rect[1]; w = $rect[2]; h = $rect[3] }
        foreground = ([long]$h -eq $foreground)
        iconic = [DshInput]::IsIconic($h)
      }
      if ($procName -match '^(msedge|chrome|firefox|brave|Code|opera|vivaldi)$') {
        $tabs = Get-WindowTabs $h
        if ($tabs.Count -gt 0) { $entry['tabs'] = $tabs }
      }
      $result += $entry
    } catch { }
  }
  return ,$result
}

# ---------------------------------------------------------------- keyboard map

function Get-Vk([string]$name) {
  $n = $name.Trim().ToLower()
  switch ($n) {
    'ctrl' { return 0x11 }
    'control' { return 0x11 }
    'shift' { return 0x10 }
    'alt' { return 0x12 }
    'menu' { return 0x12 }
    'win' { return 0x5B }
    'lwin' { return 0x5B }
    'rwin' { return 0x5C }
    'enter' { return 0x0D }
    'return' { return 0x0D }
    'esc' { return 0x1B }
    'escape' { return 0x1B }
    'tab' { return 0x09 }
    'space' { return 0x20 }
    'backspace' { return 0x08 }
    'delete' { return 0x2E }
    'del' { return 0x2E }
    'insert' { return 0x2D }
    'ins' { return 0x2D }
    'home' { return 0x24 }
    'end' { return 0x23 }
    'pageup' { return 0x21 }
    'pagedown' { return 0x22 }
    'up' { return 0x26 }
    'down' { return 0x28 }
    'left' { return 0x25 }
    'right' { return 0x27 }
    'capslock' { return 0x14 }
    'numlock' { return 0x90 }
    'printscreen' { return 0x2C }
    'scrolllock' { return 0x91 }
    'pause' { return 0x13 }
    'apps' { return 0x5D }
    default {
      if ($n.Length -eq 1) { return [int][char]$n.ToUpper() }
      if ($n -match '^f([1-9]|1[0-2])$') { return 0x6F + [int]$Matches[1] }
      throw "unknown key: $name"
    }
  }
}

# ---------------------------------------------------------------- status

# 环境画像：这台机器上「这个窗口」长什么样。
# 目的不是学习，是把「每个人电脑不同、浏览器不同」这件事变成一次确定性的探测结果，
# 让模型不必每个会话重新试一遍（试错的代价是几十秒，而且结论散会就丢）。
# 结果按 hwnd 缓存；首次探测后不再重复遍历。
function Get-EnvironmentProfile([long]$hwnd) {
  if ($null -eq $script:envCache) { $script:envCache = @{} }
  $key = [string]$hwnd
  if ($script:envCache.ContainsKey($key)) { return $script:envCache[$key] }
  $prof = @{
    hwnd = $hwnd
    windowClass = ''
    kind = 'unknown'
    verticalTabs = $false
    note = ''
  }
  if ($hwnd -le 0) { return $prof }
  try { $prof.windowClass = [DshInput]::WindowClass([IntPtr]$hwnd) } catch { }
  if ($prof.windowClass -match 'Chrome_WidgetWin|MozillaWindowClass|ApplicationFrameWindow') {
    $prof.kind = 'chromium'
  }
  elseif ($prof.windowClass -match 'CabinetWClass|ExploreWClass') {
    $prof.kind = 'explorer'
  }
  else {
    $prof.kind = 'win32'
  }
  # 垂直标签栏：Chromium 系浏览器把标签竖排在左侧。判据是「x < 80 的区域里有 2 个以上 TabItem」。
  # 这台机器上 Edge 就是垂直的（x≈30），横版布局的用户则不会有这条。
  if ($prof.kind -eq 'chromium' -and $script:uia) {
    try {
      $rootE = [System.Windows.Automation.AutomationElement]::FromHandle([IntPtr]$hwnd)
      if ($null -ne $rootE) {
        $condTab = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ControlTypeProperty, [System.Windows.Automation.ControlType]::TabItem)
        $tabsE = $rootE.FindAll([System.Windows.Automation.TreeScope]::Descendants, $condTab)
        $leftTabs = 0
        $limT = [Math]::Min($tabsE.Count, 60)
        for ($i = 0; $i -lt $limT; $i++) {
          try {
            $rT = $tabsE.Item($i).Current.BoundingRectangle
            if ($rT.IsEmpty) { continue }
            if ([double]::IsInfinity($rT.X)) { continue }
            if ($rT.X -lt 80) { $leftTabs++ }
          }
          catch { }
        }
        if ($leftTabs -ge 2) {
          $prof.verticalTabs = $true
          $prof.note = '这是垂直标签栏（标签竖排在左侧）。鼠标划到左边缘会让标签栏展开、整个页面横移上百像素，所以落点要用 locator 让工具现场算，不要提前存坐标。'
        }
      }
    }
    catch { }
  }
  $script:envCache[$key] = $prof
  return $prof
}

# 环境画像落盘：探测到的事实写进文件，跨会话、可导出、可手动补充。
# 文件是真相源（可被人工编辑覆盖），探测只是「草稿」，启动时读文件优先。
function Get-EnvironmentFile {
  $dir = Join-Path $env:USERPROFILE '.dsh\independent-input'
  if (-not (Test-Path -LiteralPath $dir)) {
    try { [void](New-Item -ItemType Directory -Path $dir -Force) } catch { }
  }
  return (Join-Path $dir 'environment.json')
}

function Read-EnvironmentFile {
  $f = Get-EnvironmentFile
  if (-not (Test-Path -LiteralPath $f)) { return $null }
  try {
    $raw = Get-Content -LiteralPath $f -Raw -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
    return ($raw | ConvertFrom-Json)
  }
  catch { return $null }
}

# 面向主人的四句话（接管前 / 干活中 / 移动时 / 收工后）。放同一个目录，跟环境画像一起导出。
# 只开放这四句：它们是"语气"，不是协议。其余提示都是给模型看的诊断信息。
function Get-PhrasesFile {
  $dir = Join-Path $env:USERPROFILE '.dsh\independent-input'
  if (-not (Test-Path -LiteralPath $dir)) {
    try { [void](New-Item -ItemType Directory -Path $dir -Force) } catch { }
  }
  return (Join-Path $dir 'phrases.json')
}

function Read-Phrases {
  $f = Get-PhrasesFile
  if (-not (Test-Path -LiteralPath $f)) { return $null }
  try {
    $raw = Get-Content -LiteralPath $f -Raw -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
    return ($raw | ConvertFrom-Json)
  }
  catch { return $null }
}

$script:phrasesMtime = [long]-1

# 每次请求前看一眼文件有没有被改：改了就把新文案推给光标，
# 于是「改文案」不需要重启 DSH，也不需要重启 sidecar。
function Sync-Phrases {
  $f = Get-PhrasesFile
  $mtime = [long]0
  if (Test-Path -LiteralPath $f) {
    try { $mtime = [long](Get-Item -LiteralPath $f).LastWriteTimeUtc.Ticks } catch { $mtime = [long]0 }
  }
  if ($mtime -eq $script:phrasesMtime) { return }
  $script:phrasesMtime = $mtime
  $p = Read-Phrases
  if ($null -eq $p) { return }
  try {
    [DshOverlay]::SetPhrases([string]$p.takeover, [string]$p.working, [string]$p.moving, [string]$p.idle)
  } catch { }
}

# 合并「文件里人工写的」与「这次探测到的」：文件优先，探测补齐缺的字段。
# 这样人工可以钉死 hwnd/verticalTabs，也可以在 notes 里补工具探不到的（域策略、多 profile）。
function Get-EnvironmentMerged([long]$hwnd) {
  $probed = Get-EnvironmentProfile $hwnd
  $saved = Read-EnvironmentFile
  if ($null -eq $saved) {
    return @{ profile = $probed; source = 'probed'; filePath = (Get-EnvironmentFile) }
  }
  # 文件结构是 { savedAt, machine, user, profile:{…}, _readme }；
  # 手写的文件可能把字段直接放顶层，两种都认。
  $src = $saved.profile
  if ($null -eq $src) { $src = $saved }
  $merged = @{}
  foreach ($k in @('hwnd', 'kind', 'windowClass', 'verticalTabs', 'note', 'notes', 'extra')) {
    if ($null -ne $src.PSObject.Properties[$k]) { $merged[$k] = $src.$k }
  }
  foreach ($k in @('hwnd', 'kind', 'windowClass', 'verticalTabs', 'note')) {
    if ($null -eq $merged[$k]) { $merged[$k] = $probed[$k] }
  }
  return @{ profile = $merged; source = 'file+probe'; filePath = (Get-EnvironmentFile) }
}

function Save-EnvironmentProfile([long]$hwnd) {
  $merged = Get-EnvironmentMerged $hwnd
  $f = $merged.filePath
  $obj = [ordered]@{
    savedAt = (Get-Date -Format 'yyyy-MM-ddTHH:mm:sszzz')
    machine = $env:COMPUTERNAME
    user = $env:USERNAME
    profile = $merged.profile
    _readme = '这是 dsh-independent-input 的环境画像。工具每次启动读它；你可以手动改（例如钉死 verticalTabs、在 profile.notes 里补工具探不到的说明）。删除本文件即恢复为每次重新探测。'
  }
  try {
    $json = $obj | ConvertTo-Json -Depth 6
    [System.IO.File]::WriteAllText($f, $json, (New-Object System.Text.UTF8Encoding($true)))
    return @{ ok = $true; filePath = $f; profile = $merged.profile }
  }
  catch {
    return @{ ok = $false; filePath = $f; error = $_.Exception.Message }
  }
}

function Invoke-Environment($req) {
  $fg = [DshInput]::GetForegroundWindow()
  $hwnd = $fg
  if ($null -ne $req.hwnd) { $hwnd = [long]$req.hwnd }
  $op = 'show'
  if ($null -ne $req.'op' -and -not [string]::IsNullOrWhiteSpace([string]$req.'op')) { $op = [string]$req.'op' }
  if ($op -eq 'save') {
    $r = Save-EnvironmentProfile $hwnd
    $r['op'] = 'save'
    return $r
  }
  $m = Get-EnvironmentMerged $hwnd
  return @{
    ok = $true
    op = 'show'
    source = $m.source
    filePath = $m.filePath
    fileExists = (Test-Path -LiteralPath $m.filePath)
    profile = $m.profile
  }
}

# D014：按标题片段找顶层窗口（不区分大小写），找不到返回 [IntPtr]::Zero。
# 只找可见窗口；隐藏窗口不该被"切前台"操作选中。
function Find-WindowByTitle([string]$needle) {
  if ([string]::IsNullOrWhiteSpace($needle)) { return [IntPtr]::Zero }
  $needle = $needle.Trim()
  foreach ($h in [DshInput]::EnumTopWindows()) {
    try {
      if (-not [DshInput]::IsWindowVisible($h)) { continue }
      $t = [DshInput]::WindowTitle($h)
      if ([string]::IsNullOrWhiteSpace($t)) { continue }
      if ($t.IndexOf($needle, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) { return $h }
    } catch { }
  }
  return [IntPtr]::Zero
}

function Get-StatusResult {
  $cursor = [DshInput]::CursorPos()
  $fg = [DshInput]::GetForegroundWindow()
  $fgTitle = ''
  try { $fgTitle = [DshInput]::WindowTitle($fg) } catch { }
  return @{
    paused = [DshInput]::Paused
    pauseReason = [DshInput]::PauseReason
    lastUserInputAgeMs = [DshInput]::LastUserInputAgeMs()
    cursor = @{ x = $cursor[0]; y = $cursor[1] }
    foreground = @{
      hwnd = [long]$fg
      title = $fgTitle
      className = [DshInput]::WindowClass($fg)
      pid = [DshInput]::WindowPid($fg)
    }
    overlay = [DshOverlay]::VisibleNow()
    overlaySuppressed = [DshOverlay]::Suppressed
    overlayBusy = [DshOverlay]::IsBusy
    overlayRect = [DshOverlay]::Bounds()
    overlayHwnd = [DshOverlay]::HandleId()
    hotkey = 'Ctrl+Alt+Q'
    hotkeyRegistered = [DshInput]::HotkeyRegistered
    peers = $script:peerSidecars
    uia = $script:uia
    cursorMode = $script:cursorMode
    cursorHoldMs = $script:cursorHoldMs
    cursorSize = $script:cursorSize
    cursorStyle = $script:cursorStyle
    cursorState = if ([DshInput]::Paused) { 'unavailiable' } else { $script:cursorStyle }
    userActiveMs = [DshInput]::UserActiveMs
    takeoverStrikes = $script:takeoverStrikes
    takeoverLimit = $script:takeoverLimit
    eventCount = $script:eventSeq
    events = $script:eventLog.ToArray()
    lastDoneAt = $script:lastDoneAt
    scope = if ($script:scopeHwnds) { $script:scopeHwnds } else { @() }
    scopeNote = if ($script:scopeHwnds) { '只允许操作白名单窗口' } else { '未限制（任何窗口都可操作）' }
    cdp = (Get-CdpStatus)
    environment = Get-EnvironmentProfile ([long]$fg)
  }
}

function Get-PausedResult {
  if (-not [DshInput]::Paused) { return $null }
  return @{
    ok = $false
    paused = $true
    reason = 'paused'
    note = '主人已经暂停/接管输入。不要继续操作；等主人说继续，再调用 action:"resume"。'
  }
}

# 事不过三：连续被主人打断 3 次后，一切真实输入都停手，并换成 help 图标"举手发问"。
# 返回 $null 表示还可以动；返回一个结果对象表示拒绝。
function Get-TakeoverBlocked {
  if ($script:takeoverStrikes -lt $script:takeoverLimit) { return $null }
  try {
    $hx = if ([DshOverlay]::HasLast) { [DshOverlay]::LastX } else { [DshInput]::CursorPos()[0] }
    $hy = if ([DshOverlay]::HasLast) { [DshOverlay]::LastY } else { [DshInput]::CursorPos()[1] }
    Show-StateAt 'help' $hx $hy
  } catch { }
  return @{
    ok = $false
    reason = 'takeover-limit'
    needsConfirmation = $true
    strikes = $script:takeoverStrikes
    limit = $script:takeoverLimit
    cursorState = 'help'
    note = "主人已经连续 $($script:takeoverStrikes) 次把手夺回去。事不过三：不再动真实鼠标/键盘。AI 光标已切成 help 图标表示疑问。等主人明确同意后再动。"
  }
}

function Add-TakeoverStrike {
  $script:takeoverStrikes++
  return $script:takeoverStrikes
}

function Clear-TakeoverStrikes {
  $script:takeoverStrikes = 0
}

# 缓慢模式：默认开。开着时 AI 的动作有"人味"——看得见的补间、一个字一个字地敲；
# 关掉就瞬移、整段写入。请求可以逐条覆盖（配合插件设置），sidecar 自身不存状态。
function Get-SlowMode($req) {
  if ($null -ne $req.slowMode) { return [bool]$req.slowMode }
  return $true
}

function Get-TypingIntervalMs($req) {
  $raw = $null
  if ($null -ne $req.typingIntervalMs) { $raw = $req.typingIntervalMs }
  elseif ($null -ne $req.intervalMs) { $raw = $req.intervalMs }
  $v = if ($null -ne $raw) { [int]$raw } else { 500 }
  if ($v -lt 0) { $v = 0 }
  if ($v -gt 3000) { $v = 3000 }
  return $v
}

# 一个字一个字地写进去：每敲一个字就重写整个值（目标控件只接受整段写入），
# 中间停 intervalMs。超过 maxChars 就退回整段写入，避免几十秒的等待。
function Write-TextSlowly([IntPtr]$hwnd, [string]$baseText, [string]$text, [int]$intervalMs, [string]$cls) {
  $acc = $baseText
  $isEdit = $cls -match 'EDIT|Edit|TextBox'
  $chars = $text.ToCharArray()
  for ($i = 0; $i -lt $chars.Length; $i++) {
    $p = Get-PausedResult
    if ($null -ne $p) { return @{ interrupted = $true; text = $acc } }
    $acc = $acc + $chars[$i]
    if ($isEdit) {
      [DshInput]::SetTextMessage($hwnd, $acc) | Out-Null
    }
    else {
      $null = Set-UiaTextInWindow $hwnd $acc $true
    }
    if ($i -lt $chars.Length - 1) { Start-Sleep -Milliseconds $intervalMs }
  }
  return @{ interrupted = $false; text = $acc }
}

function Show-StateAt([string]$state, [int]$x, [int]$y, [int]$durationMs = 0) {
  if ($script:styleNames -contains $state) { $script:cursorStyle = $state }
  [DshOverlay]::SetStyle($script:cursorStyle)
  if ($durationMs -gt 0) {
    [DshOverlay]::MoveTo($x, $y, $durationMs)
    $deadline = (Get-Date).AddMilliseconds($durationMs + 2500)
    while ([DshOverlay]::IsMoving -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 15 }
  } else {
    [DshOverlay]::ShowAt($x, $y)
  }
}

# ---------------------------------------------------------------- requests

# 陪伴模式：任何请求结束后，只要光标曾经出现过，就保证它还看得见。
# 光标可见性属于"会话级"状态，不该被某个没带坐标的动作顺手抹掉（D009）。
function Ensure-CursorVisible {
  if ($script:cursorMode -ne 'companion') { return }
  if ([DshOverlay]::Suppressed) { return }
  if (-not [DshOverlay]::HasLast) { return }
  try {
    if (-not [DshOverlay]::VisibleNow()) {
      [DshOverlay]::ShowAtQuiet([DshOverlay]::LastX, [DshOverlay]::LastY)
    }
  } catch { }
}

# dsh-cua 借鉴①：effect 三态。回答的是「这次操作到底算不算数」。
#   confirmed = 有直接证据证明意图达成（回读到元素可点 / 光标确实移了 / 前台确实换了）
#   suspected = 投递出去了，但无法确认对方是否处理（窗口消息、真实键盘、UIA 命中容器）
#   none      = 明确没做成（ok=false）
# 只读动作没有「界面效果」可言，不打标签。
function Get-EffectTag([string]$cmd, $result) {
  switch ($cmd) {
    'status' { return $null }
    'windows' { return $null }
    'capture' { return $null }
    'observe' { return $null }
    'uiaInfo' { return $null }
    'phrases' { return $null }
    'ping' { return $null }
    'debug' { return $null }
    'environment' { return $null }
    'setCursorMode' { return $null }
    'setCursorSize' { return $null }
    'setCursorStyle' { return $null }
    'pause' { return $null }
    'resume' { return $null }
    'setScope' { return $null }
    # browser 的读操作（tabs/eval/text/count）与写操作（click/fill）都走 CDP：
    # 读操作本来就没有「界面变没变」的问题；写操作的结果由调用方用 eval 复核。
    # 所以这里不按 UIA 那套判，统一不打标，避免把只读查询误报成 suspected。
    'browser' { return $null }
  }
  if ($null -eq $result -or $result -isnot [hashtable]) { return $null }
  if ($result['ok'] -eq $false) { return 'none' }
  if ($result.ContainsKey('verified')) {
    # 只有 UIA 真的命中了一个可执行元素，才算「有回读证据」。
    # 窗口消息 / BM_CLICK 的 verified 只是「消息发出去了」，界面变没变根本不知道。
    $via = [string]$result['via']
    $uiaStrong = ($via -eq 'uia-hwnd' -or $via -eq 'uia-element' -or $via -eq 'uia')
    if ($result['verified'] -eq $true -and $uiaStrong) { return 'confirmed' }
    return 'suspected'
  }
  switch ($cmd) {
    'move' { return 'confirmed' }      # 光标是我们自己的窗口，位移由 timeline 自证
    'done' { return 'confirmed' }      # 光标 + 气泡都有打点
    'overlay' { return 'confirmed' }
    'activate' { return 'confirmed' }  # ActivateWindow 内部已回读 GetForegroundWindow
    'click' { return 'suspected' }
    'type' { return 'suspected' }
    'key' { return 'suspected' }
    'scroll' { return 'suspected' }
    'act' { return 'suspected' }
  }
  return 'suspected'
}

function Invoke-Request($req) {
  $t0 = Get-Date
  # 事不过三：physical 动作连续被主人夺权 3 次后，拦在门口，连真实光标都不碰一下。
  if ([string]$req.mode -eq 'physical') {
    $blocked = Get-TakeoverBlocked
    if ($null -ne $blocked) {
      try { Add-DshEvent -action ([string]$req.cmd) -req $req -result $blocked -ms 0 } catch { }
      return $blocked
    }
  }
  # dsh-cua 借鉴②：窗口作用域闸门。只有设了白名单才生效；physical 走真实光标，管不了。
  if ($script:scopeHwnds -and @($script:scopeHwnds).Count -gt 0) {
    if (@('click','type','key','scroll','act','activate') -contains [string]$req.cmd) {
      $gh = 0
      if ($req.hwnd) { try { $gh = [long]$req.hwnd } catch { } }
      if ($gh -ne 0 -and (@($script:scopeHwnds) -notcontains $gh)) {
        $denied = @{
          ok = $false
          reason = 'out-of-scope'
          hwnd = $gh
          scope = @($script:scopeHwnds)
          note = ("窗口 $gh 不在授权范围内（当前只允许：" + (@($script:scopeHwnds) -join ', ') + "）。要放行请先 setScope 把该窗口加进去。")
        }
        try { Add-DshEvent -action ([string]$req.cmd) -req $req -result $denied -ms 0 } catch { }
        return $denied
      }
    }
  }
  $result = Invoke-RequestCore $req
  # dsh-cua 借鉴①：统一在出口给写动作打 effect 标签
  $eff = Get-EffectTag ([string]$req.cmd) $result
  if ($eff -and $result -is [hashtable]) { $result['effect'] = $eff }
  if ([string]$req.mode -eq 'physical') {
    if ($result -and $result.ok -eq $true) {
      Clear-TakeoverStrikes
    }
    elseif ($result -and [string]$result.reason -eq 'user-takeover') {
      $n = Add-TakeoverStrike
      if ($n -ge $script:takeoverLimit) {
        # 到数了：换成 help 图标，站在原地看着主人，表示"我不敢再动了"
        try {
          $hx = if ([DshOverlay]::HasLast) { [DshOverlay]::LastX } else { [DshInput]::CursorPos()[0] }
          $hy = if ([DshOverlay]::HasLast) { [DshOverlay]::LastY } else { [DshInput]::CursorPos()[1] }
          Show-StateAt 'help' $hx $hy
        } catch { }
        if ($result -is [hashtable]) {
          $result['strikes'] = $n
          $result['needsConfirmation'] = $true
        }
      }
    }
  }
  try { Add-DshEvent -action ([string]$req.cmd) -req $req -result $result -ms ((Get-Date) - $t0).TotalMilliseconds } catch { }
  try { Ensure-CursorVisible } catch { }
  try { Write-TraceDrain } catch { }
  Save-OverlayState
  return $result
}

# ============ D018：浏览器 CDP 通道（结构化通道，优先于坐标） ============
# 前置：Edge 必须带 --remote-debugging-port=9222 启动，且用独立的 --user-data-dir
# （Edge 157 起，默认 profile 不允许开调试端口）
$script:cdpPort = 9222

# 两种接入方式都支持：
#   A) Edge 带 --remote-debugging-port=9222 启动（传统，有 /json/list）
#   B) 官方通道 edge://inspect#remote-debugging 手动授权（Edge 144+，无 /json，只能读 DevToolsActivePort）
# 原则：只探测、不自动拉起浏览器，也不改用户 profile。
function Test-CdpQuick {
  try {
    $c = New-Object System.Net.Sockets.TcpClient
    $t = $c.ConnectAsync('127.0.0.1', $script:cdpPort)
    $ok = $t.Wait(300) -and $c.Connected
    try { $c.Close() } catch { }
    return [bool]$ok
  } catch { return $false }
}

# ---- CDP 常驻客户端（daemon）----
# 官方通道（edge://inspect）的授权是按连接记的：每新建一条 WS 就要人点一次「允许」。
# 一次调用 spawn 一个 node 就是一次弹窗（D022），所以改成常驻 daemon：
# 只在第一次连接时点授权，之后所有请求复用同一条连接。
$script:cdpDaemon = $null

function Ensure-CdpDaemon {
  if ($script:cdpDaemon -and -not $script:cdpDaemon.HasExited) { return $script:cdpDaemon }
  $daemonPath = Join-Path $PSScriptRoot 'tools\cdp\cdp-daemon.cjs'
  if (-not (Test-Path $daemonPath)) { return $null }
  $nodeExe = 'node'
  try {
    $cmd = Get-Command node -ErrorAction SilentlyContinue
    if ($cmd -and $cmd.Source) { $nodeExe = $cmd.Source }
  } catch { }
  try {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $nodeExe
    $psi.Arguments = '"' + $daemonPath + '"'
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $p = [System.Diagnostics.Process]::Start($psi)
    $readyTask = $p.StandardOutput.ReadLineAsync()
    [void]$readyTask.Wait(5000)
    $script:cdpDaemon = $p
    return $p
  } catch {
    return $null
  }
}

function Invoke-CdpDaemon([string]$json, [int]$timeoutMs = 70000) {
  $p = Ensure-CdpDaemon
  if (-not $p) { return @{ ok = $false; reason = 'cdp-daemon-missing'; note = '找不到 tools\cdp\cdp-daemon.cjs 或 node' } }
  try {
    $p.StandardInput.WriteLine($json)
    $p.StandardInput.Flush()
  } catch {
    $script:cdpDaemon = $null
    return @{ ok = $false; reason = 'cdp-daemon-write-failed'; error = $_.Exception.Message }
  }
  $task = $p.StandardOutput.ReadLineAsync()
  if (-not $task.Wait($timeoutMs)) {
    return @{ ok = $false; reason = 'cdp-timeout'; needAuth = $true; note = '等太久没有回应——浏览器很可能在等你点「是否允许远程调试？」；看一眼屏幕有没有弹窗，点了再试' }
  }
  $line = $task.Result
  # daemon 启动时会先吐一行握手 {"ready":true,...}；Ensure-CdpDaemon 那边读它可能超时，
  # 结果这行留在缓冲区里，会被当成本次请求的响应（表现为「拿不到标签页」）。这里兜底跳过。
  if ($line -and $line -match '"ready"\s*:\s*true') {
    $task2 = $p.StandardOutput.ReadLineAsync()
    if (-not $task2.Wait($timeoutMs)) {
      return @{ ok = $false; reason = 'cdp-timeout'; needAuth = $true; note = '等太久没有回应——浏览器很可能在等你点「是否允许远程调试？」；看一眼屏幕有没有弹窗，点了再试' }
    }
    $line = $task2.Result
  }
  if (-not $line) {
    $script:cdpDaemon = $null
    return @{ ok = $false; reason = 'cdp-daemon-eof'; note = '常驻 CDP 客户端退出了，下次请求会自动重启' }
  }
  try {
    $obj = $line | ConvertFrom-Json
    $h = @{}
    foreach ($prop in $obj.PSObject.Properties) { $h[$prop.Name] = $prop.Value }
    return $h
  } catch {
    return @{ ok = $false; reason = 'cdp-daemon-badjson'; error = $line }
  }
}

function Get-CdpStatus {
  $listening = $false
  try {
    $c = New-Object System.Net.Sockets.TcpClient
    $t = $c.ConnectAsync('127.0.0.1', $script:cdpPort)
    $listening = ($t.Wait(300) -and $c.Connected)
    try { $c.Close() } catch { }
  } catch { }
  if (-not $listening) {
    return @{ port = $script:cdpPort; listening = $false; connected = $false; needAuth = $false; lastError = 'port-closed' }
  }
  $s = Invoke-CdpDaemon '{"op":"status"}' 8000
  if (-not $s -or -not $s.ok) {
    $why = 'no-status'
    if ($s -and $s.reason) { $why = [string]$s.reason }
    return @{ port = $script:cdpPort; listening = $true; connected = $false; needAuth = $true; lastError = $why }
  }
  return @{
    port = $script:cdpPort
    listening = $true
    connected = [bool]$s.connected
    connecting = [bool]$s.connecting
    needAuth = [bool]$s.needAuth
    lastError = [string]$s.lastError
  }
}

function Invoke-CdpCli([string]$Op, [string[]]$CliArgs = @()) {
  if ($Op -eq 'tabs') { return (Invoke-CdpDaemon '{"op":"tabs"}') }
  if ($Op -eq 'eval') {
    if ($CliArgs.Count -lt 2) { return @{ ok = $false; reason = 'cdp-bad-args'; note = 'eval 需要 targetId 和 expr' } }
    $payload = @{ op = 'eval'; targetId = [string]$CliArgs[0]; expr = [string]$CliArgs[1] }
    return (Invoke-CdpDaemon ($payload | ConvertTo-Json -Compress))
  }
  return @{ ok = $false; reason = 'cdp-unknown-op'; op = $Op }
}

function Get-CdpEndpoint {
  # 只做端口探测（不在这里连 WS，WS 交给 node）
  $port = $script:cdpPort
  $listening = $false
  try {
    $c = New-Object System.Net.Sockets.TcpClient
    $t = $c.ConnectAsync('127.0.0.1', $port)
    $listening = ($t.Wait(300) -and $c.Connected)
    try { $c.Close() } catch { }
  } catch { }
  return @{ ok = $listening; mode = $(if ($listening) { 'port' } else { 'none' }); port = $port }
}

function Get-CdpTabs {
  $r = Invoke-CdpCli 'tabs'
  if (-not $r.ok) { return @() }
  $list = @()
  foreach ($t in @($r.tabs)) {
    $list += [pscustomobject]@{ id = [string]$t.id; title = [string]$t.title; url = [string]$t.url; ws = '' }
  }
  return $list
}

function Invoke-CdpEval([string]$wsUrl, [string]$expr, [int]$timeoutMs = 8000, [string]$targetId = '', [string]$browserWs = '') {
  if (-not $targetId) { return @{ ok = $false; reason = 'cdp-no-target'; note = '缺 targetId' } }
  return (Invoke-CdpCli 'eval' @($targetId, $expr))
}

function Invoke-CdpCommand([string]$wsUrl, [string]$method, $params, [int]$timeoutMs = 8000) {
  return @{ ok = $false; reason = 'cdp-deprecated'; note = 'CDP 已改由 node 执行（见 Invoke-CdpCli）' }
}

function Invoke-RequestCore($req) {
  $cmd = [string]$req.cmd
  # 每次请求都看一眼 phrases.json 有没有被改；改了就即时生效，不用重启
  try { Sync-Phrases } catch { }

  # COORDS：frame:"client" 表示 x/y 是按目标窗口的客户区量的，先换算成屏幕坐标再进各分支。
  # 只对有坐标的动作生效；换算结果写回 $req，各分支继续用 $req.x / $req.y 即可。
  if ($req.frame -eq 'client' -and $null -ne $req.x -and $null -ne $req.y) {
    $fh = 0
    if ($null -ne $req.hwnd) { try { $fh = [long]$req.hwnd } catch { } }
    if ($fh -eq 0) { try { $fh = [long][DshInput]::GetForegroundWindow() } catch { } }
    if ($fh -ne 0) {
      try {
        $rootC = [long][DshInput]::RootOf([IntPtr]$fh)
        $sp = [DshInput]::ClientToScreenPoint($rootC, [int]$req.x, [int]$req.y)
        $script:lastFrameConvert = @{
          frame = 'client'; requested = @{ x = [int]$req.x; y = [int]$req.y }; screenPoint = @{ x = [int]$sp[0]; y = [int]$sp[1] }; hwnd = $rootC
        }
        $req.x = [int]$sp[0]; $req.y = [int]$sp[1]
      } catch { $script:lastFrameConvert = @{ frame = 'client'; error = "$_" } }
    }
  }

  switch ($cmd) {
    'ping' { return @{ pong = $true } }
    # dsh-cua 借鉴②：设定 / 解除窗口作用域。传 hwnds 数组设白名单，传 clear 或不传 hwnds 则解除。
    'setScope' {
      if ($req.clear -eq $true -or $null -eq $req.hwnds) {
        $script:scopeHwnds = $null
        return @{ ok = $true; scope = @(); note = '已解除窗口限制（所有窗口都可操作）' }
      }
      $list = New-Object System.Collections.ArrayList
      foreach ($x in @($req.hwnds)) {
        try {
          $v = [long]$x
          if ($v -ne 0 -and -not $list.Contains($v)) { [void]$list.Add($v) }
        } catch { }
      }
      if ($list.Count -eq 0) {
        $script:scopeHwnds = $null
        return @{ ok = $true; scope = @(); note = 'hwnds 里没有有效窗口，已解除限制' }
      }
      $arr = @($list)
      $script:scopeHwnds = $arr
      $names = @()
      foreach ($v in $arr) {
        try { $names += ("$v " + [DshInput]::WindowTitle([IntPtr]$v)) } catch { $names += "$v" }
      }
      return @{ ok = $true; scope = $arr; windows = $names; note = ("只允许操作：" + ($names -join '；')) }
    }
    'phrases' {
      $p = $req.phrases
      if ($null -ne $p) {
        [DshOverlay]::SetPhrases([string]$p.takeover, [string]$p.working, [string]$p.moving, [string]$p.idle)
      }
      return @{ ok = $true }
    }
    'status' { return Get-StatusResult }
    # D018：浏览器 CDP 通道。结构化通道，能读 DOM、能按选择器点，不用截图。
    # 前置：Edge 带 --remote-debugging-port=9222 + 独立 --user-data-dir 启动。
    'browser' {
      # D023：设置页的「浏览器增强」开关。关掉后不再尝试连 daemon，直接说清楚为什么
      if ($req.browserEnhance -eq $false) {
        $why = '浏览器增强在设置里被关掉了（设置 → 独立输入 → 浏览器增强）。要读网页结构、填表单时把它打开。'
        return @{ ok = $false; reason = 'browser-disabled'; hint = $why; note = $why }
      }
      $op = [string]$req.op
      if (-not $op) { $op = 'tabs' }
      $ep = Get-CdpEndpoint
      $tabs = @()
      if ($ep.ok) { $tabs = @(Get-CdpTabs) }
      if (@($tabs).Count -eq 0) {
        # D022：官方通道的授权是按连接的，每次新建 WS 都可能弹「是否允许远程调试？」
        # 而这一步失败时浏览器不会报错、只会干等——所以文案必须把「去点允许」说出来，
        # 否则调用方会以为是 CDP 封装坏了（2026-11-11 夜真踩过）。
        $hint = if ($ep.ok) {
          '端口通了，但拿不到标签页。最常见的原因是浏览器在等你点「是否允许远程调试？」的弹窗——看一眼屏幕，点「允许」再试；屏幕没有弹窗的话，先打开一个普通网页标签再试。'
        } else {
          [string]$ep.hint
        }
        return @{ ok = $false; reason = 'cdp-unavailable'; mode = [string]$ep.mode; port = $ep.port; hint = $hint
          note = $hint }
      }
      if ($op -eq 'tabs') {
        $brief = @()
        foreach ($t in $tabs) { $brief += @{ id = $t.id; title = $t.title; url = $t.url } }
        return @{ ok = $true; op = 'tabs'; via = 'cdp'; count = @($tabs).Count; tabs = $brief }
      }
      $target = $null
      if ($req.url) {
        $target = $tabs | Where-Object { $_.url -like ('*' + [string]$req.url + '*') } | Select-Object -First 1
      }
      if ($null -eq $target) { $target = $tabs | Select-Object -First 1 }

      $sel = ''
      if ($req.selector) { $sel = [string]$req.selector }
      $selLit = $sel | ConvertTo-Json -Compress
      $expr = [string]$req.expr
      if ($op -eq 'click') {
        $expr = "(() => { const el = document.querySelector($selLit); if (!el) return 'NO_ELEMENT'; el.scrollIntoView({block:'center'}); el.click(); return 'CLICKED'; })()"
      } elseif ($op -eq 'text') {
        $expr = "(() => { const el = document.querySelector($selLit); if (!el) return 'NO_ELEMENT'; return (el.innerText || el.textContent || '').slice(0, 4000); })()"
      } elseif ($op -eq 'fill') {
        $valLit = ([string]$req.value) | ConvertTo-Json -Compress
        $expr = "(() => { const el = document.querySelector($selLit); if (!el) return 'NO_ELEMENT'; el.focus(); el.value = $valLit; el.dispatchEvent(new Event('input',{bubbles:true})); el.dispatchEvent(new Event('change',{bubbles:true})); return 'FILLED'; })()"
      } elseif ($op -eq 'count') {
        $expr = "document.querySelectorAll($selLit).length"
      }
      if (-not $expr) { return @{ ok = $false; reason = 'missing-expr'; note = 'op 需要 eval/expr，或 click/text/fill/count + selector' } }

      $res = Invoke-CdpEval -wsUrl $target.ws -expr $expr -targetId ([string]$target.id) -browserWs ([string]$ep.browserWs)
      $res['via'] = 'cdp'
      $res['op'] = $op
      $res['tab'] = @{ title = $target.title; url = $target.url }
      if ($res.ok -and $res.value -eq 'NO_ELEMENT') {
        $res['ok'] = $false
        $res['reason'] = 'no-element'
        $res['selector'] = $sel
        $res['note'] = '这个选择器在页面上没找到元素；先 browser({op:"count"}) 或换选择器'
      }
      return $res
    }
    # D014：收尾。光标现身 + 播报「这一轮做完了」，可选把某个窗口切回前台。
    # focus 不传 = 只播报不抢前台（默认行为，避免打断主人）。
    'done' {
      $text = if ($req.text) { [string]$req.text } else { '这一轮做完了' }
      $hold = 3000
      if ($req.holdMs) { try { $hold = [int]$req.holdMs } catch { } }
      $at = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()

      # 1) 光标：没点亮就从上次的位置现身（不从 (0,0) 冒出来）
      $cursorShown = $false
      try {
        if (-not [DshOverlay]::VisibleNow() -and [DshOverlay]::HasLast) {
          [DshOverlay]::ShowAtQuiet([DshOverlay]::LastX, [DshOverlay]::LastY)
          $cursorShown = $true
        }
      } catch { }

      # 2) 气泡：复用 ShowHeartbeat（它同时负责打点 bubble.show）
      try { [DshOverlay]::ShowHeartbeat($text, $hold) } catch { }

      # 3) 切前台：只有显式传 focus 才做
      $focusHwnd = 0
      $focused = $false
      $focusNote = ''
      if ($req.focus) {
        $s = [string]$req.focus
        $target = [IntPtr]::Zero
        if ($s -match '^(?i:true)$') {
          $target = Find-WindowByTitle 'DeepSeek Harness'
          if ($target -eq [IntPtr]::Zero) {
            # 标题里没有 DSH（用户切到别的标签后，窗口标题变成了那个页面的标题），
            # 退一步：把浏览器主窗口切回前台，至少别让主人以为没反应。
            foreach ($bn in @('msedge', 'chrome', 'firefox', 'brave')) {
              try {
                $p = Get-Process -Name $bn -ErrorAction SilentlyContinue |
                  Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
                if ($p) {
                  $target = [IntPtr]$p.MainWindowHandle
                  $focusNote = '；没找到 DSH 标签，已把浏览器窗口切回前台（标签可能还停在别的页）'
                  break
                }
              } catch { }
            }
            if ($target -eq [IntPtr]::Zero) { $focusNote = '；没找到标题含「DeepSeek Harness」的窗口，也没找到在跑的浏览器' }
          }
        } elseif ($s -match '^\d+$') {
          $target = [IntPtr][long]$s
        } else {
          $target = Find-WindowByTitle $s
          if ($target -eq [IntPtr]::Zero) { $focusNote = "；没找到标题含「$s」的窗口" }
        }
        if ($target -ne [IntPtr]::Zero) {
          $focused = [DshInput]::ActivateWindow($target)
          $focusHwnd = [long]$target
          if (-not $focused) { $focusNote = '；窗口找到了但切前台失败' }
        }
      }

      $script:lastDoneAt = $at
      return @{
        ok = $true
        at = $at
        text = $text
        holdMs = $hold
        cursorShown = $cursorShown
        focused = $focused
        focusHwnd = $focusHwnd
        lastDoneAt = $at
        note = ("光标 + 气泡 " + [math]::Round($hold / 1000.0, 1) + " 秒后收起" + $focusNote)
      }
    }
    # 待办 action:"activate"：把窗口切到前台，不动鼠标、不按键。
    # 单独的 SetForegroundWindow 会被 Windows 前台锁定拒绝（返回 False），
    # 必须借前台线程的输入队列——和 done 的 ActivateWindow 是同一套。
    'activate' {
      $target = [IntPtr]::Zero
      $how = ''
      if ($req.hwnd) { $target = [IntPtr][long]$req.hwnd; $how = 'hwnd' }
      elseif ($req.title) { $target = Find-WindowByTitle ([string]$req.title); $how = 'title' }
      if ($target -eq [IntPtr]::Zero) {
        return @{ ok = $false; reason = 'no-target'; note = '没找到要激活的窗口（传 hwnd 或 title）' }
      }
      if (-not [DshInput]::IsWindow($target)) {
        return @{ ok = $false; reason = 'bad-hwnd'; note = "hwnd $([long]$target) 不是一个有效窗口" }
      }
      $wasMin = [DshInput]::IsIconic($target)
      $wasMax = [DshInput]::IsZoomed($target)
      $wasFg = ([DshInput]::GetForegroundWindow() -eq $target)
      $ok = [DshInput]::ActivateWindow($target)
      $note = if ($wasFg) { '它本来就在前台，没有动作' }
        elseif ($wasMin) { '原来是最小化的，已还原后切到前台' }
        elseif ($wasMax) { '原来是最大化的，保持最大化切到前台' }
        else { '已切到前台' }
      return @{
        ok = $ok
        hwnd = [long]$target
        title = [DshInput]::WindowTitle($target)
        className = [DshInput]::WindowClass($target)
        via = $how
        wasMinimized = $wasMin
        wasMaximized = $wasMax
        alreadyForeground = $wasFg
        note = $note
      }
    }
    'setCursorMode' {
      $m = [string]$req.mode
      if ($m -eq 'clean' -or $m -eq 'companion') { $script:cursorMode = $m }
      if ($null -ne $req.holdMs) { $script:cursorHoldMs = [int]$req.holdMs }
      [DshOverlay]::SetMode($script:cursorMode, $script:cursorHoldMs)
      return @{ ok = $true; cursorMode = $script:cursorMode; cursorHoldMs = $script:cursorHoldMs }
    }
    'setCursorSize' {
      $s = [int]$req.size
      if ($s -ge 24 -and $s -le 192) { $script:cursorSize = $s }
      [DshOverlay]::SetSize($script:cursorSize)
      return @{ ok = $true; cursorSize = $script:cursorSize }
    }
    'setCursorStyle' {
      $s = ([string]$req.style).ToLower()
      if ($script:styleNames -contains $s) { $script:cursorStyle = $s }
      [DshOverlay]::SetStyle($script:cursorStyle)
      return @{ ok = $true; cursorStyle = $script:cursorStyle; styles = $script:styleNames }
    }
    'simulateUserInput' {
      [DshInput]::SimulateUserInput()
      return Get-StatusResult
    }
    'debug' {
      $h = [DshOverlay]::HandleId()
      $hr = @(0, 0, 0, 0)
      $vis = $false
      $ex = 0
      if ($h -ne 0) {
        $hr = [DshInput]::WindowRect([IntPtr]$h)
        $vis = [DshInput]::IsWindowVisible([IntPtr]$h)
        $ex = [DshInput]::WindowExStyle([IntPtr]$h)
      }
      return @{
        hwnd = $h
        visible = $vis
        rect = $hr
        bounds = [DshOverlay]::Bounds()
        exStyle = ('0x{0:X}' -f $ex)
        style = if ($h -ne 0) { '0x{0:X}' -f ([long][DshInput]::GetWindowLongPtrW([IntPtr]$h, -16)) } else { '0x0' }
        parent = if ($h -ne 0) { [long][DshInput]::GetParent([IntPtr]$h) } else { 0 }
        root = if ($h -ne 0) { [long][DshInput]::RootOf([IntPtr]$h) } else { 0 }
        topmost = (($ex -band 0x8) -ne 0)
        transparent = (($ex -band 0x20) -ne 0)
        noactivate = (($ex -band 0x08000000) -ne 0)
        toolwindow = (($ex -band 0x80) -ne 0)
        setWindowPosOk = [DshOverlay]::LastSetWindowPosOk
        setWindowPosError = [DshOverlay]::LastSetWindowPosError
      }
    }
    'windows' { return @{ windows = (Get-WindowsList) } }
    'observe' { return Invoke-Observe $req }
    'environment' { return Invoke-Environment $req }
    'act' { return Invoke-Act $req }
    'windowAt' {
      $h = [DshInput]::WindowAt([int]$req.x, [int]$req.y)
      return @{
        hwnd = [long]$h
        title = [DshInput]::WindowTitle($h)
        className = [DshInput]::WindowClass($h)
        root = [long][DshInput]::RootOf($h)
      }
    }
    'uiaInfo' {
      $el = Get-UiaElementAt ([int]$req.x) ([int]$req.y)
      if ($null -eq $el) { return @{ ok = $false; reason = 'null' } }
      $r = $el.Current.BoundingRectangle
      return @{
        ok = $true
        name = (Get-UiaName $el)
        type = (Get-UiaType $el)
        className = [string]$el.Current.ClassName
        rect = @{ x = [int]$r.X; y = [int]$r.Y; w = [int]$r.Width; h = [int]$r.Height }
      }
    }
    'winInfo' {
      $h = [IntPtr][long]$req.hwnd
      $r = [DshInput]::WindowRect($h)
      return @{
        hwnd = [long]$h
        title = [DshInput]::WindowTitle($h)
        className = [DshInput]::WindowClass($h)
        visible = [DshInput]::IsWindowVisible($h)
        iconic = [DshInput]::IsIconic($h)
        rect = @{ x = $r[0]; y = $r[1]; w = $r[2]; h = $r[3] }
        foreground = ([long][DshInput]::GetForegroundWindow() -eq [long]$h)
      }
    }
    'setUserActiveMs' {
      [DshInput]::SetUserActiveMs([int]$req.ms)
      return Get-StatusResult
    }
    'move' {
      $x = [int]$req.x
      $y = [int]$req.y
      # 缓慢模式：非 physical 的移动也走补间，默认 600ms；关掉就瞬移。
      $slow = Get-SlowMode $req
      $defaultDur = if ($slow) { 600 } else { 0 }
      $dur = if ($null -ne $req.durationMs) { [int]$req.durationMs } else { $defaultDur }
      if ($dur -lt 0) { $dur = 0 }
      if ($dur -gt 4000) { $dur = 4000 }
      $mode = if ($req.mode) { [string]$req.mode } else { 'overlay' }
      if ($mode -eq 'physical') {
        $grace = if ($null -ne $req.takeoverGraceMs) { [int]$req.takeoverGraceMs } else { 120 }
        $restore = $true
        if ($null -ne $req.restoreCursor) { $restore = [bool]$req.restoreCursor }
        # physical 预告：AI 光标滑到真实光标旁边说一句，停 2 秒再接管（Ctrl+Alt+Q 可暂停）。
        try {
          $rcW = [DshInput]::CursorPos()
          if (Get-SlowMode $req) { [DshOverlay]::MoveToQuiet([int]$rcW[0] + 36, [int]$rcW[1] + 36, 700) } else { [DshOverlay]::ShowAtQuiet([int]$rcW[0] + 36, [int]$rcW[1] + 36) }
          $__mvDeadline = (Get-Date).AddMilliseconds(3500); while ([DshOverlay]::IsMoving -and (Get-Date) -lt $__mvDeadline) { Start-Sleep -Milliseconds 25 }
          [DshOverlay]::ShowBadge(([DshOverlay]::PhraseTakeover('')), 2000)
          Start-Sleep -Milliseconds 2000
        } catch { }
        [DshInput]::SetAllowPhysical($true)
        [DshOverlay]::FollowCursor($true)
        try {
          $r = [DshInput]::PhysicalMove($x, $y, $dur, $grace, $restore)
          return @{
            ok = $true; via = 'physical'; x = $x; y = $y
            from = @([int]$r[0], [int]$r[1]); durationMs = $dur; elapsedMs = [int]$r[2]
            movedRealCursor = $true; restoreCursor = $restore; takeoverGuardMs = $grace
            note = '真实光标分步走到了目标；主人一动鼠标/键盘就会立刻中止（reason=user-takeover）'
          }
        }
        catch {
          $msg = $_.Exception.Message
          $reason = 'physical-failed'
          if ($msg -match 'user-takeover') { $reason = 'user-takeover' }
          elseif ($msg -match 'paused') { $reason = 'paused' }
          elseif ($msg -match 'cursor-mismatch') { $reason = 'cursor-mismatch' }
          $pos = [DshInput]::CursorPos()
          return @{
            ok = $false; reason = $reason; atX = $pos[0]; atY = $pos[1]
            elapsedMs = $dur; note = "已中止: $msg"
          }
        }
        finally {
          [DshOverlay]::FollowCursor($false)
          [DshInput]::SetAllowPhysical($false)
        }
      }
      $wasFirst = -not [DshOverlay]::HasLast
      $fromX = [DshOverlay]::LastX
      $fromY = [DshOverlay]::LastY
      if ($wasFirst) {
        # 没有历史位置时，从主人的真实光标处"长出来"，再走到目标
        $cp = [DshInput]::CursorPos()
        $fromX = $cp[0]; $fromY = $cp[1]
        if ($dur -le 0) { $dur = 500 }
      }
      $t0 = Get-Date
      Show-StateAt 'pointer' $x $y $dur
      $elapsed = [int]((Get-Date) - $t0).TotalMilliseconds
      return @{
        ok = $true; via = 'overlay'; x = $x; y = $y
        from = @($fromX, $fromY); arrived = $true
        durationMs = $dur; elapsedMs = $elapsed
        note = '只移动 AI 光标，没有移动主人的真实光标'
      }
    }
    'overlay' {
      if ($null -ne $req.busyIdleMs) { [DshOverlay]::SetBusyIdleMs([int]$req.busyIdleMs) }
      if ($req.show -eq $false) { [DshOverlay]::Hide(); return @{ ok = $true; visible = $false; suppressed = $true; cursorMode = $script:cursorMode; cursorState = $script:cursorStyle } }
      $x = if ($null -ne $req.x) { [int]$req.x } elseif ([DshOverlay]::HasLast) { [DshOverlay]::LastX } else { [DshInput]::CursorPos()[0] }
      $y = if ($null -ne $req.y) { [int]$req.y } elseif ([DshOverlay]::HasLast) { [DshOverlay]::LastY } else { [DshInput]::CursorPos()[1] }
      Show-StateAt 'pointer' $x $y
      # 说话：AI 光标旁边冒一句人话。动作日志已经写清楚了，气泡存在的意义是让主人一眼知道「它现在在干什么」。
      if (-not [string]::IsNullOrWhiteSpace([string]$req.text)) {
        $hold = if ($null -ne $req.holdMs) { [int]$req.holdMs } else { 4000 }
        if ($hold -lt 300) { $hold = 300 }
        if ($hold -gt 60000) { $hold = 60000 }
        [DshOverlay]::ShowBadge([string]$req.text, $hold)
      }
      return @{ ok = $true; visible = $true; x = $x; y = $y; cursorMode = $script:cursorMode; cursorSize = $script:cursorSize; cursorState = $script:cursorStyle }
    }
    'waitFor' {
      $timeout = if ($null -ne $req.timeoutMs) { [int]$req.timeoutMs } else { 8000 }
      if ($timeout -lt 200) { $timeout = 200 }
      if ($timeout -gt 60000) { $timeout = 60000 }
      $poll = if ($null -ne $req.pollMs) { [int]$req.pollMs } else { 400 }
      if ($poll -lt 100) { $poll = 100 }
      $mode = if ($req.mode) { [string]$req.mode } else { 'appear' }
      $loc = $req.locator
      $hwndWait = [IntPtr]::Zero
      if ($loc -and $loc.hwnd) { $hwndWait = [IntPtr][long]$loc.hwnd }
      elseif ($req.hwnd) { $hwndWait = [IntPtr][long]$req.hwnd }
      $textNeedle = if ($req.text) { [string]$req.text } else { '' }
      if ($mode -ne 'titleChange' -and $mode -ne 'textAppear' -and $null -eq $loc) {
        return @{ ok = $false; reason = 'need-locator'; note = 'waitFor 需要 locator；或者 mode 用 titleChange/textAppear' }
      }
      $titleBase = if ($hwndWait -ne [IntPtr]::Zero) { [DshInput]::GetWindowText($hwndWait) } else { '' }
      $sw = [System.Diagnostics.Stopwatch]::StartNew()
      $found = $false
      $lastSeen = $null
      while ($sw.ElapsedMilliseconds -lt $timeout) {
        if ([DshInput]::Paused) {
          return @{ ok = $false; reason = 'paused'; waitedMs = [int]$sw.ElapsedMilliseconds; mode = $mode }
        }
        $hit = $false
        if ($mode -eq 'titleChange') {
          $tNow = if ($hwndWait -ne [IntPtr]::Zero) { [DshInput]::GetWindowText($hwndWait) } else { '' }
          $hit = ($tNow -ne '' -and $tNow -ne $titleBase)
          if ($hit) { $titleBase = $tNow }
        } elseif ($mode -eq 'textAppear') {
          $tNow = if ($hwndWait -ne [IntPtr]::Zero) { [DshInput]::GetWindowText($hwndWait) } else { '' }
          $hit = ($textNeedle -ne '' -and $tNow -like "*$textNeedle*")
          if (-not $hit) { $hit = Test-UiaContainsText $hwndWait $textNeedle }
        } elseif ($mode -eq 'disappear') {
          $hit = ($null -eq (Find-UiaByLocator $loc))
        } else {
          $lastSeen = Find-UiaByLocator $loc
          $hit = ($null -ne $lastSeen)
        }
        if ($hit) { $found = $true; break }
        Start-Sleep -Milliseconds $poll
      }
      $waited = [int]$sw.ElapsedMilliseconds
      if (-not $found) {
        return @{
          ok = $false; reason = 'wait-timeout'; waitedMs = $waited; mode = $mode; timeoutMs = $timeout
          note = "等了 $waited ms 没等到（$mode）。可以调大 timeoutMs，或者换定位器"
        }
      }
      $titleNow = if ($hwndWait -ne [IntPtr]::Zero) { [DshInput]::GetWindowText($hwndWait) } else { '' }
      if ($mode -eq 'disappear' -or $mode -eq 'titleChange' -or $mode -eq 'textAppear') {
        return @{ ok = $true; found = $true; waitedMs = $waited; mode = $mode; title = $titleNow }
      }
      $rect = Get-UiaRect $lastSeen
      $elInfo = @{
        name = (Get-UiaName $lastSeen)
        className = (Get-UiaClassName $lastSeen)
        controlType = (Get-UiaType $lastSeen)
        isPassword = (Get-UiaIsPassword $lastSeen)
      }
      if ($null -ne $rect) {
        $elInfo.rect = @($rect.x, $rect.y, $rect.w, $rect.h)
        $elInfo.center = @($rect.cx, $rect.cy)
      }
      return @{ ok = $true; found = $true; waitedMs = $waited; mode = $mode; element = $elInfo }
    }
    'pause' {
      [DshInput]::Pause('api')
      if ([DshOverlay]::HasLast) { [DshOverlay]::ShowAtQuiet([DshOverlay]::LastX, [DshOverlay]::LastY) }
      # Get-StatusResult 本身不带 ok（它是「状态快照」不是「动作结果」），
      # 但 pause/resume 是动作，调用链按 ok 打勾，不补就会被记成失败。
      $pr = Get-StatusResult
      $pr['ok'] = $true
      return $pr
    }
    'resume' {
      [DshInput]::Resume()
      Clear-TakeoverStrikes
      $script:cursorStyle = 'pointer'
      [DshOverlay]::SetStyle('pointer')
      if ([DshOverlay]::HasLast) { [DshOverlay]::ShowAtQuiet([DshOverlay]::LastX, [DshOverlay]::LastY) }
      $rr = Get-StatusResult
      $rr['ok'] = $true
      return $rr
    }
    'click' {
      $x = [int]$req.x
      $y = [int]$req.y
      $reqHwnd0 = if ($null -ne $req.hwnd) { [long]$req.hwnd } else { 0 }
      $anchorEl = $null
      $locNote = ''
      # 定位器优先：给了 locator 就先解析成坐标，同时把目标 hwnd 补上——这样录下来的步骤可重放
      if ($req.locator) {
        $found0 = Find-UiaByLocator $req.locator
        if ($null -eq $found0) {
          if (-not [string]::IsNullOrWhiteSpace([string]$req.locator.ref)) {
            return @{ ok = $false; reason = 'ref-stale'; locator = $req.locator; note = ('编号 ' + [string]$req.locator.ref + ' 已失效（窗口换了、元素没了，或中间重新 observe 过）。重新 observe 一次就有新编号') }
          }
          if ([string]$script:lastLocatorMatch -eq 'ambiguous') {
            return @{ ok = $false; reason = 'locator-ambiguous'; locator = $req.locator; note = ('这个名字匹配到不止一个元素，所以没有赌。候选：' + $(if ($null -ne $script:lastLocatorCandidates -and $script:lastLocatorCandidates.Count -gt 0) { ($script:lastLocatorCandidates -join ' | ') } else { '(取不到名字)' }) + '。改用 ref（observe 拿编号），或者把名字写得更长') }
          }
          return @{ ok = $false; reason = 'locator-not-found'; locator = $req.locator; note = '定位器没找到元素，先用 waitFor 确认它存在' }
        }
        $anchorEl = $found0
        $locNote = Get-LocatorMatchNote
        $rect0 = Get-UiaRect $found0
        if ($null -eq $rect0) { return @{ ok = $false; reason = 'locator-no-rect'; locator = $req.locator } }
        if ($rect0.w -le 0 -or $rect0.h -le 0) {
          # 元素找到了但矩形是 0×0（屏幕外 / 还没渲染）：这时 center 算出来是 (0,0)，
          # physical 会真的点到屏幕左上角，而且报成功。宁可失败也不要乱点。
          return @{ ok = $false; reason = 'locator-zero-rect'; locator = $req.locator; note = '元素找到了但它的矩形是 0×0（在屏幕外或还没渲染），算不出落点。改用 x/y 坐标，或先让它可见（切到前台、展开面板）' }
        }
        # Get-UiaRect 返回的是 hashtable（x/y/w/h/cx/cy），不是数组。
        # 这里曾经按数组下标取值：$rect0[2] 永远是 $null，而 PowerShell 里 $null -le 0 为真，
        # 于是每一次 locator 点击都判成「矩形 0×0」直接返回失败——locator 点击从来没成功过。
        $x = [int]$rect0.cx
        $y = [int]$rect0.cy
        if ($reqHwnd0 -eq 0 -and $null -ne $req.locator.hwnd) { $reqHwnd0 = [long]$req.locator.hwnd }
        # ref（编号）定位时 locator 里没有 hwnd：从元素自身推它属于哪个窗口
        if ($reqHwnd0 -eq 0) { $hRef = Get-ElementWindowHwnd $found0; if ($hRef -gt 0) { $reqHwnd0 = [long]$hRef } }
      }
      $button = if ($req.button) { [string]$req.button } else { 'left' }
      $count = if ($req.count) { [int]$req.count } else { 1 }
      $mode = if ($req.mode) { [string]$req.mode } else { 'auto' }
      $paused = Get-PausedResult
      if ($null -ne $paused) { return $paused }

      # 布局稳定化：locator 的矩形是「读它的那一刻」的位置。physical 点击本来就要把真实鼠标
      # 移到目标上，而鼠标一进目标区域布局可能就变了（Edge 垂直标签栏 hover 展开时，整个页面
      # 会横移一百多像素——实测过 124px）。所以先把鼠标瞬移过去、等布局落定、重新读一次矩形，
      # 用落定后的位置去点。这样 locator 的落点永远是「鼠标已就位」那一刻的真实位置。
      $adjustedFrom = $null
      if ($req.locator -and $mode -eq 'physical') {
        try {
          [System.Windows.Forms.Cursor]::Position = New-Object System.Drawing.Point([int]$x, [int]$y)
        } catch { }
        Start-Sleep -Milliseconds 140
        $foundA = Find-UiaByLocator $req.locator
        if ($null -ne $foundA) {
          $rectA = Get-UiaRect $foundA
          if ($null -ne $rectA -and $rectA.w -gt 0 -and $rectA.h -gt 0) {
            if ([Math]::Abs($rectA.cx - $x) -gt 2 -or [Math]::Abs($rectA.cy - $y) -gt 2) {
              $adjustedFrom = @($x, $y)
              $x = [int]$rectA.cx
              $y = [int]$rectA.cy
            }
          }
        }
      }

      if ($mode -eq 'physical') {
        $dur = if ($null -ne $req.durationMs) { [int]$req.durationMs } else { 400 }
        if ($dur -lt 0) { $dur = 0 }
        if ($dur -gt 4000) { $dur = 4000 }
        $grace = if ($null -ne $req.takeoverGraceMs) { [int]$req.takeoverGraceMs } else { 120 }
        # 点完让真实光标停在目标位置（更自然）；要放回原处就显式传 restoreCursor:true
        $restoreClick = if ($null -ne $req.restoreCursor) { [bool]$req.restoreCursor } else { $false }
        # physical 预告：先把 AI 光标滑到主人真实光标旁边、说一句「要动你的鼠标了」，停 2 秒再接管。
        # 这 2 秒是反悔窗口——Ctrl+Alt+Q 随时能暂停，比弹「是/否」对话框快，也不打断流程。
        try {
          $rcW = [DshInput]::CursorPos()
          if (Get-SlowMode $req) { [DshOverlay]::MoveToQuiet([int]$rcW[0] + 36, [int]$rcW[1] + 36, 700) } else { [DshOverlay]::ShowAtQuiet([int]$rcW[0] + 36, [int]$rcW[1] + 36) }
          $__mvDeadline = (Get-Date).AddMilliseconds(3500); while ([DshOverlay]::IsMoving -and (Get-Date) -lt $__mvDeadline) { Start-Sleep -Milliseconds 25 }
          [DshOverlay]::ShowBadge(([DshOverlay]::PhraseTakeover('')), 2000)
          Start-Sleep -Milliseconds 2000
        } catch { }
        [DshInput]::SetAllowPhysical($true)
        [DshOverlay]::FollowCursor($true)
        try {
          [DshInput]::PhysicalClick($x, $y, ($button -eq 'right'), $count, $dur, $grace, $restoreClick)
          Show-StateAt 'pointer' $x $y
          # 点完让手停一下再收，否则视觉上"手"是瞬移消失的
          Start-Sleep -Milliseconds 900
          return @{
            ok = $true; via = 'physical'; x = $x; y = $y; button = $button; count = $count
            durationMs = $dur; movedRealCursor = $true; tookFocus = $true; takeoverGuardMs = $grace
            restoreCursor = $restoreClick
            layoutAdjusted = $(if ($null -ne $adjustedFrom) { @{ from = $adjustedFrom; to = @($x, $y) } } else { $null })
            note = '真实鼠标分步走过去并按下；点完停在原地（restoreCursor:true 可放回原处）；主人一动鼠标/键盘会立刻中止' + $(if ($null -ne $adjustedFrom) { '；鼠标就位后布局变了，落点已从 (' + $adjustedFrom[0] + ',' + $adjustedFrom[1] + ') 修正到 (' + $x + ',' + $y + ')' } else { '' }) + $locNote
          }
        }
        catch {
          $msg = $_.Exception.Message
          $reason = 'physical-failed'
          if ($msg -match 'user-takeover') { $reason = 'user-takeover' }
          elseif ($msg -match 'paused') { $reason = 'paused' }
          elseif ($msg -match 'cursor-mismatch') { $reason = 'cursor-mismatch' }
          $pos = [DshInput]::CursorPos()
          return @{ ok = $false; reason = $reason; atX = $pos[0]; atY = $pos[1]; note = "已中止: $msg" }
        }
        finally {
          [DshOverlay]::FollowCursor($false)
          [DshInput]::SetAllowPhysical($false)
        }
      }

      # 看得见的手：AI 光标先动画走到目标，再执行点击（不再先把自己藏起来）
      $dur = if ($null -ne $req.durationMs) { [int]$req.durationMs } else { 300 }
      if ($dur -lt 0) { $dur = 0 }
      if ($dur -gt 4000) { $dur = 4000 }
      Show-StateAt 'pointer' $x $y $dur

      $targetHwnd = $reqHwnd0
      if ($targetHwnd -eq 0) {
        return @{
          ok = $false; reason = 'need-target-hwnd'; strictNoRealMouse = $true
          note = '必须提供目标窗口 hwnd（先用 windows 拿 hwnd）；只按坐标点会点到主人正在用的窗口'
        }
      }
      $target = [IntPtr]$targetHwnd
      if (-not [DshInput]::IsWindow($target)) {
        return @{ ok = $false; reason = 'target-hwnd-invalid'; hwnd = $targetHwnd }
      }
      $root = [DshInput]::RootOf($target)
      # 定位器已经精确找到元素：直接对它执行 UIA 动作，不要再用坐标 FromPoint 重找
      #（FromPoint 常拿到盖在按钮上面的透明容器，Invoke 打在错的元素上——界面没反应却报「已执行」）
      if ($button -eq 'left' -and $count -eq 1 -and $null -ne $anchorEl) {
        $rd = Invoke-UiaElementByPattern $anchorEl
        if ($rd.ok) {
          Show-StateAt 'link' $x $y
          $rd['x'] = $x
          $rd['y'] = $y
          $rd['hwnd'] = [long]$root
          $rd['button'] = $button
          $rd['count'] = $count
          if ($locNote) { $rd['note'] = [string]$rd['note'] + $locNote }
          return $rd
        }
      }
      $h = [DshInput]::ChildAt($root, $x, $y)
      if ($h -eq [IntPtr]::Zero) { $h = $root }
      $cls0 = [DshInput]::WindowClass($h)
      if ($button -eq 'left' -and $count -eq 1 -and $cls0 -match 'BUTTON|Button') {
        # BM_CLICK 直接让按钮发命令，不经过鼠标消息，也不抢焦点。
        [DshInput]::PostMessage($h, 0x00F5, [IntPtr]::Zero, [IntPtr]::Zero) | Out-Null
        Show-StateAt 'link' $x $y
        return @{ ok = $true; via = 'bm_click'; hwnd = [long]$h; target = [long]$root; verified = $false; note = '按钮 BM_CLICK；不移动鼠标、不抢焦点' }
      }
      $r = Invoke-UiaClickInWindow $root $x $y
      if ($r.ok) {
        $state = if ($r.pattern -and ([string]$r.type -match 'Edit|Document|Text')) { 'text' } elseif ($r.pattern) { 'link' } else { 'pointer' }
        Show-StateAt $state $x $y
        $r['x'] = $x
        $r['y'] = $y
        $r['hwnd'] = [long]$root
        $r['button'] = $button
        $r['count'] = $count
        return $r
      }
      $h = [DshInput]::ChildAt($root, $x, $y)
      if ($h -eq [IntPtr]::Zero) { $h = $root }
      [DshInput]::PostMouseClick($h, $x, $y, ($button -eq 'right'), $count)
      $cls = [DshInput]::WindowClass($h)
      $state2 = 'pointer'
      if ($cls -match 'BUTTON|Button|SysLink|Toolbar|Menu') { $state2 = 'link' }
      elseif ($cls -match 'EDIT|Edit|TextBox') { $state2 = 'text' }
      Show-StateAt $state2 $x $y
      $noteMsg = '已投递给指定窗口；不移动真实鼠标，也不经过别的窗口'
      $chanBad = $false
      if ($cls -match 'Chrome_WidgetWin') {
        # 这是实测踩出来的：Chromium 的界面（标签栏、地址栏、网页）不走窗口消息，
        # 投过去等于石沉大海，而且工具还会报 ok。必须明说。
        $chanBad = $true
        $noteMsg = '目标窗口是 Chromium（Chrome_WidgetWin）：它的界面（标签栏、地址栏、网页）不处理窗口消息，这次点击很可能没生效。要动它请用 mode:"physical"，或改用 locator 让 uia 点击'
      }
      elseif ($cls -match 'Unity|Unreal|YuanShen|GenshinImpact|SDL_app') {
        $chanBad = $true
        $noteMsg = ('目标窗口是游戏/自绘渲染窗口（' + $cls + '）：它自己读设备输入、不处理窗口消息，这次点击很可能没生效。要动它请用 mode:"physical"')
      }
      $res = @{
        ok = $true; via = 'message-hwnd'; hwnd = [long]$h; target = [long]$root
        className = $cls; sent = $true; verified = $false
        note = $noteMsg
      }
      if ($chanBad) { $res['degradedFrom'] = 'message'; $res['suggest'] = 'physical' }
      return $res

      $fallbackState = 'pointer'
      $r = $null
      if ($mode -eq 'uia' -or $mode -eq 'auto') {
        $r = Invoke-UiaClick $x $y
        if ($r.ok) {
          $state = if ($r.pattern -and ([string]$r.type -match 'Edit|Document|Text')) { 'text' } elseif ($r.pattern) { 'link' } else { 'pointer' }
          Show-StateAt $state $x $y
          $r['x'] = $x
          $r['y'] = $y
          $r['button'] = $button
          $r['count'] = $count
          return $r
        }
        # UIA 没点成，但已经读到控件类型：消息点击也按控件类型给状态。
        if ($r.type) {
          $t = [string]$r.type
          if ($t -match 'Edit|Document|Text') { $fallbackState = 'text' }
          elseif ($t -match 'Button|Link|MenuItem|ListItem|TabItem|CheckBox|RadioButton|TreeItem') { $fallbackState = 'link' }
        }
        # uia 模式也允许落到窗口消息：老控件没有 InvokePattern，但消息点击有效。
      }

      if ($mode -eq 'message' -or $mode -eq 'auto' -or $mode -eq 'uia') {
        $h = [DshInput]::WindowAt($x, $y)
        if ($h -ne [IntPtr]::Zero) {
          [DshInput]::PostMouseClick($h, $x, $y, ($button -eq 'right'), $count)
          $cls = [DshInput]::WindowClass($h)
          if ($fallbackState -eq 'pointer') {
            if ($cls -match 'BUTTON|Button|SysLink|Toolbar|Menu') { $fallbackState = 'link' }
            elseif ($cls -match 'EDIT|Edit|TextBox') { $fallbackState = 'text' }
          }
          Show-StateAt $fallbackState $x $y
          return @{
            ok = $true; via = 'message'; hwnd = [long]$h
            title = [DshInput]::WindowTitle($h)
            className = $cls
            verified = $false
            note = '窗口消息已投递，目标不一定处理；请截图确认'
          }
        }
        if ($mode -eq 'message') { return @{ ok = $false; reason = 'no-window' } }
      }

      Show-StateAt 'help' $x $y
      return @{
        ok = $false; reason = 'no-route'; needsPhysical = $true; strictNoRealMouse = $false
        note = 'UIA 与窗口消息都没成功；可以显式用 mode:"physical" 让真实鼠标走一趟'
      }
    }
    'type' {
      $text = [string]$req.text
      $mode = if ($req.mode) { [string]$req.mode } else { 'auto' }
      $replace = $false
      if ($null -ne $req.replace) { $replace = [bool]$req.replace }
      # 定位器优先：给了 locator 就用元素的中心点当打字落点，目标 hwnd 也从它来
      $locEl = $null
      if ($req.locator) {
        $foundT = Find-UiaByLocator $req.locator
        if ($null -eq $foundT) {
          if (-not [string]::IsNullOrWhiteSpace([string]$req.locator.ref)) {
            return @{ ok = $false; reason = 'ref-stale'; locator = $req.locator; note = ('编号 ' + [string]$req.locator.ref + ' 已失效（窗口换了、元素没了，或中间重新 observe 过）。重新 observe 一次就有新编号') }
          }
          if ([string]$script:lastLocatorMatch -eq 'ambiguous') {
            return @{ ok = $false; reason = 'locator-ambiguous'; locator = $req.locator; note = ('这个名字匹配到不止一个元素，所以没有赌。候选：' + $(if ($null -ne $script:lastLocatorCandidates -and $script:lastLocatorCandidates.Count -gt 0) { ($script:lastLocatorCandidates -join ' | ') } else { '(取不到名字)' }) + '。改用 ref（observe 拿编号），或者把名字写得更长') }
          }
          return @{ ok = $false; reason = 'locator-not-found'; locator = $req.locator; note = '定位器没找到元素，先用 waitFor 确认它存在' }
        }
        $locEl = $foundT
        $rectT = Get-UiaRect $foundT
        if ($null -eq $rectT) { return @{ ok = $false; reason = 'locator-no-rect'; locator = $req.locator } }
        # 请求对象可能是没有 x/y 字段的 PSCustomObject，先补出字段再写，否则会抛 "property cannot be found"
        foreach ($k0 in @('x', 'y', 'hwnd')) {
          if ($null -eq $req.PSObject.Properties[$k0]) {
            $req | Add-Member -NotePropertyName $k0 -NotePropertyValue $null -Force
          }
        }
        # 同上：Get-UiaRect 是 hashtable，按数组下标取会得到 $null（于是坐标变成 0,0）
        $req.x = [int]$rectT.cx
        $req.y = [int]$rectT.cy
        if ($null -eq $req.hwnd -and $null -ne $req.locator.hwnd) { $req.hwnd = [long]$req.locator.hwnd }
        # ref（编号）定位时 locator 里没有 hwnd：从元素自身推它属于哪个窗口
        if ($null -eq $req.hwnd) { $hT = Get-ElementWindowHwnd $foundT; if ($hT -gt 0) { $req.hwnd = [long]$hT } }
      }
      $hasPoint = ($null -ne $req.x -and $null -ne $req.y)
      $paused = Get-PausedResult
      if ($null -ne $paused) { return $paused }

      # 预判：有坐标、要覆盖、又没命中 locator —— 这种情况只有 physical 通道能兑现。
      # 以前是先让窗口消息通道失败一次（replace-unsupported），再由调用方重试，
      # 白花十几秒，而且地址栏那种场景必然踩到。现在直接升级，并在 note 里说明。
      $autoUpgraded = $false
      if ($replace -and $null -eq $locEl -and $mode -eq 'auto') {
        $mode = 'physical'
        $autoUpgraded = $true
      }
      # 缓慢模式下让 AI 光标先走到输入框，再开始敲字——看得见它在打字
      $slowPre = Get-SlowMode $req
      if ($hasPoint) {
        if ($slowPre) { Show-StateAt 'pointer' ([int]$req.x) ([int]$req.y) 400 }
        else { Show-StateAt 'text' ([int]$req.x) ([int]$req.y) }
      }
      # 没有坐标时不碰光标：以前这里直接 Hide()，等于"打个字先把光标收起来"，
      # 陪伴模式下等于把人唯一看得见的线索擦掉（D009）。

      if ($mode -eq 'physical') {
        $targetHwnd = [long]$req.hwnd
        # 没给 hwnd 就发给当前前台窗口，跟人打字时"焦点在哪就打哪"一致
        if ($targetHwnd -eq 0) { $targetHwnd = [long][DshInput]::GetForegroundWindow() }
        if ($targetHwnd -eq 0) {
          return @{ ok = $false; reason = 'no-target'; note = 'physical 打字需要目标窗口：没给 hwnd，也没读到当前前台窗口' }
        }
        $root = [DshInput]::RootOf([IntPtr]$targetHwnd)
        if ($root -eq [IntPtr]::Zero) { $root = [IntPtr]$targetHwnd }
        $grace = if ($null -ne $req.takeoverGraceMs) { [int]$req.takeoverGraceMs } else { 120 }
        $interval = Get-TypingIntervalMs $req
        $hold = if ($null -ne $req.holdAfterTypingMs) { [int]$req.holdAfterTypingMs } else { 1200 }
        $dockAt = $hasPoint
        # physical 预告：AI 光标滑到真实光标旁边说一句，停 2 秒再接管（Ctrl+Alt+Q 可暂停）。
        try {
          $rcW = [DshInput]::CursorPos()
          if (Get-SlowMode $req) { [DshOverlay]::MoveToQuiet([int]$rcW[0] + 36, [int]$rcW[1] + 36, 700) } else { [DshOverlay]::ShowAtQuiet([int]$rcW[0] + 36, [int]$rcW[1] + 36) }
          $__mvDeadline = (Get-Date).AddMilliseconds(3500); while ([DshOverlay]::IsMoving -and (Get-Date) -lt $__mvDeadline) { Start-Sleep -Milliseconds 25 }
          [DshOverlay]::ShowBadge(([DshOverlay]::PhraseTakeover('')), 2000)
          Start-Sleep -Milliseconds 2000
        } catch { }
        [DshInput]::SetAllowPhysical($true)
        try {
          if ($dockAt) {
            # 光标先走到输入框右下角停住，然后字从这里一个个冒出来
            Show-StateAt 'text' ([int]$req.x + 18) ([int]$req.y + 18) 450
            Start-Sleep -Milliseconds 120
          } else {
            [DshOverlay]::FollowCursor($true)
          }
          $fg = [DshInput]::GetForegroundWindow()
          $fgRoot = [DshInput]::RootOf($fg)
          if ($fgRoot -ne $root) {
            [DshInput]::FocusWindow($root) | Out-Null
            Start-Sleep -Milliseconds 160
          }
          # replace 在 physical 通道上也必须成立：先 ctrl+a 全选、delete 清空，再逐字敲。
          # 以前这里直接敲，等于把 replace 静默降级成追加——地址栏就是这么被写成
          # 「https://www.bilibili.comhttpshttps://www.bilibili.com」的。
          if ($replace) {
            try {
              [DshInput]::PressComboSlow([int[]]@(0x11, 0x41), $grace) | Out-Null
              Start-Sleep -Milliseconds 60
              [DshInput]::PressComboSlow([int[]]@(0x2E), $grace) | Out-Null
              Start-Sleep -Milliseconds 80
            } catch { }
          }
          $n = [DshInput]::TypeUnicodeSlow($text, $interval, $grace)
          if ($dockAt) {
            # 打完继续停在输入框边（由 cursorHoldMs 自动收起），不阻塞响应
            Show-StateAt 'text' ([int]$req.x + 18) ([int]$req.y + 18)
          }
          return @{
            ok = $true; via = 'physical-typing'; hwnd = [long]$root; chars = $n
            intervalMs = $interval; movedRealCursor = $false; stoleFocus = $true
            dockedAt = if ($dockAt) { @(([int]$req.x + 18), ([int]$req.y + 18)) } else { $null }
            note = if ($autoUpgraded) {
              '覆盖（replace）只有真实键盘能兑现，已自动从窗口消息通道升级；逐字键入会抢焦点，主人一动键鼠会立刻中止'
            } else { '真实键盘逐字键入（会抢焦点）；主人一动键鼠会立刻中止' }
          }
        }
        catch {
          $msg = $_.Exception.Message
          $reason = 'physical-failed'
          if ($msg -match 'user-takeover') { $reason = 'user-takeover' }
          elseif ($msg -match 'paused') { $reason = 'paused' }
          elseif ($msg -match 'cursor-mismatch') { $reason = 'cursor-mismatch' }
          return @{ ok = $false; reason = $reason; note = "已中止: $msg" }
        }
        finally {
          if (-not $dockAt) { [DshOverlay]::FollowCursor($false) }
          [DshInput]::SetAllowPhysical($false)
        }
      }
      $targetHwnd = [long]$req.hwnd
      if ($targetHwnd -eq 0) {
        return @{
          ok = $false; reason = 'need-target-hwnd'; strictNoFocusSteal = $true
          note = '必须提供目标窗口 hwnd；不会把文字打进主人当前聚焦的输入框'
        }
      }
      $target = [IntPtr]$targetHwnd
      if (-not [DshInput]::IsWindow($target)) { return @{ ok = $false; reason = 'target-hwnd-invalid'; hwnd = $targetHwnd } }
      $root = [DshInput]::RootOf($target)
      $h = $root
      if ($hasPoint) {
        $child = [DshInput]::ChildAt($root, [int]$req.x, [int]$req.y)
        if ($child -ne [IntPtr]::Zero) { $h = $child }
      }

      $cls = [DshInput]::WindowClass($h)
      # 追加模式的基线也必须用 UIA 读：GetWindowText 在现代记事本上恒为空，
      # 拿它会算出 want = "" + text，把原有内容整段冲掉。
      $cur = Get-UiaTextOfWindow $h
      if ($null -eq $cur) { $cur = [DshInput]::GetWindowText($h) }
      $want = if ($replace) { $text } else { [string]$cur + $text }

      # 通道 -1：locator 已经命中元素，直接用它自己的 ValuePattern。
      # 这层不看 HWND 子窗口，所以 WinUI 应用（现代记事本、部分浏览器控件）也能写进去。
      if ($null -ne $locEl) {
        $rLoc = Set-UiaTextOnElement $locEl $text $replace
        if ($rLoc.ok -and $rLoc.verified) {
          if ($hasPoint) { Show-StateAt 'text' ([int]$req.x) ([int]$req.y) }
          $rLoc['hwnd'] = [long]$h
          $rLoc['target'] = [long]$root
          $rLoc['note'] = '按定位器直接对元素设值，UIA 已校验，未抢焦点、未移动鼠标'
          return $rLoc
        }
      }

      # 通道 0：缓慢模式 —— 一个字一个字写，看得见。写完整段后再校验；
      # 超过 maxSlowChars 就跳过这层，直接整段写入（避免几十秒等待）。
      $slow = Get-SlowMode $req
      $interval = Get-TypingIntervalMs $req
      $maxSlowChars = 60
      # replace 又没命中 locator：窗口消息通道本身就写不进已有内容（慢速逐字也一样，
      # 地址栏会变成两遍 URL），直接跳过这层，别白烧十几秒再报 replace-unsupported。
      if ($slow -and $text.Length -gt 0 -and $text.Length -le $maxSlowChars -and -not ($replace -and $null -eq $locEl)) {
        $base = if ($replace) { '' } else { [string]$cur }
        $res = Write-TextSlowly $h $base $text $interval $cls
        Start-Sleep -Milliseconds 80
        $nowS = Get-UiaTextOfWindow $h
        if ($res.interrupted) {
          if ($hasPoint) { Show-StateAt 'text' ([int]$req.x) ([int]$req.y) }
          return @{
            ok = $false; reason = 'paused'; paused = $true; via = 'slow-typing'
            hwnd = [long]$h; target = [long]$root; typed = $res.text.Length; intervalMs = $interval; verified = $false
            note = '缓慢输入被暂停打断，已写入的部分保留'
          }
        }
        if ($nowS -eq $want) {
          if ($hasPoint) { Show-StateAt 'text' ([int]$req.x) ([int]$req.y) }
          return @{
            ok = $true; via = 'slow-typing'; hwnd = [long]$h; target = [long]$root
            chars = $text.Length; intervalMs = $interval; verified = $true; slowMode = $true
            note = '一个字一个字写入，UIA 已校验，未抢焦点、未移动鼠标'
          }
        }
      }

      # 通道 1：EDIT 控件直接 WM_SETTEXT。写完用 UIA 读回校验，
      # 只有确认写入才算成功；失败才轮到下一个通道，绝不再补写一遍。
      if ($cls -match 'EDIT|Edit|TextBox') {
        [DshInput]::SetTextMessage($h, $want) | Out-Null
        Start-Sleep -Milliseconds 60
        $now = Get-UiaTextOfWindow $h
        if ($now -eq $want) {
          if ($hasPoint) { Show-StateAt 'text' ([int]$req.x) ([int]$req.y) }
          return @{ ok = $true; via = 'wm_settext'; hwnd = [long]$h; target = [long]$root; verified = $true; note = '直接写入目标 Edit 控件，UIA 已校验，未抢焦点、未移动鼠标' }
        }
      }

      # 通道 2：UIA ValuePattern，同样以读回校验为准。
      $r = Set-UiaTextInWindow $h $text $replace
      if ($r.ok) {
        Start-Sleep -Milliseconds 60
        $now2 = Get-UiaTextOfWindow $h
        if ($now2 -eq $want) {
          if ($hasPoint) { Show-StateAt 'text' ([int]$req.x) ([int]$req.y) }
          $r['hwnd'] = [long]$h
          $r['target'] = [long]$root
          $r['verified'] = $true
          return $r
        }
      }

      # 通道 2.5：按坐标在整棵 UIA 树里反查输入框。
      # 浏览器（Chromium / Electron）的地址栏与网页输入框都走这一路：ChildAt 给的是渲染
      # 子窗口，从它往下找不到元素，所以前面几层必然失败。
      if ($hasPoint) {
        $rp = Set-UiaTextInWindowByPoint $root ([int]$req.x) ([int]$req.y) $text $replace
        # 只有读回校验通过才算写进去了。ProseMirror 这类富文本框有 ValuePattern 但 SetValue
        # 不生效（读回还是空），以前这里只看 ok 就返回，等于把「没写成」报成了成功。
        if ($rp.ok -and $rp.verified) {
          if ($hasPoint) { Show-StateAt 'text' ([int]$req.x) ([int]$req.y) }
          $rp['hwnd'] = [long]$h
          $rp['target'] = [long]$root
          return $rp
        }
      }

      # 通道 3：窗口消息逐字符。只发 ASCII —— 非 Unicode 感知的窗口会把
      # WM_CHAR 的 wParam 按 ANSI 再解一次，中文变成 ìË“ 这类垃圾，
      # 宁可不写，也不留脏数据。
      if ($text -match '[^\x00-\x7F]') {
        if ($hasPoint) { Show-StateAt 'help' ([int]$req.x) ([int]$req.y) }
        return @{
          ok = $false; reason = 'charset-needs-uia'; hwnd = [long]$h; target = [long]$root; verified = $false
          note = '目标窗口既不接受 WM_SETTEXT 也不接受 UIA ValuePattern；窗口消息通道不支持非 ASCII（会产生乱码），已拒绝写入。这条通道不通不代表写不了：加 mode:"physical" 用真实键盘逐字敲（会抢焦点，主人一动键鼠就停）'
        }
      }
      # replace 在窗口消息通道上做不到：它是逐字符追加，没有「先清空」的语义。
      # 以前这里照样发出去，于是「覆盖地址栏」变成了把 URL 写两遍——13 秒白费还校验失败。
      if ($replace) {
        return @{
          ok = $false; reason = 'replace-unsupported'; hwnd = [long]$h; target = [long]$root; verified = $false
          note = ('窗口消息通道只能逐字符追加，没法覆盖已有内容。' + $(if ($null -ne $locEl) { '而且这个输入框是网页里的富文本框（contenteditable），UIA 的 ValuePattern 对它不生效，所以「给 locator 就行」在这里也不成立——只能加 mode:"physical" 用真实键盘覆盖（会临时抢焦点，主人一动键鼠就停）' } else { '要覆盖请给 locator（走 UIA ValuePattern 一次写完），或者加 mode:"physical"' }))
        }
      }
      [DshInput]::PostText($h, $text)
      if ($hasPoint) { Show-StateAt 'text' ([int]$req.x) ([int]$req.y) }
      return @{ ok = $true; via = 'message-hwnd'; hwnd = [long]$h; target = [long]$root; verified = $false; note = '已向目标窗口投递 ASCII 文字；不抢焦点' }
    }
    'key' {
      $mode = if ($req.mode) { [string]$req.mode } else { 'auto' }
      $paused = Get-PausedResult
      if ($null -ne $paused) { return $paused }
      $raw = [string]$req.keys
      if ([string]::IsNullOrWhiteSpace($raw)) { return @{ ok = $false; reason = 'keys required' } }
      $names = $raw -split '\+'
      $vks = @()
      foreach ($n in $names) { $vks += (Get-Vk $n) }

      # Chromium 的界面不处理窗口消息（实测：ctrl+t 不开新标签、ctrl+w 不关标签，
      # 有时还会把字符漏进页面）。auto 模式遇到它就直接升级成 physical，别白投一次再让调用方重来。
      $autoUpgraded = $false
      $autoWhy = ''
      if ($mode -eq 'auto') {
        $hChk = [long]$req.hwnd
        if ($hChk -ne 0 -and [DshInput]::IsWindow([IntPtr]$hChk)) {
          $clsChk = [DshInput]::WindowClass([DshInput]::RootOf([IntPtr]$hChk))
          if ($clsChk -match 'Chrome_WidgetWin') { $mode = 'physical'; $autoUpgraded = $true; $autoWhy = 'chromium' }
          elseif ($clsChk -match 'Unity|Unreal|YuanShen|GenshinImpact|SDL_app') { $mode = 'physical'; $autoUpgraded = $true; $autoWhy = 'game' }
        }
      }

      if ($mode -eq 'physical') {
        $targetHwnd = [long]$req.hwnd
        # 没给 hwnd 就按 SendInput 的自然语义发给当前前台窗口（比如刚导航完的浏览器）
        if ($targetHwnd -eq 0) { $targetHwnd = [long][DshInput]::GetForegroundWindow() }
        if ($targetHwnd -eq 0) {
          return @{ ok = $false; reason = 'no-target'; note = 'physical 按键需要目标窗口：没给 hwnd，也没读到当前前台窗口' }
        }
        $root = [DshInput]::RootOf([IntPtr]$targetHwnd)
        if ($root -eq [IntPtr]::Zero) { $root = [IntPtr]$targetHwnd }
        $grace = if ($null -ne $req.takeoverGraceMs) { [int]$req.takeoverGraceMs } else { 120 }
        $vkArr = New-Object int[] $vks.Length
        for ($i = 0; $i -lt $vks.Length; $i++) { $vkArr[$i] = [int]$vks[$i] }
        # physical 预告：AI 光标滑到真实光标旁边说一句，停 2 秒再接管（Ctrl+Alt+Q 可暂停）。
        try {
          $rcW = [DshInput]::CursorPos()
          if (Get-SlowMode $req) { [DshOverlay]::MoveToQuiet([int]$rcW[0] + 36, [int]$rcW[1] + 36, 700) } else { [DshOverlay]::ShowAtQuiet([int]$rcW[0] + 36, [int]$rcW[1] + 36) }
          $__mvDeadline = (Get-Date).AddMilliseconds(3500); while ([DshOverlay]::IsMoving -and (Get-Date) -lt $__mvDeadline) { Start-Sleep -Milliseconds 25 }
          [DshOverlay]::ShowBadge(([DshOverlay]::PhraseTakeover($raw)), 2000)
          Start-Sleep -Milliseconds 2000
        } catch { }
        [DshInput]::SetAllowPhysical($true)
        try {
          $fg = [DshInput]::GetForegroundWindow()
          if ([DshInput]::RootOf($fg) -ne $root) {
            [DshInput]::FocusWindow($root) | Out-Null
            Start-Sleep -Milliseconds 160
          }
          # 纯键盘动作在屏幕上没有"手"，先在 AI 光标上方弹个气泡说清要按什么
          $badge = if ($req.label) { [string]$req.label } else { $raw }
          try { [DshOverlay]::ShowBadge($badge, 2600) } catch { }
          Start-Sleep -Milliseconds 220
          [DshInput]::PressComboSlow($vkArr, $grace)
          $res = @{
            ok = $true; via = 'physical-keys'; hwnd = [long]$root; keys = $raw
            stoleFocus = $true; note = '真实键盘按下了这些键（会抢焦点）；主人一动键鼠会立刻中止'
          }
          if ($autoUpgraded) {
            # 调用方给的是 auto，实际走了真实键盘：必须说清楚为什么，不然看起来就像"窗口消息成功了"
            $res['degradedFrom'] = ('message-' + $autoWhy)
            $res['suggest'] = 'none'
            $res['note'] = $res['note'] + ('（auto 模式检测到' + $(if ($autoWhy -eq 'game') { '游戏/自绘窗口' } else { ' Chromium' }) + ' 不处理窗口消息，已直接升级为真实键盘）')
          }
          return $res
        }
        catch {
          $msg = $_.Exception.Message
          $reason = 'physical-failed'
          if ($msg -match 'user-takeover') { $reason = 'user-takeover' }
          elseif ($msg -match 'paused') { $reason = 'paused' }
          elseif ($msg -match 'cursor-mismatch') { $reason = 'cursor-mismatch' }
          return @{ ok = $false; reason = $reason; note = "已中止: $msg" }
        }
        finally {
          [DshInput]::SetAllowPhysical($false)
        }
      }
      $targetHwnd = [long]$req.hwnd
      if ($targetHwnd -eq 0) {
        return @{
          ok = $false; reason = 'need-target-hwnd'; strictNoFocusSteal = $true
          note = '必须提供目标窗口 hwnd；不会把按键打到主人当前聚焦的窗口'
        }
      }
      $h = [IntPtr]$targetHwnd
      if (-not [DshInput]::IsWindow($h)) { return @{ ok = $false; reason = 'target-hwnd-invalid'; hwnd = $targetHwnd } }
      foreach ($vk in $vks) { [DshInput]::PostKey($h, [int]$vk, $true, $false, $false) }
      [Array]::Reverse($vks)
      foreach ($vk in $vks) { [DshInput]::PostKey($h, [int]$vk, $false, $false, $false) }
      $script:cursorStyle = 'text'
      [DshOverlay]::SetStyle('text')
      $noteMsg = '已向指定窗口投递按键；不抢焦点'
      $clsK = [DshInput]::WindowClass($h)
      $badK = $false
      if ($clsK -match 'Chrome_WidgetWin') {
        $badK = $true
        $noteMsg = '目标窗口是 Chromium（Chrome_WidgetWin）：它的界面（标签栏、地址栏、网页）不处理窗口消息，这个按键很可能没生效（例如 ctrl+t 不会开新标签）。要按键请用 mode:"physical"'
      }
      elseif ($clsK -match 'Unity|Unreal|YuanShen|GenshinImpact|SDL_app') {
        $badK = $true
        $noteMsg = ('目标窗口是游戏/自绘渲染窗口（' + $clsK + '）：它自己读设备输入、不处理窗口消息，这个按键很可能没生效（例如 alt+f4 不会关游戏）。要按键请用 mode:"physical"')
      }
      $resK = @{ ok = $true; via = 'message-hwnd'; hwnd = [long]$h; keys = $raw; verified = (-not $badK); className = $clsK; note = $noteMsg }
      if ($badK) { $resK['degradedFrom'] = 'message'; $resK['suggest'] = 'physical' }
      return $resK
    }
    'scroll' {
      $x = [int]$req.x
      $y = [int]$req.y
      $delta = if ($req.delta) { [int]$req.delta } else { -120 }
      $mode = if ($req.mode) { [string]$req.mode } else { 'auto' }
      $paused = Get-PausedResult
      if ($null -ne $paused) { return $paused }

      if ($mode -eq 'physical') {
        # physical 预告：AI 光标滑到真实光标旁边说一句，停 2 秒再接管（Ctrl+Alt+Q 可暂停）。
        try {
          $rcW = [DshInput]::CursorPos()
          if (Get-SlowMode $req) { [DshOverlay]::MoveToQuiet([int]$rcW[0] + 36, [int]$rcW[1] + 36, 700) } else { [DshOverlay]::ShowAtQuiet([int]$rcW[0] + 36, [int]$rcW[1] + 36) }
          $__mvDeadline = (Get-Date).AddMilliseconds(3500); while ([DshOverlay]::IsMoving -and (Get-Date) -lt $__mvDeadline) { Start-Sleep -Milliseconds 25 }
          [DshOverlay]::ShowBadge(([DshOverlay]::PhraseTakeover('')), 2000)
          Start-Sleep -Milliseconds 2000
        } catch { }
        [DshInput]::SetAllowPhysical($true)
        [DshOverlay]::FollowCursor($true)
        try {
          [DshInput]::PhysicalScroll($x, $y, $delta)
          Show-StateAt 'vert' $x $y
          return @{ ok = $true; via = 'physical'; x = $x; y = $y; delta = $delta; movedRealCursor = $true; note = '真实滚轮滚过了目标位置' }
        }
        catch {
          $msg = $_.Exception.Message
          $reason = 'physical-failed'
          if ($msg -match 'user-takeover') { $reason = 'user-takeover' }
          elseif ($msg -match 'paused') { $reason = 'paused' }
          elseif ($msg -match 'cursor-mismatch') { $reason = 'cursor-mismatch' }
          return @{ ok = $false; reason = $reason; note = "已中止: $msg" }
        }
        finally {
          [DshOverlay]::FollowCursor($false)
          [DshInput]::SetAllowPhysical($false)
        }
      }
      $dur = if ($null -ne $req.durationMs) { [int]$req.durationMs } else { 300 }
      if ($dur -lt 0) { $dur = 0 }
      if ($dur -gt 4000) { $dur = 4000 }
      Show-StateAt 'vert' $x $y $dur
      $targetHwnd = [long]$req.hwnd
      if ($targetHwnd -eq 0) {
        return @{
          ok = $false; reason = 'need-target-hwnd'; strictNoRealMouse = $true
          note = '必须提供目标窗口 hwnd；只按坐标滚动会滚到主人正在用的窗口'
        }
      }
      $target = [IntPtr]$targetHwnd
      if (-not [DshInput]::IsWindow($target)) { return @{ ok = $false; reason = 'target-hwnd-invalid'; hwnd = $targetHwnd } }
      $root = [DshInput]::RootOf($target)
      $h = [DshInput]::ChildAt($root, $x, $y)
      if ($h -eq [IntPtr]::Zero) { $h = $root }
      [DshInput]::PostMouseScroll($h, $x, $y, $delta)
      Show-StateAt 'vert' $x $y
      # 以前这里直接用子控件句柄填 hwnd，调用方看到"我传的是 132924，回的是 4524424"，
      # 以为目标被偷偷换掉了（D002）。真相是：目标窗口没变，只是消息落在了它的子控件上。
      # 现在 hwnd 如实回传入值，实际收消息的子控件单独放 childHwnd。
      $sameWin = ([long]$h -eq $targetHwnd)
      $noteMsg2 = if ($sameWin) {
        '已投递给目标窗口本身；不移动真实鼠标'
      } else {
        ('已投递给目标窗口 ' + $targetHwnd + ' 的子控件 ' + [long]$h + '；不移动真实鼠标')
      }
      return @{
        ok = $true; via = 'message-hwnd'
        hwnd = $targetHwnd
        childHwnd = [long]$h
        target = [long]$root; delta = $delta; verified = $false
        note = $noteMsg2
      }
    }
    'drag' {
      $x1 = [int]$req.x
      $y1 = [int]$req.y
      $x2 = [int]$req.toX
      $y2 = [int]$req.toY
      $mode = if ($req.mode) { [string]$req.mode } else { 'auto' }
      $duration = if ($req.durationMs) { [int]$req.durationMs } else { 400 }
      $dx = $x2 - $x1
      $dy = $y2 - $y1
      $dragState = if ([Math]::Abs($dx) -gt [Math]::Abs($dy) * 1.6) { 'horz' }
                   elseif ([Math]::Abs($dy) -gt [Math]::Abs($dx) * 1.6) { 'vert' }
                   elseif ($dx * $dy -gt 0) { 'dgn1' }
                   elseif ($dx * $dy -lt 0) { 'dgn2' }
                   else { 'move' }
      $paused = Get-PausedResult
      if ($null -ne $paused) { return $paused }

      if ($mode -eq 'physical') {
        $grace = if ($null -ne $req.takeoverGraceMs) { [int]$req.takeoverGraceMs } else { 120 }
        # physical 预告：AI 光标滑到真实光标旁边说一句，停 2 秒再接管（Ctrl+Alt+Q 可暂停）。
        try {
          $rcW = [DshInput]::CursorPos()
          if (Get-SlowMode $req) { [DshOverlay]::MoveToQuiet([int]$rcW[0] + 36, [int]$rcW[1] + 36, 700) } else { [DshOverlay]::ShowAtQuiet([int]$rcW[0] + 36, [int]$rcW[1] + 36) }
          $__mvDeadline = (Get-Date).AddMilliseconds(3500); while ([DshOverlay]::IsMoving -and (Get-Date) -lt $__mvDeadline) { Start-Sleep -Milliseconds 25 }
          [DshOverlay]::ShowBadge(([DshOverlay]::PhraseTakeover('')), 2000)
          Start-Sleep -Milliseconds 2000
        } catch { }
        [DshInput]::SetAllowPhysical($true)
        [DshOverlay]::FollowCursor($true)
        try {
          [DshInput]::PhysicalDrag($x1, $y1, $x2, $y2, $duration, $grace)
          Show-StateAt $dragState $x2 $y2
          return @{ ok = $true; via = 'physical'; from = @($x1, $y1); to = @($x2, $y2); durationMs = $duration; takeoverGuardMs = $grace; movedRealCursor = $true; note = '真实鼠标拖拽完成；主人一动键鼠会立刻中止' }
        }
        catch {
          $msg = $_.Exception.Message
          $reason = 'physical-failed'
          if ($msg -match 'user-takeover') { $reason = 'user-takeover' }
          elseif ($msg -match 'paused') { $reason = 'paused' }
          elseif ($msg -match 'cursor-mismatch') { $reason = 'cursor-mismatch' }
          $pos = [DshInput]::CursorPos()
          return @{ ok = $false; reason = $reason; atX = $pos[0]; atY = $pos[1]; note = "已中止: $msg" }
        }
        finally {
          [DshOverlay]::FollowCursor($false)
          [DshInput]::SetAllowPhysical($false)
        }
      }
      # 拖拽前让 AI 光标先走到起点
      $dur = if ($null -ne $duration) { [int]$duration } else { 300 }
      if ($dur -lt 0) { $dur = 0 }
      if ($dur -gt 4000) { $dur = 4000 }
      Show-StateAt $dragState $x1 $y1 $dur
      $targetHwnd = [long]$req.hwnd
      if ($targetHwnd -eq 0) {
        return @{
          ok = $false; reason = 'need-target-hwnd'; strictNoRealMouse = $true
          note = '必须提供目标窗口 hwnd；只按坐标拖拽会拖到主人正在用的窗口'
        }
      }
      $target = [IntPtr]$targetHwnd
      if (-not [DshInput]::IsWindow($target)) { return @{ ok = $false; reason = 'target-hwnd-invalid'; hwnd = $targetHwnd } }
      $root = [DshInput]::RootOf($target)
      $h = [DshInput]::ChildAt($root, $x1, $y1)
      if ($h -eq [IntPtr]::Zero) { $h = $root }
      [DshInput]::PostMouseDrag($h, $x1, $y1, $x2, $y2, [Math]::Max(8, [int]($duration / 20)))
      Show-StateAt $dragState $x2 $y2
      return @{ ok = $true; via = 'message-hwnd'; hwnd = [long]$h; target = [long]$root; verified = $false; note = '已投递给指定窗口；不移动真实鼠标' }
    }
    'capture' {
      $path = [string]$req.path
      if ([string]::IsNullOrWhiteSpace($path)) { throw 'path required' }
      # includeOverlay 为真时不隐藏光标：要验证「屏幕上到底有没有那个箭头和气泡」时
      # 必须拍得到它，否则截图永远说不清。
      $keepOverlay = [bool]$req.includeOverlay
      $wasVisible = [DshOverlay]::VisibleNow()
      if ($wasVisible -and -not $keepOverlay) {
        [DshOverlay]::Hide()
        # ToolTip 的隐藏是 Windows 内部异步做的，不等一下会截到残影。
        Start-Sleep -Milliseconds 180
      }
      $src = 'screen'
      $capturedRect = $null
      $usedPrintWindow = $false
      $frame = 'screen'
      $originX = 0; $originY = 0
      $clientX = 0; $clientY = 0; $clientW = 0; $clientH = 0
      try {
        $dir = [System.IO.Path]::GetDirectoryName($path)
        if (-not [string]::IsNullOrWhiteSpace($dir)) { [System.IO.Directory]::CreateDirectory($dir) | Out-Null }
        $capHwnd = 0
        if ($null -ne $req.hwnd) { $capHwnd = [long]$req.hwnd }
        if ($capHwnd -ne 0) {
          if ([DshInput]::IsIconic([IntPtr]$capHwnd)) {
            # D021：最小化窗口截不到内容（PrintWindow 会"成功"但返回黑图），必须明确拒绝。
            return @{ ok = $false; reason = 'window-minimized'; hwnd = $capHwnd
              note = '窗口已最小化，截不到内容（PrintWindow 会返回黑图）。先 activate 把它恢复再截，或改用 browser(op:"eval") 直接读 DOM。' }
          }
          # D016：窗口在前台时用屏幕拷贝——图坐标 == 屏幕坐标，绝对准；
          # 后台/被遮挡时才用 PrintWindow（能拿到它自己的画面，但图的原点是窗口矩形，
          # 与屏幕坐标可能存在偏移，调用方必须看 frame/origin 字段，不能假设两者相等）。
          $isFg = $false
          try { $isFg = [DshInput]::IsForeground($capHwnd) } catch { }
          if ($isFg) {
            $wr = [DshInput]::WindowRect([IntPtr]$capHwnd)
            [DshInput]::CapturePng($path, [int]$wr[0], [int]$wr[1], [int]$wr[2], [int]$wr[3]) | Out-Null
            $src = 'window-screen-copy'
            $frame = 'screen'
            $originX = [int]$wr[0]; $originY = [int]$wr[1]
            $capturedRect = @{ x = [int]$wr[0]; y = [int]$wr[1]; w = [int]$wr[2]; h = [int]$wr[3] }
          } else {
            [DshInput]::CaptureWindowPng($path, $capHwnd, [ref]$usedPrintWindow) | Out-Null
            if (-not $usedPrintWindow) {
              # D021：后台窗口 PrintWindow 失败时**不能**回退屏幕拷贝——那会截到前台窗口的画面，
              # 返回一张"看起来正常但其实不是目标窗口"的图，比报错更危险。
              return @{ ok = $false; reason = 'printwindow-failed'; hwnd = $capHwnd
                note = 'PrintWindow 渲染失败且窗口不在前台——屏幕拷贝只会截到别的窗口，所以拒绝返回错误画面。先 activate 该窗口再截，或改用 browser(op:"eval") 直接读 DOM。' }
            }
            $src = 'window-printwindow'
            $wr = [DshInput]::WindowRect([IntPtr]$capHwnd)
            $frame = 'window-rect'
            $originX = [int]$wr[0]; $originY = [int]$wr[1]
            $capturedRect = @{ x = [int]$wr[0]; y = [int]$wr[1]; w = [int]$wr[2]; h = [int]$wr[3] }
          }
          try {
            $cr = [DshInput]::ClientRectInScreen([long][DshInput]::RootOf([IntPtr]$capHwnd))
            $clientX = [int]$cr[0]; $clientY = [int]$cr[1]; $clientW = [int]$cr[2]; $clientH = [int]$cr[3]
          } catch { }
        } elseif ($req.rect) {
          $parts = ([string]$req.rect) -split ','
          $x = [int]$parts[0]; $y = [int]$parts[1]; $w = [int]$parts[2]; $h = [int]$parts[3]
          [DshInput]::CapturePng($path, $x, $y, $w, $h) | Out-Null
          $src = 'rect'
          $capturedRect = @{ x = $x; y = $y; w = $w; h = $h }
        } else {
          [DshInput]::CapturePng($path, 0, 0, 0, 0) | Out-Null
          $src = 'screen'
          $capturedRect = @{ x = 0; y = 0; w = [DshInput]::ScreenWidth(); h = [DshInput]::ScreenHeight() }
        }
      } finally {
        if ($wasVisible -and -not $keepOverlay -and [DshOverlay]::HasLast) {
          [DshOverlay]::ShowAtQuiet([DshOverlay]::LastX, [DshOverlay]::LastY)
        }
      }
      # D006：把坐标链说清楚，别让调用方自己心算缩放系数
      $iw = 0; $ih = 0
      try {
        $img = [System.Drawing.Image]::FromFile($path)
        $iw = $img.Width; $ih = $img.Height
        $img.Dispose()
      } catch { }
      $sw = [DshInput]::ScreenWidth()
      $sh = [DshInput]::ScreenHeight()
      return @{
        ok = $true
        path = $path
        source = $src
        frame = $frame
        originX = $originX
        originY = $originY
        clientX = $clientX
        clientY = $clientY
        clientSize = @{ w = $clientW; h = $clientH }
        imageSize = @{ w = $iw; h = $ih }
        screenSize = @{ w = $sw; h = $sh }
        capturedRect = $capturedRect
        scale = 1.0
        note = '图是屏幕物理像素。坐标换算：屏幕点 = 图内点 + (originX, originY)；若要用客户区坐标，屏幕点 = 客户区点 + (clientX, clientY)。frame 说明图的原点属于哪个坐标系（screen / window-rect）。若你看到的是被降采样的预览，按 imageSize/预览尺寸 的比值放大回去。'
      }
    }
    'overlayShot' {
      $path = [string]$req.path
      if ([string]::IsNullOrWhiteSpace($path)) { throw 'path required' }
      $dir = [System.IO.Path]::GetDirectoryName($path)
      if (-not [string]::IsNullOrWhiteSpace($dir)) { [System.IO.Directory]::CreateDirectory($dir) | Out-Null }
      $s = 0
      if ($null -ne $req.size) { $s = [int]$req.size }
      if ($s -le 0) { $s = $script:cursorSize }
      [DshInput]::CapturePng($path, [DshOverlay]::LastX, [DshOverlay]::LastY, $s, $s) | Out-Null
      return @{ ok = $true; path = $path; x = [DshOverlay]::LastX; y = [DshOverlay]::LastY; size = $s }
    }
    'shutdown' {
      [DshOverlay]::Stop()
      [DshInput]::StopHooks()
      [DshInput]::StopHotkey()
      return @{ ok = $true }
    }
    default { throw "unknown command: $cmd" }
  }
}

# ---------------------------------------------------------------- 光标位置持久化

# 跨进程记住"上一次停在哪儿"，这样即使 sidecar 重启，下一次动作也是从原处走过去，
# 而不是从屏幕外某个角落凭空冒出来。
$script:statePath = Join-Path $env:USERPROFILE '.dsh\independent-input\overlay-state.json'

function Restore-OverlayState {
  try {
    if (-not (Test-Path -LiteralPath $script:statePath)) { return }
    $s = Get-Content -Raw -LiteralPath $script:statePath | ConvertFrom-Json
    if ($null -ne $s.x -and $null -ne $s.y) {
      $x = [int]$s.x; $y = [int]$s.y
      $vs = [System.Windows.Forms.SystemInformation]::VirtualScreen
      if ($x -ge $vs.Left -and $x -le ($vs.Left + $vs.Width) -and $y -ge $vs.Top -and $y -le ($vs.Top + $vs.Height)) {
        [DshOverlay]::RestoreLast($x, $y)
      }
    }
  } catch { }
}

function Save-OverlayState {
  try {
    if (-not [DshOverlay]::HasLast) { return }
    $dir = Split-Path -Parent $script:statePath
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $json = '{"x":' + [DshOverlay]::LastX + ',"y":' + [DshOverlay]::LastY + '}'
    [System.IO.File]::WriteAllText($script:statePath, $json, [System.Text.UTF8Encoding]::new($false))
  } catch { }
}

# ---------------------------------------------------------------- main

$assetDir = Join-Path $PSScriptRoot 'assets\cursors'
try {
  [DshOverlay]::ConfigureStyles($assetDir)
  [DshOverlay]::SetStyle($script:cursorStyle)
  [DshOverlay]::SetMode($script:cursorMode, $script:cursorHoldMs)
  [DshOverlay]::SetSize($script:cursorSize)
} catch { }

Restore-OverlayState

# 同路径下还有别的 sidecar 在跑吗？多实例会抢热键、叠 overlay，需要让主人看见
$script:peerSidecars = 0
try {
  $me = $PID
  $others = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue | Where-Object { $_.ProcessId -ne $me -and $_.CommandLine -and $_.CommandLine -like '*sidecar.ps1*' })
  $script:peerSidecars = $others.Count
} catch { }

[DshInput]::StartHotkey()
$ready = @{
  event = 'ready'
  pid = $PID
  uia = $script:uia
  hotkey = 'Ctrl+Alt+Q'
  version = '0.3.0'
}
$script:stdout.WriteLine((ConvertTo-Json $ready -Compress))

while ($true) {
  $line = $script:stdin.ReadLine()
  if ($null -eq $line) { break }
  if ([string]::IsNullOrWhiteSpace($line)) { continue }
  $id = $null
  try {
    $req = $line | ConvertFrom-Json
    $id = $req.id
    $result = Invoke-Request $req
    if ($result -is [hashtable]) {
      $result['cursorState'] = if ([DshInput]::Paused) { 'unavailiable' } else { $script:cursorStyle }
      # D005：UIA 容器（列表行/整页）的 name 是所有子文本拼接，直接回传是纯噪音
      if ($result.ContainsKey('name') -and $result['name'] -is [string] -and $result['name'].Length -gt 120) {
        $result['nameTotalLen'] = $result['name'].Length
        $result['name'] = $result['name'].Substring(0, 120) + '…'
      }
      if ($result.ContainsKey('elements') -and $result['elements'] -is [System.Collections.IEnumerable]) {
        foreach ($el in $result['elements']) {
          if (($el -is [hashtable]) -and $el.ContainsKey('name') -and ($el['name'] -is [string]) -and $el['name'].Length -gt 120) {
            $el['nameTotalLen'] = $el['name'].Length
            $el['name'] = $el['name'].Substring(0, 120) + '…'
          }
        }
      }
    }
    $resp = @{ id = $id; ok = $true; result = $result }
  } catch {
    $resp = @{ id = $id; ok = $false; error = $_.Exception.Message }
  }
  $script:stdout.WriteLine((ConvertTo-Json $resp -Compress -Depth 16))
  if ($req.cmd -eq 'shutdown') { break }
}


