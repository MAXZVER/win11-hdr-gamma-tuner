<#
    Calibrate.ps1 - мастер определения потолка белого панели.

    Зачем: у каждой панели свой предел яркости на полном поле, и на нём
    держатся все остальные настройки. У Dell U4025QW это 255 нит при
    обещанных спекой DisplayHDR 600 трёхстах пятидесяти.

    Как измеряется. Кривая умеет отображать SDR-белый на любой уровень НИЖЕ
    того, что задан слайдером Windows. Значит достаточно один раз попросить
    поставить слайдер на максимум, а дальше перебирать уровень программно:
    приложение само меняет кривую и показывает узор. Пользователь только
    отвечает, видны полосы или поле ровное.

    Узор - чередующиеся полосы кодов 255 и 250 по всему экрану. Если панель
    не дотягивает до запрошенного уровня, оба кода упираются в потолок и
    сливаются. Полосы по всему полю, а не пятно на фоне, - чтобы обойти
    локальное затемнение, которое на многих мониторах не отключается:
    внутри каждой зоны подсветки оба кода лежат поровну.

    Результат пишется в tuner-settings.json полями SliderNits и Ceiling.
#>

[CmdletBinding()]
param([ValidateSet('auto', 'en', 'ru')][string]$Lang = 'auto')

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $MyInvocation.MyCommand.Definition

. (Join-Path $Root 'LutGen.ps1')

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$Dispwin      = Join-Path $Root 'dispwin.exe'
$CurrentLut   = Join-Path $Root 'current.cal'
$SettingsFile = Join-Path $Root 'tuner-settings.json'
$IconFile     = Join-Path $Root 'Display-Tuner.ico'

# слайдер Windows на максимуме: нит = 80 + 4 * процент
$ProbeSlider = 480
$SettleSec   = 15      # ABL включается не сразу, полю надо повисеть
$StepNits    = 5       # точность поиска

if (-not (Test-Path $Dispwin)) { throw "dispwin.exe not found in $Root" }

# ------------------------------------------------------------------- strings
$Strings = @{
    en = @{
        Title      = 'Panel calibration'
        Step1      = 'Step 1 of 2 - prepare'
        Intro      = @'
This finds the highest white level your panel can actually hold on a full
screen. Every other setting hangs off that number, and it differs per panel:
the spec sheet is usually optimistic.

What to do:

1. Set the Windows "SDR content brightness" slider to 100%.
2. In the monitor OSD turn Auto Brightness and Auto Color Temp. off -
   an ambient sensor moving the backlight would ruin the measurement.
3. Come back here and press Start.

The test runs fullscreen. Each step holds a pattern for {0} seconds, then
asks one question. Expect three to five minutes.
'@
        OpenHdr    = 'Open HDR settings'
        Start      = 'Start'
        Cancel     = 'Cancel'
        Settling   = 'Backlight settling: {0} s'
        Question   = 'Are the stripes visible?      Enter - yes      Space - no (flat)      Esc - abort'
        Probing    = 'Testing {0} nits   (range {1}-{2})'
        Step2      = 'Step 2 of 2 - result'
        ResultFmt  = @'
Your panel holds {0} nits on a full field.

Recommended Windows slider position: {1}%  ({2} nits)

That is the ceiling itself: going higher buys nothing, because the panel
clips anyway, and it costs curve precision - the lower the slider, the more
code space is left for the visible range.

Set the slider to {1}% and press Save.
'@
        Save       = 'Save'
        Aborted    = 'Calibration aborted, nothing was changed.'
        NoChange   = 'Close'
        Saved      = 'Saved. Set the Windows slider to {0}% if you have not yet.'
    }
    ru = @{
        Title      = 'Калибровка панели'
        Step1      = 'Шаг 1 из 2 — подготовка'
        Intro      = @'
Сейчас определим, какой уровень белого ваша панель реально держит на полном
экране. На этом числе висят все остальные настройки, и у каждой панели оно
своё: в характеристиках обычно написано больше, чем есть.

Что нужно сделать:

1. Поставить слайдер «Яркость контента SDR» в Windows на 100%.
2. В меню монитора выключить Auto Brightness и Auto Color Temp. —
   датчик освещённости будет двигать подсветку и испортит замер.
3. Вернуться сюда и нажать «Начать».

Тест идёт на весь экран. На каждом шаге узор висит {0} секунд, потом
задаётся один вопрос. Займёт три-пять минут.
'@
        OpenHdr    = 'Открыть настройки HDR'
        Start      = 'Начать'
        Cancel     = 'Отмена'
        Settling   = 'Подсветка устаканивается: {0} с'
        Question   = 'Видны полосы?      Enter — да      Пробел — нет, поле ровное      Esc — прервать'
        Probing    = 'Проверяем {0} нит   (диапазон {1}–{2})'
        Step2      = 'Шаг 2 из 2 — результат'
        ResultFmt  = @'
Ваша панель держит {0} нит на полном поле.

Рекомендуемое положение слайдера Windows: {1}%  ({2} нит)

Это и есть потолок: выше поднимать бессмысленно — панель всё равно срежет,
а точность кривой упадёт. Чем ниже слайдер, тем больше кодового
пространства остаётся на видимый диапазон.

Поставьте слайдер на {1}% и нажмите «Сохранить».
'@
        Save       = 'Сохранить'
        Aborted    = 'Калибровка прервана, ничего не изменено.'
        NoChange   = 'Закрыть'
        Saved      = 'Сохранено. Поставьте слайдер Windows на {0}%, если ещё не.'
    }
}

