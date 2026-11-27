param([int]$AppId,[string]$Title,[string]$Value,[string]$Action)
$ErrorActionPreference = 'Stop'
if ($env:RUNNER_ENVIRONMENT -ne 'github-hosted' -or $env:GITHUB_REPOSITORY -ne 'drmixer/fms-releases' -or (Get-Process -Id $AppId).Path -ne $env:FMS_TEST_EXE) { throw 'Expected the release runner test app.' }
Add-Type -AssemblyName UIAutomationClient,UIAutomationTypes,System.Windows.Forms
if (-not ('DialogQA' -as [type])) {
    Add-Type @'
using System;
using System.Runtime.InteropServices;
public class DialogQA {
    [DllImport("user32.dll",CharSet=CharSet.Unicode)] public static extern IntPtr FindWindow(string cls,string title);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hwnd,out int pid);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hwnd);
}
'@
}
$deadline=(Get-Date).AddSeconds(12)
do {
    $hwnd=[DialogQA]::FindWindow('#32770',$Title)
    $owner=0
    [void][DialogQA]::GetWindowThreadProcessId($hwnd,[ref]$owner)
    if ($owner -eq $AppId) {
        $dialog=[Windows.Automation.AutomationElement]::FromHandle($hwnd)
        $controls=@($dialog.FindAll([Windows.Automation.TreeScope]::Descendants,[Windows.Automation.Condition]::TrueCondition))
        $button=$controls | Where-Object { $_.Current.Name.Replace('&','') -eq $Action } | Select-Object -First 1
        if ($button) {
            [void][DialogQA]::SetForegroundWindow($hwnd)
            if ($Value) {
                $edit=$controls | Where-Object { $_.Current.AutomationId -eq '1001' -and $_.Current.Name -notlike 'Address:*' } | Select-Object -First 1
                if (-not $edit) { Start-Sleep -Milliseconds 200; continue }
                $edit.SetFocus()
                [Windows.Forms.SendKeys]::SendWait('^a')
                [Windows.Forms.SendKeys]::SendWait($Value)
                [Windows.Forms.SendKeys]::SendWait('{ENTER}')
            } else {
                $button.SetFocus()
                [Windows.Forms.SendKeys]::SendWait(' ')
            }
            return
        }
    }
    Start-Sleep -Milliseconds 200
} while ((Get-Date) -lt $deadline)
if ($dialog) { $controls | ForEach-Object { '{0} {1}' -f $_.Current.AutomationId,$_.Current.Name } | Select-Object -First 80 | Out-Host }
throw "Did not find $Action in $Title."
