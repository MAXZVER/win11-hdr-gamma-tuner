<#
    Display-Tuner.ps1 - brightness and gamma for Windows 11 HDR mode.

        DisplayTuner.exe             open the window
        DisplayTuner.exe -Tray       background, tray icon only (autostart uses this)
        DisplayTuner.exe -Apply      apply saved settings and exit
        DisplayTuner.exe -Lang en    force a language (en / ru)

    Not a Windows service on purpose: services run in session 0 and cannot show
    a tray icon. What is needed is an ordinary user process started at logon -
    that is the -Tray mode.

    The Windows "SDR content brightness" slider is set once to 43% and never
    touched again. Brightness lives in the curve, which maps SDR white from
    252 nits down to whatever is selected. Windows exposes no API for that
    slider, which is why it is frozen.

    The curve is written to current.cal and overwritten each time, so the
    folder does not fill up with files.
#>

[CmdletBinding()]
param(
    [switch]$Apply,
    [switch]$Tray,
    [ValidateSet('auto', 'en', 'ru')][string]$Lang = 'auto'
)

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $MyInvocation.MyCommand.Definition

. (Join-Path $Root 'LutGen.ps1')

$Dispwin      = Join-Path $Root 'dispwin.exe'
$CurrentLut   = Join-Path $Root 'current.cal'
$SettingsFile = Join-Path $Root 'tuner-settings.json'
$IconFile     = Join-Path $Root 'Display-Tuner.ico'
$IconFileOff  = Join-Path $Root 'Display-Tuner-off.ico'
# ярлык в папке автозагрузки: не требует прав администратора, в отличие
# от задачи в планировщике, и виден пользователю в привычном месте
$StartupLnk   = Join-Path ([Environment]::GetFolderPath('Startup')) 'Display Tuner.lnk'

# потолок панели у каждого свой; ставится мастером Calibrate.ps1
$DefaultSliderNits = 252
$MinNits = 80

# profile keys are stable; only the labels are translated
$PresetKeys = @('day', 'evening', 'night')

if (-not (Test-Path $Dispwin)) {
    throw "dispwin.exe not found in $Root. Get ArgyllCMS from https://www.argyllcms.com/downloadwin.html"
}

# ------------------------------------------------------------------ strings
$Strings = @{
    en = @{
        Title        = 'Display Tuner'
        SliderHint   = 'Windows SDR slider is at {0}% - leave it alone'
        Brightness   = 'Brightness'
        Gamma        = 'Gamma'
        Profiles     = 'Profiles'
        SaveHere     = 'Save here'
        GameMode     = 'Game mode'
        RestoreCurve = 'Restore correction'
        GameHint     = 'Game mode drops the curve: it crushes native HDR in games'
        Tests        = 'Tests'
        ToTray       = 'To tray'
        Nits         = '{0} nits'
        StateOn      = '{0} nits  -  gamma {1}'
        StateOff     = 'game mode'
        TrayOn       = 'Brightness: {0} nits, gamma {1}'
        TrayOff      = 'Game mode: curve removed'
        Ready        = 'ready'
        Applying     = 'applying...'
        Applied      = 'applied: {0} nits, gamma {1}'
        Cleared      = 'curve removed - native HDR in games is untouched'
        ProfileSet   = 'profile "{0}"'
        ProfileSaved = 'profile "{0}" overwritten'
        Error        = 'error: {0}'
        ShowWindow   = 'Show window'
        GameToggle   = 'Game mode (drop the curve)'
        Quit         = 'Quit'
        Restart      = 'Settings saved. The app will restart to pick them up.'
        Day          = 'Day'
        Evening      = 'Evening'
        Night        = 'Night'
        TestShadow   = 'Shadows (gray-test)'
        TestBand     = 'Banding (band-test)'
        TestColor    = 'Colour (color-test)'
        TestClip     = 'White ceiling (clip-test)'
        Autostart    = 'Start with Windows'
        StartupOn    = 'autostart on'
        StartupOff   = 'autostart off'
        Calibrate    = 'Calibrate panel...'
        NotCalibrated = 'panel not calibrated yet - press Calibrate'
    }
    ru = @{
        Title        = 'Яркость дисплея'
        SliderHint   = 'слайдер SDR в Windows: {0}%, не менять'
        Brightness   = 'Яркость'
        Gamma        = 'Гамма'
        Profiles     = 'Профили'
        SaveHere     = 'Записать сюда'
        GameMode     = 'Игровой режим'
        RestoreCurve = 'Вернуть коррекцию'
        GameHint     = 'Игровой режим снимает кривую: она давит нативный HDR в играх'
        Tests        = 'Тесты'
        ToTray       = 'В трей'
        Nits         = '{0} нит'
        StateOn      = '{0} нит  ·  гамма {1}'
        StateOff     = 'игровой режим'
        TrayOn       = 'Яркость: {0} нит, гамма {1}'
        TrayOff      = 'Игровой режим: кривая снята'
        Ready        = 'готов'
        Applying     = 'применяю...'
        Applied      = 'применено: {0} нит, гамма {1}'
        Cleared      = 'кривая снята — нативный HDR в играх не давится'
        ProfileSet   = 'профиль «{0}»'
        ProfileSaved = 'профиль «{0}» перезаписан'
        Error        = 'ошибка: {0}'
        ShowWindow   = 'Показать окно'
        GameToggle   = 'Игровой режим (снять кривую)'
        Quit         = 'Выход'
        Restart      = 'Настройки сохранены. Приложение перезапустится, чтобы их подхватить.'
        Day          = 'День'
        Evening      = 'Вечер'
        Night        = 'Ночь'
        TestShadow   = 'Тени (gray-test)'
        TestBand     = 'Полосение (band-test)'
        TestColor    = 'Цвет (color-test)'
        TestClip     = 'Потолок белого (clip-test)'
        Autostart    = 'Запускать при входе'
        StartupOn    = 'автозапуск включён'
        StartupOff   = 'автозапуск выключен'
        Calibrate    = 'Калибровать панель…'
        NotCalibrated = 'панель ещё не откалибрована — нажмите «Калибровать»'
    }
}

