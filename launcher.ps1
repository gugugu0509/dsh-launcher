# ============================================================================
#  DSH 桌面启动器 (DeepSeek Harness Desktop Launcher)
#  ---------------------------------------------------------------------------
#  启动 / 停止 / 打开 DeepSeek Harness Web 界面。
#  双击同目录下的 "启动DSH.bat" 运行，或直接：
#     powershell -NoProfile -ExecutionPolicy Bypass -File launcher.ps1
#
#  可选参数：
#     -HarnessDir <路径>   显式指定 DSH 源码目录（默认自动检测）
#     -Port <端口>         Web 端口（默认 3080）
# ============================================================================
param(
    [switch]$NoAutoOpen,
    [switch]$GenIconOnly,
    [string]$HarnessDir = '',   # 可选：显式指定 DSH 源码目录
    [int]$Port = 3080           # Web 端口
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------- 配置 ------
$WebRoot = "http://127.0.0.1:$Port"

$LauncherDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$LogDir      = Join-Path $LauncherDir 'logs'
$OutLog      = Join-Path $LogDir 'dsh-web.log'
$ErrLog      = Join-Path $LogDir 'dsh-web.err.log'
$PidFile     = Join-Path $LauncherDir 'dsh.pid'
$IconPath    = Join-Path $LauncherDir 'dsh.ico'
$UsageScript = Join-Path $LauncherDir 'usage.js'
$UsageResult = Join-Path $LogDir 'usage-result.json'

# 大肥鱼吃白饭 —— 人物素材（透明 PNG，来源见 README）
$FishFront   = Join-Path $LauncherDir 'assets\front.png'   # 大肥鱼正面立绘（界面展示）
$FishIcon    = Join-Path $LauncherDir 'assets\icon.png'    # 大肥鱼头像（窗口图标）
$FishMeme    = Join-Path $LauncherDir 'assets\meme.png'    # 经典「你这吃白饭的蓝色大肥鱼」插画

# ------------------------------------------------------------- 初始化 ------
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# 隐藏启动器自带的控制台黑窗：powershell 进程会伴随一个命令窗口，
# 即使 GUI 窗口正常，这个黑窗一直存在。关闭它不影响运行，但很碍眼。
try {
    Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class ConsoleBox {
    [DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
}
"@
    $consoleHwnd = [ConsoleBox]::GetConsoleWindow()
    if ($consoleHwnd -ne [IntPtr]::Zero) { [ConsoleBox]::ShowWindow($consoleHwnd, 0) | Out-Null }  # SW_HIDE=0
} catch { }

if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }

# ------------------------------------------------------------ 路径检测 ------
function Test-DshCheckout {
    param([string]$Dir)
    if (-not $Dir -or -not (Test-Path $Dir)) { return $false }
    return (Test-Path (Join-Path $Dir 'pnpm-workspace.yaml')) -and
           (Test-Path (Join-Path $Dir 'package.json')) -and
           (Test-Path (Join-Path $Dir 'apps\web'))
}

function Resolve-HarnessDir {
    # 1) 显式指定（命令行参数 / 环境变量 DSH_HARNESS_DIR）
    if ($HarnessDir -and (Test-DshCheckout $HarnessDir)) { return $HarnessDir }
    if ($env:DSH_HARNESS_DIR -and (Test-DshCheckout $env:DSH_HARNESS_DIR)) { return $env:DSH_HARNESS_DIR }

    # 2) 从正在运行的 DSH 进程命令行推断（最贴近实际）
    try {
        $conn = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue |
                Select-Object -First 1
        if ($conn) {
            $proc = Get-CimInstance Win32_Process -Filter "ProcessId=$($conn.OwningProcess)" -ErrorAction SilentlyContinue
            if ($proc -and $proc.CommandLine) {
                $cands = [regex]::Matches($proc.CommandLine, '[A-Za-z]:\\[^"\s]*') |
                         ForEach-Object { $_.Value }
                foreach ($c in $cands) {
                    $p = $c
                    for ($i = 0; $i -lt 4; $i++) {
                        if (-not $p) { break }
                        if (Test-DshCheckout $p) { return $p }
                        $p = Split-Path -Parent $p
                    }
                }
            }
        }
    } catch { }

    # 3) 从启动器所在目录向上查找（检查自身及同级含 harness/dsh 的目录）
    $cur = $LauncherDir
    for ($i = 0; $i -lt 6; $i++) {
        if (Test-DshCheckout $cur) { return $cur }
        $kids = Get-ChildItem $cur -Directory -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -match 'harness|dsh' }
        foreach ($k in $kids) { if (Test-DshCheckout $k.FullName) { return $k.FullName } }
        $parent = Split-Path -Parent $cur
        if (-not $parent -or $parent -eq $cur) { break }
        $cur = $parent
    }

    # 4) 未找到：返回 $null（调用方会提示用 -HarnessDir 或 DSH_HARNESS_DIR 指定）
    return $null
}

$ResolvedHarness = Resolve-HarnessDir

# ---------------------------------------------------------------- 函数 ------
function Test-DshRunning {
    # 用轻量 TcpClient 快速探测端口是否在监听。
    # 原实现 Get-NetTCPConnection 在虚拟网络/远程桌面（Todesk 等）下极慢甚至卡住，
    # 会阻塞 UI 线程导致窗口转圈、无法拖动。改用带短超时的 TCP 连接测试。
    try {
        $client = New-Object System.Net.Sockets.TcpClient
        try {
            $ar = $client.BeginConnect('127.0.0.1', $Port, $null, $null)
            $ok = $ar.AsyncWaitHandle.WaitOne(300, $false)   # 300ms 超时
            if ($ok) { $client.EndConnect($ar); return $true }
            return $false
        } finally {
            if ($client) { try { $client.Close() } catch { } }
        }
    } catch { return $false }
}

