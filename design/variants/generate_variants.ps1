# generate_variants.ps1
# 生成图标底板的两种实验：加深明暗对比 / 随机明暗格子，并出对比图。
#
# 用法： .\generate_variants.ps1
#
# 输出（本目录）：
#   <name>.svg / <name>_256.png / <name>_64.png
#   sheet_contrast.png   当前版 + 4 个加深方案
#   sheet_random.png     当前版 + 4 个随机方案
#   luminances.txt       每个方案 6 个格子的相对亮度与极差

param([string]$Dir = $PSScriptRoot)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------- 亮度工具
function Get-Luminance([string]$hex) {
  $h = $hex.TrimStart('#')
  $r = [Convert]::ToInt32($h.Substring(0,2),16) / 255.0
  $g = [Convert]::ToInt32($h.Substring(2,2),16) / 255.0
  $b = [Convert]::ToInt32($h.Substring(4,2),16) / 255.0
  $f = { param($s) if ($s -le 0.04045) { $s/12.92 } else { [math]::Pow((($s+0.055)/1.055), 2.4) } }
  return 0.2126*(& $f $r) + 0.7152*(& $f $g) + 0.0722*(& $f $b)
}

# ---------------------------------------------------------------- 图标模板
# 6 个格子按 [左列上, 右列上, 左列中, 右列中, 左列下, 右列下] 排列
$COLS = @(6.0, 26.9)
$ROWS = @(1.0, 16.6, 32.2)
$CW   = 20.1
$CH   = 14.8

function New-IconSvg {
  param(
    [string]$Out,
    [string[]]$Cells,        # 6 个色值
    [string]$Seam  = '#0B6B62',
    [string]$Badge = '#0E7C72',
    [string]$Note  = ''
  )
  $c = $Cells
  $rects = @()
  $i = 0
  foreach ($ry in $ROWS) {
    foreach ($rx in $COLS) {
      $rects += ('    <rect x="{0}" y="{1}" width="{2}" height="{3}" fill="{4}"/>' -f $rx, $ry, $CW, $CH, $c[$i])
      $i++
    }
  }
  $rectBlock = $rects -join "`n"

  $svg = @"
<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 48 48">
  <!-- SSHive 应用图标 · $Note
       48 网格 / 透明底 / 底板 2 列 x 3 行 / 徽标投影裁切在底板内 -->
  <defs>
    <clipPath id="plate"><rect x="6" y="1" width="41" height="46" rx="4"/></clipPath>
    <filter id="softShadow" x="-40%" y="-40%" width="180%" height="180%">
      <feGaussianBlur stdDeviation="1.15"/>
    </filter>
  </defs>

  <!-- 层 1：底板（分隔缝用深色底） -->
  <g clip-path="url(#plate)">
    <rect x="6" y="1" width="41" height="46" fill="$Seam"/>
$rectBlock
  </g>

  <!-- 层 2：徽标投影 —— 只落在底板上，且是模糊阴影而不是一块半透明矩形 -->
  <g clip-path="url(#plate)">
    <rect x="1" y="22.3" width="18" height="18" rx="2" fill="#04211E" opacity="0.55" filter="url(#softShadow)"/>
  </g>

  <!-- 层 3：徽标本体 -->
  <rect x="1" y="21" width="18" height="18" rx="2" fill="$Badge"/>

  <!-- 层 4：终端提示符 -->
  <g stroke="#FFFFFF" stroke-width="2.3" stroke-linecap="round" stroke-linejoin="round" fill="none">
    <path d="M 4.5 25.5 L 9 30 L 4.5 34.5"/>
    <path d="M 11.5 34.5 H 15.5"/>
  </g>
</svg>
"@
  Set-Content -Path $Out -Value $svg -Encoding UTF8
}

# ---------------------------------------------------------------- 方案定义
$variants = [ordered]@{}

# 当前版本（对照）
$variants['V0_current'] = @{
  Note = '当前版本（对照）'
  Cells = @('#0EA5A0','#0C9B96','#0D9488','#0E8579','#0E8579','#0E7C72')
}

# --- 加深明暗对比的 4 个尝试 ---
$variants['C1_tight'] = @{
  Note = '加深 1/4 · 合规带内拉满（保守）'
  Cells = @('#0EA5A0','#0D9E99','#0D9488','#0D8A80','#0D7D74','#0C6F68')
}
$variants['C2_medium'] = @{
  Note = '加深 2/4 · 亮格轻越界'
  Cells = @('#14B8A6','#10AB9C','#0D9488','#0D867C','#0B6F67','#0A5F59')
}
$variants['C3_deep'] = @{
  Note = '加深 3/4 · 两端都越界'
  Cells = @('#2DD4BF','#14B8A6','#0E9E92','#0C7F76','#0A655E','#07463F')
}
$variants['C4_extreme'] = @{
  Note = '加深 4/4 · 极深到近黑'
  Cells = @('#5EEAD4','#2DD4BF','#0D9488','#0B6F67','#083F3B','#04211E')
  Seam  = '#02110F'
}

# --- 随机明暗格子的 4 个尝试 ---
function Get-Shuffled {
  param([string[]]$Items, [int]$Seed)
  $rnd = New-Object System.Random($Seed)
  $a = @($Items)
  for ($i = $a.Count-1; $i -gt 0; $i--) {
    $j = $rnd.Next(0, $i+1)
    $t = $a[$i]; $a[$i] = $a[$j]; $a[$j] = $t
  }
  return $a
}
$randPalette = @('#14B8A6','#10AB9C','#0D9488','#0D867C','#0B6F67','#0A5F59')
foreach ($seed in 11, 27, 43, 61) {
  $variants["R$seed" + "_random"] = @{
    Note  = "随机 种子=$seed"
    Cells = (Get-Shuffled -Items $randPalette -Seed $seed)
  }
}

