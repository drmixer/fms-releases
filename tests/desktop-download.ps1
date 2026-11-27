$ErrorActionPreference = 'Stop'
if ($env:GITHUB_REPOSITORY -ne 'drmixer/fms-releases' -or $env:RUNNER_ENVIRONMENT -ne 'github-hosted' -or $env:FMS_PUBLIC_RUNNER_TEST -ne '1') { throw 'Disposable release runner required.' }
$edge = @("${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe","$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $edge) { throw 'No installed Edge browser.' }
$asset='FMS-0.1.1-windows-x64-nsis.exe'
$url="https://github.com/drmixer/fms-releases/releases/download/v0.1.1/$asset"
$target=Join-Path ([Environment]::GetFolderPath('UserProfile')) "Downloads\$asset"
if (Test-Path $target) { throw 'Download destination already exists.' }
$profile=Join-Path $env:RUNNER_TEMP ('fms-browser-'+[Guid]::NewGuid())
Start-Process $edge -ArgumentList "--no-first-run --user-data-dir=`"$profile`" $url"
for ($i=0;$i -lt 60 -and -not (Test-Path $target);$i++) {Start-Sleep -Milliseconds 500}
if (Test-Path $target) {
    if ((Get-FileHash $target).Hash -ne $env:RELEASE_SHA256) { throw 'Browser download digest differed.' }
    Write-Host 'PASS: The normal Edge download matched the published installer digest.'
    $marks=Get-Content -LiteralPath $target -Stream 'Zone.Identifier' -ErrorAction SilentlyContinue
    if ('ZoneId=3' -notin $marks) { throw 'Expected an Internet-zone marker on the Edge download.' }
    Write-Host 'PASS: Windows classified the browser download as Internet-zone.'
} else {
    Start-Process $edge -ArgumentList "--user-data-dir=`"$profile`" edge://downloads"
    Start-Sleep -Seconds 3
    Add-Type -AssemblyName UIAutomationClient,UIAutomationTypes
    $ui=[Windows.Automation.AutomationElement]
    $windows=$ui::RootElement.FindAll([Windows.Automation.TreeScope]::Children,[Windows.Automation.Condition]::TrueCondition)
    foreach ($win in $windows) {
        if ($win.Current.Name -notmatch 'Edge|Downloads' -or (Get-Process -id $win.Current.ProcessId).ProcessName -ne 'msedge') { continue }
        $win.FindAll([Windows.Automation.TreeScope]::Descendants,[Windows.Automation.Condition]::TrueCondition) |
            ForEach-Object { $_.Current.Name } | Where-Object { $_ -match 'FMS-|uncommon|commonly downloaded|trust|blocked|dangerous|virus|harm|verify|couldn.t download' } | Select-Object -Unique -First 12 | Out-Host
    }
    throw 'Edge did not complete a normal download within the test window.'
}