function Get-TokenUrl {
    # 从日志里提取带 token 的完整地址；找不到就退回根地址。
    # 自己的日志优先；再回退到 E 盘共享启动日志（外部/一键脚本启动的实例 token 在那）。
    # 额外日志（例如由外部脚本启动的实例）可用环境变量 DSH_EXTRA_LOGS 指定，多个路径用 ; 分隔
    $extra = @()
    if ($env:DSH_EXTRA_LOGS) { $extra = @($env:DSH_EXTRA_LOGS -split ';' | Where-Object { $_ -and (Test-Path $_) }) }
    foreach ($log in @($OutLog, $ErrLog) + $extra) {
        if (Test-Path $log) {
            $content = Get-Content $log -Raw -ErrorAction SilentlyContinue
            if ($content) {
                $m = [regex]::Match($content, 'http://127\.0\.0\.1:\d+/\?token=[^\s\r\n]+')
                if ($m.Success) { return $m.Value }
            }
        }
    }
    return $WebRoot
}

function Adopt-RunningDsh {
    # 若 dsh 已在运行但 dsh.pid 记录的进程失效（例如由外部/一键脚本启动），
    # 认领当前监听 3080 的进程，使「停止/关窗(停止)」与本启动器启动时的行为一致。
    if (-not (Test-DshRunning)) { return }
    try {
        $conn = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
        $live = $conn.OwningProcess
        if (-not $live) { return }
        $owned = $false
        if (Test-Path $PidFile) {
            $pid_ = (Get-Content $PidFile -Raw -ErrorAction SilentlyContinue).Trim()
            if ($pid_ -eq ([string]$live)) { $owned = $true }
        }
        if (-not $owned) {
            Set-Content -Path $PidFile -Value $live -Encoding ASCII
            Write-Host ("[Adopt] 已认领当前运行的 dsh (PID {0})" -f $live)
        }
    } catch { }
}

function Start-Dsh {
    if (Test-DshRunning) { return $false }   # 已在运行
    # 清空 WorkBuddy 劫持环境，避免 dsh 启动时被杀
    $env:NODE_OPTIONS=''; $env:ELECTRON_RUN_AS_NODE=''
    $env:CODEBUDDY_SAFE_DELETE_ENABLED=''; $env:CODEBUDDY_SAFE_DELETE_BULK_GUARD=''
    $env:CODEBUDDY_SAFE_DELETE_SANDBOX=''; $env:CODEBUDDY_SAFE_DELETE_BULK_STATE_DIR=''
    $env:CODEBUDDY_SAFE_DELETE_BIN_DIR=''; $env:CODEBUDDY_NODE_BIN=''
    # 如需指定数据目录，请在启动前设置 DSH_HOME（这里不再硬编码）

    # 清空旧日志，确保本次启动的日志是干净的
    Set-Content -Path $OutLog -Value '' -Encoding UTF8 -ErrorAction SilentlyContinue
    Set-Content -Path $ErrLog -Value '' -Encoding UTF8 -ErrorAction SilentlyContinue

    # 启动方式（二选一）：
    #   ① 设了 DSH_BIN（指向打包版 .../@deepseek-ai/dsh/lib/bin.js）→ 用 node 直接起
    #   ② 否则在 DSH 源码目录用 pnpm dsh web 启动
    $bin = $env:DSH_BIN
    if ($bin -and (Test-Path $bin)) {
        $node = if ($env:DSH_NODE) { $env:DSH_NODE } else { 'node' }
        $proc = Start-Process -FilePath $node `
            -ArgumentList @($bin, 'web', '--no-open') `
            -RedirectStandardOutput $OutLog `
            -RedirectStandardError $ErrLog `
            -WindowStyle Hidden `
            -PassThru
    } else {
        if (-not $ResolvedHarness) {
            throw '未找到 DSH 源码目录：请用 -HarnessDir / DSH_HARNESS_DIR 指定，或设置 DSH_BIN 指向打包版 bin.js。'
        }
        $proc = Start-Process -FilePath 'cmd.exe' `
            -ArgumentList '/c', 'pnpm dsh web --no-open' `
            -WorkingDirectory $ResolvedHarness `
            -RedirectStandardOutput $OutLog `
            -RedirectStandardError $ErrLog `
            -WindowStyle Hidden `
            -PassThru
    }

    Set-Content -Path $PidFile -Value $proc.Id -Encoding ASCII
    return $true
}

function Stop-Dsh {
    # 停止 dsh：优先按记录的进程树，否则按端口兜底。
    # 加固：进程不存在时不再抛错（避免 $ErrorActionPreference='Stop' 导致未处理异常弹窗）。
    $killed = $false
    try {
        if (Test-Path $PidFile) {
            $pid_ = (Get-Content $PidFile -Raw -ErrorAction SilentlyContinue).Trim()
            if ($pid_ -match '^\d+$') {
                # 仅在进程仍存活时才结束，避免 taskkill 对失效 PID 报错
                if (Get-Process -Id ([int]$pid_) -ErrorAction SilentlyContinue) {
                    taskkill /PID $pid_ /T /F 2>$null | Out-Null
                    $killed = $true
                }
            }
            Remove-Item $PidFile -ErrorAction SilentlyContinue
        }

        Start-Sleep -Milliseconds 500
        if (Test-DshRunning) {
            $conn = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
            foreach ($c in $conn) {
                Stop-Process -Id $c.OwningProcess -Force -ErrorAction SilentlyContinue
                $killed = $true
            }
        }
    } catch {
        # 吞掉并仅写提示，绝不因失效 PID 等中断 GUI
        try { Write-Host ("[Stop-Dsh] " + $_.Exception.Message) } catch { }
    }
    return $killed
}

function Open-Dsh {
    $url = Get-TokenUrl
    Start-Process $url
}

function Get-PetProcesses([string]$exePath) {
    # 用 CIM 按进程名 + 可执行路径定位桌宠进程（避免 Get-Process .Path 在
    # 提权/系统进程上抛异常，被 $ErrorActionPreference='Stop' 放大导致杀不掉）
    $name = Split-Path -Leaf $exePath
    Get-CimInstance Win32_Process -Filter ("Name='{0}'" -f $name) -ErrorAction SilentlyContinue |
        Where-Object { $_.ExecutablePath -eq $exePath }
}

function Get-LogTail {
    # 只读日志末尾（最多 300 行），避免全量读大日志文件阻塞 UI 线程
    if (-not (Test-Path $OutLog)) { return '' }
    $text = Get-Content $OutLog -Tail 300 -ErrorAction SilentlyContinue
    if (-not $text) { $text = Get-Content $ErrLog -Tail 300 -ErrorAction SilentlyContinue }
    return ($text -join "`n")
}

function Format-Tokens {
    param([double]$n)
    if ($n -ge 1e9) { return ('{0:N2}B' -f ($n / 1e9)) }
    if ($n -ge 1e6) { return ('{0:N2}M' -f ($n / 1e6)) }
    if ($n -ge 1e3) { return ('{0:N1}K' -f ($n / 1e3)) }
    return ('{0:N0}' -f $n)
}

function Get-Usage {
    # 运行 usage.js，返回解析后的对象；失败返回 $null。
    # 用带超时的异步进程启动，避免 node 卡住阻塞 UI 线程。
    if (-not (Test-Path $UsageScript)) { return $null }
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = 'node'
        # 参数用双引号包裹路径（路径含空格时必需），不要多加引号
        $psi.Arguments = ('"{0}" "{1}"' -f $UsageScript, $UsageResult)
        $psi.WorkingDirectory = $LauncherDir
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.CreateNoWindow = $true
        $proc = [System.Diagnostics.Process]::Start($psi)
        if (-not $proc.WaitForExit(5000)) {   # 5 秒超时
            try { $proc.Kill() } catch { }
            return $null
        }
        if (Test-Path $UsageResult) {
            $content = Get-Content $UsageResult -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
            if ($content) { return ($content | ConvertFrom-Json) }
        }
        return $null
    } catch { return $null }
}

