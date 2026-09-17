# build_ico.ps1
# 把 <Name>_<size>.png 打包成多尺寸 Windows ICO。
#
# 用法：
#   .\build_ico.ps1 -Dir .\round3 -Name D1_lock_prompt
#   .\build_ico.ps1 -Dir .\round3 -Name D1_lock_prompt -Out D:\somewhere\sshive.ico
#
# 说明：
#   - 默认打包微软官方列出的 Windows 图标尺寸集合；
#   - 每个尺寸用独立的 PNG 渲染结果（不是缩放同一个大图），小尺寸才不会糊；
#   - 256 在 ICO 目录项里以 0 表示。

param(
  [string]$Dir = $PSScriptRoot,
  [Parameter(Mandatory = $true)][string]$Name,
  [int[]]$Sizes = @(16, 20, 24, 30, 32, 36, 40, 48, 60, 64, 72, 80, 96, 128, 256),
  [string]$Out
)

$ErrorActionPreference = 'Stop'
if (-not $Out) { $Out = Join-Path $Dir "$Name.ico" }

$imgs = @()
foreach ($s in ($Sizes | Sort-Object)) {
  $p = Join-Path $Dir "$($Name)_$s.png"
  if (-not (Test-Path $p)) { Write-Warning "缺少 $p，已跳过"; continue }
  $imgs += [pscustomobject]@{ Size = $s; Bytes = [System.IO.File]::ReadAllBytes($p) }
}
if ($imgs.Count -eq 0) { throw "没有找到任何 PNG：$Dir\$Name`_<size>.png" }

$ms = New-Object System.IO.MemoryStream
$bw = New-Object System.IO.BinaryWriter($ms)

# ICONDIR
$bw.Write([uint16]0)              # reserved
$bw.Write([uint16]1)              # type: 1 = icon
$bw.Write([uint16]$imgs.Count)

# ICONDIRENTRY × N
$offset = 6 + 16 * $imgs.Count
foreach ($i in $imgs) {
  $dim = if ($i.Size -ge 256) { 0 } else { $i.Size }
  $bw.Write([byte]$dim)           # width  (0 = 256)
  $bw.Write([byte]$dim)           # height
  $bw.Write([byte]0)              # color count
  $bw.Write([byte]0)              # reserved
  $bw.Write([uint16]1)            # planes
  $bw.Write([uint16]32)           # bit count
  $bw.Write([uint32]$i.Bytes.Length)
  $bw.Write([uint32]$offset)
  $offset += $i.Bytes.Length
}

# 图像数据（PNG 直接内嵌）
foreach ($i in $imgs) { $bw.Write($i.Bytes) }
$bw.Flush()

[System.IO.File]::WriteAllBytes($Out, $ms.ToArray())
$bw.Dispose(); $ms.Dispose()

$kb = [math]::Round((Get-Item $Out).Length / 1KB, 1)
Write-Host ("ICO 完成: {0}  ({1} 个尺寸: {2})  {3} KB" -f $Out, $imgs.Count, (($imgs | ForEach-Object { $_.Size }) -join '/'), $kb)