# ---------------------------------------------------------------- 生成 SVG
Write-Host '== 生成 SVG =='
foreach ($k in $variants.Keys) {
  $v = $variants[$k]
  $out = Join-Path $Dir "$k.svg"
  New-IconSvg -Out $out -Cells $v.Cells -Seam ($(if($v.Seam){$v.Seam}else{'#0B6B62'})) -Note $v.Note
  Write-Host "   $k.svg"
}

# ---------------------------------------------------------------- 亮度报告
$lines = @()
$lines += '方案                  6 格亮度 (左列上→右列下)                              极差(最亮:最暗)'
foreach ($k in $variants.Keys) {
  $ls = @()
  foreach ($c in $variants[$k].Cells) { $ls += (Get-Luminance $c) }
  $max = ($ls | Measure-Object -Maximum).Maximum
  $min = ($ls | Measure-Object -Minimum).Minimum
  $ratio = ($max + 0.05) / ($min + 0.05)
  $lines += ('{0,-20} {1}   {2:N2}:1' -f $k, (($ls | ForEach-Object { '{0:N3}' -f $_ }) -join ' '), $ratio)
}
$lines | Set-Content -Path (Join-Path $Dir 'luminances.txt') -Encoding UTF8
$lines | ForEach-Object { Write-Host "   $_" }

# ---------------------------------------------------------------- 渲染
Write-Host '== 渲染 =='
$browser = @(
  'C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe',
  'C:\Program Files\Microsoft\Edge\Application\msedge.exe',
  'C:\Program Files\Google\Chrome\Application\chrome.exe'
) | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $browser) { throw '未找到 Edge / Chrome' }
$profileDir = Join-Path $env:TEMP 'sshive_variants_profile'
New-Item -ItemType Directory -Force -Path $profileDir | Out-Null

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
  $wrap = Join-Path (Split-Path $Svg -Parent) ("_w_" + [guid]::NewGuid().ToString('N') + '.html')
  $html = '<!DOCTYPE html><html><head><meta charset="utf-8"><style>html,body{margin:0;padding:0;background:transparent;overflow:hidden}' +
          "img{display:block;width:${Size}px;height:${Size}px}</style></head><body><img src=""" + (Split-Path $Svg -Leaf) + '"></body></html>'
  Set-Content -Path $wrap -Value $html -Encoding UTF8
  try { Invoke-Shot -Url ('file:///' + ($wrap -replace '\\','/')) -Out $Out -W $Size -H $Size }
  finally { Remove-Item $wrap -Force -ErrorAction SilentlyContinue }
}

foreach ($k in $variants.Keys) {
  Render-Svg -Svg (Join-Path $Dir "$k.svg") -Size 256 -Out (Join-Path $Dir "${k}_256.png")
  Render-Svg -Svg (Join-Path $Dir "$k.svg") -Size 64  -Out (Join-Path $Dir "${k}_64.png")
  Write-Host "   $k"
}

# ---------------------------------------------------------------- 对比图
Write-Host '== 生成对比图 =='
function New-Sheet {
  param([string[]]$Names, [string]$Out, [string]$Title)
  $cells = ''
  foreach ($n in $Names) {
    $cells += '<div class="cell"><img src="' + $n + '_256.png"><div class="lbl">' + $n + '</div></div>'
  }
  $html = @"
<!DOCTYPE html><html><head><meta charset="utf-8"><style>
html,body{margin:0;padding:0;font-family:'Segoe UI',sans-serif}
.band{padding:18px 22px}
.light{background:#F3F3F3;color:#111}
.dark{background:#202020;color:#eee}
.title{font-size:13px;opacity:.7;margin-bottom:12px}
.row{display:flex;align-items:flex-start;gap:16px}
.cell{display:flex;flex-direction:column;align-items:center;gap:6px}
.cell img{display:block;width:256px;height:256px}
.lbl{font-size:11px;opacity:.65}
</style></head><body>
<div class="band light"><div class="title">$Title — 亮底</div><div class="row">$cells</div></div>
<div class="band dark"><div class="title">$Title — 暗底</div><div class="row">$cells</div></div>
</body></html>
"@
  $hp = Join-Path $Dir ("_sheet_" + [guid]::NewGuid().ToString('N') + '.html')
  Set-Content -Path $hp -Value $html -Encoding UTF8
  $w = $Names.Count * (256 + 16) + 44
  $h = 2 * (256 + 70) + 20
  try { Invoke-Shot -Url ('file:///' + ($hp -replace '\\','/')) -Out $Out -W $w -H $h }
  finally { Remove-Item $hp -Force -ErrorAction SilentlyContinue }
}

New-Sheet -Names @('V0_current','C1_tight','C2_medium','C3_deep','C4_extreme') `
  -Out (Join-Path $Dir 'sheet_contrast.png') -Title '明暗对比：当前 → 逐级加深'
New-Sheet -Names @('V0_current','R11_random','R27_random','R43_random','R61_random') `
  -Out (Join-Path $Dir 'sheet_random.png') -Title '随机明暗格子：当前 + 4 个随机种子'

Write-Host '完成。'