# ------------------------------------------------------------------ settings
function Get-DefaultSettings {
    return [ordered]@{
        White   = 140
        Gamma   = 2.6
        Enabled = $true
        Lang    = 'auto'
        SliderNits = $DefaultSliderNits
        Ceiling    = 0
        Presets = [ordered]@{
            day     = [ordered]@{ White = 220; Gamma = 2.2 }
            evening = [ordered]@{ White = 140; Gamma = 2.6 }
            night   = [ordered]@{ White = 100; Gamma = 2.4 }
        }
    }
}

function Read-Settings {
    $s = Get-DefaultSettings
    if (-not (Test-Path $SettingsFile)) { return $s }
    try {
        $j = Get-Content $SettingsFile -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($null -ne $j.White)   { $s.White   = [int]$j.White }
        if ($null -ne $j.Gamma)   { $s.Gamma   = [double]$j.Gamma }
        if ($null -ne $j.Enabled) { $s.Enabled = [bool]$j.Enabled }
        if ($null -ne $j.Lang)    { $s.Lang    = [string]$j.Lang }
        if ($null -ne $j.SliderNits) { $s.SliderNits = [int]$j.SliderNits }
        if ($null -ne $j.Ceiling)    { $s.Ceiling    = [int]$j.Ceiling }
        if ($null -ne $j.Presets) {
            # старые файлы держали профили под русскими именами
            $legacy = @{ day = 'День'; evening = 'Вечер'; night = 'Ночь' }
            foreach ($k in $PresetKeys) {
                $p = $j.Presets.$k
                if ($null -eq $p) { $p = $j.Presets.($legacy[$k]) }
                if ($null -ne $p -and $null -ne $p.White) {
                    $s.Presets[$k].White = [int]$p.White
                    $s.Presets[$k].Gamma = [double]$p.Gamma
                }
            }
        }
    } catch { }
    return $s
}

function Write-Settings($s) {
    try { $s | ConvertTo-Json -Depth 5 | Set-Content -Path $SettingsFile -Encoding UTF8 } catch { }
}

$settings = Read-Settings

$SliderNits = [int]$settings.SliderNits
if ($SliderNits -lt 120 -or $SliderNits -gt 480) { $SliderNits = $DefaultSliderNits }
$SliderPct  = [int][math]::Round(($SliderNits - 80) / 4)
$MaxNits    = $SliderNits

# язык: ключ запуска важнее файла, файл важнее системы
$pick = if ($Lang -ne 'auto') { $Lang }
        elseif ($settings.Lang -and $settings.Lang -ne 'auto') { $settings.Lang }
        elseif ((Get-Culture).TwoLetterISOLanguageName -eq 'ru') { 'ru' }
        else { 'en' }