# ----------------------------------------------------------------- 图标 -----
function New-DshIcon {
    # 用「大肥鱼吃白饭」高清立绘生成 256x256 窗口/桌面图标（透明底 + 深蓝圆底 + 大肥鱼立绘）
    # 优先使用 assets\front.png（高清正面立绘），缺失时退回 assets\icon.png
    $srcPng = if (Test-Path $FishFront) { $FishFront } elseif (Test-Path $FishIcon) { $FishIcon } else { $null }

    $size = 256
    $bmp = New-Object System.Drawing.Bitmap $size, $size
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $g.Clear([System.Drawing.Color]::Transparent)

    # 底部圆形深蓝底座，衬托蓝色大肥鱼
    $sz = 216
    $rect = New-Object System.Drawing.Rectangle ([int](($size - $sz) / 2)), ([int](($size - $sz) / 2)), $sz, $sz
    $brush = New-Object System.Drawing.Drawing2D.LinearGradientBrush($rect,
        [System.Drawing.Color]::FromArgb(30, 30, 46),
        [System.Drawing.Color]::FromArgb(60, 70, 120), 135)
    $g.FillEllipse($brush, $rect)

    if ($srcPng) {
        $src = [System.Drawing.Image]::FromFile($srcPng)
        try {
            # 居中绘制，等比缩放到 208px
            $ratio = [Math]::Min(208.0 / $src.Width, 208.0 / $src.Height)
            $w = [int]($src.Width * $ratio)
            $h = [int]($src.Height * $ratio)
            $x = [int](($size - $w) / 2)
            $y = [int](($size - $h) / 2)
            $g.DrawImage($src, $x, $y, $w, $h)
            # 同时生成高清桌面 PNG 图标（透明底），供桌面快捷方式使用
            try {
                $bmp.Save((Join-Path $LauncherDir 'fish-desktop.png'), [System.Drawing.Imaging.ImageFormat]::Png)
            } catch { }
        } finally { $src.Dispose() }
    } else {
        # 无素材时退回文字版
        $font = New-Object System.Drawing.Font 'Segoe UI', 60, ([System.Drawing.FontStyle]::Bold)
        $sf = New-Object System.Drawing.StringFormat
        $sf.Alignment = [System.Drawing.StringAlignment]::Center
        $sf.LineAlignment = [System.Drawing.StringAlignment]::Center
        $g.DrawString('DSH', $font, [System.Drawing.Brushes]::White, (New-Object System.Drawing.RectangleF 0, 0, $size, $size), $sf)
        $font.Dispose(); $sf.Dispose()
    }

    $brush.Dispose(); $g.Dispose(); $bmp.Dispose()

    # 用独立的 ICO 组装脚本把 fish-desktop.png 转成多尺寸 .ico。
    # GetHicon()/Icon.Save() 只能产出单尺寸、低色深的 .ico，桌面/任务栏显示效果差。
    $makeIcon = Join-Path $LauncherDir '制作图标.ps1'
    if (Test-Path $makeIcon) {
        try { & $makeIcon -Source (Join-Path $LauncherDir 'fish-desktop.png') -Out $IconPath } catch { }
    }
}

if (-not (Test-Path $IconPath)) { try { New-DshIcon } catch { $IconPath = $null } }

# 仅生成图标（供快捷方式安装脚本调用），生成后立即退出，不启动 GUI
if ($GenIconOnly) { exit 0 }

