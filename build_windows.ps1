# build_windows.ps1
# 一键：构建 Windows release → 部署到 D:\exedirect\SSH-Agent-Windows-x64 →
#      打包绿色 zip（同目录）→ 启动
#
# 用法：
#   .\build_windows.ps1            完整流程（构建 + 部署 + 打包 zip + 启动）
#   .\build_windows.ps1 -SkipBuild 跳过构建，仅部署 + 打包（上次构建产物）
#   .\build_windows.ps1 -NoStart   部署后不启动
#   .\build_windows.ps1 -SkipZip   跳过 zip 打包
#   .\build_windows.ps1 -SkipBuild -NoStart -SkipZip
#
# 说明：
#   - 构建/覆盖前会自动结束运行中的 sshagent.exe（DLL 文件锁）
#   - 部署时保留 WebView2 运行时数据目录（EBWebView / sshagent.exe.WebView2），
#     不丢失已登录网页的 Cookie 等数据
#   - 构建失败则中止，不覆盖、不启动
#   - 绿色 zip 输出到部署目录下：<target>\SSH-Agent-Windows-x64.zip

param(
  [switch]$SkipBuild,
  [switch]$NoStart,
  [switch]$SkipZip
)

$ErrorActionPreference = 'Stop'

$root    = $PSScriptRoot
$release = Join-Path $root 'build\windows\x64\runner\Release'
$target  = 'D:\exedirect\SSH-Agent-Windows-x64'

# 运行时数据目录（部署时保留，不删除）
$runtimeDirs = @('EBWebView', 'sshagent.exe.WebView2')

function Test-ExeRunning {
  return [bool](Get-Process sshagent -ErrorAction SilentlyContinue)
}

# ---------------------------------------------------------------- 1. 杀进程
if (Test-ExeRunning) {
  Write-Host '==> 结束运行中的 sshagent.exe ...'
  Get-Process sshagent -ErrorAction SilentlyContinue | Stop-Process -Force
  Start-Sleep -Milliseconds 800
}

# ---------------------------------------------------------------- 2. 构建
if (-not $SkipBuild) {
  Write-Host '==> flutter build windows --release ...'
  $env:PATH = "D:\APPs\bin;$env:PATH"   # nuget
  & flutter build windows --release
  if ($LASTEXITCODE -ne 0) {
    Write-Error '构建失败，已中止部署（未覆盖目标目录）'
    exit 1
  }
  Write-Host '构建成功。'
} else {
  Write-Host '==> 跳过构建（-SkipBuild），使用上次构建产物'
}

if (-not (Test-Path "$release\sshagent.exe")) {
  Write-Error "未找到构建产物: $release\sshagent.exe（请先不带 -SkipBuild 运行一次）"
  exit 1
}

# ---------------------------------------------------------------- 3. 部署
Write-Host "==> 部署到 $target ..."
New-Item -ItemType Directory -Force -Path $target | Out-Null

# 先清掉目标目录中除运行时数据外的旧文件（含已废弃的旧 DLL 等）
Get-ChildItem $target -Force | Where-Object {
  $_.Name -notin $runtimeDirs
} | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue

# 复制新构建产物（源目录同样排除运行时垃圾）
Get-ChildItem $release -Force | Where-Object {
  $_.Name -notin $runtimeDirs
} | ForEach-Object {
  Copy-Item $_.FullName -Destination $target -Recurse -Force
}

$fileCount = (Get-ChildItem $target -Recurse -File | Measure-Object).Count
$sizeMB    = [Math]::Round((Get-ChildItem $target -Recurse -File | Measure-Object Length -Sum).Sum / 1MB, 1)
Write-Host "部署完成：$fileCount 个文件，$sizeMB MB"

# ---------------------------------------------------------------- 4. 打包绿色 zip
if ($SkipZip) {
  Write-Host '==> 跳过 zip 打包（-SkipZip）'
} else {
  Write-Host '==> 打包绿色 zip ...'
  $zipPath = Join-Path $target 'SSH-Agent-Windows-x64.zip'
  $stage = Join-Path $env:TEMP 'sshagent_zip_stage'
  # 用干净临时目录收集核心文件（排除运行时数据，避免把旧 zip/缓存打进去）
  Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue
  New-Item -ItemType Directory -Force -Path $stage | Out-Null
  Get-ChildItem $release -Force | Where-Object {
    $_.Name -notin $runtimeDirs
  } | ForEach-Object {
    Copy-Item $_.FullName -Destination $stage -Recurse -Force
  }
  # 清掉误入的运行时目录与旧 zip
  Remove-Item (Join-Path $stage 'EBWebView') -Recurse -Force -ErrorAction SilentlyContinue
  Remove-Item (Join-Path $stage 'sshagent.exe.WebView2') -Recurse -Force -ErrorAction SilentlyContinue
  Remove-Item (Join-Path $stage 'SSH-Agent-Windows-x64.zip') -Force -ErrorAction SilentlyContinue
  Compress-Archive -Path "$stage\*" -DestinationPath $zipPath -Force
  Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue
  $zipMB = [Math]::Round((Get-Item $zipPath).Length / 1MB, 1)
  Write-Host "zip 完成: $zipPath ($zipMB MB)"
}

# ---------------------------------------------------------------- 5. 启动
if ($NoStart) {
  Write-Host '==> 跳过启动（-NoStart）'
} else {
  Write-Host '==> 启动 sshagent.exe ...'
  Start-Process (Join-Path $target 'sshagent.exe')
  Start-Sleep -Seconds 2
  if (Test-ExeRunning) {
    Write-Host '✔ sshagent.exe 已启动'
  } else {
    Write-Warning '进程未检测到，请检查是否启动失败'
  }
}

Write-Host "完成。部署目录: $target"
