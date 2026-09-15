<#
    Gamma-GUI.ps1 - подбор яркости и гаммы кнопками.
    Запускать через Gamma-GUI.bat (он прячет консоль).

    Слайдер «Яркость контента SDR» в Windows ставится ОДИН РАЗ на 43% и больше
    не трогается. Яркость дальше задаётся кривой: она отображает SDR-белый
    с 252 нит на нужное значение. Программного доступа к слайдеру у Windows нет,
    поэтому единственная ручная настройка вынесена в заголовок окна.
#>

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$Root = Split-Path -Parent $MyInvocation.MyCommand.Definition
. (Join-Path $Root 'LutGen.ps1')

$Dispwin = Join-Path $Root 'dispwin.exe'

# на сколько выставлен слайдер Windows; выше потолка панели смысла нет
$SliderNits = 252

$Whites = @(100, 120, 140, 160, 180, 220, 252)
$Gammas = @(
    @{ V = 2.0; Note = 'тени максимально открыты' }
    @{ V = 2.2; Note = 'нейтрально' }
    @{ V = 2.4; Note = 'чуть контрастнее' }
    @{ V = 2.6; Note = 'рабочая' }
    @{ V = 2.8; Note = 'тени начинают закрываться' }
    @{ V = 3.0; Note = 'предел, тени сыпятся' }
)

$script:CurW = 140
$script:CurG = 2.6

# ------------------------------------------------------------------ гамма-рамп
Add-Type -TypeDefinition @"
using System; using System.Runtime.InteropServices;
public class RampRead {
  [DllImport("gdi32.dll")] public static extern bool GetDeviceGammaRamp(IntPtr hdc, ref RAMP r);
  [DllImport("user32.dll")] public static extern IntPtr GetDC(IntPtr h);
  [DllImport("user32.dll")] public static extern int ReleaseDC(IntPtr h, IntPtr hdc);
  [StructLayout(LayoutKind.Sequential)] public struct RAMP { [MarshalAs(UnmanagedType.ByValArray, SizeConst=768)] public UInt16[] v; }
  public static UInt16[] Read() { RAMP r = new RAMP(); r.v = new UInt16[768];
    IntPtr dc = GetDC(IntPtr.Zero); bool ok = GetDeviceGammaRamp(dc, ref r); ReleaseDC(IntPtr.Zero, dc);
    return ok ? r.v : null; }
}
"@

function Test-RampLinear {
    $v = [RampRead]::Read()
    if ($null -eq $v) { return $false }
    $d = 0.0
    for ($i = 0; $i -lt 256; $i++) { $d += [math]::Abs($v[$i] - $i * 257) }
    return ($d -lt 256)
}

# ----------------------------------------------------------------------- окно
$form                 = New-Object System.Windows.Forms.Form
$form.Text            = 'Яркость и гамма — Dell U4025QW'
$form.Size            = New-Object System.Drawing.Size(540, 390)
$form.StartPosition   = 'CenterScreen'
$form.FormBorderStyle = 'FixedSingle'
$form.MaximizeBox     = $false
$form.Font            = New-Object System.Drawing.Font('Segoe UI', 9)
$form.TopMost         = $true

$banner           = New-Object System.Windows.Forms.Label
$banner.Text      = 'Слайдер «Яркость контента SDR» в Windows должен стоять на 43% и не меняться'
$banner.Location  = New-Object System.Drawing.Point(16, 12)
$banner.Size      = New-Object System.Drawing.Size(500, 18)
$banner.ForeColor = [System.Drawing.Color]::FromArgb(180, 90, 0)
$form.Controls.Add($banner)

$status          = New-Object System.Windows.Forms.Label
$status.Location = New-Object System.Drawing.Point(16, 38)
$status.Size     = New-Object System.Drawing.Size(500, 24)
$status.Font     = New-Object System.Drawing.Font('Segoe UI', 12, [System.Drawing.FontStyle]::Bold)
$form.Controls.Add($status)

$note            = New-Object System.Windows.Forms.Label
$note.Location   = New-Object System.Drawing.Point(16, 62)
$note.Size       = New-Object System.Drawing.Size(500, 20)
$note.ForeColor  = [System.Drawing.Color]::DimGray
$form.Controls.Add($note)

function Add-Caption([string]$Text, [int]$Y) {
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $Text
    $l.Location = New-Object System.Drawing.Point(16, $Y)
    $l.Size = New-Object System.Drawing.Size(500, 16)
    $l.ForeColor = [System.Drawing.Color]::DimGray
    $form.Controls.Add($l)
}

$wButtons = @{}
$gButtons = @{}

