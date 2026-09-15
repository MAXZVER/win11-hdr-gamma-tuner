<#
    Monitor-VCP.ps1 - управление монитором по DDC/CI через штатный Windows API
    (dxva2.dll, Monitor Configuration API). Сторонних программ не требует.

    Требует: OSD -> Menu -> Others -> DDC/CI -> On

        .\Monitor-VCP.ps1 -Dump                  # что монитор вообще отдаёт
        .\Monitor-VCP.ps1 -Get Saturation
        .\Monitor-VCP.ps1 -Set Saturation -Value 55
        .\Monitor-VCP.ps1 -Set Contrast -Value 82
        .\Monitor-VCP.ps1 -Code 0x90 -Value 50   # по сырому VCP-коду

    Preset (0xDC): 0 = Standard, 3 = Movie, 5 = Games
    ColorPreset (0x14): 1 = sRGB, 4 = 5000K, 5 = 6500K, 6 = 7500K,
                        8 = 9300K, 9 = 10000K, 11 = User1, 12 = User2 (Custom Color)

    Saturation и Hue монитор по DDC/CI не отдаёт - проверено по строке
    возможностей, кодов 8A и 90 в ней нет. Только джойстиком.

    Имена и коды - из стандарта MCCS. Какие поддерживаются, показывает -Dump.
#>

[CmdletBinding(DefaultParameterSetName = 'Dump')]
param(
    [Parameter(ParameterSetName = 'Dump')]
    [switch]$Dump,

    [Parameter(ParameterSetName = 'Get', Mandatory = $true)]
    [string]$Get,

    [Parameter(ParameterSetName = 'Set', Mandatory = $true)]
    [string]$Set,

    [Parameter(ParameterSetName = 'Set', Mandatory = $true)]
    [Parameter(ParameterSetName = 'Raw', Mandatory = $true)]
    [int]$Value,

    [Parameter(ParameterSetName = 'Raw', Mandatory = $true)]
    [int]$Code,

    [int]$MonitorIndex = 0
)

$ErrorActionPreference = 'Stop'

if (-not ('MonitorVcp' -as [type])) {
Add-Type -TypeDefinition @"
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

public class MonitorVcp {
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct PHYSICAL_MONITOR {
        public IntPtr hPhysicalMonitor;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)]
        public string szPhysicalMonitorDescription;
    }

    delegate bool MonitorEnumProc(IntPtr hMonitor, IntPtr hdc, IntPtr lprc, IntPtr data);

    [DllImport("user32.dll")]
    static extern bool EnumDisplayMonitors(IntPtr hdc, IntPtr clip, MonitorEnumProc proc, IntPtr data);

    [DllImport("dxva2.dll", SetLastError = true)]
    static extern bool GetNumberOfPhysicalMonitorsFromHMONITOR(IntPtr h, ref uint n);

    [DllImport("dxva2.dll", SetLastError = true)]
    static extern bool GetPhysicalMonitorsFromHMONITOR(IntPtr h, uint n, [Out] PHYSICAL_MONITOR[] a);

    [DllImport("dxva2.dll", SetLastError = true)]
    static extern bool DestroyPhysicalMonitors(uint n, [In] PHYSICAL_MONITOR[] a);

    [DllImport("dxva2.dll", SetLastError = true)]
    static extern bool GetVCPFeatureAndVCPFeatureReply(IntPtr h, byte code, out uint type, out uint current, out uint max);

    [DllImport("dxva2.dll", SetLastError = true)]
    static extern bool SetVCPFeature(IntPtr h, byte code, uint value);

    public static List<PHYSICAL_MONITOR> Open() {
        var result = new List<PHYSICAL_MONITOR>();
        var handles = new List<IntPtr>();
        EnumDisplayMonitors(IntPtr.Zero, IntPtr.Zero,
            delegate(IntPtr hMon, IntPtr hdc, IntPtr rc, IntPtr d) { handles.Add(hMon); return true; },
            IntPtr.Zero);
        foreach (IntPtr h in handles) {
            uint n = 0;
            if (!GetNumberOfPhysicalMonitorsFromHMONITOR(h, ref n) || n == 0) continue;
            var arr = new PHYSICAL_MONITOR[n];
            if (!GetPhysicalMonitorsFromHMONITOR(h, n, arr)) continue;
            result.AddRange(arr);
        }
        return result;
    }

    public static void Close(List<PHYSICAL_MONITOR> mons) {
        foreach (var m in mons) {
            var one = new PHYSICAL_MONITOR[] { m };
            DestroyPhysicalMonitors(1, one);
        }
    }

    // возвращает null, если код не поддерживается
    public static uint[] Read(IntPtr h, byte code) {
        uint type, cur, max;
        if (!GetVCPFeatureAndVCPFeatureReply(h, code, out type, out cur, out max)) return null;
        return new uint[] { cur, max, type };
    }

    public static bool Write(IntPtr h, byte code, uint value) {
        return SetVCPFeature(h, code, value);
    }
}
"@
}