$Loc = $Strings[$pick]
if (-not $Loc) { $Loc = $Strings['en'] }

function Get-PresetLabel([string]$Key) {
    switch ($Key) {
        'day'     { return $Loc.Day }
        'evening' { return $Loc.Evening }
        'night'   { return $Loc.Night }
        default   { return $Key }
    }
}

# ------------------------------------------------------------------ applying
function Invoke-Curve([int]$White, [double]$Gamma) {
    New-Lut -SliderNits $SliderNits -WhiteNits $White -Gamma $Gamma -Path $CurrentLut
    & $Dispwin $CurrentLut | Out-Null
    return ($LASTEXITCODE -eq 0)
}

function Clear-Curve {
    & $Dispwin -c | Out-Null
    return ($LASTEXITCODE -eq 0)
}

if ($Apply -and -not $Tray) {
    if ($settings.Enabled) { [void](Invoke-Curve ([int]$settings.White) ([double]$settings.Gamma)) }
    else { [void](Clear-Curve) }
    exit
}

# -------------------------------------------------------------------- window
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

# Один экземпляр на пользователя: приложение стартует при входе и живёт в трее,
# второй запуск должен просто показать уже работающее окно, а не поднять копию.
$mutexName = 'Local\DisplayTuner_' + $env:USERNAME
$script:Mutex = New-Object System.Threading.Mutex($true, $mutexName, [ref]$null)
if (-not $script:Mutex.WaitOne(0)) { exit }

# Процесс запускается скрытым, чтобы не мелькала консоль. Побочный эффект:
# первое окно наследует флаг «скрыто» из startup info и само не показывается.
if (-not ('Win32Show' -as [type])) {
Add-Type -TypeDefinition @"
using System; using System.Runtime.InteropServices;
public class Win32Show {
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
}
"@
}

$appIcon = if (Test-Path $IconFile) { New-Object System.Drawing.Icon $IconFile }
           else { [System.Drawing.SystemIcons]::Application }
# серый значок для игрового режима: состояние должно читаться прямо в трее
$appIconOff = if (Test-Path $IconFileOff) { New-Object System.Drawing.Icon $IconFileOff } else { $appIcon }

$form                 = New-Object System.Windows.Forms.Form
$form.Text            = $Loc.Title
$form.Size            = New-Object System.Drawing.Size(500, 496)
$form.StartPosition   = 'CenterScreen'
$form.FormBorderStyle = 'FixedSingle'
$form.MaximizeBox     = $false
$form.Font            = New-Object System.Drawing.Font('Segoe UI', 9)
$form.Icon            = $appIcon
$form.BackColor       = [System.Drawing.Color]::FromArgb(250, 250, 250)
$form.ShowInTaskbar   = -not $Tray

function New-Label([string]$Text, [int]$X, [int]$Y, [int]$W, [int]$H, [double]$Size, [bool]$Bold, $Color) {
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $Text
    $l.Location = New-Object System.Drawing.Point($X, $Y)
    $l.Size = New-Object System.Drawing.Size($W, $H)
    $style = if ($Bold) { [System.Drawing.FontStyle]::Bold } else { [System.Drawing.FontStyle]::Regular }
    $l.Font = New-Object System.Drawing.Font('Segoe UI', [single]$Size, $style)
    if ($Color) { $l.ForeColor = $Color }
    $form.Controls.Add($l)
    return $l
}

$dim = [System.Drawing.Color]::FromArgb(120, 120, 120)

$lblState = New-Label '' 20 16 450 30 15 $true $null
$lblSliderHint = New-Label '' 20 46 450 18 8 $false $dim

$lblBrightness = New-Label '' 20 82 220 18 9 $false $dim
$lblWhite = New-Label '' 320 82 140 18 9 $true $null
$lblWhite.TextAlign = 'MiddleRight'

$trkWhite = New-Object System.Windows.Forms.TrackBar
$trkWhite.Location = New-Object System.Drawing.Point(18, 102)
$trkWhite.Size = New-Object System.Drawing.Size(444, 45)
$trkWhite.Minimum = $MinNits
$trkWhite.Maximum = $MaxNits
$trkWhite.TickFrequency = 20
$trkWhite.SmallChange = 2
$trkWhite.LargeChange = 10
$trkWhite.Value = [math]::Max($MinNits, [math]::Min($MaxNits, [int]$settings.White))
$form.Controls.Add($trkWhite)

