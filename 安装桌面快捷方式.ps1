# ============================================================================
#  安装桌面快捷方式
#  在桌面创建 "DSH 启动器.lnk"，双击即可启动 DSH 桌面启动器。
# ============================================================================

$LauncherDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$BatPath     = Join-Path $LauncherDir '启动DSH.bat'
$IconPath    = Join-Path $LauncherDir 'dsh.ico'

if (-not (Test-Path $BatPath)) {
    Write-Host "找不到 $BatPath" -ForegroundColor Red
    exit 1
}

# 如果图标不存在，尝试调用启动器生成一次
if (-not (Test-Path $IconPath)) {
    try {
        & (Join-Path $LauncherDir 'launcher.ps1') -GenIconOnly 2>$null
    } catch { }
}

$Desktop  = [Environment]::GetFolderPath('Desktop')
$Shortcut = Join-Path $Desktop 'DSH 启动器.lnk'

$shell = New-Object -ComObject WScript.Shell
$lnk = $shell.CreateShortcut($Shortcut)
$lnk.TargetPath       = $BatPath
$lnk.WorkingDirectory = $LauncherDir
$lnk.Description      = 'DeepSeek Harness 桌面启动器'
if (Test-Path $IconPath) { $lnk.IconLocation = "$IconPath,0" }
$lnk.Save()

Write-Host "已创建桌面快捷方式：" -NoNewline
Write-Host $Shortcut -ForegroundColor Green
