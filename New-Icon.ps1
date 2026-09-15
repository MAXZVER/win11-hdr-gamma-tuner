<#
    New-Icon.ps1 - рисует Display-Tuner.ico.

    Значок в стиле macOS-дока: скруглённый квадрат с тёплым градиентом и белым
    солнцем. Солнце - самый читаемый символ яркости; на 16 и 20 пикселях лучи
    сливаются в кашу, поэтому там рисуется только диск, покрупнее.

    Все кадры пишутся классическими DIB, без PNG внутри ICO: GDI+, через
    который значок грузит само приложение, PNG-кадры отрисовывать не умеет.
#>

Add-Type -AssemblyName System.Drawing

$Root  = Split-Path -Parent $MyInvocation.MyCommand.Definition
$Out   = Join-Path $Root 'Display-Tuner.ico'
$Sizes = @(16, 20, 24, 32, 40, 48, 64, 96, 128)

function New-Glyph([int]$S) {
    $bmp = New-Object System.Drawing.Bitmap -ArgumentList ([int]$S), ([int]$S), ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = 'AntiAlias'
    $g.Clear([System.Drawing.Color]::Transparent)

    $pad  = [single]($S * 0.045)
    $side = [single]($S - 2 * $pad)
    $r    = [single]($side * 0.225)
    $d    = [single]($r * 2)

    # скруглённый квадрат
    $path = New-Object System.Drawing.Drawing2D.GraphicsPath
    $path.AddArc($pad, $pad, $d, $d, 180, 90)
    $path.AddArc($pad + $side - $d, $pad, $d, $d, 270, 90)
    $path.AddArc($pad + $side - $d, $pad + $side - $d, $d, $d, 0, 90)
    $path.AddArc($pad, $pad + $side - $d, $d, $d, 90, 90)
    $path.CloseFigure()

    # тёплый градиент: янтарь сверху, глубокий оранжевый снизу
    $rect = New-Object System.Drawing.RectangleF -ArgumentList $pad, $pad, $side, $side
    $bg = New-Object System.Drawing.Drawing2D.LinearGradientBrush(
        $rect,
        [System.Drawing.Color]::FromArgb(255, 255, 190, 70),
        [System.Drawing.Color]::FromArgb(255, 243, 116, 20),
        90.0)
    $g.FillPath($bg, $path)

    # мягкий блик сверху - объём, как у иконок дока
    $glossRect = New-Object System.Drawing.RectangleF -ArgumentList $pad, $pad, $side, ([single]($side * 0.55))
    $gloss = New-Object System.Drawing.Drawing2D.LinearGradientBrush(
        $glossRect,
        [System.Drawing.Color]::FromArgb(70, 255, 255, 255),
        [System.Drawing.Color]::FromArgb(0, 255, 255, 255),
        90.0)
    $old = $g.Clip
    $g.SetClip($path)
    $g.FillRectangle($gloss, $glossRect)
    $g.Clip = $old

    $cx = [single]($pad + $side / 2)
    $cy = [single]($pad + $side / 2)
    $white = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(255, 255, 253, 248))

    if ($S -le 20) {
        # мелкие размеры: только диск, иначе лучи превращаются в грязь
        $rad = [single]($side * 0.30)
        $g.FillEllipse($white, ($cx - $rad), ($cy - $rad), ($rad * 2), ($rad * 2))
    } else {
        $rad = [single]($side * 0.19)
        $g.FillEllipse($white, ($cx - $rad), ($cy - $rad), ($rad * 2), ($rad * 2))

        $r1 = [single]($side * 0.28)
        $r2 = [single]($side * 0.415)
        $pen = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(255, 255, 253, 248)), ([single]([math]::Max(1.0, $side * 0.085)))
        $pen.StartCap = 'Round'
        $pen.EndCap = 'Round'
        for ($k = 0; $k -lt 8; $k++) {
            $a = [double]($k * [math]::PI / 4)
            $x1 = [single]($cx + [math]::Cos($a) * $r1)
            $y1 = [single]($cy + [math]::Sin($a) * $r1)
            $x2 = [single]($cx + [math]::Cos($a) * $r2)
            $y2 = [single]($cy + [math]::Sin($a) * $r2)
            $g.DrawLine($pen, $x1, $y1, $x2, $y2)
        }
        $pen.Dispose()
    }

    $white.Dispose(); $gloss.Dispose(); $bg.Dispose(); $path.Dispose(); $g.Dispose()
    return $bmp
}

# DIB-кадр: BITMAPINFOHEADER + BGRA снизу вверх + пустая AND-маска
function Get-DibBytes([System.Drawing.Bitmap]$Bmp) {
    $w = $Bmp.Width; $h = $Bmp.Height
    $ms = New-Object System.IO.MemoryStream
    $bw = New-Object System.IO.BinaryWriter $ms

    $bw.Write([uint32]40)
    $bw.Write([int32]$w)
    $bw.Write([int32]($h * 2))
    $bw.Write([uint16]1)
    $bw.Write([uint16]32)
    $bw.Write([uint32]0)
    $bw.Write([uint32]0)
    $bw.Write([int32]0); $bw.Write([int32]0)
    $bw.Write([uint32]0); $bw.Write([uint32]0)

    for ($y = $h - 1; $y -ge 0; $y--) {
        for ($x = 0; $x -lt $w; $x++) {
            $c = $Bmp.GetPixel($x, $y)
            $bw.Write([byte]$c.B); $bw.Write([byte]$c.G); $bw.Write([byte]$c.R); $bw.Write([byte]$c.A)
        }
    }

    $maskRow = [int]([math]::Floor(($w + 31) / 32) * 4)
    $zeros = New-Object byte[] ($maskRow * $h)
    $bw.Write($zeros)

    $bw.Flush()
    $bytes = $ms.ToArray()
    $bw.Dispose(); $ms.Dispose()
    return ,$bytes      # запятая обязательна: иначе PowerShell развернёт массив
}

$frames = @()
foreach ($s in $Sizes) {
    $b = New-Glyph $s
    $frames += ,@{ Size = $s; Bytes = (Get-DibBytes $b) }
    $b.Dispose()
}

$fs = [System.IO.File]::Create($Out)
$bw = New-Object System.IO.BinaryWriter $fs
try {
    $bw.Write([uint16]0)
    $bw.Write([uint16]1)
    $bw.Write([uint16]$frames.Count)

    $offset = 6 + 16 * $frames.Count
    foreach ($f in $frames) {
        $dim = if ($f.Size -ge 256) { 0 } else { $f.Size }
        $bw.Write([byte]$dim); $bw.Write([byte]$dim)
        $bw.Write([byte]0);    $bw.Write([byte]0)
        $bw.Write([uint16]1);  $bw.Write([uint16]32)
        $bw.Write([uint32]$f.Bytes.Length)
        $bw.Write([uint32]$offset)
        $offset += $f.Bytes.Length
    }
    foreach ($f in $frames) { $bw.Write($f.Bytes) }
} finally {
    $bw.Flush(); $bw.Dispose(); $fs.Dispose()
}

Write-Host ("готово: {0}  ({1:N0} байт, размеры {2})" -f $Out, (Get-Item $Out).Length, ($Sizes -join ', ')) -ForegroundColor Green