# Имя -> VCP-код по стандарту MCCS
$Names = [ordered]@{
    'Brightness'   = 0x10
    'Contrast'     = 0x12
    'Preset'       = 0xDC
    'ColorPreset'  = 0x14
    'RedGain'      = 0x16
    'GreenGain'    = 0x18
    'BlueGain'     = 0x1A
    'RedBlack'     = 0x6C
    'GreenBlack'   = 0x6E
    'BlueBlack'    = 0x70
    'Sharpness'    = 0x87
    'Saturation'   = 0x8A
    'Hue'          = 0x90
    'InputSource'  = 0x60
    'Volume'       = 0x62
    'PowerMode'    = 0xD6
    'VcpVersion'   = 0xDF
}

# DDC/CI - медленный I2C-канал: транзакции подряд срываются, нужны повторы и пауза.
function Read-Vcp([IntPtr]$Handle, [byte]$VcpCode, [int]$Tries = 4) {
    for ($i = 0; $i -lt $Tries; $i++) {
        $r = [MonitorVcp]::Read($Handle, $VcpCode)
        if ($null -ne $r) { return $r }
        Start-Sleep -Milliseconds 150
    }
    return $null
}

function Write-Vcp([IntPtr]$Handle, [byte]$VcpCode, [uint32]$NewValue, [int]$Tries = 4) {
    for ($i = 0; $i -lt $Tries; $i++) {
        if ([MonitorVcp]::Write($Handle, $VcpCode, $NewValue)) { Start-Sleep -Milliseconds 120; return $true }
        Start-Sleep -Milliseconds 150
    }
    return $false
}

$mons = [MonitorVcp]::Open()
if ($mons.Count -eq 0) { throw "Мониторы через DDC/CI не найдены. Проверь Menu -> Others -> DDC/CI -> On." }
if ($MonitorIndex -ge $mons.Count) { throw "Монитор с индексом $MonitorIndex не найден (всего: $($mons.Count))." }

$mon = $mons[$MonitorIndex]
$h   = $mon.hPhysicalMonitor

try {
    switch ($PSCmdlet.ParameterSetName) {

        'Dump' {
            Write-Host ''
            Write-Host ("Монитор [{0}]: {1}" -f $MonitorIndex, $mon.szPhysicalMonitorDescription) -ForegroundColor Cyan
            if ($mons.Count -gt 1) { Write-Host ("всего мониторов: {0} (переключение через -MonitorIndex)" -f $mons.Count) -ForegroundColor DarkGray }
            Write-Host ''
            Write-Host 'имя            код   текущее   максимум' -ForegroundColor DarkGray
            foreach ($n in $Names.Keys) {
                $r = Read-Vcp $h ([byte]$Names[$n])
                if ($null -eq $r) {
                    Write-Host ("{0,-14} 0x{1:X2}   -" -f $n, $Names[$n]) -ForegroundColor DarkGray
                } else {
                    Write-Host ("{0,-14} 0x{1:X2}   {2,7}   {3,8}" -f $n, $Names[$n], $r[0], $r[1]) -ForegroundColor White
                }
            }
            Write-Host ''
        }

        'Get' {
            if (-not $Names.Contains($Get)) { throw "Неизвестное имя '$Get'. Доступные: $($Names.Keys -join ', ')" }
            $r = Read-Vcp $h ([byte]$Names[$Get])
            if ($null -eq $r) { throw "Монитор не поддерживает $Get (0x$('{0:X2}' -f $Names[$Get]))." }
            "{0} = {1} (макс {2})" -f $Get, $r[0], $r[1]
        }

        'Set' {
            if (-not $Names.Contains($Set)) { throw "Неизвестное имя '$Set'. Доступные: $($Names.Keys -join ', ')" }
            $c = [byte]$Names[$Set]
            $r = Read-Vcp $h $c
            if ($null -eq $r) { throw "Монитор не поддерживает $Set (0x$('{0:X2}' -f $c))." }
            if ($Value -lt 0 -or $Value -gt $r[1]) { throw "Значение вне диапазона 0..$($r[1])." }
            if (-not (Write-Vcp $h $c ([uint32]$Value))) { throw "Не удалось записать $Set." }
            "{0}: {1} -> {2}" -f $Set, $r[0], $Value
        }

        'Raw' {
            $c = [byte]$Code
            $r = Read-Vcp $h $c
            if ($null -eq $r) { throw ("Монитор не поддерживает код 0x{0:X2}." -f $Code) }
            if (-not (Write-Vcp $h $c ([uint32]$Value))) { throw "Не удалось записать." }
            "0x{0:X2}: {1} -> {2}" -f $Code, $r[0], $Value
        }
    }
}
finally {
    [MonitorVcp]::Close($mons)
}
