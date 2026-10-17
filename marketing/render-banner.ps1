# Renders marketing/launch-banner.png (1600x900) for the AURA pre-launch announcement.
# Windows PowerShell 5.1 + System.Drawing; deterministic (fixed random seed).
param(
  [string]$Out = (Join-Path $PSScriptRoot "launch-banner.png"),
  [string]$Logo = (Join-Path $PSScriptRoot "..\contracts\assets\aura-logo.png"),
  [string]$When = "OCT 17  ·  17:00 UTC"
)
Add-Type -AssemblyName System.Drawing
$W = 1600; $H = 900
$bmp = New-Object System.Drawing.Bitmap $W, $H
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.SmoothingMode = 'AntiAlias'; $g.TextRenderingHint = 'AntiAliasGridFit'; $g.InterpolationMode = 'HighQualityBicubic'; $g.CompositingQuality = 'HighQuality'
function C($a, $r, $gg, $b) { [System.Drawing.Color]::FromArgb($a, $r, $gg, $b) }
function P($x, $y) { New-Object System.Drawing.PointF $x, $y }
function RoundRect($x, $y, $w, $h, $r) {
  $p = New-Object System.Drawing.Drawing2D.GraphicsPath
  $p.AddArc($x, $y, 2*$r, 2*$r, 180, 90); $p.AddArc($x+$w-2*$r, $y, 2*$r, 2*$r, 270, 90)
  $p.AddArc($x+$w-2*$r, $y+$h-2*$r, 2*$r, 2*$r, 0, 90); $p.AddArc($x, $y+$h-2*$r, 2*$r, 2*$r, 90, 90); $p.CloseFigure(); $p
}
function Blob($cx, $cy, $rx, $ry, $color) {
  $p = New-Object System.Drawing.Drawing2D.GraphicsPath; $p.AddEllipse($cx-$rx, $cy-$ry, 2*$rx, 2*$ry)
  $b = New-Object System.Drawing.Drawing2D.PathGradientBrush $p; $b.CenterColor = $color; $b.SurroundColors = @((C 0 0 0 0)); $g.FillPath($b, $p)
}
function LG($x1, $y1, $x2, $y2, $c1, $c2) { New-Object System.Drawing.Drawing2D.LinearGradientBrush (P $x1 $y1), (P $x2 $y2), $c1, $c2 }
$iris = @((C 255 255 140 220), (C 255 255 230 140), (C 255 140 255 210), (C 255 120 170 255), (C 255 200 140 255))
function IrisBrush($x1, $y1, $x2, $y2) {
  $b = New-Object System.Drawing.Drawing2D.LinearGradientBrush (P $x1 $y1), (P $x2 $y2), $iris[0], $iris[4]
  $blend = New-Object System.Drawing.Drawing2D.ColorBlend; $blend.Colors = $iris; $blend.Positions = @(0, 0.25, 0.5, 0.75, 1); $b.InterpolationColors = $blend; $b
}
$rand = New-Object System.Random 404

# ---- deep space background
$bg = LG 0 0 $W $H (C 255 6 7 24) (C 255 22 10 48)
$g.FillRectangle($bg, 0, 0, $W, $H)
Blob 430 420 620 520 (C 120 70 60 200)
Blob 1180 160 520 300 (C 90 200 60 170)
Blob 1350 620 420 260 (C 70 40 160 200)
Blob 250 820 520 200 (C 80 220 80 160)
Blob 820 300 300 220 (C 50 120 90 220)

# ---- stars
for ($i = 0; $i -lt 420; $i++) {
  $x = $rand.Next(0, $W); $y = $rand.Next(0, 650); $s = [Math]::Max(1, $rand.NextDouble() * 2.6); $a = $rand.Next(60, 230)
  $g.FillEllipse((New-Object System.Drawing.SolidBrush (C $a 230 235 255)), [float]$x, [float]$y, [float]$s, [float]$s)
}
foreach ($star in @(@(1080, 90), @(1510, 260), @(700, 70), @(1540, 400), @(90, 120))) {
  $sx = $star[0]; $sy = $star[1]
  Blob $sx $sy 18 18 (C 220 255 255 255)
  $pen = New-Object System.Drawing.Pen (C 160 255 255 255), 1.5
  $g.DrawLine($pen, $sx-22, $sy, $sx+22, $sy); $g.DrawLine($pen, $sx, $sy-22, $sx, $sy+22)
}

