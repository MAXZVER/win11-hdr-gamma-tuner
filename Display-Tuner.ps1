<#
    Display-Tuner.ps1 - настройка яркости и гаммы Dell U4025QW.

        Display-Tuner.bat            открыть окно
        Display-Tuner.ps1 -Tray      запуск в фоне, значок в трее (автозагрузка)
        Display-Tuner.ps1 -Apply     применить сохранённое и выйти

    Почему не служба: службы работают в нулевой сессии и значок в трее показать
    не могут. Нужен обычный процесс пользователя, стартующий при входе, - это
    и есть режим -Tray.

    Слайдер «Яркость контента SDR» в Windows ставится один раз на 43% и не
    трогается. Яркость задаётся кривой: она отображает SDR-белый с 252 нит
    на выбранное значение. Программного доступа к слайдеру Windows не даёт.

    Кривая пишется в current.cal и перезаписывается, чтобы не плодить файлы.
#>

[CmdletBinding()]
param(
    [switch]$Apply,
    [switch]$Tray
)

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $MyInvocation.MyCommand.Definition

. (Join-Path $Root 'LutGen.ps1')

$Dispwin      = Join-Path $Root 'dispwin.exe'
$CurrentLut   = Join-Path $Root 'current.cal'
$SettingsFile = Join-Path $Root 'tuner-settings.json'
$IconFile     = Join-Path $Root 'Display-Tuner.ico'

$SliderNits = 252     # на сколько выставлен слайдер Windows (43%)
$MinNits    = 80
$MaxNits    = 252

if (-not (Test-Path $Dispwin)) { throw "dispwin.exe не найден: $Root" }

# ------------------------------------------------------------------ настройки
function Get-DefaultSettings {
    return [ordered]@{
        White   = 140
        Gamma   = 2.6
        Enabled = $true
        Presets = [ordered]@{
            'День'  = [ordered]@{ White = 220; Gamma = 2.2 }
            'Вечер' = [ordered]@{ White = 140; Gamma = 2.6 }
            'Ночь'  = [ordered]@{ White = 100; Gamma = 2.4 }
        }
    }
}

function Read-Settings {
    if (-not (Test-Path $SettingsFile)) { return Get-DefaultSettings }
    try {
        $j = Get-Content $SettingsFile -Raw -Encoding UTF8 | ConvertFrom-Json
        $s = Get-DefaultSettings
        if ($null -ne $j.White)   { $s.White   = [int]$j.White }
        if ($null -ne $j.Gamma)   { $s.Gamma   = [double]$j.Gamma }
        if ($null -ne $j.Enabled) { $s.Enabled = [bool]$j.Enabled }
        if ($null -ne $j.Presets) {
            foreach ($name in @($s.Presets.Keys)) {
                $p = $j.Presets.$name
                if ($null -ne $p) {
                    $s.Presets[$name].White = [int]$p.White
                    $s.Presets[$name].Gamma = [double]$p.Gamma
                }
            }
        }
        return $s
    } catch { return Get-DefaultSettings }
}

function Write-Settings($s) {
    try { $s | ConvertTo-Json -Depth 5 | Set-Content -Path $SettingsFile -Encoding UTF8 } catch { }
}

# ------------------------------------------------------------------ применение
function Invoke-Curve([int]$White, [double]$Gamma) {
    New-Lut -SliderNits $SliderNits -WhiteNits $White -Gamma $Gamma -Path $CurrentLut
    & $Dispwin $CurrentLut | Out-Null
    return ($LASTEXITCODE -eq 0)
}

function Clear-Curve {
    & $Dispwin -c | Out-Null
    return ($LASTEXITCODE -eq 0)
}

$settings = Read-Settings

# --- применить и выйти -------------------------------------------------------
if ($Apply -and -not $Tray) {
    if ($settings.Enabled) { [void](Invoke-Curve ([int]$settings.White) ([double]$settings.Gamma)) }
    else { [void](Clear-Curve) }
    exit
}