$lblGammaCap = New-Label '' 20 156 220 18 9 $false $dim
$lblGamma = New-Label '' 320 156 140 18 9 $true $null
$lblGamma.TextAlign = 'MiddleRight'

$trkGamma = New-Object System.Windows.Forms.TrackBar
$trkGamma.Location = New-Object System.Drawing.Point(18, 176)
$trkGamma.Size = New-Object System.Drawing.Size(444, 45)
$trkGamma.Minimum = 18      # 1.8, step 0.1
$trkGamma.Maximum = 32      # 3.2
$trkGamma.TickFrequency = 2
$trkGamma.SmallChange = 1
$trkGamma.LargeChange = 2
$trkGamma.Value = [math]::Max(18, [math]::Min(32, [int][math]::Round([double]$settings.Gamma * 10)))
$form.Controls.Add($trkGamma)

$lblProfiles = New-Label '' 20 230 300 18 9 $false $dim

$presetButtons = @{}
$px = 18
foreach ($key in $PresetKeys) {
    $b = New-Object System.Windows.Forms.Button
    $b.Text = [string](Get-PresetLabel $key)
    $b.Size = New-Object System.Drawing.Size(96, 32)
    $b.Location = New-Object System.Drawing.Point($px, 250)
    $b.FlatStyle = 'System'
    $b.Tag = $key
    $form.Controls.Add($b)
    $presetButtons[$key] = $b
    $px += 102
}

$btnSave = New-Object System.Windows.Forms.Button
$btnSave.Text = $Loc.SaveHere
$btnSave.Size = New-Object System.Drawing.Size(110, 32)
$btnSave.Location = New-Object System.Drawing.Point(312, 250)
$btnSave.FlatStyle = 'System'
$form.Controls.Add($btnSave)

$btnToggle = New-Object System.Windows.Forms.Button
$btnToggle.Size = New-Object System.Drawing.Size(200, 38)
$btnToggle.Location = New-Object System.Drawing.Point(18, 298)
$btnToggle.FlatStyle = 'System'
$btnToggle.Font = New-Object System.Drawing.Font('Segoe UI', 10)
$form.Controls.Add($btnToggle)

$btnTests = New-Object System.Windows.Forms.Button
$btnTests.Text = $Loc.Tests
$btnTests.Size = New-Object System.Drawing.Size(96, 38)
$btnTests.Location = New-Object System.Drawing.Point(224, 298)
$btnTests.FlatStyle = 'System'
$form.Controls.Add($btnTests)

$btnHide = New-Object System.Windows.Forms.Button
$btnHide.Text = $Loc.ToTray
$btnHide.Size = New-Object System.Drawing.Size(96, 38)
$btnHide.Location = New-Object System.Drawing.Point(326, 298)
$btnHide.FlatStyle = 'System'
$form.Controls.Add($btnHide)

$lblGameHint = New-Label '' 20 340 450 16 8 $false $dim

$chkAuto = New-Object System.Windows.Forms.CheckBox
$chkAuto.Location = New-Object System.Drawing.Point(18, 364)
$chkAuto.Size = New-Object System.Drawing.Size(280, 24)
$chkAuto.FlatStyle = 'System'
$form.Controls.Add($chkAuto)

$lblStatus = New-Label '' 20 396 450 18 8 $false $dim

$cboLang = New-Object System.Windows.Forms.ComboBox
$cboLang.Location = New-Object System.Drawing.Point(368, 364)
$cboLang.Size = New-Object System.Drawing.Size(94, 22)
$cboLang.DropDownStyle = 'DropDownList'
$cboLang.FlatStyle = 'System'
[void]$cboLang.Items.AddRange(@('Auto', 'English', 'Русский'))
$cboLang.SelectedIndex = switch ($settings.Lang) { 'en' { 1 } 'ru' { 2 } default { 0 } }
$form.Controls.Add($cboLang)