# -------------------------------------------------------------- 界面主题 -----
$Bg      = [System.Drawing.Color]::FromArgb(30, 30, 46)   # #1e1e2e
$BgPanel = [System.Drawing.Color]::FromArgb(24, 24, 37)   # #181825
$Fg      = [System.Drawing.Color]::FromArgb(205, 214, 244) # #cdd6f4
$Muted   = [System.Drawing.Color]::FromArgb(166, 173, 200) # #a6adc8
$Green   = [System.Drawing.Color]::FromArgb(166, 227, 161) # #a6e3a1
$Red     = [System.Drawing.Color]::FromArgb(243, 139, 168) # #f38ba8
$Blue    = [System.Drawing.Color]::FromArgb(137, 180, 250) # #89b4fa
$Yellow  = [System.Drawing.Color]::FromArgb(249, 226, 175) # #f9e2af

$fontUi   = New-Object System.Drawing.Font 'Microsoft YaHei UI', 9
$fontTitle= New-Object System.Drawing.Font 'Microsoft YaHei UI', 14, ([System.Drawing.FontStyle]::Bold)
$fontMono = New-Object System.Drawing.Font 'Consolas', 9

# ----------------------------------------------------------------- 窗体 -----
$form = New-Object System.Windows.Forms.Form
$form.Text = 'DSH 启动器 · 大肥鱼吃白饭（关窗=停止 DSH）'
$form.Size = New-Object System.Drawing.Size 560, 640
# 手动定位（不依赖 CenterScreen）——多显示器 / 虚拟显示器（Todesk、MuMu 等）下
# CenterScreen 会把窗口算到副屏或屏幕外，导致标题栏不可见、窗口无法拖动。
# 位置在 Run 之前按主屏工作区中心计算，这里仅确保 StartPosition 为 Manual。
$form.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
$form.BackColor = $Bg
$form.ForeColor = $Fg
$form.MinimumSize = New-Object System.Drawing.Size 480, 520
if ($IconPath) { $form.Icon = New-Object System.Drawing.Icon $IconPath }

# 注意：不再设置 TopMost。置顶会让启动器永久浮在最上层、挡住其他窗口，
# 用户已反馈困扰。窗口本身可正常拖动（UI 线程阻塞已修复）。

# 确保窗口显示时一定还原为正常状态（防止外部以 -WindowStyle Hidden / 最小化启动时窗口不出现）
$form.Add_Shown({
    $form.WindowState = [System.Windows.Forms.FormWindowState]::Normal
    $form.ShowInTaskbar = $true
    $form.Activate()
})

# 大肥鱼吃白饭 —— 人物立绘（透明 PNG，展示在标题左侧）
$picFish = New-Object System.Windows.Forms.PictureBox
$picFish.SizeMode = [System.Windows.Forms.PictureBoxSizeMode]::Zoom
$picFish.BackColor = [System.Drawing.Color]::Transparent
$picFish.Location = New-Object System.Drawing.Point 16, 12
$picFish.Size = New-Object System.Drawing.Size 48, 64
if (Test-Path $FishFront) {
    try {
        $bytes = [System.IO.File]::ReadAllBytes($FishFront)
        $ms = New-Object System.IO.MemoryStream (,$bytes)
        $picFish.Image = [System.Drawing.Image]::FromStream($ms)
    } catch { }
}
$form.Controls.Add($picFish)

# 标题
$lblTitle = New-Object System.Windows.Forms.Label
$lblTitle.Text = 'DeepSeek Harness'
$lblTitle.Font = $fontTitle
$lblTitle.ForeColor = $Fg
$lblTitle.Location = New-Object System.Drawing.Point 72, 18
$lblTitle.Size = New-Object System.Drawing.Size 250, 34
$form.Controls.Add($lblTitle)

$lblSubtitle = New-Object System.Windows.Forms.Label
$lblSubtitle.Text = '桌面启动器 · 大肥鱼吃白饭'
$lblSubtitle.Font = $fontUi
$lblSubtitle.ForeColor = $Muted
$lblSubtitle.Location = New-Object System.Drawing.Point 74, 52
$lblSubtitle.Size = New-Object System.Drawing.Size 240, 20
$form.Controls.Add($lblSubtitle)

# 状态指示灯
$lblStatus = New-Object System.Windows.Forms.Label
$lblStatus.Font = New-Object System.Drawing.Font 'Microsoft YaHei UI', 10, ([System.Drawing.FontStyle]::Bold)
$lblStatus.ForeColor = $Muted
$lblStatus.TextAlign = [System.Drawing.ContentAlignment]::MiddleRight
$lblStatus.Location = New-Object System.Drawing.Point 330, 18
$lblStatus.Size = New-Object System.Drawing.Size 210, 40
$lblStatus.Text = '●  未检测'
$form.Controls.Add($lblStatus)

# 按钮区
function New-Button {
    param([string]$Text, [System.Drawing.Color]$Color, [int]$X, [int]$Y, [int]$W, [int]$H)
    $btn = New-Object System.Windows.Forms.Button
    $btn.Text = $Text
    $btn.Font = $fontUi
    $btn.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $btn.FlatAppearance.BorderSize = 0
    $btn.BackColor = $Color
    $btn.ForeColor = $Bg
    $btn.Location = New-Object System.Drawing.Point $X, $Y
    $btn.Size = New-Object System.Drawing.Size $W, $H
    $btn.Cursor = [System.Windows.Forms.Cursors]::Hand
    return $btn
}

$btnStart = New-Button '启动'  $Green 20 88 120 40
$btnStop  = New-Button '停止'  $Red   152 88 120 40
$btnOpen  = New-Button '打开界面' $Blue 284 88 120 40
$btnLog   = New-Button '日志'  $BgPanel 416 88 120 40
$btnLog.ForeColor = $Fg
$form.Controls.Add($btnStart)
$form.Controls.Add($btnStop)
$form.Controls.Add($btnOpen)
$form.Controls.Add($btnLog)