# Один экземпляр на пользователя: приложение стартует при входе и живёт в трее,
# второй запуск должен просто показать уже работающее окно, а не поднять копию.
$mutexName = 'Local\DisplayTuner_' + $env:USERNAME
$script:Mutex = New-Object System.Threading.Mutex($true, $mutexName, [ref]$null)
if (-not $script:Mutex.WaitOne(0)) {
    # уже запущено - будим то окно и выходим
    Add-Type -TypeDefinition @"
using System; using System.Runtime.InteropServices;
public class Waker {
  [DllImport("user32.dll")] public static extern int RegisterWindowMessage(string s);
  [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, int m, IntPtr w, IntPtr l);
  public static readonly IntPtr HWND_BROADCAST = (IntPtr)0xffff;
}
"@
    $msg = [Waker]::RegisterWindowMessage('DisplayTunerShow')
    [void][Waker]::PostMessage([Waker]::HWND_BROADCAST, $msg, [IntPtr]::Zero, [IntPtr]::Zero)
    exit
}

# ---------------------------------------------------------------------- окно
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

# Процесс запускается с -WindowStyle Hidden, чтобы не мелькала консоль. Побочный
# эффект: первое окно процесса наследует флаг «скрыто» из startup info и само
# не показывается. Поэтому поднимаем его через ShowWindow явно.
if (-not ('Win32Show' -as [type])) {
Add-Type -TypeDefinition @"
using System; using System.Runtime.InteropServices;
public class Win32Show {
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
}
"@
}

$appIcon = if (Test-Path $IconFile) {
    New-Object System.Drawing.Icon $IconFile
} else {
    [System.Drawing.SystemIcons]::Application
}

$form                 = New-Object System.Windows.Forms.Form
$form.Text            = 'Яркость дисплея'
$form.Size            = New-Object System.Drawing.Size(460, 450)
$form.StartPosition   = 'CenterScreen'
$form.FormBorderStyle = 'FixedSingle'
$form.MaximizeBox     = $false
$form.Font            = New-Object System.Drawing.Font('Segoe UI', 9)
$form.Icon            = $appIcon
$form.BackColor       = [System.Drawing.Color]::FromArgb(250, 250, 250)
$form.ShowInTaskbar   = -not $Tray

function New-Label([string]$Text, [int]$X, [int]$Y, [int]$W, [int]$H, [int]$Size, [bool]$Bold, $Color) {
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $Text
    $l.Location = New-Object System.Drawing.Point($X, $Y)
    $l.Size = New-Object System.Drawing.Size($W, $H)
    $style = if ($Bold) { [System.Drawing.FontStyle]::Bold } else { [System.Drawing.FontStyle]::Regular }
    $l.Font = New-Object System.Drawing.Font('Segoe UI', $Size, $style)
    if ($Color) { $l.ForeColor = $Color }
    $form.Controls.Add($l)
    return $l
}

$dim = [System.Drawing.Color]::FromArgb(120, 120, 120)

$lblState = New-Label '' 20 16 400 30 15 $true $null
$lblHint  = New-Label 'слайдер SDR в Windows: 43%, не менять' 20 46 400 18 8 $false $dim

[void](New-Label 'Яркость' 20 82 100 18 9 $false $dim)
$lblWhite = New-Label '' 320 82 100 18 9 $true $null
$lblWhite.TextAlign = 'MiddleRight'

$trkWhite = New-Object System.Windows.Forms.TrackBar
$trkWhite.Location = New-Object System.Drawing.Point(18, 102)
$trkWhite.Size = New-Object System.Drawing.Size(404, 45)
$trkWhite.Minimum = $MinNits
$trkWhite.Maximum = $MaxNits
$trkWhite.TickFrequency = 20
$trkWhite.SmallChange = 2
$trkWhite.LargeChange = 10
$trkWhite.Value = [math]::Max($MinNits, [math]::Min($MaxNits, [int]$settings.White))
$form.Controls.Add($trkWhite)

[void](New-Label 'Гамма' 20 156 100 18 9 $false $dim)
$lblGamma = New-Label '' 320 156 100 18 9 $true $null
$lblGamma.TextAlign = 'MiddleRight'

$trkGamma = New-Object System.Windows.Forms.TrackBar
$trkGamma.Location = New-Object System.Drawing.Point(18, 176)
$trkGamma.Size = New-Object System.Drawing.Size(404, 45)
$trkGamma.Minimum = 18      # 1.8, шаг 0.1
$trkGamma.Maximum = 32      # 3.2
$trkGamma.TickFrequency = 2
$trkGamma.SmallChange = 1
$trkGamma.LargeChange = 2
$trkGamma.Value = [math]::Max(18, [math]::Min(32, [int][math]::Round([double]$settings.Gamma * 10)))
$form.Controls.Add($trkGamma)

