<#
    Try-Gamma.ps1 - быстрое сравнение гамм на слух и глаз.

        .\Try-Gamma.ps1 2.2      # нейтрально, максимум деталей в тенях
        .\Try-Gamma.ps1 2.6      # заметно сочнее
        .\Try-Gamma.ps1 3.0      # близко к той картинке, что нравилась раньше

    Все варианты рассчитаны под яркость 140 нит при слайдере SDR 43%.
    Слайдер не трогать: он должен совпадать с W в кривой, иначе поедет всё.

    Чем выше гамма, тем сильнее расходятся каналы и тем насыщеннее цвет.
    Плата - середина и тени темнее, порог различимости в тенях уползает вверх.
#>

param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('2.2', '2.4', '2.6', '2.8', '3.0')]
    [string]$Gamma
)

$ErrorActionPreference = 'Stop'

$Dispwin = Join-Path $PSScriptRoot 'dispwin.exe'
$Lut     = Join-Path $PSScriptRoot ('lut-s252-w140-g{0}.cal' -f $Gamma.Replace('.', ''))

if (-not (Test-Path $Dispwin)) { throw "dispwin.exe не найден: $PSScriptRoot" }
if (-not (Test-Path $Lut))     { throw "Кривая не найдена: $Lut" }

& $Dispwin $Lut
if ($LASTEXITCODE -ne 0) { throw "dispwin вернул код $LASTEXITCODE" }

$note = switch ($Gamma) {
    '2.2' { 'нейтрально - тени с кода 3' }
    '2.4' { 'чуть сочнее' }
    '2.6' { 'заметно сочнее' }
    '2.8' { 'сочно, тени начинают закрываться' }
    '3.0' { 'близко к прежней картинке' }
}
Write-Host ("gamma {0} - {1}" -f $Gamma, $note) -ForegroundColor Cyan