function Update-Highlight {
    foreach ($k in $wButtons.Keys) {
        $b = $wButtons[$k]
        if ([int]$k -eq $script:CurW) {
            $b.BackColor = [System.Drawing.Color]::FromArgb(210, 232, 255)
            $b.Font = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
        } else {
            $b.BackColor = [System.Drawing.SystemColors]::Control
            $b.Font = New-Object System.Drawing.Font('Segoe UI', 10)
        }
    }
    foreach ($k in $gButtons.Keys) {
        $b = $gButtons[$k]
        if ([double]$k -eq $script:CurG) {
            $b.BackColor = [System.Drawing.Color]::FromArgb(210, 232, 255)
            $b.Font = New-Object System.Drawing.Font('Segoe UI', 11, [System.Drawing.FontStyle]::Bold)
        } else {
            $b.BackColor = [System.Drawing.SystemColors]::Control
            $b.Font = New-Object System.Drawing.Font('Segoe UI', 11)
        }
    }
    $status.Text = "белый $($script:CurW) нит  ·  гамма $($script:CurG)"
    $g = $Gammas | Where-Object { $_.V -eq $script:CurG } | Select-Object -First 1
    $note.Text = if ($g) { $g.Note } else { '' }
}

function Invoke-Current {
    $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
    try {
        $path = Get-LutPath -Root $Root -SliderNits $SliderNits -WhiteNits $script:CurW -Gamma $script:CurG
        Start-Process -FilePath $Dispwin -ArgumentList "`"$path`"" -NoNewWindow -Wait
    } catch {
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Ошибка') | Out-Null
    } finally {
        $form.Cursor = [System.Windows.Forms.Cursors]::Default
    }
    Update-Highlight
}

# --- яркость ---
Add-Caption 'Яркость белого, нит' 94
$x0 = 16; $y = 114; $w = 66; $h = 44; $gap = 6
for ($i = 0; $i -lt $Whites.Count; $i++) {
    $b = New-Object System.Windows.Forms.Button
    $b.Text = [string]$Whites[$i]
    $b.Size = New-Object System.Drawing.Size($w, $h)
    $b.Location = New-Object System.Drawing.Point(($x0 + $i * ($w + $gap)), $y)
    $b.Font = New-Object System.Drawing.Font('Segoe UI', 10)
    $b.FlatStyle = 'System'
    $b.Tag = $Whites[$i]
    $b.Add_Click({ $script:CurW = [int]$this.Tag; Invoke-Current })
    $form.Controls.Add($b)
    $wButtons["$($Whites[$i])"] = $b
}

# --- гамма ---
Add-Caption 'Гамма — контраст и глубина' 174
$y2 = 194; $w2 = 78
for ($i = 0; $i -lt $Gammas.Count; $i++) {
    $G = $Gammas[$i].V
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $G.ToString('0.0')
    $b.Size = New-Object System.Drawing.Size($w2, 44)
    $b.Location = New-Object System.Drawing.Point(($x0 + $i * ($w2 + $gap)), $y2)
    $b.Font = New-Object System.Drawing.Font('Segoe UI', 11)
    $b.FlatStyle = 'System'
    $b.Tag = $G
    $b.Add_Click({ $script:CurG = [double]$this.Tag; Invoke-Current })
    $form.Controls.Add($b)
    $gButtons["$G"] = $b
}

# --- нижний ряд ---
$y3 = 256
$mk = {
    param($Text, $Idx, $OnClick)
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $Text
    $b.Size = New-Object System.Drawing.Size(112, 32)
    $b.Location = New-Object System.Drawing.Point(($x0 + $Idx * 120), $y3)
    $b.FlatStyle = 'System'
    $b.Add_Click($OnClick)
    $form.Controls.Add($b)
}

& $mk 'Применить' 0 { Invoke-Current }
& $mk 'Линейная' 1 {
    Start-Process -FilePath $Dispwin -ArgumentList '-c' -NoNewWindow -Wait
    $status.Text = 'коррекция снята'
    $note.Text = 'режим для нативных HDR-игр'
    foreach ($k in $wButtons.Keys) { $wButtons[$k].BackColor = [System.Drawing.SystemColors]::Control }
    foreach ($k in $gButtons.Keys) { $gButtons[$k].BackColor = [System.Drawing.SystemColors]::Control }
}
& $mk 'Тени' 2 { Start-Process (Join-Path $Root 'gray-test.html') }
& $mk 'Цвет' 3 { Start-Process (Join-Path $Root 'color-test.html') }

$hint = New-Object System.Windows.Forms.Label
$hint.Text = "Яркость меняется кривой, в Параметры Windows ходить не нужно.`nЕсли слайдер всё же сдвинули, гамма-рамп очистится: нажми «Применить»."
$hint.Location = New-Object System.Drawing.Point(16, ($y3 + 44))
$hint.Size = New-Object System.Drawing.Size(500, 40)
$hint.ForeColor = [System.Drawing.Color]::DimGray
$form.Controls.Add($hint)

Update-Highlight
if (Test-RampLinear) { $status.Text = 'коррекция снята — выбери яркость'; $note.Text = '' }

[void]$form.ShowDialog()