$testMenu = New-Object System.Windows.Forms.ContextMenuStrip
foreach ($entry in @(
    @{ Label = $Loc.TestShadow; File = 'gray-test.html'  },
    @{ Label = $Loc.TestBand;   File = 'band-test.html'  },
    @{ Label = $Loc.TestColor;  File = 'color-test.html' },
    @{ Label = $Loc.TestClip;   File = 'clip-test.html'  })) {
    $item = $testMenu.Items.Add([string]$entry.Label)
    $item.Tag = $entry.File
    $item.Add_Click({ Start-Process (Join-Path $Root $this.Tag) })
}
[void]$testMenu.Items.Add('-')
$itCalibrate = $testMenu.Items.Add([string]$Loc.Calibrate)
$itCalibrate.Add_Click({
    Start-Process -FilePath 'powershell.exe' -ArgumentList @(
        '-ExecutionPolicy','Bypass','-WindowStyle','Hidden','-File',
        ('"' + (Join-Path $Root 'Calibrate.ps1') + '"')) -Wait
    # мастер перезаписал настройки - перечитываем и перезапускаемся
    [System.Windows.Forms.MessageBox]::Show($Loc.Restart, $Loc.Title) | Out-Null
    Start-Process -FilePath ([System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName)
    Stop-App
})

$trayIcon = New-Object System.Windows.Forms.NotifyIcon
$trayIcon.Icon = $appIcon
$trayIcon.Text = $Loc.Title
$trayIcon.Visible = $true
$trayMenu = New-Object System.Windows.Forms.ContextMenuStrip
$trayIcon.ContextMenuStrip = $trayMenu

# ------------------------------------------------------------------ behaviour
$script:White    = [int]$trkWhite.Value
$script:Gamma    = [double]$trkGamma.Value / 10
$script:Enabled  = [bool]$settings.Enabled
$script:Quitting = $false
$itToggle = $null

function Save-Now {
    $settings.White   = $script:White
    $settings.Gamma   = $script:Gamma
    $settings.Enabled = $script:Enabled
    Write-Settings $settings
}

function Update-Labels {
    $gs = $script:Gamma.ToString('0.0', [System.Globalization.CultureInfo]::InvariantCulture)
    $lblWhite.Text = $Loc.Nits -f $script:White
    $lblGamma.Text = $gs
    if ($script:Enabled) {
        $lblState.Text  = $Loc.StateOn -f $script:White, $gs
        $btnToggle.Text = $Loc.GameMode
        $trayIcon.Text  = $Loc.TrayOn -f $script:White, $gs
        $trayIcon.Icon  = $appIcon
        if ($itToggle) { $itToggle.Text = $Loc.GameToggle }
    } else {
        $lblState.Text  = $Loc.StateOff
        $btnToggle.Text = $Loc.RestoreCurve
        $trayIcon.Text  = $Loc.TrayOff
        $trayIcon.Icon  = $appIconOff
        if ($itToggle) { $itToggle.Text = $Loc.RestoreCurve }
    }
}

function Invoke-Now {
    $gs = $script:Gamma.ToString('0.0', [System.Globalization.CultureInfo]::InvariantCulture)
    try {
        if ($script:Enabled) {
            [void](Invoke-Curve $script:White $script:Gamma)
            $lblStatus.Text = $Loc.Applied -f $script:White, $gs
        } else {
            [void](Clear-Curve)
            $lblStatus.Text = $Loc.Cleared
        }
    } catch {
        $lblStatus.Text = $Loc.Error -f $_.Exception.Message
    }
    Update-Labels
    Save-Now
}

function Set-Preset([string]$Key) {
    $p = $settings.Presets[$Key]
    if ($null -eq $p) { return }
    $script:White = [int]$p.White
    $script:Gamma = [double]$p.Gamma
    $script:Enabled = $true
    $trkWhite.Value = $script:White
    $trkGamma.Value = [int][math]::Round($script:Gamma * 10)
    Invoke-Now
    $lblStatus.Text = $Loc.ProfileSet -f (Get-PresetLabel $Key)
}

function Test-Autostart { return (Test-Path $StartupLnk) }

function Set-Autostart([bool]$On) {
    try {
        if ($On) {
            $exe = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
            $ws = New-Object -ComObject WScript.Shell
            $lnk = $ws.CreateShortcut($StartupLnk)
            $lnk.TargetPath = $exe
            $lnk.Arguments = '-Tray'
            $lnk.WorkingDirectory = $Root
            $lnk.Description = 'Display Tuner'
            $lnk.Save()
        } elseif (Test-Path $StartupLnk) {
            Remove-Item $StartupLnk -Force
        }
        return $true
    } catch { return $false }
}

function Show-MainWindow {
    $form.Show()
    $form.WindowState = 'Normal'
    [void][Win32Show]::ShowWindow($form.Handle, 5)
    [void][Win32Show]::SetForegroundWindow($form.Handle)
    $form.Activate()
}

function Stop-App {
    $script:Quitting = $true
    $trayIcon.Visible = $false
    [System.Windows.Forms.Application]::Exit()
}

# генерация кривой ~120 мс: за живым перетаскиванием не успеет, ждём паузы
$debounce = New-Object System.Windows.Forms.Timer
$debounce.Interval = 150
$debounce.Add_Tick({ $debounce.Stop(); Invoke-Now })

function Request-Apply {
    $debounce.Stop()
    Update-Labels
    $lblStatus.Text = $Loc.Applying
    $debounce.Start()
}

$trkWhite.Add_ValueChanged({ $script:White = [int]$trkWhite.Value; Request-Apply })
$trkGamma.Add_ValueChanged({ $script:Gamma = [double]$trkGamma.Value / 10; Request-Apply })

$btnToggle.Add_Click({ $script:Enabled = -not $script:Enabled; Invoke-Now })
$btnTests.Add_Click({ $testMenu.Show($btnTests, 0, $btnTests.Height) })
$btnHide.Add_Click({ $form.Hide() })

foreach ($key in $PresetKeys) {
    $presetButtons[$key].Add_Click({ Set-Preset $this.Tag })
}

$btnSave.Add_Click({
    $menu = New-Object System.Windows.Forms.ContextMenuStrip
    foreach ($key in $PresetKeys) {
        $it = $menu.Items.Add([string](Get-PresetLabel $key))
        $it.Tag = $key
        $it.Add_Click({
            $settings.Presets[$this.Tag].White = $script:White
            $settings.Presets[$this.Tag].Gamma = $script:Gamma
            Write-Settings $settings
            $lblStatus.Text = $Loc.ProfileSaved -f (Get-PresetLabel $this.Tag)
        })
    }
    $menu.Show($btnSave, 0, $btnSave.Height)
})

$itShow = $trayMenu.Items.Add([string]$Loc.ShowWindow)
$itShow.Font = New-Object System.Drawing.Font($trayMenu.Font, [System.Drawing.FontStyle]::Bold)
$itShow.Add_Click({ Show-MainWindow })
[void]$trayMenu.Items.Add('-')
$trayPresetItems = @{}
foreach ($key in $PresetKeys) {
    $it = $trayMenu.Items.Add([string](Get-PresetLabel $key))
    $it.Tag = $key
    $it.Add_Click({ Set-Preset $this.Tag })
    $trayPresetItems[$key] = $it
}
[void]$trayMenu.Items.Add('-')
$itToggle = $trayMenu.Items.Add([string]$Loc.GameToggle)
$itToggle.Add_Click({ $script:Enabled = -not $script:Enabled; Invoke-Now })
[void]$trayMenu.Items.Add('-')
$itQuit = $trayMenu.Items.Add([string]$Loc.Quit)
$itQuit.Add_Click({ Stop-App })

$trayIcon.Add_DoubleClick({ Show-MainWindow })

# сворачивание и закрытие прячут окно; приложение живёт в трее
$form.Add_Resize({ if ($form.WindowState -eq 'Minimized') { $form.Hide() } })
$form.Add_FormClosing({
    param($sender, $e)
    if (-not $script:Quitting) { $e.Cancel = $true; $form.Hide() }
})

# Ширина надписи зависит от языка, поэтому кнопки расставляются по замеру
# текста, а не по заранее вбитым координатам. Иначе русские подписи налезают
# друг на друга.
function Set-ButtonRow {
    param([array]$Buttons, [int]$StartX, [int]$Y, [int]$Height, [int]$Gap, [int]$MinWidth, [int]$RightEdge)
    $pad = 22
    $widths = @()
    foreach ($b in $Buttons) {
        $w = [System.Windows.Forms.TextRenderer]::MeasureText($b.Text, $b.Font).Width + $pad
        if ($w -lt $MinWidth) { $w = $MinWidth }
        $widths += $w
    }
    $total = ($widths | Measure-Object -Sum).Sum + $Gap * ($Buttons.Count - 1)
    $avail = $RightEdge - $StartX
    if ($total -gt $avail -and $total -gt 0) {
        # не влезает - ужимаем пропорционально, чтобы не выехать за окно
        $k = $avail / $total
        for ($i = 0; $i -lt $widths.Count; $i++) { $widths[$i] = [int][math]::Floor($widths[$i] * $k) }
    }
    $x = $StartX
    for ($i = 0; $i -lt $Buttons.Count; $i++) {
        $Buttons[$i].Location = New-Object System.Drawing.Point([int]$x, [int]$Y)
        $Buttons[$i].Size = New-Object System.Drawing.Size([int]$widths[$i], [int]$Height)
        $x += $widths[$i] + $Gap
    }
}

function Update-Language {
    $form.Text          = $Loc.Title
    $lblSliderHint.Text = $Loc.SliderHint -f $SliderPct
    $lblBrightness.Text = $Loc.Brightness
    $lblGammaCap.Text   = $Loc.Gamma
    $lblProfiles.Text   = $Loc.Profiles
    $lblGameHint.Text   = $Loc.GameHint
    $btnSave.Text       = $Loc.SaveHere
    $btnTests.Text      = $Loc.Tests
    $btnHide.Text       = $Loc.ToTray
    $trayIcon.Text      = $Loc.Title

    foreach ($key in $PresetKeys) {
        $presetButtons[$key].Text = [string](Get-PresetLabel $key)
        if ($trayPresetItems[$key]) { $trayPresetItems[$key].Text = [string](Get-PresetLabel $key) }
    }

    $testLabels = @($Loc.TestShadow, $Loc.TestBand, $Loc.TestColor, $Loc.TestClip)
    for ($i = 0; $i -lt $testMenu.Items.Count -and $i -lt $testLabels.Count; $i++) {
        $testMenu.Items[$i].Text = [string]$testLabels[$i]
    }

    $chkAuto.Text = $Loc.Autostart
    if ($itCalibrate) { $itCalibrate.Text = $Loc.Calibrate }
    $itShow.Text = $Loc.ShowWindow
    $itQuit.Text = $Loc.Quit

    Update-Labels   # состояние, кнопка игрового режима, подсказка в трее

    # раскладка зависит от длины подписей, поэтому пересчитывается после перевода
    $row1 = @()
    foreach ($key in $PresetKeys) { $row1 += $presetButtons[$key] }
    $row1 += $btnSave
    Set-ButtonRow -Buttons $row1 -StartX 18 -Y 250 -Height 32 -Gap 8 -MinWidth 80 -RightEdge 462

    Set-ButtonRow -Buttons @($btnToggle, $btnTests, $btnHide) -StartX 18 -Y 298 -Height 38 -Gap 8 -MinWidth 90 -RightEdge 462
}

$chkAuto.Add_CheckedChanged({
    if (Set-Autostart $chkAuto.Checked) {
        $lblStatus.Text = if ($chkAuto.Checked) { $Loc.StartupOn } else { $Loc.StartupOff }
    } else {
        $lblStatus.Text = $Loc.Error -f 'autostart'
        $chkAuto.Checked = (Test-Autostart)
    }
})

$cboLang.Add_SelectedIndexChanged({
    $code = switch ($cboLang.SelectedIndex) { 1 { 'en' } 2 { 'ru' } default { 'auto' } }
    $settings.Lang = $code
    # auto - снова спросить систему
    $script:pick = if ($code -ne 'auto') { $code }
                   elseif ((Get-Culture).TwoLetterISOLanguageName -eq 'ru') { 'ru' }
                   else { 'en' }
    $script:Loc = $Strings[$script:pick]
    Update-Language
    Write-Settings $settings
    $lblStatus.Text = $Loc.Ready
})

Update-Language
$lblStatus.Text = $Loc.Ready

$chkAuto.Checked = Test-Autostart

if ($Tray) {
    # Дисплей на логоне инициализируется не мгновенно: если применить кривую
    # сразу, гамма-рамп потом затрётся. Раньше эту задержку давал планировщик,
    # теперь она своя - значок в трее при этом появляется сразу.
    $boot = New-Object System.Windows.Forms.Timer
    $boot.Interval = 15000
    $boot.Add_Tick({ $boot.Stop(); Invoke-Now })
    $boot.Start()
} else {
    # окно поднимаем из таймера, уже внутри цикла сообщений
    $boot = New-Object System.Windows.Forms.Timer
    $boot.Interval = 60
    $boot.Add_Tick({ $boot.Stop(); Show-MainWindow })
    $boot.Start()
}

$ctx = New-Object System.Windows.Forms.ApplicationContext
[System.Windows.Forms.Application]::Run($ctx)

$trayIcon.Dispose()
$form.Dispose()