[void](New-Label 'Профили' 20 230 200 18 9 $false $dim)

$presetButtons = @{}
$px = 18
foreach ($name in @($settings.Presets.Keys)) {
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $name
    $b.Size = New-Object System.Drawing.Size(96, 32)
    $b.Location = New-Object System.Drawing.Point($px, 250)
    $b.FlatStyle = 'System'
    $b.Tag = $name
    $form.Controls.Add($b)
    $presetButtons[$name] = $b
    $px += 102
}

$btnSave = New-Object System.Windows.Forms.Button
$btnSave.Text = 'Записать сюда'
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
$btnTests.Text = 'Тесты'
$btnTests.Size = New-Object System.Drawing.Size(96, 38)
$btnTests.Location = New-Object System.Drawing.Point(224, 298)
$btnTests.FlatStyle = 'System'
$form.Controls.Add($btnTests)

$btnHide = New-Object System.Windows.Forms.Button
$btnHide.Text = 'В трей'
$btnHide.Size = New-Object System.Drawing.Size(96, 38)
$btnHide.Location = New-Object System.Drawing.Point(326, 298)
$btnHide.FlatStyle = 'System'
$form.Controls.Add($btnHide)

$lblGameHint = New-Label 'Игровой режим снимает кривую: она давит нативный HDR в играх' 20 340 400 16 8 $false $dim
$lblStatus = New-Label '' 20 358 400 18 8 $false $dim

$testMenu = New-Object System.Windows.Forms.ContextMenuStrip
foreach ($t in @(
    @{ T = 'Тени (gray-test)';           F = 'gray-test.html'  },
    @{ T = 'Полосение (band-test)';      F = 'band-test.html'  },
    @{ T = 'Цвет (color-test)';          F = 'color-test.html' },
    @{ T = 'Потолок белого (clip-test)'; F = 'clip-test.html'  })) {
    $item = $testMenu.Items.Add($t.T)
    $item.Tag = $t.F
    $item.Add_Click({ Start-Process (Join-Path $Root $this.Tag) })
}

$trayIcon = New-Object System.Windows.Forms.NotifyIcon
$trayIcon.Icon = $appIcon
$trayIcon.Text = 'Яркость дисплея'
$trayIcon.Visible = $true
$trayMenu = New-Object System.Windows.Forms.ContextMenuStrip
$trayIcon.ContextMenuStrip = $trayMenu

# ------------------------------------------------------------------- поведение
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
    $lblWhite.Text = "$($script:White) нит"
    $lblGamma.Text = $script:Gamma.ToString('0.0')
    if ($script:Enabled) {
        $lblState.Text = "$($script:White) нит  ·  гамма $($script:Gamma.ToString('0.0'))"
        $btnToggle.Text = 'Игровой режим'
        $trayIcon.Text = "Яркость: $($script:White) нит, гамма $($script:Gamma.ToString('0.0'))"
        if ($itToggle) { $itToggle.Text = 'Игровой режим (снять кривую)' }
    } else {
        $lblState.Text = 'игровой режим'
        $btnToggle.Text = 'Вернуть коррекцию'
        $trayIcon.Text = 'Игровой режим: кривая снята'
        if ($itToggle) { $itToggle.Text = 'Вернуть коррекцию' }
    }
}

function Invoke-Now {
    try {
        if ($script:Enabled) {
            [void](Invoke-Curve $script:White $script:Gamma)
            $lblStatus.Text = "применено: $($script:White) нит, гамма $($script:Gamma.ToString('0.0'))"
        } else {
            [void](Clear-Curve)
            $lblStatus.Text = 'кривая снята — нативный HDR в играх не давится'
        }
    } catch {
        $lblStatus.Text = 'ошибка: ' + $_.Exception.Message
    }
    Update-Labels
    Save-Now
}

function Set-Preset([string]$Name) {
    $p = $settings.Presets[$Name]
    if ($null -eq $p) { return }
    $script:White = [int]$p.White
    $script:Gamma = [double]$p.Gamma
    $script:Enabled = $true
    $trkWhite.Value = $script:White
    $trkGamma.Value = [int][math]::Round($script:Gamma * 10)
    Invoke-Now
    $lblStatus.Text = "профиль «$Name»"
}