# 自动打开浏览器勾选框
$chkAutoOpen = New-Object System.Windows.Forms.CheckBox
$chkAutoOpen.Text = '启动后自动打开浏览器'
$chkAutoOpen.Font = $fontUi
$chkAutoOpen.ForeColor = $Muted
$chkAutoOpen.Checked = -not $NoAutoOpen
$chkAutoOpen.Location = New-Object System.Drawing.Point 24, 144
$chkAutoOpen.Size = New-Object System.Drawing.Size 220, 24
$form.Controls.Add($chkAutoOpen)

# 用量面板（余额 + token）
$pnlUsage = New-Object System.Windows.Forms.Panel
$pnlUsage.BackColor = $BgPanel
$pnlUsage.Location = New-Object System.Drawing.Point 20, 174
$pnlUsage.Size = New-Object System.Drawing.Size 516, 64
$pnlUsage.Anchor = 'Top, Left, Right'
$form.Controls.Add($pnlUsage)

$lblBalanceCap = New-Object System.Windows.Forms.Label
$lblBalanceCap.Text = '账户余额'
$lblBalanceCap.Font = $fontUi
$lblBalanceCap.ForeColor = $Muted
$lblBalanceCap.Location = New-Object System.Drawing.Point 14, 8
$lblBalanceCap.Size = New-Object System.Drawing.Size 70, 18
$pnlUsage.Controls.Add($lblBalanceCap)

$lblBalance = New-Object System.Windows.Forms.Label
$lblBalance.Text = '¥ —'
$lblBalance.Font = New-Object System.Drawing.Font 'Microsoft YaHei UI', 13, ([System.Drawing.FontStyle]::Bold)
$lblBalance.ForeColor = $Green
$lblBalance.Location = New-Object System.Drawing.Point 14, 26
$lblBalance.Size = New-Object System.Drawing.Size 124, 28
$pnlUsage.Controls.Add($lblBalance)

$lblTokensCap = New-Object System.Windows.Forms.Label
$lblTokensCap.Text = '已用 Tokens'
$lblTokensCap.Font = $fontUi
$lblTokensCap.ForeColor = $Muted
$lblTokensCap.Location = New-Object System.Drawing.Point 190, 8
$lblTokensCap.Size = New-Object System.Drawing.Size 110, 18
$pnlUsage.Controls.Add($lblTokensCap)

$lblTokens = New-Object System.Windows.Forms.Label
$lblTokens.Text = '—'
$lblTokens.Font = New-Object System.Drawing.Font 'Microsoft YaHei UI', 13, ([System.Drawing.FontStyle]::Bold)
$lblTokens.ForeColor = $Fg
$lblTokens.Location = New-Object System.Drawing.Point 190, 26
$lblTokens.Size = New-Object System.Drawing.Size 190, 28
$pnlUsage.Controls.Add($lblTokens)

$lblTokensDetail = New-Object System.Windows.Forms.Label
$lblTokensDetail.Text = '输入/输出/缓存'
$lblTokensDetail.Font = New-Object System.Drawing.Font 'Microsoft YaHei UI', 7.5
$lblTokensDetail.ForeColor = $Muted
$lblTokensDetail.Location = New-Object System.Drawing.Point 368, 8
$lblTokensDetail.Size = New-Object System.Drawing.Size 60, 44
$lblTokensDetail.TextAlign = [System.Drawing.ContentAlignment]::MiddleRight
$pnlUsage.Controls.Add($lblTokensDetail)

# 手动刷新余额/token 按钮
$btnRefresh = New-Object System.Windows.Forms.Button
$btnRefresh.Text = '刷新'
$btnRefresh.Font = New-Object System.Drawing.Font 'Microsoft YaHei UI', 8
$btnRefresh.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$btnRefresh.FlatAppearance.BorderSize = 0
$btnRefresh.BackColor = [System.Drawing.Color]::FromArgb(69, 71, 90)
$btnRefresh.ForeColor = $Fg
$btnRefresh.Cursor = [System.Windows.Forms.Cursors]::Hand
$btnRefresh.Location = New-Object System.Drawing.Point 474, 20
$btnRefresh.Size = New-Object System.Drawing.Size 36, 26
$pnlUsage.Controls.Add($btnRefresh)

# 余额充值按钮：一键打开 DeepSeek 官方充值页
$btnTopUp = New-Object System.Windows.Forms.Button
$btnTopUp.Text = '充值 ↗'
$btnTopUp.Font = New-Object System.Drawing.Font 'Microsoft YaHei UI', 8
$btnTopUp.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$btnTopUp.FlatAppearance.BorderSize = 0
$btnTopUp.BackColor = $Blue
$btnTopUp.ForeColor = $Bg
$btnTopUp.Cursor = [System.Windows.Forms.Cursors]::Hand
$btnTopUp.Location = New-Object System.Drawing.Point 432, 20
$btnTopUp.Size = New-Object System.Drawing.Size 40, 26
$pnlUsage.Controls.Add($btnTopUp)

# ============================================================
# API 价格 + 余额可用量估算面板（DeepSeek 峰谷定价，2026-08-17 起生效）
# ============================================================
$pnlPrice = New-Object System.Windows.Forms.Panel
$pnlPrice.BackColor = $BgPanel
$pnlPrice.Location = New-Object System.Drawing.Point 20, 246
$pnlPrice.Size = New-Object System.Drawing.Size 516, 84
$pnlPrice.Anchor = 'Top, Left, Right'
$form.Controls.Add($pnlPrice)

