<#
    Build-Exe.ps1 - собирает DisplayTuner.exe.

    Зачем: панель задач и сторонние доки показывают значок ИСПОЛНЯЕМОГО файла,
    а не окна. Пока приложение запускается через powershell.exe, в доке будет
    иконка PowerShell, сколько ни задавай form.Icon.

    Решение: крошечный C#-хост, который поднимает Display-Tuner.ps1 внутри
    своего процесса. Процесс называется DisplayTuner.exe и несёт нашу иконку.

    Компилятор берётся из состава .NET Framework, ставить ничего не нужно.
#>

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $MyInvocation.MyCommand.Definition

$Exe    = Join-Path $Root 'DisplayTuner.exe'
$Icon   = Join-Path $Root 'Display-Tuner.ico'
$Script = Join-Path $Root 'Display-Tuner.ps1'
$Src    = Join-Path $env:TEMP 'DisplayTunerHost.cs'

if (-not (Test-Path $Icon)) {
    Write-Host 'значка нет, рисую...' -ForegroundColor DarkGray
    & (Join-Path $Root 'New-Icon.ps1')
}
if (-not (Test-Path $Icon)) { throw "не удалось создать значок: $Icon" }
if (-not (Test-Path $Script)) { throw "нет скрипта: $Script" }

$csc = Join-Path $env:SystemRoot 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path $csc)) { $csc = Join-Path $env:SystemRoot 'Microsoft.NET\Framework\v4.0.30319\csc.exe' }
if (-not (Test-Path $csc)) { throw 'csc.exe не найден' }

# System.Management.Automation лежит в GAC; путь берём у уже загруженной сборки
$smaPath = [System.Management.Automation.PowerShell].Assembly.Location
if (-not $smaPath -or -not (Test-Path $smaPath)) { throw 'не удалось найти System.Management.Automation.dll' }

$code = @'
using System;
using System.IO;
using System.Reflection;
using System.Management.Automation;
using System.Windows.Forms;

static class Host
{
    [STAThread]
    static int Main(string[] args)
    {
        // скрипт лежит рядом с exe
        string dir = Path.GetDirectoryName(Assembly.GetExecutingAssembly().Location);
        string script = Path.Combine(dir, "Display-Tuner.ps1");
        if (!File.Exists(script))
        {
            MessageBox.Show("Не найден Display-Tuner.ps1 рядом с программой:\n" + dir,
                            "Яркость дисплея", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return 1;
        }

        try
        {
            using (PowerShell ps = PowerShell.Create())
            {
                ps.AddCommand(script);
                foreach (string a in args)
                {
                    // параметры-переключатели вида -Tray
                    if (a.StartsWith("-") && a.Length > 1) ps.AddParameter(a.Substring(1));
                }
                ps.Invoke();

                if (ps.Streams.Error.Count > 0)
                {
                    string msg = "";
                    foreach (ErrorRecord e in ps.Streams.Error) msg += e.ToString() + "\n";
                    MessageBox.Show(msg, "Яркость дисплея: ошибка",
                                    MessageBoxButtons.OK, MessageBoxIcon.Warning);
                    return 2;
                }
            }
        }
        catch (Exception ex)
        {
            MessageBox.Show(ex.ToString(), "Яркость дисплея: сбой",
                            MessageBoxButtons.OK, MessageBoxIcon.Error);
            return 3;
        }
        return 0;
    }
}
'@

Set-Content -Path $Src -Value $code -Encoding UTF8

$args = @(
    '/nologo'
    '/target:winexe'
    ('/out:"{0}"' -f $Exe)
    ('/win32icon:"{0}"' -f $Icon)
    ('/reference:"{0}"' -f $smaPath)
    '/reference:System.Windows.Forms.dll'
    '/reference:System.dll'
    '/optimize+'
    ('"{0}"' -f $Src)
)

Write-Host 'компилирую...' -ForegroundColor DarkGray
$p = Start-Process -FilePath $csc -ArgumentList $args -NoNewWindow -Wait -PassThru `
        -RedirectStandardOutput (Join-Path $env:TEMP 'csc-out.txt') `
        -RedirectStandardError  (Join-Path $env:TEMP 'csc-err.txt')

$out = Get-Content (Join-Path $env:TEMP 'csc-out.txt') -Raw -ErrorAction SilentlyContinue
$err = Get-Content (Join-Path $env:TEMP 'csc-err.txt') -Raw -ErrorAction SilentlyContinue

if ($p.ExitCode -ne 0) {
    if ($out) { Write-Host $out }
    if ($err) { Write-Host $err -ForegroundColor Red }
    throw "csc вернул код $($p.ExitCode)"
}

Write-Host ("готово: {0}  ({1:N0} байт)" -f $Exe, (Get-Item $Exe).Length) -ForegroundColor Green
Write-Host 'запуск: DisplayTuner.exe  ·  фоном: DisplayTuner.exe -Tray' -ForegroundColor DarkGray
