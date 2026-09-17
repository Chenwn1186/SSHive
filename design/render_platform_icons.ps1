# render_platform_icons.ps1
# 由 design/app_icon*.svg 生成各平台所需的全部图标资源。
#
# 用法：
#   .\render_platform_icons.ps1              # 生成全部
#   .\render_platform_icons.ps1 -DryRun      # 只打印将要写入的文件，不渲染
#
# 源文件：
#   design/app_icon.svg           透明底主稿（Windows / Android 传统图标 / macOS / favicon）
#   design/app_icon_opaque.svg    满幅不透明（iOS / web，平台自行做圆角遮罩）
#   design/app_icon_adaptive.svg  Android 自适应图标前景层（432 画布，内容压在安全区）
#
# 说明：每个尺寸都是独立按目标像素光栅化（不是缩放同一张大图），小尺寸才不糊。

param(
  [string]$DesignDir = $PSScriptRoot,
  [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path $DesignDir -Parent

$svgTransparent = Join-Path $DesignDir 'app_icon.svg'
$svgOpaque      = Join-Path $DesignDir 'app_icon_opaque.svg'
$svgAdaptive    = Join-Path $DesignDir 'app_icon_adaptive.svg'
foreach ($f in $svgTransparent, $svgOpaque, $svgAdaptive) {
  if (-not (Test-Path $f)) { throw "缺少源文件: $f" }
}

$androidRes = Join-Path $repo 'android\app\src\main\res'
$iosDir     = Join-Path $repo 'ios\Runner\Assets.xcassets\AppIcon.appiconset'
$macosDir   = Join-Path $repo 'macos\Runner\Assets.xcassets\AppIcon.appiconset'
$webDir     = Join-Path $repo 'web'
$winIco     = Join-Path $repo 'windows\runner\resources\app_icon.ico'
$tmpIcoDir  = Join-Path $env:TEMP 'sshive_icon_build'

# ---------------------------------------------------------------- 任务表
$tasks = @()
function Add-Task($svg, $size, $out) { $script:tasks += [pscustomobject]@{ Svg = $svg; Size = $size; Out = $out } }

# Windows ICO：先生成各尺寸 PNG，再由 build_ico.ps1 打包
$winSizes = 16, 20, 24, 30, 32, 36, 40, 48, 60, 64, 72, 80, 96, 128, 256
foreach ($s in $winSizes) { Add-Task $svgTransparent $s (Join-Path $tmpIcoDir "app_icon_$s.png") }

# Android 传统图标（透明底）
$androidLegacy = @{ 'mdpi' = 48; 'hdpi' = 72; 'xhdpi' = 96; 'xxhdpi' = 144; 'xxxhdpi' = 192 }
foreach ($k in $androidLegacy.Keys) {
  Add-Task $svgTransparent $androidLegacy[$k] (Join-Path $androidRes "mipmap-$k\ic_launcher.png")
}

# Android 自适应图标前景层（432 画布的 108/162/216/324/432）
$androidFg = @{ 'mdpi' = 108; 'hdpi' = 162; 'xhdpi' = 216; 'xxhdpi' = 324; 'xxxhdpi' = 432 }
foreach ($k in $androidFg.Keys) {
  Add-Task $svgAdaptive $androidFg[$k] (Join-Path $androidRes "mipmap-$k\ic_launcher_foreground.png")
}

# iOS（不透明，平台自带圆角遮罩）
$ios = [ordered]@{
  'Icon-App-20x20@1x.png'      = 20
  'Icon-App-20x20@2x.png'      = 40
  'Icon-App-20x20@3x.png'      = 60
  'Icon-App-29x29@1x.png'      = 29
  'Icon-App-29x29@2x.png'      = 58
  'Icon-App-29x29@3x.png'      = 87
  'Icon-App-40x40@1x.png'      = 40
  'Icon-App-40x40@2x.png'      = 80
  'Icon-App-40x40@3x.png'      = 120
  'Icon-App-60x60@2x.png'      = 120
  'Icon-App-60x60@3x.png'      = 180
  'Icon-App-76x76@1x.png'      = 76
  'Icon-App-76x76@2x.png'      = 152
  'Icon-App-83.5x83.5@2x.png'  = 167
  'Icon-App-1024x1024@1x.png'  = 1024
}
foreach ($n in $ios.Keys) { Add-Task $svgOpaque $ios[$n] (Join-Path $iosDir $n) }

# macOS（透明底，图标自带圆角外形）
$macos = [ordered]@{
  'app_icon_16.png' = 16; 'app_icon_32.png' = 32; 'app_icon_64.png' = 64
  'app_icon_128.png' = 128; 'app_icon_256.png' = 256
  'app_icon_512.png' = 512; 'app_icon_1024.png' = 1024
}
foreach ($n in $macos.Keys) { Add-Task $svgTransparent $macos[$n] (Join-Path $macosDir $n) }

# Web（maskable 必须满幅不透明；普通图标用透明底主稿）
Add-Task $svgTransparent 16  (Join-Path $webDir 'favicon.png')
Add-Task $svgTransparent 192 (Join-Path $webDir 'icons\Icon-192.png')
Add-Task $svgTransparent 512 (Join-Path $webDir 'icons\Icon-512.png')
Add-Task $svgOpaque      192 (Join-Path $webDir 'icons\Icon-maskable-192.png')
Add-Task $svgOpaque      512 (Join-Path $webDir 'icons\Icon-maskable-512.png')

# 预览图
Add-Task $svgTransparent 1024 (Join-Path $DesignDir 'app_icon_preview.png')

# ---------------------------------------------------------------- 执行
Write-Host "共 $($tasks.Count) 个渲染任务"
if ($DryRun) {
  $tasks | ForEach-Object { "  {0,5}px  {1}" -f $_.Size, ($_.Out.Replace($repo + '\', '')) }
  return
}

$browser = @(
  'C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe',
  'C:\Program Files\Microsoft\Edge\Application\msedge.exe',
  'C:\Program Files\Google\Chrome\Application\chrome.exe',
  'C:\Program Files (x86)\Google\Chrome\Application\chrome.exe'
) | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $browser) { throw '未找到 Edge / Chrome，无法渲染' }

$profileDir = Join-Path $env:TEMP 'sshive_svgshot_profile'
New-Item -ItemType Directory -Force -Path $profileDir | Out-Null
New-Item -ItemType Directory -Force -Path $tmpIcoDir | Out-Null

function Invoke-Shot {
  param([string]$Url, [string]$Out, [int]$W, [int]$H)
  $prev = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  & $browser --headless --disable-gpu --no-first-run --no-default-browser-check `
    --disable-extensions --hide-scrollbars --force-device-scale-factor=1 `
    --user-data-dir="$profileDir" --default-background-color=00000000 `
    --window-size="$W,$H" --screenshot="$Out" $Url 2>&1 | Out-Null
  $ErrorActionPreference = $prev
  if (-not (Test-Path $Out)) { throw "渲染失败: $Out" }
}

function Render-Svg {
  param([string]$Svg, [int]$Size, [string]$Out)
  $outDir = Split-Path $Out -Parent
  if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Force -Path $outDir | Out-Null }
  $wrap = Join-Path (Split-Path $Svg -Parent) ("_wrap_" + [guid]::NewGuid().ToString('N') + ".html")
  $html = '<!DOCTYPE html><html><head><meta charset="utf-8"><style>' +
          'html,body{margin:0;padding:0;background:transparent;overflow:hidden}' +
          "img{display:block;width:${Size}px;height:${Size}px}</style></head><body>" +
          '<img src="' + (Split-Path $Svg -Leaf) + '"></body></html>'
  Set-Content -Path $wrap -Value $html -Encoding UTF8
  try {
    Invoke-Shot -Url ('file:///' + ($wrap -replace '\\', '/')) -Out $Out -W $Size -H $Size
  } finally { Remove-Item $wrap -Force -ErrorAction SilentlyContinue }
}

$i = 0
foreach ($t in $tasks) {
  $i++
  Write-Host ("[{0,2}/{1}] {2,5}px  {3}" -f $i, $tasks.Count, $t.Size, (Split-Path $t.Out -Leaf))
  Render-Svg -Svg $t.Svg -Size $t.Size -Out $t.Out
}

# ---------------------------------------------------------------- Windows ICO
Write-Host '打包 Windows ICO ...'
& (Join-Path $DesignDir 'tools\build_ico.ps1') -Dir $tmpIcoDir -Name 'app_icon' -Out $winIco
Remove-Item $tmpIcoDir -Recurse -Force -ErrorAction SilentlyContinue

Write-Host '完成。'