# 标题行
$lblPriceTitle = New-Object System.Windows.Forms.Label
$lblPriceTitle.Text = 'API 价格 · 峰谷定价（2026-08-17 起生效）'
$lblPriceTitle.Font = New-Object System.Drawing.Font 'Microsoft YaHei UI', 8.5, ([System.Drawing.FontStyle]::Bold)
$lblPriceTitle.ForeColor = $Fg
$lblPriceTitle.Location = New-Object System.Drawing.Point 10, 6
$lblPriceTitle.Size = New-Object System.Drawing.Size 300, 18
$pnlPrice.Controls.Add($lblPriceTitle)

# Flash 行（峰谷定价：空闲/高峰）
$lblFlashCap = New-Object System.Windows.Forms.Label
$lblFlashCap.Text = 'v4-flash  输出 4.5/9元 · 输入 1.5/3元 · 命中 0.05/0.1元'
$lblFlashCap.Font = New-Object System.Drawing.Font 'Microsoft YaHei UI', 8
$lblFlashCap.ForeColor = $Muted
$lblFlashCap.Location = New-Object System.Drawing.Point 10, 28
$lblFlashCap.Size = New-Object System.Drawing.Size 340, 18
$pnlPrice.Controls.Add($lblFlashCap)

# Flash 可用量（余额 ÷ 输出价）
$lblFlashEst = New-Object System.Windows.Forms.Label
$lblFlashEst.Text = '≈ —'
$lblFlashEst.Font = New-Object System.Drawing.Font 'Microsoft YaHei UI', 8
$lblFlashEst.ForeColor = $Green
$lblFlashEst.Location = New-Object System.Drawing.Point 356, 28
$lblFlashEst.Size = New-Object System.Drawing.Size 150, 18
$lblFlashEst.TextAlign = [System.Drawing.ContentAlignment]::MiddleRight
$pnlPrice.Controls.Add($lblFlashEst)

# Pro 行（峰谷定价：空闲/高峰）
$lblProCap = New-Object System.Windows.Forms.Label
$lblProCap.Text = 'v4-pro   输出 13.5/27元 · 输入 4.5/9元 · 命中 0.15/0.3元'
$lblProCap.Font = New-Object System.Drawing.Font 'Microsoft YaHei UI', 8
$lblProCap.ForeColor = $Muted
$lblProCap.Location = New-Object System.Drawing.Point 10, 50
$lblProCap.Size = New-Object System.Drawing.Size 340, 18
$pnlPrice.Controls.Add($lblProCap)

# Pro 可用量
$lblProEst = New-Object System.Windows.Forms.Label
$lblProEst.Text = '≈ —'
$lblProEst.Font = New-Object System.Drawing.Font 'Microsoft YaHei UI', 8
$lblProEst.ForeColor = $Green
$lblProEst.Location = New-Object System.Drawing.Point 356, 50
$lblProEst.Size = New-Object System.Drawing.Size 150, 18
$lblProEst.TextAlign = [System.Drawing.ContentAlignment]::MiddleRight
$pnlPrice.Controls.Add($lblProEst)

# 提示行
$lblPriceHint = New-Object System.Windows.Forms.Label
$lblPriceHint.Text = '价：高峰时段 9:00-12:00 / 14:00-18:00，其余空闲时段半价。估算按输出价。'
$lblPriceHint.Font = New-Object System.Drawing.Font 'Microsoft YaHei UI', 7.5
$lblPriceHint.ForeColor = [System.Drawing.Color]::FromArgb(100, 108, 130)
$lblPriceHint.Location = New-Object System.Drawing.Point 10, 68
$lblPriceHint.Size = New-Object System.Drawing.Size 496, 14
$pnlPrice.Controls.Add($lblPriceHint)

# 日志面板（压缩高度给价格面板让位）
$txtLog = New-Object System.Windows.Forms.TextBox
$txtLog.Multiline = $true
$txtLog.ReadOnly = $true
$txtLog.ScrollBars = [System.Windows.Forms.ScrollBars]::Vertical
$txtLog.BackColor = $BgPanel
$txtLog.ForeColor = $Muted
$txtLog.Font = $fontMono
$txtLog.Location = New-Object System.Drawing.Point 20, 338
$txtLog.Size = New-Object System.Drawing.Size 516, 198
$txtLog.Anchor = 'Top, Bottom, Left, Right'
# 占位提示：说明这个区域是运行日志（DSH 启动/停止时的控制台输出）
$lblLogPlaceholder = New-Object System.Windows.Forms.Label
$lblLogPlaceholder.Text = '运行日志——点击「启动」后会在此显示 DSH 的启动与运行输出。'
$lblLogPlaceholder.Font = $fontUi
$lblLogPlaceholder.ForeColor = [System.Drawing.Color]::FromArgb(100, 108, 130)
$lblLogPlaceholder.Location = New-Object System.Drawing.Point 26, 344
$lblLogPlaceholder.Size = New-Object System.Drawing.Size 504, 20
$lblLogPlaceholder.Anchor = 'Top, Left, Right'
$form.Controls.Add($lblLogPlaceholder)
$form.Controls.Add($txtLog)

# 底部状态栏
$lblBar = New-Object System.Windows.Forms.Label
$lblBar.Font = $fontUi
$lblBar.ForeColor = $Muted
$lblBar.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
$lblBar.Location = New-Object System.Drawing.Point 20, 545
$lblBar.Size = New-Object System.Drawing.Size 516, 24
$lblBar.Anchor = 'Bottom, Left, Right'
$form.Controls.Add($lblBar)

# 底部提示：关闭=停止，最小化=后台继续运行（位置紧贴状态栏下方，避免超出客户区）
$lblHint = New-Object System.Windows.Forms.Label
$lblHint.Font = $fontUi
$lblHint.ForeColor = $Muted
$lblHint.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
$lblHint.Text = '提示：关闭窗口=停止 DSH（含后台进程）；最小化=DSH 继续运行'
$lblHint.Location = New-Object System.Drawing.Point 20, 572
$lblHint.Size = New-Object System.Drawing.Size 516, 18
$lblHint.Anchor = 'Bottom, Left, Right'
$form.Controls.Add($lblHint)