$pick = if ($Lang -ne 'auto') { $Lang }
        elseif ((Get-Culture).TwoLetterISOLanguageName -eq 'ru') { 'ru' }
        else { 'en' }
$Loc = $Strings[$pick]
if (-not $Loc) { $Loc = $Strings['en'] }

# Процесс запускается скрытым, чтобы не мелькала консоль. Побочный эффект:
# первое окно наследует флаг «скрыто» из startup info и само не показывается.
if (-not ('CalShow' -as [type])) {
Add-Type -TypeDefinition @"
using System; using System.Runtime.InteropServices;
public class CalShow {
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
}
"@
}

function Show-Force($Form) {
    [void][CalShow]::ShowWindow($Form.Handle, 5)     # SW_SHOW
    [void][CalShow]::SetForegroundWindow($Form.Handle)
    $Form.Activate()
}

$appIcon = if (Test-Path $IconFile) { New-Object System.Drawing.Icon $IconFile }
           else { [System.Drawing.SystemIcons]::Application }

# ------------------------------------------------------------------ settings
function Read-Raw {
    if (-not (Test-Path $SettingsFile)) { return $null }
    try { return Get-Content $SettingsFile -Raw -Encoding UTF8 | ConvertFrom-Json } catch { return $null }
}

function Save-Result([int]$Ceiling, [int]$SliderNits) {
    $j = Read-Raw
    $out = [ordered]@{
        White      = if ($j -and $j.White)   { [int]$j.White }   else { 140 }
        Gamma      = if ($j -and $j.Gamma)   { [double]$j.Gamma } else { 2.6 }
        Enabled    = if ($j -and $null -ne $j.Enabled) { [bool]$j.Enabled } else { $true }
        Lang       = if ($j -and $j.Lang)    { [string]$j.Lang } else { 'auto' }
        SliderNits = $SliderNits
        Ceiling    = $Ceiling
        Presets    = if ($j -and $j.Presets) { $j.Presets } else {
            [ordered]@{
                day     = [ordered]@{ White = 220; Gamma = 2.2 }
                evening = [ordered]@{ White = 140; Gamma = 2.6 }
                night   = [ordered]@{ White = 100; Gamma = 2.4 }
            }
        }
    }
    # яркость не должна оказаться выше нового потолка
    if ($out.White -gt $SliderNits) { $out.White = $SliderNits }
    $out | ConvertTo-Json -Depth 5 | Set-Content -Path $SettingsFile -Encoding UTF8
}

function Set-Probe([int]$WhiteNits) {
    New-Lut -SliderNits $ProbeSlider -WhiteNits $WhiteNits -Gamma 2.2 -Path $CurrentLut
    & $Dispwin $CurrentLut | Out-Null
}

function Clear-Curve { & $Dispwin -c | Out-Null }

# --------------------------------------------------------------- step 1: intro
$intro                 = New-Object System.Windows.Forms.Form
$intro.Text            = $Loc.Title
$intro.Size            = New-Object System.Drawing.Size(600, 520)
$intro.StartPosition   = 'CenterScreen'
$intro.FormBorderStyle = 'FixedSingle'
$intro.MaximizeBox     = $false
$intro.Font            = New-Object System.Drawing.Font('Segoe UI', 9)
$intro.Icon            = $appIcon
$intro.BackColor       = [System.Drawing.Color]::FromArgb(250, 250, 250)

