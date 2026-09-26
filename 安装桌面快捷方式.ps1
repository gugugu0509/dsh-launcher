# ============================================================================
#  安装桌面快捷方式
#  在桌面创建 "DSH 启动器.lnk"，双击即可启动 DSH 桌面启动器。
#  桌面图标使用高清「大肥鱼吃白饭」立绘（fish-desktop.png / dsh.ico）。
# ============================================================================

$LauncherDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$BatPath     = Join-Path $LauncherDir '启动DSH.bat'
$IconPath    = Join-Path $LauncherDir 'dsh.ico'
$PngIcon     = Join-Path $LauncherDir 'fish-desktop.png'
$MakeIcon    = Join-Path $LauncherDir '制作图标.ps1'

if (-not (Test-Path $BatPath)) {
    Write-Host "找不到 $BatPath" -ForegroundColor Red
    exit 1
}

# 确保 dsh.ico 是多尺寸 .ico。
# 注意：Windows 快捷方式的图标只能用 .ico/.exe/.dll，直接用 .png 不会生效（会退回默认图标）。
if (-not (Test-Path $IconPath)) {
    if (Test-Path $MakeIcon) {
        & $MakeIcon
    } elseif (Test-Path $PngIcon) {
        try { & (Join-Path $LauncherDir 'launcher.ps1') -GenIconOnly 2>$null } catch { }
    }
}

$Desktop  = [Environment]::GetFolderPath('Desktop')
$Shortcut = Join-Path $Desktop 'DSH 启动器.lnk'

$shell = New-Object -ComObject WScript.Shell
$lnk = $shell.CreateShortcut($Shortcut)
$lnk.TargetPath       = $BatPath
$lnk.WorkingDirectory = $LauncherDir
$lnk.Description      = 'DeepSeek Harness 桌面启动器 · 大肥鱼吃白饭'
$lnk.IconLocation     = "$IconPath,0"
$lnk.Save()

Write-Host "已创建桌面快捷方式：" -NoNewline
Write-Host $Shortcut -ForegroundColor Green
Write-Host "图标：$($lnk.IconLocation)" -ForegroundColor DarkGray