# 最小化时任务栏标题给出提示（最小化≠关闭）
$form.Add_Resize({
    if ($form.WindowState -eq [System.Windows.Forms.FormWindowState]::Minimized) {
        $form.Text = 'DSH 启动器 · 最小化≠关闭：DSH 后台运行中，关窗才停止'
    } else {
        $form.Text = 'DSH 启动器 · 大肥鱼吃白饭（关窗=停止 DSH）'
    }
})

# ------------------------------------------------------------- 运行时状态 -----
$script:openedBrowser = $false   # 本次会话是否已自动打开过浏览器
$script:lastLogText  = ''        # 上次日志内容，用于增量刷新
$script:usageTick    = 0         # 用量刷新计数器
$script:usageLoaded  = $false    # 是否已成功加载过一次用量
$script:startingDsh  = $false    # 启动中标记（防重复点击重复拉起进程树）
$script:startedAt    = [DateTime]::UtcNow

function Update-Status {
    $running = Test-DshRunning
    if ($running) {
        $script:startingDsh = $false
        $lblStatus.Text = '●  运行中'
        $lblStatus.ForeColor = $Green
        $btnStart.Enabled = $false
        $btnStop.Enabled  = $true
        $lblBar.Text = "端口 $Port  ·  $WebRoot"
    } else {
        $lblStatus.Text = '●  已停止'
        $lblStatus.ForeColor = $Red
        $btnStart.Enabled = $true
        $btnStop.Enabled  = $false
        $lblBar.Text = "DSH 未运行"
    }
}

function Refresh-Log {
    $text = Get-LogTail
    if ($text -ne $script:lastLogText) {
        $script:lastLogText = $text
        # 有真实日志内容时隐藏占位提示，恢复日志文字颜色
        if ($text.Trim().Length -gt 0) {
            $lblLogPlaceholder.Visible = $false
            $txtLog.ForeColor = $Muted
        }
        $txtLog.Text = $text
        $txtLog.SelectionStart = $txtLog.TextLength
        $txtLog.ScrollToCaret()
    }
}

