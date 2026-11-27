param([ValidateSet('login','credential','account','scan','backup')]$Scenario)
$ErrorActionPreference='Stop'
$exe=Join-Path $env:RUNNER_TEMP 'FMS desktop test\fms.exe'
if ($env:RUNNER_ENVIRONMENT -ne 'github-hosted' -or $env:GITHUB_REPOSITORY -ne 'drmixer/fms-releases' -or $env:FMS_TEST_EXE -ne $exe) { throw 'Requires the installed QA package.' }
Add-Type -AssemblyName UIAutomationClient,UIAutomationTypes,System.Windows.Forms
$ui=[Windows.Automation.AutomationElement]
$types=[Windows.Automation.ControlType]
$work=New-Item -ItemType Directory (Join-Path $env:RUNNER_TEMP ('fms-uia-'+[guid]::NewGuid()))
function Launch {
    $env:FMS_SMOKE_DIAGNOSTICS=Join-Path $work ([guid]::NewGuid().ToString()+'.log')
    $script:app=Start-Process $exe -PassThru
    for($i=0; $i -lt 80; $i++) {
        $line=Get-Content $env:FMS_SMOKE_DIAGNOSTICS -ErrorAction SilentlyContinue | Select-String '^startup-main-window hwnd=0x([a-fA-F0-9]+)' | Select-Object -First 1
        if ($line) { break }
        Start-Sleep -Milliseconds 200
    }
    if (-not $line) { throw 'Expected FMS main window.' }
    $script:root=$ui::FromHandle([IntPtr]::new([Convert]::ToInt64($line.Matches[0].Groups[1].Value,16)))
}
function Find-Control($name,$type) {
    $cond=[Windows.Automation.PropertyCondition]::new($ui::ControlTypeProperty,$type)
    for ($i=0; $i -lt 24; $i++) {
        $all=$root.FindAll([Windows.Automation.TreeScope]::Descendants,$cond)
        $elem=$all | Where-Object { $_.Current.Name -like $name -and $_.Current.IsEnabled } | Select-Object -First 1
        if ($elem) { return $elem }
        Start-Sleep -Milliseconds 250
    }
    $root.FindAll([Windows.Automation.TreeScope]::Descendants,[Windows.Automation.Condition]::TrueCondition) | Select-Object -First 100 | ForEach-Object { Write-Host ($_.Current.ControlType.ProgrammaticName+' '+$_.Current.Name) }
    throw "FMS accessibility control missing: $name"
}
function Click($name) {
    $el=Find-Control $name $types::Button
    $el.GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern).Invoke()
}
function Fill($name,$value) {
    $el=Find-Control $name $types::Edit
    $field=$el.GetCurrentPattern([Windows.Automation.ValuePattern]::Pattern)
    for ($i=0; $i -lt 3; $i++) {
        $el.SetFocus()
        [Windows.Forms.SendKeys]::SendWait('^a')
        [Windows.Forms.SendKeys]::SendWait($value)
        if ($field.Current.Value -ceq $value) { return }
        $field.SetValue($value)
        if ($field.Current.Value -ceq $value) { return }
    }
    throw "Could not fill $name."
}
function Quit {
    Click 'Settings'
    Click 'Quit FMS'
    if (-not $app.WaitForExit(8000) -or $app.ExitCode -ne 0) { throw 'Settings Quit did not exit cleanly.' }
}
function Entries {
    foreach ($rootKey in [Microsoft.Win32.Registry]::CurrentUser,[Microsoft.Win32.Registry]::LocalMachine) {
        $key=$rootKey.OpenSubKey('Software\Microsoft\Windows\CurrentVersion\Run')
        if ($key) { $v=$key.GetValue('FMS'); if ($v) { $v }; $key.Dispose() }
    }
}
try {
    Launch
    if ($Scenario -eq 'login') {
        Click 'Settings'
        $toggle=Find-Control 'Launch at login*' $types::CheckBox
        $pattern=$toggle.GetCurrentPattern([Windows.Automation.TogglePattern]::Pattern)
        if (@(Entries).Count) { throw 'Expected a clean launch registration.' }
        $pattern.Toggle()
        for ($i=0;$i -lt 25 -and -not @(Entries).Count;$i++) { Start-Sleep -Milliseconds 200 }
        $values=@(Entries)
        $quoted=$values.Count -eq 1 -and $values[0] -eq ('"'+$exe+'" --background')
        $plain=$values.Count -eq 1 -and $values[0] -eq ($exe+' --background')
        Write-Host "Startup entries=$($values.Count) matched=$($quoted -or $plain) quoted=$quoted"
        if ($values.Count) {
            $pattern.Toggle()
            for ($i=0;$i -lt 25 -and @(Entries).Count;$i++) { Start-Sleep -Milliseconds 200 }
            if (@(Entries).Count) { throw 'Disabling did not clear the startup registration.' }
            Write-Host 'PASS: Disabling launch at login cleared the registration.'
        }
        Click 'Quit FMS'
        if (-not $app.WaitForExit(8000) -or $app.ExitCode -ne 0) { throw 'Settings Quit failed.' }
        Write-Host 'PASS: Settings Quit exited normally.'
        if (-not $quoted) { throw 'Expected a quoted executable in the startup entry.' }
    } elseif ($Scenario -eq 'account') {
        Click '+ Account'
        Fill 'Service' 'Resend'
        Fill 'Email / username' 'desktop@example.invalid'
        Click 'Save account'
        [void](Find-Control 'Account saved locally*' $types::Text)
        Write-Host 'PASS: Added an account in FMS through its Windows UI.'
        Quit
    } elseif ($Scenario -eq 'scan') {
        $scanRoot=New-Item -ItemType Directory (Join-Path $work 'scan')
        $folder=New-Item -ItemType Directory (Join-Path $scanRoot 'qa-scan-project')
        [IO.File]::WriteAllText((Join-Path $folder 'package.json'),'{"name":"qa-scan-project","dependencies":{"resend":"1.0.0"}}')
        Click 'Scan'
        & "$PSScriptRoot/desktop-dialog.ps1" -AppId $app.Id -Title 'Choose where your projects live' -Action 'Select Folder' -Value $scanRoot.FullName
        Click 'Select all'
        Click 'Import selected'
        [void](Find-Control 'Imported 1 project*' $types::Text)
        Fill 'Search projects, services, accounts and identities' 'qa-scan-project'
        [void](Find-Control 'qa-scan-project' $types::Text)
        Start-Sleep -Milliseconds 500
        Click 'Manage project'
        Write-Host 'PASS: Scanned a folder and imported the discovered project.'
        Click 'Connect account'
        Click '*desktop@example.invalid*'
        [void](Find-Control 'Manage account' $types::Button)
        Write-Host 'PASS: Linked the test account to the imported project.'
        Click 'Reveal'
        $shell=New-Object -ComObject Shell.Application
        $found=$false
        for ($i=0;$i -lt 55 -and -not $found;$i++) {
            foreach($window in $shell.Windows()) {
                try { foreach($item in $window.Document.SelectedItems()) { if ($item.Path -eq $folder.FullName -or $item.Path -eq ('\\?\'+$folder.FullName)) { $found=$true } } } catch {}
            }
            $windows=$ui::RootElement.FindAll([Windows.Automation.TreeScope]::Children,[Windows.Automation.Condition]::TrueCondition) | Where-Object { $_.Current.ClassName -eq 'CabinetWClass' }
            foreach ($win in $windows) {
                $match=[Windows.Automation.PropertyCondition]::new($ui::NameProperty,'qa-scan-project')
                foreach ($item in $win.FindAll([Windows.Automation.TreeScope]::Descendants,$match)) {
                    $selection=$null
                    if ($item.TryGetCurrentPattern([Windows.Automation.SelectionItemPattern]::Pattern,[ref]$selection) -and $selection.Current.IsSelected) { $found=$true }
                }
            }
            Start-Sleep -Milliseconds 200
        }
        if ($found) { Write-Host 'PASS: Explorer selected the scanned project folder.' }
        else {
            $windows | ForEach-Object { Write-Host ('Explorer window after Reveal: '+$_.Current.Name) }
            $root.FindAll([Windows.Automation.TreeScope]::Descendants,[Windows.Automation.Condition]::TrueCondition) | ForEach-Object { $_.Current.Name } | Where-Object { $_ -match 'could not|failed|couldn.t|shown in|denied|cannot find' } | Select-Object -Unique | Out-Host
        }
        [Windows.Forms.SendKeys]::SendWait('^+f')
        Fill 'Quick Find' 'desktop@example.invalid'
        [void](Find-Control '*desktop@example.invalid*' $types::ListItem)
        Write-Host 'PASS: Ctrl+Shift+F opened Quick Find and returned the saved account.'
        if (-not $found) { throw 'Could not verify the selection through Explorer.' }
    } elseif ($Scenario -eq 'backup') {
        $file=Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'FMS-metadata-backup.json'
        if (Test-Path $file) { throw 'Expected a fresh default backup destination.' }
        Click 'Settings'
        Click 'Export backup'
        & "$PSScriptRoot/desktop-dialog.ps1" -AppId $app.Id -Title 'Export private FMS metadata' -Action 'Save'
        [void](Find-Control 'Metadata backup saved*' $types::Text)
        if (-not (Test-Path $file)) {
            $roots=@([Environment]::GetFolderPath('MyDocuments'),$env:GITHUB_WORKSPACE)
            $roots+=@(Get-ChildItem $env:RUNNER_TEMP -Directory -Filter 'fms-uia-*' | ForEach-Object { $_.FullName })
            $files=@($roots | ForEach-Object { Get-ChildItem -LiteralPath $_ -Filter 'FMS-metadata-backup*' -File -Recurse -ErrorAction SilentlyContinue })
            if ($files.Count -ne 1) { throw "Expected a single new backup in the test folders, found $($files.Count)." }
            $file=$files[0].FullName
        }
        $data=(Get-Content $file -Raw | ConvertFrom-Json)
        if ($data.format -ne 'fms-metadata-backup' -or 'desktop@example.invalid' -notin $data.identities.value) { throw 'Backup missing the expected account.' }
        Write-Host 'PASS: The exported backup contained the synthetic account.'
        Click 'Quit FMS'
        if (-not $app.WaitForExit(8000) -or $app.ExitCode -ne 0) { throw 'Export session failed to exit cleanly.' }
        $profileDir=Join-Path $env:APPDATA 'com.findmyshit.fms'
        if (-not (Test-Path (Join-Path $profileDir 'fms.sqlite3'))) { throw 'Expected disposable app database.' }
        Move-Item -LiteralPath $profileDir -Destination (Join-Path $work 'original')
        Launch
        Click 'Settings'
        Click 'Restore backup'
        & "$PSScriptRoot/desktop-dialog.ps1" -AppId $app.Id -Title 'Restore FMS metadata' -Action 'Open' -Value $file
        & "$PSScriptRoot/desktop-dialog.ps1" -AppId $app.Id -Title 'Restore FMS metadata' -Action 'Restore metadata'
        [void](Find-Control 'Metadata restored for*' $types::Text)
        Click 'Quit FMS'
        if (-not $app.WaitForExit(8000) -or $app.ExitCode -ne 0) { throw 'Restore session failed to exit cleanly.' }
        Launch
        Fill 'Search projects, services, accounts and identities' 'desktop@example.invalid'
        [void](Find-Control '*desktop@example.invalid*' $types::Text)
        Write-Host 'PASS: Restored the account into an empty profile and found it after restart.'
        Quit
    } else {
        $dir=New-Item -ItemType Directory (Join-Path $work 'local-project')
        $source=Join-Path $dir '.env'
        $original=[guid]::NewGuid().ToString()
        [IO.File]::WriteAllText($source,('RESEND_API_KEY='+$original))
        Click '+ Project'
        Fill 'Project name' 'Native QA'
        Fill 'Local folder*' $dir.FullName
        Click 'Add project'
        Start-Sleep -Milliseconds 800
        Fill 'Search projects, services, accounts and identities' 'RESEND_API_KEY'
        Click 'Manage project'
        Click 'Securely save'
        [void](Find-Control 'Copy secret' $types::Button)
        Write-Host 'PASS: FMS UI saved a synthetic credential.'
        Quit
        [IO.File]::WriteAllText($source,('RESEND_API_KEY='+[guid]::NewGuid()))
        Launch
        Fill 'Search projects, services, accounts and identities' 'RESEND_API_KEY'
        Click 'Manage project'
        Set-Clipboard 'fms-test-marker'
        Click 'Copy secret'
        for ($i=0;$i -lt 25 -and (Get-Clipboard -Raw).Trim() -ne $original;$i++) { Start-Sleep -Milliseconds 200 }
        if ((Get-Clipboard -Raw).Trim() -ne $original) { throw 'Clipboard did not contain the originally saved test value.' }
        Set-Clipboard 'fms-test-complete'
        Write-Host 'PASS: Copy secret returned the saved value after restart and a source change.'
        Quit
    }
} finally {
    if ($app -and -not $app.HasExited) { $app.Kill() }
}
