$taskName = "Apply sRGB to Gamma LUT"
$existingTask = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue

if ($existingTask -ne $null) {
	Write-Host "Removing previous task"
	Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
}

$exeFile = Join-Path $PSScriptRoot 'DisplayTuner.exe'
$arg1 = '-Tray'

$action = New-ScheduledTaskAction -Execute $exeFile -Argument $arg1 -WorkingDirectory $PSScriptRoot
$trigger = New-ScheduledTaskTrigger -AtLogOn
# Дисплей на логоне инициализируется не мгновенно; без задержки dispwin
# может отработать до того, как режим установлен, и рамп затрётся.
$trigger.Delay = "PT20S"
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries

Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Settings $settings