# ---- synthwave grid floor
$horizon = 690; $vx = 800
$floor = LG 0 ($horizon-40) 0 $H (C 0 0 0 0) (C 200 10 4 30)
$g.FillRectangle($floor, 0, ($horizon-40), $W, ($H-$horizon+40))
$gridPen = New-Object System.Drawing.Pen (C 110 230 110 255), 1.6
for ($k = -14; $k -le 14; $k++) { $g.DrawLine($gridPen, $vx, $horizon, $vx + $k*170, $H) }
for ($j = 1; $j -le 9; $j++) { $yy = $horizon + [Math]::Pow($j/9.0, 2.2) * ($H - $horizon); $gridPen.Color = (C ([int](40 + 12*$j)) 140 160 255); $g.DrawLine($gridPen, 0, [float]$yy, $W, [float]$yy) }
$g.DrawLine((New-Object System.Drawing.Pen (C 200 255 150 230), 2.5), 0, $horizon, $W, $horizon)
Blob $vx $horizon 700 26 (C 150 255 140 230)

# ---- logo with halo and iridescent orbits
$cx = 400; $cy = 400
Blob $cx $cy 330 330 (C 150 110 120 255)
Blob $cx $cy 200 200 (C 120 255 170 240)
$state = $g.Save()
$g.TranslateTransform($cx, $cy)
foreach ($o in @(@(0, 300, 120, 4), @(60, 320, 110, 3), @(-55, 285, 95, 2.5))) {
  $g.RotateTransform($o[0])
  $pen = New-Object System.Drawing.Pen (IrisBrush (-$o[1]) 0 $o[1] 0), $o[3]
  $g.DrawEllipse($pen, -$o[1], -$o[2], 2*$o[1], 2*$o[2])
  $g.RotateTransform(-$o[0])
}
$g.Restore($state)
$logoImg = [System.Drawing.Image]::FromFile((Resolve-Path $Logo))
$g.DrawImage($logoImg, $cx-250, $cy-250, 500, 500)
foreach ($dot in @(@(640, 260, 9), @(165, 560, 7), @(600, 600, 6), @(210, 210, 5))) { Blob $dot[0] $dot[1] ($dot[2]*3) ($dot[2]*3) (C 230 255 220 250) }

# ---- AI AGENT chip
$chip = RoundRect 800 92 210 50 25
$g.FillPath((New-Object System.Drawing.SolidBrush (C 60 255 255 255)), $chip)
$g.DrawPath((New-Object System.Drawing.Pen (IrisBrush 800 0 1010 0), 2), $chip)
$fChip = New-Object System.Drawing.Font("Segoe UI Semibold", 22, [System.Drawing.FontStyle]::Regular, [System.Drawing.GraphicsUnit]::Pixel)
$g.FillEllipse((New-Object System.Drawing.SolidBrush (C 255 140 255 210)), 822, 110, 14, 14)
$g.DrawString("AI AGENT", $fChip, [System.Drawing.Brushes]::White, 846, 102)

# ---- AURA title with glow
$fam = New-Object System.Drawing.FontFamily "Segoe UI Black"
$title = New-Object System.Drawing.Drawing2D.GraphicsPath
$title.AddString("AURA", $fam, [int][System.Drawing.FontStyle]::Regular, 190, (P 786 128), [System.Drawing.StringFormat]::GenericDefault)
foreach ($wd in 34, 24, 16, 9) { $glowPen = New-Object System.Drawing.Pen (C ([int](12 + (34-$wd))) 210 120 255), $wd; $glowPen.LineJoin = 'Round'; $g.DrawPath($glowPen, $title) }
$g.FillPath((IrisBrush 790 150 1300 330), $title)
$g.DrawPath((New-Object System.Drawing.Pen (C 200 255 255 255), 1.5), $title)

$fSub = New-Object System.Drawing.Font("Segoe UI Semibold", 34, [System.Drawing.FontStyle]::Regular, [System.Drawing.GraphicsUnit]::Pixel)
$x = 800
$g.DrawString("L A U N C H I N G   O N   E T H E R E U M", $fSub, (New-Object System.Drawing.SolidBrush (C 255 225 228 255)), $x, 352)

