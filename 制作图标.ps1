# ============================================================================
#  制作图标 —— 把 PNG 立绘转成多尺寸 .ico（含透明通道）
#  桌面快捷方式 / 窗口图标只能使用 .ico（或 .exe/.dll），不能直接用 .png。
#  本脚本用 PNG 压缩条目组装标准 ICO 容器，生成 16/24/32/48/64/128/256 全尺寸，
#  保证小图标（任务栏、Alt-Tab）也清晰。
#
#  用法:
#    powershell -NoProfile -ExecutionPolicy Bypass -File 制作图标.ps1
#    powershell -NoProfile -ExecutionPolicy Bypass -File 制作图标.ps1 -Source <png> -Out <ico>
# ============================================================================
param(
    [string]$Source = '',
    [string]$Out = ''
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

$dir = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $Source) { $Source = Join-Path $dir 'fish-desktop.png' }
if (-not $Out)    { $Out    = Join-Path $dir 'dsh.ico' }

if (-not (Test-Path $Source)) { Write-Error "找不到源图：$Source"; exit 1 }

$sizes = @(16, 24, 32, 48, 64, 128, 256)

$src = [System.Drawing.Image]::FromFile($Source)
try {
    # 逐尺寸高质量缩放为 PNG
    $pngs = @()
    foreach ($s in $sizes) {
        $bmp = New-Object System.Drawing.Bitmap $s, $s
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $g.SmoothingMode     = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $g.PixelOffsetMode   = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
        $g.Clear([System.Drawing.Color]::Transparent)
        $g.DrawImage($src, 0, 0, $s, $s)
        $g.Dispose()
        $ms = New-Object System.IO.MemoryStream
        $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
        $pngs += , $ms.ToArray()
        $bmp.Dispose()
        $ms.Dispose()
    }
} finally {
    $src.Dispose()
}

# 组装 ICO 容器（目录项 16 字节/项，图像数据用 PNG 压缩条目，Vista+ 支持）
$count  = $sizes.Count
$offset = 6 + 16 * $count

$ms = New-Object System.IO.MemoryStream
$bw = New-Object System.IO.BinaryWriter $ms
$bw.Write([UInt16]0)               # reserved
$bw.Write([UInt16]1)               # type = icon
$bw.Write([UInt16]$count)          # 图像数量

for ($i = 0; $i -lt $count; $i++) {
    $s = $sizes[$i]
    if ($s -ge 256) { $wb = 0 } else { $wb = [byte]$s }   # 256 记作 0
    $bw.Write([byte]$wb)            # width
    $bw.Write([byte]$wb)            # height
    $bw.Write([byte]0)              # colorCount
    $bw.Write([byte]0)              # reserved
    $bw.Write([UInt16]1)            # planes
    $bw.Write([UInt16]32)           # bitCount
    $bw.Write([UInt32]$pngs[$i].Length)   # bytesInRes
    $bw.Write([UInt32]$offset)             # imageOffset
    $offset += $pngs[$i].Length
}
foreach ($p in $pngs) { $bw.Write($p) }
$bw.Flush()

[System.IO.File]::WriteAllBytes($Out, $ms.ToArray())
$bw.Dispose()
$ms.Dispose()

Write-Host ("已生成图标：{0}（{1} 个尺寸）" -f $Out, $count) -ForegroundColor Green
