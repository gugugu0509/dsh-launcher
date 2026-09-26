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

# ------------------------------------------------------------- 初始化 ------
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

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

    # 4) 未找到：返回 $null，由调用方提示用 -HarnessDir 显式指定
    return $null
}

$ResolvedHarness = Resolve-HarnessDir

# ---------------------------------------------------------------- 函数 ------
function Test-DshRunning {
    $conn = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
    return [bool]$conn
}

function Get-TokenUrl {
    # 从日志里提取带 token 的完整地址；找不到就退回根地址
    foreach ($log in @($OutLog, $ErrLog)) {
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

function Start-Dsh {
    if (Test-DshRunning) { return $false }   # 已在运行
    if (-not $ResolvedHarness) {
        throw '未找到 DSH 源码目录。可用 -HarnessDir <路径> 显式指定。'
    }

    # 清空旧日志，确保本次启动的日志是干净的
    Set-Content -Path $OutLog -Value '' -Encoding UTF8 -ErrorAction SilentlyContinue
    Set-Content -Path $ErrLog -Value '' -Encoding UTF8 -ErrorAction SilentlyContinue

    # 通过 cmd 启动，pnpm 是 .cmd 垫片，必须交给 cmd 执行
    $proc = Start-Process -FilePath 'cmd.exe' `
        -ArgumentList '/c', 'pnpm dsh web --no-open' `
        -WorkingDirectory $ResolvedHarness `
        -RedirectStandardOutput $OutLog `
        -RedirectStandardError $ErrLog `
        -WindowStyle Hidden `
        -PassThru

    Set-Content -Path $PidFile -Value $proc.Id -Encoding ASCII
    return $true
}

function Stop-Dsh {
    # 优先按记录的进程树结束，否则按端口兜底
    $killed = $false
    if (Test-Path $PidFile) {
        $pid_ = (Get-Content $PidFile -Raw -ErrorAction SilentlyContinue).Trim()
        if ($pid_ -match '^\d+$') {
            & taskkill /PID $pid_ /T /F 2>$null | Out-Null
            $killed = $true
        }
        Remove-Item $PidFile -ErrorAction SilentlyContinue
    }

    Start-Sleep -Milliseconds 500
    if (Test-DshRunning) {
        $conn = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
        foreach ($c in $conn) {
            Stop-Process -Id $c.OwningProcess -Force -ErrorAction SilentlyContinue
        }
        $killed = $true
    }
    return $killed
}

function Open-Dsh {
    $url = Get-TokenUrl
    Start-Process $url
}

function Get-LogTail {
    if (-not (Test-Path $OutLog)) { return '' }
    $text = Get-Content $OutLog -Raw -ErrorAction SilentlyContinue
    if (-not $text) { $text = Get-Content $ErrLog -Raw -ErrorAction SilentlyContinue }
    return $text
}

function Format-Tokens {
    param([double]$n)
    if ($n -ge 1e9) { return ('{0:N2}B' -f ($n / 1e9)) }
    if ($n -ge 1e6) { return ('{0:N2}M' -f ($n / 1e6)) }
    if ($n -ge 1e3) { return ('{0:N1}K' -f ($n / 1e3)) }
    return ('{0:N0}' -f $n)
}

function Get-Usage {
    # 运行 usage.js，返回解析后的对象；失败返回 $null
    if (-not (Test-Path $UsageScript)) { return $null }
    try {
        $raw = & node $UsageScript $UsageResult 2>$null
        if (Test-Path $UsageResult) {
            return (Get-Content $UsageResult -Raw -Encoding UTF8 | ConvertFrom-Json)
        }
        if ($raw) { return ($raw -join "`n" | ConvertFrom-Json) }
    } catch { }
    return $null
}

# ----------------------------------------------------------------- 图标 -----
function New-DshIcon {
    # 生成一个简单的 DSH 图标（圆角渐变底 + 文字）
    $bmp = New-Object System.Drawing.Bitmap 64, 64
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias

    $rect = New-Object System.Drawing.Rectangle 0, 0, 64, 64
    $brush = New-Object System.Drawing.Drawing2D.LinearGradientBrush(
        $rect,
        [System.Drawing.Color]::FromArgb(137, 180, 250),
        [System.Drawing.Color]::FromArgb(180, 190, 254),
        45)
    $g.FillRectangle($brush, $rect)

    $font = New-Object System.Drawing.Font 'Segoe UI', 20, ([System.Drawing.FontStyle]::Bold)
    $sf = New-Object System.Drawing.StringFormat
    $sf.Alignment = [System.Drawing.StringAlignment]::Center
    $sf.LineAlignment = [System.Drawing.StringAlignment]::Center
    $g.DrawString('DSH', $font, [System.Drawing.Brushes]::White, (New-Object System.Drawing.RectangleF 0, 0, 64, 64), $sf)

    $hIcon = $bmp.GetHicon()
    $icon = [System.Drawing.Icon]::FromHandle($hIcon)
    $fs = [System.IO.File]::Create($IconPath)
    try { $icon.Save($fs) } finally { $fs.Close() }

    $icon.Dispose(); $font.Dispose(); $sf.Dispose(); $brush.Dispose(); $g.Dispose(); $bmp.Dispose()
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
$form.Text = 'DSH 启动器'
$form.Size = New-Object System.Drawing.Size 560, 640
$form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
$form.BackColor = $Bg
$form.ForeColor = $Fg
$form.MinimumSize = New-Object System.Drawing.Size 480, 520
if ($IconPath) { $form.Icon = New-Object System.Drawing.Icon $IconPath }

# 标题
$lblTitle = New-Object System.Windows.Forms.Label
$lblTitle.Text = 'DeepSeek Harness'
$lblTitle.Font = $fontTitle
$lblTitle.ForeColor = $Fg
$lblTitle.Location = New-Object System.Drawing.Point 20, 18
$lblTitle.Size = New-Object System.Drawing.Size 320, 34
$form.Controls.Add($lblTitle)

$lblSubtitle = New-Object System.Windows.Forms.Label
$lblSubtitle.Text = '桌面启动器'
$lblSubtitle.Font = $fontUi
$lblSubtitle.ForeColor = $Muted
$lblSubtitle.Location = New-Object System.Drawing.Point 22, 52
$lblSubtitle.Size = New-Object System.Drawing.Size 200, 20
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
$lblBalance.Size = New-Object System.Drawing.Size 150, 28
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
$lblTokensDetail.Text = '输入 · 输出 · 缓存'
$lblTokensDetail.Font = New-Object System.Drawing.Font 'Microsoft YaHei UI', 8
$lblTokensDetail.ForeColor = $Muted
$lblTokensDetail.Location = New-Object System.Drawing.Point 388, 8
$lblTokensDetail.Size = New-Object System.Drawing.Size 122, 44
$lblTokensDetail.TextAlign = [System.Drawing.ContentAlignment]::MiddleRight
$pnlUsage.Controls.Add($lblTokensDetail)

# 日志面板
$txtLog = New-Object System.Windows.Forms.TextBox
$txtLog.Multiline = $true
$txtLog.ReadOnly = $true
$txtLog.ScrollBars = [System.Windows.Forms.ScrollBars]::Vertical
$txtLog.BackColor = $BgPanel
$txtLog.ForeColor = $Muted
$txtLog.Font = $fontMono
$txtLog.Location = New-Object System.Drawing.Point 20, 246
$txtLog.Size = New-Object System.Drawing.Size 516, 290
$txtLog.Anchor = 'Top, Bottom, Left, Right'
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

# ------------------------------------------------------------- 运行时状态 -----
$script:openedBrowser = $false   # 本次会话是否已自动打开过浏览器
$script:lastLogText  = ''        # 上次日志内容，用于增量刷新
$script:usageTick    = 0         # 用量刷新计数器
$script:usageLoaded  = $false    # 是否已成功加载过一次用量

function Update-Status {
    $running = Test-DshRunning
    if ($running) {
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
        $lblBar.Text = 'DSH 未运行'
    }
}

function Refresh-Log {
    $text = Get-LogTail
    if ($text -ne $script:lastLogText) {
        $script:lastLogText = $text
        $txtLog.Text = $text
        $txtLog.SelectionStart = $txtLog.TextLength
        $txtLog.ScrollToCaret()
    }
}

function Update-Usage {
    # 每隔 10 秒刷新一次用量（余额 + token）
    $script:usageTick++
    if ($script:usageTick -lt 13) { return }   # 800ms * 13 ≈ 10.4s
    $script:usageTick = 0

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

    # token 用量
    if ($u.tokens) {
        $total = [double]$u.tokens.total
        $lblTokens.Text = (Format-Tokens $total)
        $lblTokensDetail.Text = ('输入 {0} · 输出 {1} · 缓存 {2}' -f `
            (Format-Tokens ([double]$u.tokens.input)), `
            (Format-Tokens ([double]$u.tokens.output)), `
            (Format-Tokens ([double]$u.tokens.cacheRead)))
    } elseif ($u.error) {
        $lblTokens.Text = '—'
        $lblTokensDetail.Text = $u.error
    }
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
    if (Test-DshRunning) { Update-Status; return }
    $btnStart.Enabled = $false
    $lblStatus.Text = '●  启动中…'
    $lblStatus.ForeColor = $Yellow
    $txtLog.AppendText("`r`n=== 正在启动 DeepSeek Harness ... ===`r`n")
    $txtLog.AppendText("目录: $ResolvedHarness`r`n")
    try {
        Start-Dsh | Out-Null
        $script:openedBrowser = $false
        $script:lastLogText = ''
    } catch {
        $txtLog.AppendText("启动失败: $($_.Exception.Message)`r`n")
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

$form.Add_FormClosing({
    # 关闭窗口不停止 DSH（后台继续运行）
})

# 定时刷新
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 800
$timer.Add_Tick({ On-Tick })
$timer.Start()

# ----------------------------------------------------------------- 启动 -----
Update-Status
Refresh-Log
$script:usageTick = 12   # 让首次 tick 立即加载用量
[System.Windows.Forms.Application]::Run($form)
$timer.Stop()