# ---- launch-time pill (glass + neon border)
$pill = RoundRect $x 420 610 86 43
$pillBrush = LG $x 0 ($x+610) 0 (C 210 98 80 235) (C 210 220 90 200)
$g.FillPath($pillBrush, $pill)
$g.DrawPath((New-Object System.Drawing.Pen (C 255 255 255 255), 2), $pill)
$fTime = New-Object System.Drawing.Font("Segoe UI Black", 44, [System.Drawing.FontStyle]::Regular, [System.Drawing.GraphicsUnit]::Pixel)
$fLbl = New-Object System.Drawing.Font("Segoe UI Semibold", 18, [System.Drawing.FontStyle]::Regular, [System.Drawing.GraphicsUnit]::Pixel)
$g.DrawString("CONTRACT LAUNCH", $fLbl, (New-Object System.Drawing.SolidBrush (C 230 255 255 255)), $x+36, 428)
$g.DrawString($When, $fTime, [System.Drawing.Brushes]::White, $x+32, 446)

# ---- glass info cards
$cards = @(
  @("1B", "SUPPLY", "100% LP locked forever"),
  @("1.3%", "FEES", "0.3% platform + 1% creator"),
  @("2%", "MAX / WALLET", "first 5 min, anti-snipe")
)
$fBig = New-Object System.Drawing.Font("Segoe UI Black", 46, [System.Drawing.FontStyle]::Regular, [System.Drawing.GraphicsUnit]::Pixel)
$fCap = New-Object System.Drawing.Font("Segoe UI Semibold", 17, [System.Drawing.FontStyle]::Regular, [System.Drawing.GraphicsUnit]::Pixel)
$fTxt = New-Object System.Drawing.Font("Segoe UI", 16, [System.Drawing.FontStyle]::Regular, [System.Drawing.GraphicsUnit]::Pixel)
$cw = 236; $ch = 150; $gap = 18; $cy0 = 540
for ($i = 0; $i -lt 3; $i++) {
  $cx0 = $x + $i * ($cw + $gap)
  $card = RoundRect $cx0 $cy0 $cw $ch 22
  $glass = LG $cx0 $cy0 $cx0 ($cy0+$ch) (C 70 255 255 255) (C 25 255 255 255)
  $g.FillPath($glass, $card)
  $g.DrawPath((New-Object System.Drawing.Pen (C 110 255 255 255), 1.5), $card)
  $g.FillRectangle((IrisBrush $cx0 0 ($cx0+$cw) 0), $cx0+22, $cy0, $cw-44, 3)
  $g.DrawString($cards[$i][0], $fBig, (IrisBrush $cx0 $cy0 ($cx0+$cw) ($cy0+60)), $cx0+18, $cy0+12)
  $g.DrawString($cards[$i][1], $fCap, (New-Object System.Drawing.SolidBrush (C 255 190 200 255)), $cx0+22, $cy0+80)
  $g.DrawString($cards[$i][2], $fTxt, [System.Drawing.Brushes]::White, $cx0+22, $cy0+106)
}

# ---- footer ribbon
$ribbon = LG 0 0 $W 0 (C 170 20 10 50) (C 170 50 20 90)
$g.FillRectangle($ribbon, 0, $H-64, $W, 64)
$g.FillRectangle((IrisBrush 0 0 $W 0), 0, $H-64, $W, 2)
$fFoot = New-Object System.Drawing.Font("Segoe UI Semibold", 22, [System.Drawing.FontStyle]::Regular, [System.Drawing.GraphicsUnit]::Pixel)
$fFootS = New-Object System.Drawing.Font("Segoe UI", 20, [System.Drawing.FontStyle]::Regular, [System.Drawing.GraphicsUnit]::Pixel)
$g.DrawString("Launching with Programmable  ·  Uniswap v4", $fFoot, [System.Drawing.Brushes]::White, 48, $H-48)
$g.DrawString("auracoin.cloud   ·   @auracoin404   ·   CA posted only at launch   ·   NFA", $fFootS, (New-Object System.Drawing.SolidBrush (C 255 200 205 255)), 760, $H-46)

$bmp.Save($Out, [System.Drawing.Imaging.ImageFormat]::Png)
$g.Dispose(); $bmp.Dispose(); $logoImg.Dispose()
"saved $Out"
