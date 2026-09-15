<#
    Setup.ps1 - развернуть калибровку Dell U4025QW на новой машине.

        .\Setup.ps1                      # настроить с рабочими параметрами
        .\Setup.ps1 -Verify              # только проверить текущее состояние
        .\Setup.ps1 -WhiteNits 180       # другая яркость
        .\Setup.ps1 -Gamma 2.4           # другая гамма
        .\Setup.ps1 -RegisterAutoStart   # + автозагрузка (нужен администратор)

    Нужен только dispwin.exe рядом со скриптом. Кривые генерируются на месте
    (LutGen.ps1), Python не требуется.

    Два уровня белого:
      SliderNits - куда Windows кладёт белый SDR. Ставится слайдером «Яркость
                   контента SDR» ОДИН раз и не трогается. 43% = 252 нита, это
                   потолок панели: выше поднимать бессмысленно, а точность
                   кривой падает.
      WhiteNits  - фактическая яркость. Живёт в кривой, меняется программно.
#>

[CmdletBinding()]
param(
    [double]$SliderNits = 252,
    [double]$WhiteNits = 140,
    [ValidateRange(1.6, 4.0)][double]$Gamma = 2.6,
    [int]$Vibrance = 55,
    [int]$Contrast = 75,
    [switch]$Verify,
    [switch]$RegisterAutoStart
)

$ErrorActionPreference = 'Stop'
$Root    = Split-Path -Parent $MyInvocation.MyCommand.Definition
$Dispwin = Join-Path $Root 'dispwin.exe'

. (Join-Path $Root 'LutGen.ps1')

function Head([string]$t) { Write-Host ''; Write-Host $t -ForegroundColor Cyan; Write-Host '' }
function Step([string]$t) { Write-Host "  $t" -ForegroundColor White }
function Dim([string]$t)  { Write-Host "  $t" -ForegroundColor DarkGray }
function Ok([string]$t)   { Write-Host "  + $t" -ForegroundColor Green }
function Bad([string]$t)  { Write-Host "  ! $t" -ForegroundColor Yellow }

# ------------------------------------------------------------------ гамма-рамп
if (-not ('SetupRamp' -as [type])) {
Add-Type -TypeDefinition @"
using System; using System.Runtime.InteropServices;
public class SetupRamp {
  [DllImport("gdi32.dll")] public static extern bool GetDeviceGammaRamp(IntPtr hdc, ref RAMP r);
  [DllImport("user32.dll")] public static extern IntPtr GetDC(IntPtr h);
  [DllImport("user32.dll")] public static extern int ReleaseDC(IntPtr h, IntPtr hdc);
  [StructLayout(LayoutKind.Sequential)] public struct RAMP { [MarshalAs(UnmanagedType.ByValArray, SizeConst=768)] public UInt16[] v; }
  public static UInt16[] Read() { RAMP r = new RAMP(); r.v = new UInt16[768];
    IntPtr dc = GetDC(IntPtr.Zero); bool ok = GetDeviceGammaRamp(dc, ref r); ReleaseDC(IntPtr.Zero, dc);
    return ok ? r.v : null; }
}
"@
}

function Get-RampDeviation {
    $v = [SetupRamp]::Read()
    if ($null -eq $v) { return -1 }
    $d = 0.0
    for ($i = 0; $i -lt 256; $i++) { $d += [math]::Abs($v[$i] - $i * 257) }
    return $d
}

