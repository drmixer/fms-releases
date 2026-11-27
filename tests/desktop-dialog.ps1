param([int]$AppId,[string]$Title,[string]$Value,[string]$Action)
$ErrorActionPreference = 'Stop'
if ($env:RUNNER_ENVIRONMENT -ne 'github-hosted' -or $env:GITHUB_REPOSITORY -ne 'drmixer/fms-releases' -or (Get-Process -Id $AppId).Path -ne $env:FMS_TEST_EXE) { throw 'Expected the release runner test app.' }
Add-Type -AssemblyName UIAutomationClient,UIAutomationTypes
$ui = [Windows.Automation.AutomationElement]
$children = [Windows.Automation.TreeScope]::Children
$descendants = [Windows.Automation.TreeScope]::Descendants
$owned = [Windows.Automation.PropertyCondition]::new($ui::ProcessIdProperty,$AppId)
$deadline = (Get-Date).AddSeconds(15)
do {
    $windows = @($ui::RootElement.FindAll($children,$owned))
    $dialog = $windows | Where-Object { $_.Current.Name -eq $Title } | Select-Object -First 1
    if ($dialog) {
        $controls = @($dialog.FindAll($descendants,[Windows.Automation.Condition]::TrueCondition))
        if ($Value) {
            $edit = $controls | Where-Object { $_.Current.ControlType -eq [Windows.Automation.ControlType]::Edit -and $_.Current.AutomationId -eq '1001' } | Select-Object -First 1
            if ($edit) { $edit.GetCurrentPattern([Windows.Automation.ValuePattern]::Pattern).SetValue($Value) }
        }
        $button = $controls | Where-Object { $_.Current.ControlType -eq [Windows.Automation.ControlType]::Button -and $_.Current.Name.Replace('&','') -eq $Action } | Select-Object -First 1
        if ($button -and (-not $Value -or $edit)) {
            $button.GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern).Invoke()
            exit 0
        }
    }
    Start-Sleep -Milliseconds 200
} while ((Get-Date) -lt $deadline)
if ($dialog) { $controls | ForEach-Object { '{0} {1} {2}' -f $_.Current.ControlType.ProgrammaticName,$_.Current.AutomationId,$_.Current.Name } | Select-Object -First 80 | Out-Host }
else { $windows | ForEach-Object { $_.Current.Name } | Out-Host }
throw "Did not find $Action in $Title."
