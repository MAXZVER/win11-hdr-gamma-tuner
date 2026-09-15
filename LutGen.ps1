<#
    LutGen.ps1 - генератор кривых для HDR-режима. Подключается через точку:
        . (Join-Path $PSScriptRoot 'LutGen.ps1')

    Кривая считается в PQ-домене: в HDR GPU-рамп работает по кодам финального
    сигнала, а они в PQ означают абсолютные ниты.

    Два уровня белого, и это главное отличие от прежней версии:

      SliderNits - куда Windows кладёт белый SDR-контента. Задаётся слайдером
                   «Яркость контента SDR», программно недоступен, ставится
                   один раз и не трогается. Нит = 80 + 4 × процент.

      WhiteNits  - какую яркость белого мы хотим на самом деле. Свободный
                   параметр, живёт целиком в кривой.

    Когда они равны, получается прежнее поведение. Когда WhiteNits меньше -
    яркость понижается программно, без похода в настройки Windows.

    Выше SliderNits лежат света HDR-контента. Там кривая не identity, а линейный
    подъём в PQ-координатах от нового белого до пика: иначе на границе SDR-белого
    получился бы разрыв, а так переход непрерывный и света остаются достижимыми.
#>

$script:LutM1 = 2610.0 / 16384
$script:LutM2 = 2523.0 / 4096 * 128
$script:LutC1 = 3424.0 / 4096
$script:LutC2 = 2413.0 / 4096 * 32
$script:LutC3 = 2392.0 / 4096 * 32

function ConvertTo-Nits([double]$n) {
    if ($n -le 0) { return 0.0 }
    $p = [math]::Pow($n, 1 / $script:LutM2)
    $num = [math]::Max($p - $script:LutC1, 0.0)
    $den = $script:LutC2 - $script:LutC3 * $p
    return 10000.0 * [math]::Pow($num / $den, 1 / $script:LutM1)
}

function ConvertTo-PqCode([double]$L) {
    if ($L -le 0) { return 0.0 }
    $Y = [math]::Pow($L / 10000.0, $script:LutM1)
    return [math]::Pow(($script:LutC1 + $script:LutC2 * $Y) / (1 + $script:LutC3 * $Y), $script:LutM2)
}

function ConvertTo-SrgbEncoded([double]$l) {
    if ($l -le 0) { return 0.0 }
    if ($l -le 0.0031308) { return 12.92 * $l }
    return 1.055 * [math]::Pow($l, 1 / 2.4) - 0.055
}

function Get-LutName([int]$SliderNits, [int]$WhiteNits, [double]$Gamma) {
    $g = $Gamma.ToString('0.0', [System.Globalization.CultureInfo]::InvariantCulture).Replace('.', '')
    if ($SliderNits -eq $WhiteNits) { return "lut-w$WhiteNits-g$g.cal" }
    return "lut-s$SliderNits-w$WhiteNits-g$g.cal"
}

function New-Lut {
    param(
        [Parameter(Mandatory = $true)][double]$SliderNits,
        [Parameter(Mandatory = $true)][double]$WhiteNits,
        [Parameter(Mandatory = $true)][double]$Gamma,
        [Parameter(Mandatory = $true)][string]$Path
    )

    if ($WhiteNits -gt $SliderNits) {
        throw "WhiteNits ($WhiteNits) больше SliderNits ($SliderNits): ярче слайдера кривая сделать не может."
    }

    $Steps = 1024
    $ci = [System.Globalization.CultureInfo]::InvariantCulture

    $nSlider = ConvertTo-PqCode $SliderNits    # где кончается SDR-диапазон
    $nWhite  = ConvertTo-PqCode $WhiteNits     # куда мы кладём белый
    $slope   = if ($nSlider -lt 1.0) { (1.0 - $nWhite) / (1.0 - $nSlider) } else { 1.0 }

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('CAL')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('ORIGINATOR "srgb-to-gamma' + $Gamma + ' S' + $SliderNits + ' W' + $WhiteNits + '"')
    [void]$sb.AppendLine('DEVICE_CLASS "DISPLAY"')
    [void]$sb.AppendLine('COLOR_REP "RGB"')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('NUMBER_OF_FIELDS 4')
    [void]$sb.AppendLine('BEGIN_DATA_FORMAT')
    [void]$sb.AppendLine('RGB_I RGB_R RGB_G RGB_B')
    [void]$sb.AppendLine('END_DATA_FORMAT')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('NUMBER_OF_SETS ' + $Steps)
    [void]$sb.AppendLine('BEGIN_DATA')

    for ($i = 0; $i -lt $Steps; $i++) {
        $x = $i / ($Steps - 1)
        $L = ConvertTo-Nits $x
        if ($L -ge $SliderNits) {
            # света HDR: линейный подъём в PQ от нового белого до пика
            $v = $nWhite + ($x - $nSlider) * $slope
        } else {
            $e = ConvertTo-SrgbEncoded ($L / $SliderNits)          # код, как его видит Windows
            $v = ConvertTo-PqCode ([math]::Pow($e, $Gamma) * $WhiteNits)
        }
        $v = [math]::Max(0.0, [math]::Min(1.0, $v))
        $ns = $x.ToString('F14', $ci)
        $vs = $v.ToString('F14', $ci)
        [void]$sb.AppendLine($ns + "`t" + $vs + "`t" + $vs + "`t" + $vs)
    }

    [void]$sb.AppendLine('END_DATA')
    [System.IO.File]::WriteAllText($Path, $sb.ToString())
}

function Get-LutPath {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][int]$SliderNits,
        [Parameter(Mandatory = $true)][int]$WhiteNits,
        [Parameter(Mandatory = $true)][double]$Gamma
    )
    $path = Join-Path $Root (Get-LutName $SliderNits $WhiteNits $Gamma)
    if (-not (Test-Path $path)) { New-Lut -SliderNits $SliderNits -WhiteNits $WhiteNits -Gamma $Gamma -Path $path }
    return $path
}
