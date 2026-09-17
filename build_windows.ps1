# build_windows.ps1
# 一键：构建 Windows release → 部署到 -Target 指定目录 →
#      打包绿色 zip（同目录）→ 启动
#
# 用法（-Target 必填，传本机实际部署路径；目录不存在会自动创建）：
#   .\build_windows.ps1 -Target 'D:\exe dire\SSHive'                     完整流程
#   .\build_windows.ps1 -Target 'D:\exe dire\SSHive' -SkipBuild          跳过构建，仅部署
#   .\build_windows.ps1 -Target 'D:\exe dire\SSHive' -NoStart            部署后不启动
#   .\build_windows.ps1 -Target 'D:\exe dire\SSHive' -SkipZip            跳过 zip 打包
#   .\build_windows.ps1 'D:\exe dire\SSHive' -SkipBuild -NoStart -SkipZip  位置参数写法
#
# 说明：
#   - 部署目录不再硬编码，每次由 -Target 传入；会校验并拒绝盘符根目录、
#     系统目录等危险目标（部署过程会清空目标目录，故做保护）
#   - 构建/覆盖前会自动结束运行中的 sshive.exe（DLL 文件锁）
#   - 部署时保留 WebView2 运行时数据目录（EBWebView / sshive.exe.WebView2），
#     不丢失已登录网页的 Cookie 等数据
#   - 首次运行会把旧版 sshagent.exe.WebView2 数据目录迁移为 sshive.exe.WebView2
#     （改名前的网页登录态/缓存自动继承）
#   - 构建失败则中止，不覆盖、不启动
#   - 绿色 zip 输出到部署目录下：<target>\SSHive-Windows-x64.zip

param(
  [Parameter(Mandatory = $true, Position = 0,
    HelpMessage = '本机实际部署目录，例如 D:\exe dire\SSHive')]
  [string]$Target,

  [switch]$SkipBuild,
  [switch]$NoStart,
  [switch]$SkipZip
)

$ErrorActionPreference = 'Stop'

$root    = $PSScriptRoot
$release = Join-Path $root 'build\windows\x64\runner\Release'
$exeName = 'sshive.exe'
$zipName = 'SSHive-Windows-x64.zip'

# ------------------------------------------------- 部署目录（由调用方传入）
# 规范化路径，并在任何破坏性操作前做安全校验
$target    = [System.IO.Path]::GetFullPath($Target.Trim().Trim('"'))
$driveRoot = [System.IO.Path]::GetPathRoot($target).TrimEnd('\')
if ($target.TrimEnd('\') -eq $driveRoot) {
  Write-Error "拒绝部署到盘符根目录（会误删整盘）: $target"
  exit 1
}
if ($target -like "$env:SystemRoot*") {
  Write-Error "拒绝部署到系统目录: $target"
  exit 1
}

# 运行时数据目录（部署时保留，不删除；旧名用于一次性迁移）
$runtimeDirs  = @('EBWebView', 'sshive.exe.WebView2', 'sshagent.exe.WebView2')

function Test-ExeRunning {
  return [bool](Get-Process sshive -ErrorAction SilentlyContinue)
}

# ---------------------------------------------------------------- 1. 杀进程
$running = Get-Process -Name 'sshive', 'sshagent' -ErrorAction SilentlyContinue
if ($running) {
  Write-Host '==> 结束运行中的实例 ...'
  $running | Stop-Process -Force
  Start-Sleep -Milliseconds 1000
}

# ---------------------------------------------------------------- 2. 构建
if (-not $SkipBuild) {
  if (-not (Get-Command flutter -ErrorAction SilentlyContinue)) {
    Write-Error '未找到 flutter 命令，请先把 Flutter SDK 的 bin 目录加入 PATH'
    exit 1
  }
  # flutter_inappwebview_windows 的 CMake 需要 nuget
  if ((Test-Path 'D:\APPs\bin') -and -not (Get-Command nuget -ErrorAction SilentlyContinue)) {
    $env:PATH = "D:\APPs\bin;$env:PATH"
  }
  Write-Host '==> flutter build windows --release ...'
  & flutter build windows --release
  if ($LASTEXITCODE -ne 0) {
    Write-Error '构建失败，已中止部署（未覆盖目标目录）'
    exit 1
  }
  Write-Host '构建成功。'
} else {
  Write-Host '==> 跳过构建（-SkipBuild），使用上次构建产物'
}

if (-not (Test-Path "$release\$exeName")) {
  Write-Error "未找到构建产物: $release\$exeName（请先不带 -SkipBuild 运行一次）"
  exit 1
}

# ---------------------------------------------------------------- 3. 迁移旧数据目录
New-Item -ItemType Directory -Force -Path $target | Out-Null
$oldData = Join-Path $target 'sshagent.exe.WebView2'
$newData = Join-Path $target 'sshive.exe.WebView2'
if ((Test-Path $oldData) -and -not (Test-Path $newData)) {
  Write-Host '==> 迁移旧版 WebView2 数据目录（保留网页登录态）...'
  Move-Item $oldData $newData -Force
}

# ---------------------------------------------------------------- 4. 部署
Write-Host "==> 部署到 $target ..."

# 先清掉目标目录中除运行时数据与 zip 外的旧文件（含改名前的旧 exe/DLL）
Get-ChildItem $target -Force | Where-Object {
  $_.Name -notin $runtimeDirs -and $_.Name -ne $zipName -and $_.Name -ne 'SSH-Agent-Windows-x64.zip'
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

# ---------------------------------------------------------------- 5. 打包绿色 zip
if ($SkipZip) {
  Write-Host '==> 跳过 zip 打包（-SkipZip）'
} else {
  Write-Host '==> 打包绿色 zip ...'
  $zipPath = Join-Path $target $zipName
  $stage = Join-Path $env:TEMP 'sshive_zip_stage'
  Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue
  New-Item -ItemType Directory -Force -Path $stage | Out-Null
  Get-ChildItem $release -Force | Where-Object {
    $_.Name -notin $runtimeDirs
  } | ForEach-Object {
    Copy-Item $_.FullName -Destination $stage -Recurse -Force
  }
  # 清掉误入的运行时目录与旧 zip
  foreach ($d in $runtimeDirs) {
    Remove-Item (Join-Path $stage $d) -Recurse -Force -ErrorAction SilentlyContinue
  }
  Get-ChildItem $stage -Filter '*.zip' | Remove-Item -Force -ErrorAction SilentlyContinue
  Compress-Archive -Path "$stage\*" -DestinationPath $zipPath -Force
  Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue
  # 清掉改名前的旧 zip（避免混淆）
  Remove-Item (Join-Path $target 'SSH-Agent-Windows-x64.zip') -Force -ErrorAction SilentlyContinue
  $zipMB = [Math]::Round((Get-Item $zipPath).Length / 1MB, 1)
  Write-Host "zip 完成: $zipPath ($zipMB MB)"
}

# ---------------------------------------------------------------- 6. 启动
if ($NoStart) {
  Write-Host '==> 跳过启动（-NoStart）'
} else {
  Write-Host "==> 启动 $exeName ..."
  Start-Process (Join-Path $target $exeName)
  Start-Sleep -Seconds 2
  if (Test-ExeRunning) {
    Write-Host "✔ $exeName 已启动"
  } else {
    Write-Warning '进程未检测到，请检查是否启动失败'
  }
}

Write-Host "完成。部署目录: $target"