$lblStep = New-Object System.Windows.Forms.Label
$lblStep.Text = $Loc.Step1
$lblStep.Location = New-Object System.Drawing.Point(24, 20)
$lblStep.Size = New-Object System.Drawing.Size(540, 26)
$lblStep.Font = New-Object System.Drawing.Font('Segoe UI', 13, [System.Drawing.FontStyle]::Bold)
$intro.Controls.Add($lblStep)

$txt = New-Object System.Windows.Forms.Label
$txt.Text = $Loc.Intro -f $SettleSec
$txt.Location = New-Object System.Drawing.Point(24, 56)
$txt.Size = New-Object System.Drawing.Size(544, 330)
$txt.ForeColor = [System.Drawing.Color]::FromArgb(60, 60, 60)
$intro.Controls.Add($txt)

$btnHdr = New-Object System.Windows.Forms.Button
$btnHdr.Text = $Loc.OpenHdr
$btnHdr.Size = New-Object System.Drawing.Size(180, 34)
$btnHdr.Location = New-Object System.Drawing.Point(24, 410)
$btnHdr.FlatStyle = 'System'
$btnHdr.Add_Click({ Start-Process 'ms-settings:display' })
$intro.Controls.Add($btnHdr)

$btnStart = New-Object System.Windows.Forms.Button
$btnStart.Text = $Loc.Start
$btnStart.Size = New-Object System.Drawing.Size(130, 34)
$btnStart.Location = New-Object System.Drawing.Point(300, 410)
$btnStart.FlatStyle = 'System'
$btnStart.DialogResult = 'OK'
$intro.Controls.Add($btnStart)

$btnCancel = New-Object System.Windows.Forms.Button
$btnCancel.Text = $Loc.Cancel
$btnCancel.Size = New-Object System.Drawing.Size(130, 34)
$btnCancel.Location = New-Object System.Drawing.Point(438, 410)
$btnCancel.FlatStyle = 'System'
$btnCancel.DialogResult = 'Cancel'
$intro.Controls.Add($btnCancel)

$intro.Add_Shown({ Show-Force $intro })
$intro.AcceptButton = $btnStart
$intro.CancelButton = $btnCancel

if ($intro.ShowDialog() -ne 'OK') { $intro.Dispose(); exit }
$intro.Dispose()

# ------------------------------------------------------- step 2: measurement
# половинное деление: lo заведомо достижим, hi заведомо нет
$script:Lo = 100
$script:Hi = $ProbeSlider
$script:Probe = 0
$script:Remaining = 0
$script:Answered = $false
$script:Aborted = $false

$test                 = New-Object System.Windows.Forms.Form
$test.FormBorderStyle = 'None'
$test.WindowState     = 'Maximized'
$test.TopMost         = $true
$test.BackColor       = [System.Drawing.Color]::Black
$test.KeyPreview      = $true
$test.Cursor          = [System.Windows.Forms.Cursors]::Default

$hud = New-Object System.Windows.Forms.Label
$hud.AutoSize = $false
$hud.Height = 78
$hud.Dock = 'Bottom'
$hud.TextAlign = 'MiddleCenter'
$hud.Font = New-Object System.Drawing.Font('Segoe UI', 11)
$hud.BackColor = [System.Drawing.Color]::FromArgb(24, 24, 24)
$hud.ForeColor = [System.Drawing.Color]::FromArgb(190, 190, 190)
$test.Controls.Add($hud)

$test.Add_Paint({
    param($sender, $e)
    $g = $e.Graphics
    $w = $test.ClientSize.Width
    $h = $test.ClientSize.Height - $hud.Height
    # полосы двух близких кодов: ширина 4 пикселя, чтобы внутри каждой
    # зоны подсветки оба кода лежали поровну
    $hi = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(255, 255, 255))
    $lo = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(250, 250, 250))
    $g.FillRectangle($hi, 0, 0, $w, $h)
    for ($x = 4; $x -lt $w; $x += 8) { $g.FillRectangle($lo, $x, 0, 4, $h) }
    $hi.Dispose(); $lo.Dispose()
})

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 1000

function Start-Probe {
    if (($script:Hi - $script:Lo) -le $StepNits) { Complete-Test; return }
    $mid = [int]([math]::Round((($script:Lo + $script:Hi) / 2) / $StepNits) * $StepNits)
    if ($mid -le $script:Lo) { $mid = $script:Lo + $StepNits }
    if ($mid -ge $script:Hi) { $mid = $script:Hi - $StepNits }
    $script:Probe = $mid
    $script:Answered = $false
    $script:Remaining = $SettleSec
    Set-Probe $mid
    $hud.Text = ($Loc.Probing -f $mid, $script:Lo, $script:Hi) + "`n" + ($Loc.Settling -f $script:Remaining)
    $timer.Start()
}

