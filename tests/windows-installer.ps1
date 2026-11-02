#requires -Version 7.2
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$InstallerPath,
    [Parameter(Mandatory)][ValidatePattern('\A[a-fA-F0-9]{64}\z')][string]$Sha256,
    [Parameter(Mandatory)][ValidatePattern('\A[0-9]+\.[0-9]+\.[0-9]+\z')][string]$Version,
    [string]$PreviousInstallerPath,
    [string]$PreviousSha256,
    [string]$PreviousVersion
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Assert-HostedTest {
    if (-not $IsWindows -or $env:GITHUB_ACTIONS -ne 'true' -or
        $env:RUNNER_ENVIRONMENT -ne 'github-hosted' -or $env:FMS_PUBLIC_RUNNER_TEST -ne '1') {
        throw 'This test runs only in the approved disposable GitHub-hosted Windows job.'
    }
}

function Assert-InstallerHash([string]$Path, [string]$Expected) {
    if ($Expected -notmatch '\A[a-fA-F0-9]{64}\z' -or
        [IO.Path]::GetExtension($Path) -ne '.exe' -or
        (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash -ne $Expected) {
        throw 'Installer checksum or file type did not match the approved candidate.'
    }
}

function Invoke-BoundedProcess([string]$Path, [string]$Arguments, [int]$TimeoutSeconds = 240) {
    $child = Start-Process -FilePath $Path -ArgumentList $Arguments -PassThru
    try {
        if (-not $child.WaitForExit($TimeoutSeconds * 1000)) {
            throw 'Installer process exceeded its time limit.'
        }
        if ($child.ExitCode -ne 0) { throw "Installer process exited with code $($child.ExitCode)." }
    } finally {
        if (-not $child.HasExited) { Stop-Process -Id $child.Id -Force }
        $child.Dispose()
    }
}

function Get-FmsRegistration {
    $keys = @(
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKCU:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    @(Get-ItemProperty $keys -ErrorAction SilentlyContinue | Where-Object {
        $_.PSObject.Properties['DisplayName'] -and $_.DisplayName -eq 'FMS'
    })
}

function Assert-Installed([string]$ExpectedVersion) {
    if (-not (Test-Path -LiteralPath $exe) -or -not (Test-Path -LiteralPath $uninstaller)) {
        throw 'The installed executable or uninstaller is missing.'
    }
    $actual = [Diagnostics.FileVersionInfo]::GetVersionInfo($exe).ProductVersion
    if ($actual -notmatch ('^' + [regex]::Escape($ExpectedVersion) + '(?:\.0)?$')) {
        throw 'Installed executable version does not match the requested release.'
    }
    $records = @(Get-FmsRegistration)
    if ($records.Count -ne 1 -or $records[0].DisplayVersion -ne $ExpectedVersion -or
        $records[0].InstallLocation.Trim('"').TrimEnd('\') -ne $installDir.TrimEnd('\') -or
        $records[0].UninstallString.Trim('"') -ne $uninstaller) {
        throw 'Per-user uninstall registration does not match this installation.'
    }
}

function Invoke-Fixture([string]$Mode) {
    & $python $fixtureScript $Mode $database $fixtureId
    if ($LASTEXITCODE -ne 0) { throw 'Synthetic account fixture check failed.' }
}

Assert-HostedTest
if ([bool]$PreviousInstallerPath -or [bool]$PreviousSha256 -or [bool]$PreviousVersion) {
    if (-not $PreviousInstallerPath -or $PreviousSha256 -notmatch '\A[a-fA-F0-9]{64}\z' -or
        $PreviousVersion -notmatch '\A[0-9]+\.[0-9]+\.[0-9]+\z' -or [version]$PreviousVersion -ge [version]$Version) {
        throw 'Upgrade checks require an older installer, version, and its SHA-256 together.'
    }
    Assert-InstallerHash $PreviousInstallerPath $PreviousSha256
}
Assert-InstallerHash $InstallerPath $Sha256
if (Get-Process -Name fms -ErrorAction SilentlyContinue) { throw 'An FMS process already exists; refusing to use this profile.' }
$appData = Join-Path $env:APPDATA 'com.findmyshit.fms'
if (Test-Path -LiteralPath $appData) { throw 'FMS application data already exists; refusing to use this profile.' }
if (@(Get-FmsRegistration).Count -ne 0) { throw 'FMS is already installed in this profile.' }

$python = (Get-Command python -CommandType Application -ErrorAction Stop).Source
$fixtureScript = Join-Path $PSScriptRoot 'metadata-fixture.py'
$fixtureId = [guid]::NewGuid().ToString()
$testRoot = Join-Path $env:RUNNER_TEMP "fms-installer-$fixtureId"
# A space in the destination exercises NSIS's trailing /D argument handling.
$installDir = Join-Path $testRoot 'FMS test application'
$exe = Join-Path $installDir 'fms.exe'
$uninstaller = Join-Path $installDir 'uninstall.exe'
$database = Join-Path $appData 'fms.sqlite3'
New-Item -ItemType Directory -Path $testRoot | Out-Null
$passed = [Collections.Generic.List[string]]::new()
$upgrade = if ($PreviousInstallerPath) { 'previous version to candidate' } else { 'same-version reinstall only' }

try {
    $initial = if ($PreviousInstallerPath) { $PreviousInstallerPath } else { $InstallerPath }
    $initialVersion = if ($PreviousInstallerPath) { $PreviousVersion } else { $Version }
    Invoke-BoundedProcess $initial "/S /D=$installDir"
    Assert-Installed $initialVersion
    $passed.Add('Silent install, executable version, and per-user registration')
    $runtime = & (Join-Path $PSScriptRoot 'windows-runtime.ps1') -ExecutablePath $exe
    $passed.Add("Manager HWND, WebView2 child, single instance, close/background, --background; shortcut: $($runtime.Shortcut)")
    & (Join-Path $PSScriptRoot 'windows-credential-store.ps1')
    $passed.Add('OS Credential Manager synthetic write/read/delete capability (not FMS save/decrypt)')
    Invoke-Fixture 'seed'

    Invoke-BoundedProcess $InstallerPath "/S /D=$installDir"
    Assert-Installed $Version
    Invoke-Fixture 'verify'
    $passed.Add("Installer data preservation: $upgrade")
    $runtime = & (Join-Path $PSScriptRoot 'windows-runtime.ps1') -ExecutablePath $exe
    Invoke-Fixture 'verify'
    $passed.Add("Synthetic account and database integrity after application restart; shortcut: $($runtime.Shortcut)")

    Invoke-BoundedProcess $uninstaller '/S'
    $deadline = (Get-Date).AddSeconds(60)
    do {
        if (-not (Test-Path -LiteralPath $exe) -and @(Get-FmsRegistration).Count -eq 0) { break }
        Start-Sleep -Milliseconds 250
    } while ((Get-Date) -lt $deadline)
    if ((Test-Path -LiteralPath $exe) -or @(Get-FmsRegistration).Count -ne 0) {
        throw 'Uninstall did not remove the application and its registration.'
    }
    Invoke-Fixture 'verify'
    $passed.Add('Silent uninstall preserves the synthetic application database')
    Write-Host 'Windows installer checks passed.'
} finally {
    if ($env:GITHUB_STEP_SUMMARY) {
        @(
            '## FMS installer checks',
            "Candidate: $Version; runner: $env:RUNNER_OS/$env:RUNNER_ARCH",
            "Upgrade coverage: $upgrade",
            '',
            'Completed checks:',
            ($passed | ForEach-Object { "- $_" }),
            '',
            'A missing completed check means the run stopped before passing it.',
            'Not verified: rendered UI, app credential save/decrypt, SmartScreen/UAC, tray menu, normal Quit, or sign-in startup.',
            'Only synthetic database fixtures were used. No profile, database, screenshot, or log artifacts were uploaded.'
        ) | Add-Content -LiteralPath $env:GITHUB_STEP_SUMMARY
    }
}