# ---------------------------------------------------------------------- DDC/CI
if (-not ('SetupVcp' -as [type])) {
Add-Type -TypeDefinition @"
using System; using System.Collections.Generic; using System.Runtime.InteropServices; using System.Text;
public class SetupVcp {
  [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
  public struct PM { public IntPtr h; [MarshalAs(UnmanagedType.ByValTStr, SizeConst=128)] public string d; }
  delegate bool EP(IntPtr h, IntPtr a, IntPtr b, IntPtr c);
  [DllImport("user32.dll")] static extern bool EnumDisplayMonitors(IntPtr a, IntPtr b, EP p, IntPtr d);
  [DllImport("dxva2.dll")] static extern bool GetNumberOfPhysicalMonitorsFromHMONITOR(IntPtr h, ref uint n);
  [DllImport("dxva2.dll")] static extern bool GetPhysicalMonitorsFromHMONITOR(IntPtr h, uint n, [Out] PM[] a);
  [DllImport("dxva2.dll")] static extern bool DestroyPhysicalMonitors(uint n, [In] PM[] a);
  [DllImport("dxva2.dll")] static extern bool GetVCPFeatureAndVCPFeatureReply(IntPtr h, byte c, out uint t, out uint cur, out uint max);
  [DllImport("dxva2.dll")] static extern bool SetVCPFeature(IntPtr h, byte c, uint v);
  [DllImport("dxva2.dll")] static extern bool GetCapabilitiesStringLength(IntPtr h, out uint len);
  [DllImport("dxva2.dll")] static extern bool CapabilitiesRequestAndCapabilitiesReply(IntPtr h, StringBuilder s, uint len);

  static PM[] arr;
  public static IntPtr H = IntPtr.Zero;
  public static string Desc = "";

  public static bool Open() {
    var hs = new List<IntPtr>();
    EnumDisplayMonitors(IntPtr.Zero, IntPtr.Zero,
      delegate(IntPtr m, IntPtr a, IntPtr b, IntPtr c) { hs.Add(m); return true; }, IntPtr.Zero);
    foreach (var h in hs) {
      uint n = 0;
      if (!GetNumberOfPhysicalMonitorsFromHMONITOR(h, ref n) || n == 0) continue;
      arr = new PM[n];
      if (!GetPhysicalMonitorsFromHMONITOR(h, n, arr)) continue;
      H = arr[0].h; Desc = arr[0].d; return true;
    }
    return false;
  }
  public static void Close() { if (arr != null) { DestroyPhysicalMonitors(1, arr); arr = null; H = IntPtr.Zero; } }
  public static int Read(byte c) {
    uint t, cur, max;
    if (!GetVCPFeatureAndVCPFeatureReply(H, c, out t, out cur, out max)) return -1;
    return (int)cur;
  }
  public static bool Write(byte c, uint v) { return SetVCPFeature(H, c, v); }
  public static string Caps() {
    uint len = 0;
    if (!GetCapabilitiesStringLength(H, out len) || len == 0) return "";
    var sb = new StringBuilder((int)len);
    if (!CapabilitiesRequestAndCapabilitiesReply(H, sb, len)) return "";
    return sb.ToString();
  }
}
"@
}

# DDC/CI - медленный I2C-канал, транзакции подряд срываются
function Read-Ddc([byte]$Code, [int]$Tries = 4) {
    for ($i = 0; $i -lt $Tries; $i++) {
        $r = [SetupVcp]::Read($Code)
        if ($r -ge 0) { return $r }
        Start-Sleep -Milliseconds 150
    }
    return -1
}

function Write-Ddc([byte]$Code, [int]$Value, [int]$Tries = 4) {
    for ($i = 0; $i -lt $Tries; $i++) {
        if ([SetupVcp]::Write($Code, [uint32]$Value)) { Start-Sleep -Milliseconds 120; return $true }
        Start-Sleep -Milliseconds 150
    }
    return $false
}

# =============================================================================

if ($WhiteNits -gt $SliderNits) { throw "WhiteNits ($WhiteNits) больше SliderNits ($SliderNits)." }

$sliderPct = [math]::Round(($SliderNits - 80) / 4)
$lutName   = Get-LutName ([int]$SliderNits) ([int]$WhiteNits) $Gamma
$lutPath   = Join-Path $Root $lutName

Head 'Калибровка Dell U4025QW'
Write-Host "  яркость $WhiteNits нит  ·  гамма $Gamma  ·  Digital Vibrance $Vibrance%" -ForegroundColor White
Write-Host "  слайдер SDR $sliderPct% ($SliderNits нит) - ставится один раз" -ForegroundColor DarkGray

if (-not (Test-Path $Dispwin)) {
    throw "dispwin.exe не найден в $Root`n" +
          "Скачай ArgyllCMS с https://www.argyllcms.com/downloadwin.html и положи dispwin.exe рядом.`n" +
          "В репозитории его нет: чужая лицензия (AGPL3/GPL2+)."
}

# --- монитор -----------------------------------------------------------------
Head '1. Монитор'
if (-not [SetupVcp]::Open()) {
    Bad 'DDC/CI недоступен. Включи: Menu -> Others -> DDC/CI -> On'
    Dim 'Без него настройки монитора придётся выставлять джойстиком.'
} else {
    $caps  = [SetupVcp]::Caps()
    $model = if ($caps -match 'model\(([^)]+)\)') { $matches[1] } else { '?' }
    Ok ('найден: ' + [SetupVcp]::Desc + '  (model ' + $model + ')')
    if ($model -ne 'U4025QW' -and $model -ne '?') {
        Bad 'Это не U4025QW. Потолок белого у другой панели свой:'
        Dim 'померь через clip-test.html и задай -SliderNits <нит>.'
    }
    $cur = Read-Ddc 0x12
    if ($cur -lt 0) {
        Bad 'контраст прочитать не удалось'
    } elseif ($cur -eq $Contrast) {
        Ok "контраст уже $Contrast"
    } elseif ($Verify) {
        Bad "контраст $cur, ожидается $Contrast"
        Dim 'в HDR Dell блокирует эту настройку - расхождение ожидаемо'
    } else {
        [void](Write-Ddc 0x12 $Contrast)
        Start-Sleep -Milliseconds 400
        $back = Read-Ddc 0x12
        if ($back -eq $Contrast) {
            Ok "контраст $cur -> $Contrast"
            Dim 'у каждого пресета свой контраст; после смены пресета проверить заново'
        } else {
            Bad "контраст остался $back - в HDR-режиме Dell блокирует эту настройку"
            Dim 'это нормально: значение относится к HDR-пресету и на картинку не влияет'
        }
    }
    [SetupVcp]::Close()
}

# --- кривая ------------------------------------------------------------------
Head '2. Кривая'
if (Test-Path $lutPath) {
    Ok "$lutName уже есть"
} elseif ($Verify) {
    Bad "$lutName отсутствует"
} else {
    New-Lut -SliderNits $SliderNits -WhiteNits $WhiteNits -Gamma $Gamma -Path $lutPath
    Ok "сгенерирована $lutName"
}

# --- настройки приложения ----------------------------------------------------
$tunerSettings = Join-Path $Root 'tuner-settings.json'
if (-not $Verify) {
    $s = if (Test-Path $tunerSettings) {
        try { Get-Content $tunerSettings -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $null }
    } else { $null }
    $presets = if ($s -and $s.Presets) { $s.Presets } else {
        [ordered]@{
            'День'  = [ordered]@{ White = 220; Gamma = 2.2 }
            'Вечер' = [ordered]@{ White = 140; Gamma = 2.6 }
            'Ночь'  = [ordered]@{ White = 100; Gamma = 2.4 }
        }
    }
    $out = [ordered]@{ White = [int]$WhiteNits; Gamma = $Gamma; Enabled = $true; Presets = $presets }
    $out | ConvertTo-Json -Depth 5 | Set-Content -Path $tunerSettings -Encoding UTF8
    Ok "настройки приложения записаны ($WhiteNits нит, гамма $Gamma)"
}

# --- ручные шаги -------------------------------------------------------------
if (-not $Verify) {
    Head '3. Выставь руками'
    Step 'HDR в Windows: включён (Win+Alt+B)'
    Step 'Монитор, Smart HDR: DisplayHDR 600'
    Step 'Монитор, Brightness/Contrast: Auto Brightness = Off, Auto Color Temp. = Off'
    Dim  'в HDR это меню заблокировано - выключи HDR, поменяй, включи обратно'
    Step "Слайдер <Яркость контента SDR>: $sliderPct%   - один раз и больше не трогать"
    Dim  'Параметры -> Система -> Дисплей -> HDR. Яркость дальше меняется кривой.'

    $gpu = (Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue |
            Select-Object -First 1 -ExpandProperty Name)
    if ($gpu) { Dim "видеокарта: $gpu" }
    if ($gpu -match 'NVIDIA') {
        Step "NVIDIA -> Display -> Adjust desktop color settings: Digital vibrance = $Vibrance%"
        Dim  'там же Brightness / Contrast / Gamma НЕ трогать - они затирают кривую'
        Dim  'Color accuracy mode: Accurate, галку reference mode не ставить'
        Step 'NVIDIA -> Change resolution: RGB, Full, 10 bpc'
    } elseif ($gpu -match 'AMD|Radeon') {
        Step "AMD Software -> Display -> Custom Color -> Saturation (~ $Vibrance% эквивалент)"
        Step 'AMD Software -> Display: Pixel Format = RGB 4:4:4 Full RGB'
    } elseif ($gpu -match 'Intel') {
        Step "Intel Graphics Command Center -> Display -> Color -> Saturation (~ $Vibrance%)"
        Step 'Intel Graphics Command Center -> Display -> General: Quantization Range = Full'
    } else {
        Step "Насыщенность в драйвере видеокарты (~ $Vibrance%)"
        Step 'Формат вывода: RGB, полный диапазон (Full), 10 бит'
    }
    Write-Host ''
    Dim  'Слайдер SDR чистит гамма-рамп, поэтому кривая грузится последней.'
    Read-Host '  Готово? Enter'
}

# --- загрузка и проверка -----------------------------------------------------
Head '4. Загрузка'
if (-not $Verify) {
    & $Dispwin $lutPath
    if ($LASTEXITCODE -ne 0) { throw "dispwin вернул код $LASTEXITCODE" }
    Start-Sleep -Milliseconds 300
}
$dev = Get-RampDeviation
if ($dev -lt 0) {
    Bad 'рамп прочитать не удалось'
} elseif ($dev -lt 256) {
    Bad 'рамп ЛИНЕЙНЫЙ - кривая не применилась'
} else {
    Ok ('кривая в рампе (отклонение {0:N0})' -f $dev)
}

# --- автозагрузка ------------------------------------------------------------
Head '5. Автозагрузка'
$taskName = 'Apply sRGB to Gamma LUT'
$existing = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
$taskArg  = if ($existing) { ($existing.Actions | Select-Object -First 1).Arguments } else { $null }
$taskExe   = if ($existing) { ($existing.Actions | Select-Object -First 1).Execute } else { $null }
$taskStale = $existing -and (($taskArg -notlike '*-Tray*') -or ($taskExe -notlike '*DisplayTuner.exe*'))

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$isAdmin  = ([Security.Principal.WindowsPrincipal]$identity).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if ($existing -and -not $taskStale) {
    Ok 'задача зарегистрирована и указывает на текущую кривую'
} elseif ($taskStale -and -not $RegisterAutoStart) {
    Bad "задача запускает не приложение: $taskArg"
    Dim '  Setup.ps1 -RegisterAutoStart   (от администратора) - перепишет'
} elseif (-not $existing -and -not $RegisterAutoStart) {
    Dim 'не зарегистрирована. Чтобы кривая грузилась при входе:'
    Dim '  Setup.ps1 -RegisterAutoStart   (от администратора)'
} elseif (-not $isAdmin) {
    Bad 'для регистрации задачи нужен запуск от администратора'
} else {
    if ($existing) { Unregister-ScheduledTask -TaskName $taskName -Confirm:$false }
    # задача запускает приложение: оно применит то, что сохранено в tuner-settings.json
    $tunerExe = Join-Path $Root 'DisplayTuner.exe'
    if (Test-Path $tunerExe) {
        $action = New-ScheduledTaskAction -Execute $tunerExe -Argument '-Tray' -WorkingDirectory $Root
    } else {
        # exe не собран - запускаем скрипт напрямую
        $tuner = Join-Path $Root 'Display-Tuner.ps1'
        $psArgs = '-ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $tuner + '" -Tray'
        $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $psArgs -WorkingDirectory $Root
    }
    $trigger = New-ScheduledTaskTrigger -AtLogOn
    # дисплей на логоне инициализируется не мгновенно
    $trigger.Delay = 'PT20S'
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
    Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Settings $settings | Out-Null
    Ok 'задача зарегистрирована (задержка 20 с после входа)'
}

Head 'Дальше'
Dim 'DisplayTuner.exe   - приложение: ползунки, профили, трей'
Dim 'Build-Exe.ps1      - пересобрать exe, New-Icon.ps1 - перерисовать значок'
Dim 'Gamma-GUI.bat      - старое окно с кнопками'
Dim 'gray-test.html     - тени: должны различаться примерно с кода 5'
Dim 'band-test.html     - полосение: узкие диапазоны кодов во всю ширину'
Dim 'color-test.html    - не клипается ли цвет'
Dim 'clip-test.html     - потолок белого, если панель другая'
Dim 'Monitor-VCP.ps1    - настройки монитора по DDC/CI'
Write-Host ''
