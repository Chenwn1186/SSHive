# render_previews.ps1
# 把一个目录里的 *.svg 渲染成 PNG 预览（Chromium headless，保持矢量精度与透明底）。
#
# 用法：
#   .\render_previews.ps1 -Dir ..\        # 渲染指定目录全部 svg：<name>_1024.png + strip_<name>.png
#   .\render_previews.ps1 -Dir ..\ -ExtraSizes 256,96,48   # 额外渲染指定尺寸的 PNG
#
# 说明：
#   - 每个图形输出 1024 透明底大图，以及一张「多尺寸 + 亮/暗背景」对比条，
#     用于检查 16~48px 下是否还认得出来。
#   - 用独立 user-data-dir，不会影响你正在使用的浏览器。

param(
  [string]$Dir = $PSScriptRoot,
  [int[]]$ExtraSizes = @()
)

$ErrorActionPreference = 'Stop'

$browser = @(
  'C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe',
  'C:\Program Files\Microsoft\Edge\Application\msedge.exe',
  'C:\Program Files\Google\Chrome\Application\chrome.exe',
  'C:\Program Files (x86)\Google\Chrome\Application\chrome.exe'
) | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $browser) { throw '未找到 Edge / Chrome，无法渲染' }

$profileDir = Join-Path $env:TEMP 'sshive_svgshot_profile'
New-Item -ItemType Directory -Force -Path $profileDir | Out-Null

function Invoke-Shot {
  param([string]$Url, [string]$Out, [int]$W, [int]$H)
  if (Test-Path $Out) { Remove-Item $Out -Force }
  # headless 浏览器会把「…bytes written to file」写到 stderr，
  # 在 ErrorActionPreference=Stop 下会被当成终止性错误，这里单独降级处理
  $prev = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  & $browser --headless --disable-gpu --no-first-run --no-default-browser-check `
    --disable-extensions --hide-scrollbars --force-device-scale-factor=1 `
    --user-data-dir="$profileDir" --default-background-color=00000000 `
    --window-size="$W,$H" --screenshot="$Out" $Url 2>&1 | Out-Null
  $ErrorActionPreference = $prev
  if (-not (Test-Path $Out)) { throw "渲染失败: $Out" }
}

function ConvertTo-FileUrl { param([string]$Path) 'file:///' + ($Path -replace '\\', '/') }

# 按目标尺寸「缩放」渲染 SVG。
# 直接用小窗口截 SVG 文档只会得到左上角裁切（SVG 自身宽高是 1024），
# 因此这里用一层 HTML 把 SVG 当成 <img> 指定像素尺寸，再截图。
function Invoke-ShotScaled {
  param([string]$SvgPath, [string]$Out, [int]$Size)
  $wrapper = Join-Path (Split-Path $SvgPath -Parent) ("_wrap_" + [guid]::NewGuid().ToString('N') + ".html")
  $html = '<!DOCTYPE html><html><head><meta charset="utf-8"><style>' +
          'html,body{margin:0;padding:0;background:transparent;overflow:hidden}' +
          "img{display:block;width:${Size}px;height:${Size}px}</style></head><body>" +
          '<img src="' + (Split-Path $SvgPath -Leaf) + '"></body></html>'
  Set-Content -Path $wrapper -Value $html -Encoding UTF8
  try { Invoke-Shot -Url (ConvertTo-FileUrl $wrapper) -Out $Out -W $Size -H $Size }
  finally { Remove-Item $wrapper -Force -ErrorAction SilentlyContinue }
}

$svgs = Get-ChildItem -Path $Dir -Filter '*.svg' | Sort-Object Name
if (-not $svgs) { throw "目录中没有 svg: $Dir" }

foreach ($svg in $svgs) {
  $name = $svg.BaseName
  Write-Host "==> $name"

  # 1) 1024 透明底大图
  Invoke-Shot -Url (ConvertTo-FileUrl $svg.FullName) -Out (Join-Path $Dir "$name`_1024.png") -W 1024 -H 1024

  # 2) 额外尺寸（按目标像素缩放渲染，不是左上角裁切）
  foreach ($s in $ExtraSizes) {
    Invoke-ShotScaled -SvgPath $svg.FullName -Out (Join-Path $Dir "$name`_$s.png") -Size $s
  }

  # 3) 多尺寸 + 亮/暗背景对比条
  $sizes = @(128, 64, 48, 32, 24, 16)
  $cells = ($sizes | ForEach-Object { "<img src=""$($svg.Name)"" width=""$_"" height=""$_"">" }) -join ''
  $row = { param($bg, $fg) "<div style=""display:flex;align-items:center;gap:26px;padding:26px 30px;background:$bg;color:$fg"">$cells</div>" }
  $html = @"
<!DOCTYPE html><html><head><meta charset="utf-8"><style>
html,body{margin:0;padding:0;background:transparent;font-family:'Segoe UI',sans-serif}
</style></head><body>
$(& $row '#F3F3F3' '#000')
$(& $row '#202020' '#fff')
</body></html>
"@
  $htmlPath = Join-Path $Dir "$name`_strip.html"
  Set-Content -Path $htmlPath -Value $html -Encoding UTF8
  $w = 128 + 64 + 48 + 32 + 24 + 16 + (5 * 26) + 60
  $h = 128 + 52 + 128 + 52
  Invoke-Shot -Url (ConvertTo-FileUrl $htmlPath) -Out (Join-Path $Dir "strip_$name.png") -W $w -H $h
  Remove-Item $htmlPath -Force
}

Write-Host "完成，输出目录: $Dir"
