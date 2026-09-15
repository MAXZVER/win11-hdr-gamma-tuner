<#
    Sensor-Probe.ps1 - поиск датчика освещённости среди вендорских VCP-кодов.

    Стандартного кода для чтения освещённости в MCCS нет, но Dell держит
    свои коды в диапазонах E0-EF и F0-FD. Что за ними - в документации нет,
    выясняется сравнением снимков при разном освещении.

        .\Sensor-Probe.ps1 -Save light      # снимок при обычном свете
        .\Sensor-Probe.ps1 -Save dark       # снимок, накрыв датчик рукой
        .\Sensor-Probe.ps1 -Diff light dark # что изменилось

    Датчик на U4025QW - в нижней рамке по центру, рядом с джойстиком.
#>

[CmdletBinding(DefaultParameterSetName = 'Dump')]
param(
    [Parameter(ParameterSetName = 'Save', Mandatory = $true)][string]$Save,
    [Parameter(ParameterSetName = 'Diff', Mandatory = $true)][string[]]$Diff
)

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $MyInvocation.MyCommand.Definition

# коды из строки возможностей монитора
$Codes = @(
    0x02,0x04,0x05,0x08,0x10,0x12,0x14,0x16,0x18,0x1A,0x52,0x60,0x62,0x66,0x67,0x68,
    0x87,0xAC,0xAE,0xB2,0xB6,0xC6,0xC8,0xC9,0xCA,0xCC,0xD6,0xDC,0xDF,
    0xE0,0xE1,0xE2,0xE4,0xE5,0xE7,0xE8,0xE9,0xEA,0xEE,0xEF,0xF0,0xF1,0xF2,0xFD
)

if (-not ('ProbeVcp' -as [type])) {
Add-Type -TypeDefinition @"
using System; using System.Collections.Generic; using System.Runtime.InteropServices;
public class ProbeVcp {
  [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
  public struct PM { public IntPtr h; [MarshalAs(UnmanagedType.ByValTStr, SizeConst=128)] public string d; }
  delegate bool EP(IntPtr h, IntPtr a, IntPtr b, IntPtr c);
  [DllImport("user32.dll")] static extern bool EnumDisplayMonitors(IntPtr a, IntPtr b, EP p, IntPtr d);
  [DllImport("dxva2.dll")] static extern bool GetNumberOfPhysicalMonitorsFromHMONITOR(IntPtr h, ref uint n);
  [DllImport("dxva2.dll")] static extern bool GetPhysicalMonitorsFromHMONITOR(IntPtr h, uint n, [Out] PM[] a);
  [DllImport("dxva2.dll")] static extern bool DestroyPhysicalMonitors(uint n, [In] PM[] a);
  [DllImport("dxva2.dll")] static extern bool GetVCPFeatureAndVCPFeatureReply(IntPtr h, byte c, out uint t, out uint cur, out uint max);
  static PM[] arr; public static IntPtr H = IntPtr.Zero;
  public static bool Open() {
    var hs = new List<IntPtr>();
    EnumDisplayMonitors(IntPtr.Zero, IntPtr.Zero,
      delegate(IntPtr m, IntPtr a, IntPtr b, IntPtr c) { hs.Add(m); return true; }, IntPtr.Zero);
    foreach (var h in hs) {
      uint n = 0;
      if (!GetNumberOfPhysicalMonitorsFromHMONITOR(h, ref n) || n == 0) continue;
      arr = new PM[n];
      if (!GetPhysicalMonitorsFromHMONITOR(h, n, arr)) continue;
      H = arr[0].h; return true; }
    return false; }
  public static void Close() { if (arr != null) { DestroyPhysicalMonitors(1, arr); arr = null; } }
  public static long Read(byte c) {
    uint t, cur, max;
    if (!GetVCPFeatureAndVCPFeatureReply(H, c, out t, out cur, out max)) return -1;
    return (long)cur; }
}
"@
}

function Read-Vcp([byte]$Code, [int]$Tries = 4) {
    for ($i = 0; $i -lt $Tries; $i++) {
        $r = [ProbeVcp]::Read($Code)
        if ($r -ge 0) { return $r }
        Start-Sleep -Milliseconds 150
    }
    return -1
}

function Get-Snapshot {
    if (-not [ProbeVcp]::Open()) { throw 'DDC/CI недоступен. Menu -> Others -> DDC/CI -> On' }
    try {
        $o = [ordered]@{}
        foreach ($c in $Codes) { $o[('{0:X2}' -f $c)] = Read-Vcp ([byte]$c) }
        return $o
    } finally { [ProbeVcp]::Close() }
}

switch ($PSCmdlet.ParameterSetName) {

    'Save' {
        $snap = Get-Snapshot
        $path = Join-Path $Root ('sensor-' + $Save + '.json')
        ($snap.GetEnumerator() | ForEach-Object { '"{0}": {1}' -f $_.Key, $_.Value }) -join ",`n" |
            ForEach-Object { "{`n$_`n}" } | Set-Content -Path $path -Encoding UTF8
        Write-Host "снимок сохранён: $path" -ForegroundColor Green
        Write-Host ''
        $snap.GetEnumerator() | ForEach-Object { '  0x{0} = {1}' -f $_.Key, $_.Value }
    }

    'Diff' {
        if ($Diff.Count -ne 2) { throw 'нужно два имени снимков: -Diff light dark' }
        $a = Get-Content (Join-Path $Root ('sensor-' + $Diff[0] + '.json')) -Raw | ConvertFrom-Json
        $b = Get-Content (Join-Path $Root ('sensor-' + $Diff[1] + '.json')) -Raw | ConvertFrom-Json
        Write-Host ''
        Write-Host ('различия: {0} -> {1}' -f $Diff[0], $Diff[1]) -ForegroundColor Cyan
        Write-Host ''
        $any = $false
        foreach ($p in $a.PSObject.Properties) {
            $va = $p.Value
            $vb = $b.$($p.Name)
            if ($va -ne $vb) {
                $any = $true
                Write-Host ('  0x{0} : {1,8} -> {2,-8}  (дельта {3})' -f $p.Name, $va, $vb, ($vb - $va)) -ForegroundColor Yellow
            }
        }
        if (-not $any) { Write-Host '  ничего не изменилось - датчик через DDC/CI не читается' -ForegroundColor DarkGray }
        Write-Host ''
    }

    default {
        $snap = Get-Snapshot
        $snap.GetEnumerator() | ForEach-Object { '  0x{0} = {1}' -f $_.Key, $_.Value }
    }
}
