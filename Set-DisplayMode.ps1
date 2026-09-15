<#
    Set-DisplayMode.ps1 - профили Dell U4025QW

    Основная схема: рабочий стол в SDR, HDR включается только под игры.
    В SDR гамма панели нативная 2.2 и никакой коррекции не требуется, поэтому
    штатное состояние рампа - линейное. Из этого следует, что перед игрой
    ничего сбрасывать не надо: достаточно Win+Alt+B.

        .\Set-DisplayMode.ps1 sdr        # рабочий стол (штатный режим)
        .\Set-DisplayMode.ps1 sdr-night  # тёмная комната, BT.1886
        .\Set-DisplayMode.ps1 hdr        # HDR на рабочем столе (запасной путь)
        .\Set-DisplayMode.ps1 off        # линейный рамп

    Требуется dispwin.exe рядом со скриптом (ArgyllCMS).
#>

param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('sdr', 'sdr-night', 'hdr', 'off')]
    [string]$Mode
)

$ErrorActionPreference = 'Stop'

$Dispwin = Join-Path $PSScriptRoot 'dispwin.exe'
if (-not (Test-Path $Dispwin)) { throw "dispwin.exe не найден рядом со скриптом: $PSScriptRoot" }

function Invoke-Dispwin([string[]]$DispwinArgs) {
    & $Dispwin @DispwinArgs
    if ($LASTEXITCODE -ne 0) { throw "dispwin вернул код $LASTEXITCODE" }
}

function Write-Step([string]$Text) { Write-Host "  $Text" -ForegroundColor White }
function Write-Dim([string]$Text)  { Write-Host "  $Text" -ForegroundColor DarkGray }

switch ($Mode) {

    'sdr' {
        Invoke-Dispwin @('-c')
        Write-Host ''
        Write-Host 'SDR - рабочий стол' -ForegroundColor Cyan
        Write-Host ''
        Write-Step 'HDR в Windows: выключен (Win+Alt+B)'
        Write-Step 'Монитор, Preset Mode: Game, Movie или Custom Color'
        Write-Dim  'НЕ sRGB и не Color Space - они зажимают гамут и убивают сочность'
        Write-Step 'Монитор, Color: Saturation вверх до вкуса, Hue не трогать'
        Write-Step 'Монитор, Brightness: по вкусу, в SDR он разблокирован (до ~349 нит)'
        Write-Host ''
        Write-Dim  'Рамп линейный. Перед играми ничего делать не нужно - только Win+Alt+B.'
        Write-Host ''
    }

    'sdr-night' {
        $lut = Join-Path $PSScriptRoot 'sdr-bt1886-dark.cal'
        if (-not (Test-Path $lut)) { throw "Файл не найден: $lut" }
        Invoke-Dispwin @($lut)
        Write-Host ''
        Write-Host 'SDR - тёмная комната, BT.1886' -ForegroundColor Cyan
        Write-Dim  'Яркость монитора убавить в OSD. Вернуть день: .\Set-DisplayMode.ps1 sdr'
        Write-Host ''
    }

    'hdr' {
        $lut = Join-Path $PSScriptRoot 'lut-s252-w140-g26.cal'
        if (-not (Test-Path $lut)) { throw "Файл не найден: $lut" }
        Write-Host ''
        Write-Host 'HDR на рабочем столе - запасной путь' -ForegroundColor Yellow
        Write-Host ''
        Write-Step 'HDR в Windows: включён'
        Write-Step 'Монитор, Smart HDR: DisplayHDR 600'
        Write-Step 'Слайдер <Яркость контента SDR>: 43%  - один раз, яркость задаёт кривая'
        Write-Dim  'Параметры -> Система -> Дисплей -> HDR'
        Write-Host ''
        Write-Dim  'Слайдер чистит гамма-рамп, поэтому кривая грузится после него.'
        Read-Host  '  Готово? Enter для загрузки кривой'
        Invoke-Dispwin @($lut)
        Write-Host 'Загружено: lut-s252-w140-g26.cal' -ForegroundColor Green
        Write-Host ''
    }

    'off' {
        Invoke-Dispwin @('-c')
        Write-Host 'Рамп линейный.' -ForegroundColor Yellow
    }
}
