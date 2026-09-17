# check_contrast.ps1
# 按微软官方规范校验图标的对比度：
#   "Make sure at least half of your icon passes a 3.0:1 contrast ratio
#    on light and dark theme."
#
# 做法：把带透明通道的 PNG 分别合成到亮色底(#FFFFFF)和暗色底(#202020)上，
#       逐像素算 WCAG 对比度，统计「在两种背景下都 >= 3.0:1」的不透明像素占比。
#
# 用法：
#   .\check_contrast.ps1 -Dir ..\..\windows\runner\resources -Sizes 256,96,48,32,24,16

param(
  [string]$Dir = $PSScriptRoot,
  [int[]]$Sizes = @(256, 96, 48, 32, 24, 16),
  [double]$Threshold = 3.0,
  [int]$AlphaCutoff = 8
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

function Get-Luminance([int]$r, [int]$g, [int]$b) {
  $f = {
    param($c)
    $s = $c / 255.0
    if ($s -le 0.04045) { return $s / 12.92 }
    return [math]::Pow((($s + 0.055) / 1.055), 2.4)
  }
  return 0.2126 * (& $f $r) + 0.7152 * (& $f $g) + 0.0722 * (& $f $b)
}

function Get-Ratio([double]$l1, [double]$l2) {
  $hi = [math]::Max($l1, $l2); $lo = [math]::Min($l1, $l2)
  return ($hi + 0.05) / ($lo + 0.05)
}

# 背景：亮色主题 / 暗色主题（Windows 11 暗色底约为 #202020）
$lightBg = @(255, 255, 255)
$darkBg  = @(32, 32, 32)
$lLightBg = Get-Luminance $lightBg[0] $lightBg[1] $lightBg[2]
$lDarkBg  = Get-Luminance $darkBg[0] $darkBg[1] $darkBg[2]

$files = Get-ChildItem -Path $Dir -Filter '*.png' |
  Where-Object { $_.BaseName -match ('_(' + (($Sizes | ForEach-Object { [string]$_ }) -join '|') + ')$') } |
  Sort-Object Name

if (-not $files) { Write-Host "没有找到待检 PNG（-Dir $Dir，Sizes $($Sizes -join ','))"; return }

$rows = @()
foreach ($f in $files) {
  $bmp = [System.Drawing.Bitmap]::FromFile($f.FullName)
  try {
    $opaque = 0; $pass = 0
    for ($y = 0; $y -lt $bmp.Height; $y++) {
      for ($x = 0; $x -lt $bmp.Width; $x++) {
        $c = $bmp.GetPixel($x, $y)
        if ($c.A -le $AlphaCutoff) { continue }
        $opaque++
        $a = $c.A / 255.0
        # 合成到亮底
        $wr = [int][math]::Round($c.R * $a + $lightBg[0] * (1 - $a))
        $wg = [int][math]::Round($c.G * $a + $lightBg[1] * (1 - $a))
        $wb = [int][math]::Round($c.B * $a + $lightBg[2] * (1 - $a))
        # 合成到暗底
        $dr = [int][math]::Round($c.R * $a + $darkBg[0] * (1 - $a))
        $dg = [int][math]::Round($c.G * $a + $darkBg[1] * (1 - $a))
        $db = [int][math]::Round($c.B * $a + $darkBg[2] * (1 - $a))

        $rw = Get-Ratio (Get-Luminance $wr $wg $wb) $lLightBg
        $rd = Get-Ratio (Get-Luminance $dr $dg $db) $lDarkBg
        if ($rw -ge $Threshold -and $rd -ge $Threshold) { $pass++ }
      }
    }
    $pct = if ($opaque -gt 0) { 100.0 * $pass / $opaque } else { 0 }
    $rows += [pscustomobject]@{
      图标       = $f.Name
      尺寸       = "$($bmp.Width)x$($bmp.Height)"
      不透明像素 = $opaque
      双背景达标 = ('{0:N1}%' -f $pct)
      判定       = if ($pct -ge 50) { 'PASS' } else { 'FAIL' }
    }
  } finally { $bmp.Dispose() }
}

$rows | Format-Table -AutoSize | Out-String -Width 200 | Write-Host