function Complete-Test {
    $timer.Stop()
    $test.Close()
}

$timer.Add_Tick({
    $script:Remaining--
    if ($script:Remaining -gt 0) {
        $hud.Text = ($Loc.Probing -f $script:Probe, $script:Lo, $script:Hi) + "`n" + ($Loc.Settling -f $script:Remaining)
    } else {
        $timer.Stop()
        $script:Answered = $true
        $hud.Text = ($Loc.Probing -f $script:Probe, $script:Lo, $script:Hi) + "`n" + $Loc.Question
    }
})

$test.Add_KeyDown({
    param($sender, $e)
    if ($e.KeyCode -eq 'Escape') { $script:Aborted = $true; Complete-Test; return }
    if (-not $script:Answered) { return }
    if ($e.KeyCode -eq 'Enter') { $script:Lo = $script:Probe; Start-Probe }
    elseif ($e.KeyCode -eq 'Space') { $script:Hi = $script:Probe; Start-Probe }
})

$test.Add_Shown({ Show-Force $test; Start-Probe })
[void]$test.ShowDialog()
$test.Dispose()
Clear-Curve

if ($script:Aborted) {
    [void][System.Windows.Forms.MessageBox]::Show($Loc.Aborted, $Loc.Title)
    exit
}

# ------------------------------------------------------------ step 3: result
$ceiling = $script:Lo
$sliderPct = [int]([math]::Round((($ceiling - 80) / 4)))
if ($sliderPct -lt 0) { $sliderPct = 0 }
if ($sliderPct -gt 100) { $sliderPct = 100 }
$sliderNits = 80 + 4 * $sliderPct

$res                 = New-Object System.Windows.Forms.Form
$res.Text            = $Loc.Title
$res.Size            = New-Object System.Drawing.Size(600, 440)
$res.StartPosition   = 'CenterScreen'
$res.FormBorderStyle = 'FixedSingle'
$res.MaximizeBox     = $false
$res.Font            = New-Object System.Drawing.Font('Segoe UI', 9)
$res.Icon            = $appIcon
$res.BackColor       = [System.Drawing.Color]::FromArgb(250, 250, 250)

$lblStep2 = New-Object System.Windows.Forms.Label
$lblStep2.Text = $Loc.Step2
$lblStep2.Location = New-Object System.Drawing.Point(24, 20)
$lblStep2.Size = New-Object System.Drawing.Size(540, 26)
$lblStep2.Font = New-Object System.Drawing.Font('Segoe UI', 13, [System.Drawing.FontStyle]::Bold)
$res.Controls.Add($lblStep2)

$txt2 = New-Object System.Windows.Forms.Label
$txt2.Text = $Loc.ResultFmt -f $ceiling, $sliderPct, $sliderNits
$txt2.Location = New-Object System.Drawing.Point(24, 56)
$txt2.Size = New-Object System.Drawing.Size(544, 260)
$txt2.ForeColor = [System.Drawing.Color]::FromArgb(60, 60, 60)
$res.Controls.Add($txt2)

$btnHdr2 = New-Object System.Windows.Forms.Button
$btnHdr2.Text = $Loc.OpenHdr
$btnHdr2.Size = New-Object System.Drawing.Size(180, 34)
$btnHdr2.Location = New-Object System.Drawing.Point(24, 340)
$btnHdr2.FlatStyle = 'System'
$btnHdr2.Add_Click({ Start-Process 'ms-settings:display' })
$res.Controls.Add($btnHdr2)

$btnSaveRes = New-Object System.Windows.Forms.Button
$btnSaveRes.Text = $Loc.Save
$btnSaveRes.Size = New-Object System.Drawing.Size(160, 34)
$btnSaveRes.Location = New-Object System.Drawing.Point(408, 340)
$btnSaveRes.FlatStyle = 'System'
$btnSaveRes.DialogResult = 'OK'
$res.Controls.Add($btnSaveRes)
$res.Add_Shown({ Show-Force $res })
$res.AcceptButton = $btnSaveRes

if ($res.ShowDialog() -eq 'OK') {
    Save-Result $ceiling $sliderNits
    [void][System.Windows.Forms.MessageBox]::Show(($Loc.Saved -f $sliderPct), $Loc.Title)
}
$res.Dispose()