function Show-MainWindow {
    $form.Show()
    $form.WindowState = 'Normal'
    [void][Win32Show]::ShowWindow($form.Handle, 5)     # SW_SHOW
    [void][Win32Show]::SetForegroundWindow($form.Handle)
    $form.Activate()
}

function Stop-App {
    $script:Quitting = $true
    $trayIcon.Visible = $false
    [System.Windows.Forms.Application]::Exit()
}

# генерация кривой ~120 мс: за живым перетаскиванием не успеет, поэтому ждём паузы
$debounce = New-Object System.Windows.Forms.Timer
$debounce.Interval = 150
$debounce.Add_Tick({ $debounce.Stop(); Invoke-Now })

function Request-Apply {
    $debounce.Stop()
    Update-Labels
    $lblStatus.Text = 'применяю...'
    $debounce.Start()
}

$trkWhite.Add_ValueChanged({ $script:White = [int]$trkWhite.Value; Request-Apply })
$trkGamma.Add_ValueChanged({ $script:Gamma = [double]$trkGamma.Value / 10; Request-Apply })

$btnToggle.Add_Click({ $script:Enabled = -not $script:Enabled; Invoke-Now })
$btnTests.Add_Click({ $testMenu.Show($btnTests, 0, $btnTests.Height) })
$btnHide.Add_Click({ $form.Hide() })

foreach ($name in @($presetButtons.Keys)) {
    $presetButtons[$name].Add_Click({ Set-Preset $this.Tag })
}

$btnSave.Add_Click({
    $menu = New-Object System.Windows.Forms.ContextMenuStrip
    foreach ($name in @($settings.Presets.Keys)) {
        $it = $menu.Items.Add($name)
        $it.Tag = $name
        $it.Add_Click({
            $settings.Presets[$this.Tag].White = $script:White
            $settings.Presets[$this.Tag].Gamma = $script:Gamma
            Write-Settings $settings
            $lblStatus.Text = "профиль «$($this.Tag)» перезаписан"
        })
    }
    $menu.Show($btnSave, 0, $btnSave.Height)
})

# --- меню трея ---
$itShow = $trayMenu.Items.Add('Показать окно')
$itShow.Font = New-Object System.Drawing.Font($trayMenu.Font, [System.Drawing.FontStyle]::Bold)
$itShow.Add_Click({ Show-MainWindow })
[void]$trayMenu.Items.Add('-')
foreach ($name in @($settings.Presets.Keys)) {
    $it = $trayMenu.Items.Add($name)
    $it.Tag = $name
    $it.Add_Click({ Set-Preset $this.Tag })
}
[void]$trayMenu.Items.Add('-')
$itToggle = $trayMenu.Items.Add('Игровой режим (снять кривую)')
$itToggle.Add_Click({ $script:Enabled = -not $script:Enabled; Invoke-Now })
[void]$trayMenu.Items.Add('-')
$itQuit = $trayMenu.Items.Add('Выход')
$itQuit.Add_Click({ Stop-App })

$trayIcon.Add_DoubleClick({ Show-MainWindow })

# сворачивание и закрытие прячут окно; приложение живёт в трее
$form.Add_Resize({ if ($form.WindowState -eq 'Minimized') { $form.Hide() } })
$form.Add_FormClosing({
    param($sender, $e)
    if (-not $script:Quitting) {
        $e.Cancel = $true
        $form.Hide()
    }
})

Update-Labels

# --------------------------------------------------------------------- запуск
$lblStatus.Text = 'готов'

if ($Tray) {
    # фоновый режим: применяем сохранённое, окно не показываем.
    # Run с пустым контекстом крутит цикл сообщений без единой формы -
    # окно потом открывается из меню трея.
    Invoke-Now
    $ctx = New-Object System.Windows.Forms.ApplicationContext
    [System.Windows.Forms.Application]::Run($ctx)
} else {
    # окно поднимаем из таймера, уже внутри цикла сообщений: до его старта
    # ShowWindow не срабатывает из-за флага «скрыто» у процесса
    $boot = New-Object System.Windows.Forms.Timer
    $boot.Interval = 60
    $boot.Add_Tick({ $boot.Stop(); Show-MainWindow })
    $boot.Start()
    $ctx = New-Object System.Windows.Forms.ApplicationContext
    [System.Windows.Forms.Application]::Run($ctx)
}

$trayIcon.Dispose()
$form.Dispose()