function Apply-Usage {
    # 执行一次用量查询并刷新界面显示（余额 + token）。
    # 手动刷新按钮和定时刷新都调用它。
    $u = Get-Usage
    if ($null -eq $u) {
        if (-not $script:usageLoaded) {
            $lblBalance.Text = '查询失败'
            $lblBalance.ForeColor = $Muted
            $lblTokens.Text = '—'
        }
        return
    }
    $script:usageLoaded = $true

    # 余额
    if ($u.balance -and $u.balance.available) {
        $lblBalance.Text = ('¥ {0:N2}' -f [double]$u.balance.total)
        $lblBalance.ForeColor = $Green
    } elseif ($u.balance) {
        $lblBalance.Text = '不可用'
        $lblBalance.ForeColor = $Red
    } else {
        $lblBalance.Text = '¥ —'
        $lblBalance.ForeColor = $Muted
    }

    # 可用量估算：余额 ÷ 每百万 token 输出价（元）× 100 万 token
    # 分别按高峰价（保守）与空闲价（乐观）估算
    $bal = 0.0
    if ($u.balance -and $u.balance.available) { $bal = [double]$u.balance.total }
    if ($bal -gt 0) {
        # v4-flash 输出：高峰 9 元 / 空闲 4.5 元（每百万 token）
        $flashPeak = $bal / 9.0 * 1e6
        $flashOff  = $bal / 4.5 * 1e6
        $lblFlashEst.Text = ('≈ {0} 输出token（空闲 {1}）' -f (Format-Tokens $flashPeak), (Format-Tokens $flashOff))
        $lblFlashEst.ForeColor = $Green
        # v4-pro 输出：高峰 27 元 / 空闲 13.5 元（每百万 token）
        $proPeak = $bal / 27.0 * 1e6
        $proOff  = $bal / 13.5 * 1e6
        $lblProEst.Text = ('≈ {0} 输出token（空闲 {1}）' -f (Format-Tokens $proPeak), (Format-Tokens $proOff))
        $lblProEst.ForeColor = $Green
    } else {
        $lblFlashEst.Text = '≈ —'
        $lblProEst.Text = '≈ —'
        $lblFlashEst.ForeColor = $Muted
        $lblProEst.ForeColor = $Muted
    }

    # token 用量（明细竖排三行，适应窄面板）
    if ($u.tokens) {
        $total = [double]$u.tokens.total
        $lblTokens.Text = (Format-Tokens $total)
        $fmt = '输入 {0}' + "`r`n" + '输出 {1}' + "`r`n" + '缓存 {2}'
        $lblTokensDetail.Text = ($fmt -f `
            (Format-Tokens ([double]$u.tokens.input)), `
            (Format-Tokens ([double]$u.tokens.output)), `
            (Format-Tokens ([double]$u.tokens.cacheRead)))
    } elseif ($u.error) {
        $lblTokens.Text = '—'
        $lblTokensDetail.Text = $u.error
    }
}

function Update-Usage {
    # 定时刷新：每隔约 10 秒执行一次用量查询（余额 + token）
    $script:usageTick++
    if ($script:usageTick -lt 5) { return }   # 2s * 5 ≈ 10s
    $script:usageTick = 0

    Apply-Usage
}

function On-Tick {
    Update-Status
    Refresh-Log
    Update-Usage

    # 服务起来后，按需自动打开浏览器（带 token 地址）
    if ((Test-DshRunning) -and $chkAutoOpen.Checked -and -not $script:openedBrowser) {
        $script:openedBrowser = $true
        try { Open-Dsh } catch { $script:openedBrowser = $false }
    }
}

# ----------------------------------------------------------------- 事件 -----
$btnStart.Add_Click({
    if (Test-DshRunning) {
        # 已在运行：直接打开界面（点「启动」就是想用 DSH）
        Update-Status
        try { Open-Dsh } catch { }
        return
    }
    if ($script:startingDsh) {
        # 启动中：20 秒内忽略重复点击，避免重复拉起进程树抢端口
        if (([DateTime]::UtcNow - $script:startedAt).TotalSeconds -lt 20) { return }
        $script:startingDsh = $false
    }
    $script:startingDsh = $true
    $script:startedAt = [DateTime]::UtcNow
    $btnStart.Enabled = $false
    $lblStatus.Text = '●  启动中…'
    $lblStatus.ForeColor = $Yellow
    $txtLog.AppendText("`r`n=== 正在启动 DeepSeek Harness ... ===`r`n")
    $txtLog.AppendText("版本: E 盘打包版 0.1.2-rc.1 (DSH_HOME=E)`r`n")
    try {
        Start-Dsh | Out-Null
        $script:openedBrowser = $false
        $script:lastLogText = ''
        $txtLog.AppendText("已启动，等待服务就绪（首次约 5-15 秒，就绪后自动打开浏览器）...`r`n")
    } catch {
        $script:startingDsh = $false
        $btnStart.Enabled = $true
        $txtLog.AppendText("启动失败: $($_.Exception.Message)`r`n")
        if ($_.Exception.Message -match '使用|占用|being used|another process|无法访问|拒绝访问') {
            $txtLog.AppendText("提示：日志文件可能被残留的 DSH 进程占用，请先点「停止」清理后再启动。`r`n")
        }
        [System.Windows.Forms.MessageBox]::Show(
            "启动失败：$($_.Exception.Message)", 'DSH 启动器',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
    }
})

$btnStop.Add_Click({
    $txtLog.AppendText("`r`n=== 正在停止 DeepSeek Harness ... ===`r`n")
    Stop-Dsh | Out-Null
    $script:openedBrowser = $false
    Update-Status
})

$btnOpen.Add_Click({
    if (-not (Test-DshRunning)) {
        [System.Windows.Forms.MessageBox]::Show('DSH 尚未运行，请先点击「启动」。', 'DSH 启动器',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
        return
    }
    Open-Dsh
})

$btnLog.Add_Click({
    $log = if (Test-Path $OutLog) { $OutLog } elseif (Test-Path $ErrLog) { $ErrLog } else { $null }
    if ($log) { Start-Process $log } else {
        [System.Windows.Forms.MessageBox]::Show('暂无日志文件。', 'DSH 启动器') | Out-Null
    }
})

# 手动刷新余额 / token
$btnRefresh.Add_Click({
    $btnRefresh.Enabled = $false
    $btnRefresh.Text = '…'
    try {
        Apply-Usage
        $script:usageLoaded = $true
    } catch { }
    Start-Sleep -Milliseconds 300   # 避免连点
    $btnRefresh.Text = '刷新'
    $btnRefresh.Enabled = $true
})

# 充值：打开 DeepSeek 官方充值页（platform.deepseek.com/top_up）
$btnTopUp.Add_Click({
    try {
        Start-Process 'https://platform.deepseek.com/top_up'
    } catch {
        [System.Windows.Forms.MessageBox]::Show("无法打开充值页面：$($_.Exception.Message)", 'DSH 启动器') | Out-Null
    }
})

$form.Add_FormClosing({
    # 关窗=停止 DSH（设计如此）：但只对本启动器自己启动的 dsh 自动停止；
    # 若 dsh 由外部启动（记录的 PID 已失效/不存在），先询问，避免误杀正在运行的实例。
    $launcherOwned = $false
    if (Test-Path $PidFile) {
        $pid_ = (Get-Content $PidFile -Raw -ErrorAction SilentlyContinue).Trim()
        if ($pid_ -match '^\d+$' -and (Get-Process -Id ([int]$pid_) -ErrorAction SilentlyContinue)) {
            $launcherOwned = $true
        }
    }
    if (Test-DshRunning) {
        if ($launcherOwned) {
            Stop-Dsh | Out-Null
        } else {
            $ans = [System.Windows.Forms.MessageBox]::Show(
                "检测到 DSH 正在运行，但不是由本启动器启动的。`r`n确定要停止它吗？选否=仅关闭本窗口，DSH 继续运行。",
                'DSH 启动器', [System.Windows.Forms.MessageBoxButtons]::YesNo,
                [System.Windows.Forms.MessageBoxIcon]::Question)
            if ($ans -eq [System.Windows.Forms.DialogResult]::Yes) {
                Stop-Dsh | Out-Null
            }
        }
    }
})

# 定时刷新（2 秒一次，避免过快触发同步网络/IO 操作阻塞 UI 线程）
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 2000
$timer.Add_Tick({ On-Tick })
$timer.Start()

# ----------------------------------------------------------------- 启动 -----
Update-Status
Adopt-RunningDsh   # 认领当前已在运行的 dsh（若非本启动器启动），使停止/关窗行为一致
Refresh-Log
$script:usageTick = 12   # 让首次 tick 立即加载用量

# 窗口定位：显示前按主屏工作区中心计算。
# 不用 CenterScreen：多显示器 / 虚拟显示器（Todesk、MuMu 等）下它会把窗口
# 算到副屏甚至屏幕外（标题栏不可见 → 窗口无法拖动）。手动计算保证窗口
# 一定出现在主屏中心，标题栏可见、随时可拖动。
$wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
$form.Location = New-Object System.Drawing.Point (
    ($wa.X + [int](($wa.Width - $form.Width) / 2)),
    ($wa.Y + [int](($wa.Height - $form.Height) / 2)))

[System.Windows.Forms.Application]::Run($form)
$timer.Stop()
