#requires -Version 7.2
[CmdletBinding()]
param([Parameter(Mandatory)][string]$ExecutablePath)

if (-not $IsWindows -or $env:GITHUB_ACTIONS -ne 'true' -or
    $env:RUNNER_ENVIRONMENT -ne 'github-hosted' -or $env:FMS_PUBLIC_RUNNER_TEST -ne '1') {
    throw 'This test runs only in the approved disposable GitHub-hosted Windows job.'
}

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

if (-not ("NativeWindow" -as [type])) {
Add-Type @"
using System;
using System.Runtime.InteropServices;

public static class NativeWindow {
    [StructLayout(LayoutKind.Sequential)]
    public struct RECT {
        public int Left;
        public int Top;
        public int Right;
        public int Bottom;
    }

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool IsWindow(IntPtr hWnd);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool IsWindowVisible(IntPtr hWnd);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);

    [StructLayout(LayoutKind.Sequential)]
    private struct KeyboardInput {
        public ushort Key, Scan;
        public uint Flags, Time;
        public UIntPtr Extra;
    }
    [StructLayout(LayoutKind.Sequential)]
    private struct MouseInput {
        public int X, Y;
        public uint Data, Flags, Time;
        public UIntPtr Extra;
    }
    [StructLayout(LayoutKind.Explicit)]
    private struct InputUnion {
        [FieldOffset(0)] public KeyboardInput Keyboard;
        [FieldOffset(0)] public MouseInput Mouse;
    }
    [StructLayout(LayoutKind.Sequential)]
    private struct Input { public uint Type; public InputUnion Data; }
    [DllImport("user32.dll", SetLastError = true)]
    private static extern uint SendInput(uint count, Input[] inputs, int size);
    [DllImport("user32.dll", SetLastError = true)]
    private static extern IntPtr OpenInputDesktop(uint flags, bool inherit, uint access);
    [DllImport("user32.dll")]
    private static extern bool CloseDesktop(IntPtr desktop);
    public static bool InputDesktopAvailable() {
        if (!Environment.UserInteractive) return false;
        IntPtr desktop = OpenInputDesktop(0, false, 1);
        if (desktop == IntPtr.Zero) return false;
        CloseDesktop(desktop);
        return true;
    }
    public static bool SendShortcut() {
        ushort[] keys = { 0x11, 0x10, 0x46, 0x46, 0x10, 0x11 };
        Input[] inputs = new Input[keys.Length];
        for (int i = 0; i < keys.Length; i++) {
            inputs[i].Type = 1;
            inputs[i].Data.Keyboard.Key = keys[i];
            inputs[i].Data.Keyboard.Flags = i >= 3 ? 2u : 0u;
        }
        bool accepted = SendInput((uint)inputs.Length, inputs, Marshal.SizeOf<Input>()) == inputs.Length;
        if (!accepted) {
            // Release modifiers if Windows accepted only part of the sequence.
            Input[] releases = new Input[3];
            for (int i = 0; i < releases.Length; i++) {
                releases[i].Type = 1;
                releases[i].Data.Keyboard.Key = keys[i];
                releases[i].Data.Keyboard.Flags = 2;
            }
            SendInput((uint)releases.Length, releases, Marshal.SizeOf<Input>());
        }
        return accepted;
    }

    private const uint WM_CLOSE = 0x0010;
    private const uint SMTO_ABORTIFHUNG = 0x0002;

    [DllImport("user32.dll", EntryPoint = "SendMessageTimeoutW", SetLastError = true)]
    private static extern IntPtr SendMessageTimeout(
        IntPtr hWnd,
        uint msg,
        UIntPtr wParam,
        IntPtr lParam,
        uint flags,
        uint timeout,
        out UIntPtr result
    );

    public static bool RequestClose(IntPtr hWnd) {
        UIntPtr result;
        return SendMessageTimeout(
            hWnd,
            WM_CLOSE,
            UIntPtr.Zero,
            IntPtr.Zero,
            SMTO_ABORTIFHUNG,
            5000,
            out result
        ) != IntPtr.Zero;
    }
}
"@
}

$shortcutPasses = 0

$exe = (Resolve-Path -LiteralPath $ExecutablePath).Path
$diagnosticDirectory = if ($env:RUNNER_TEMP) { $env:RUNNER_TEMP } else { [IO.Path]::GetTempPath() }
$diagnosticLog = Join-Path $diagnosticDirectory "fms-smoke-$([Guid]::NewGuid()).log"
$env:FMS_SMOKE_DIAGNOSTICS = $diagnosticLog
Write-Host "Smoke testing $exe"
Write-Host "Diagnostic log: $diagnosticLog"

function Reset-Diagnostics {
    Remove-Item $diagnosticLog -ErrorAction SilentlyContinue
}

function Show-Diagnostics {
    if (Test-Path -LiteralPath $diagnosticLog) {
        Get-Content -LiteralPath $diagnosticLog | Where-Object {
            $_ -match '^[a-z-]+ hwnd=(?:0x)?[0-9a-fA-F]+ tauri_visible=Some\((true|false)\) native_visible=Some\((true|false)\)$'
        } | Select-Object -Last 10 | ForEach-Object { Write-Host $_ }
    }
}

function Wait-ForTauriMainWindowHandle(
    [System.Diagnostics.Process]$Process,
    [int]$TimeoutSeconds = 20
) {
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        if ($Process.HasExited) {
            throw "FMS exited unexpectedly with code $($Process.ExitCode)."
        }

        if (Test-Path $diagnosticLog) {
            $line = Get-Content $diagnosticLog |
                Where-Object { $_ -like "startup-main-window*" } |
                Select-Object -Last 1
            if ($line -and $line -match "hwnd=(0x[0-9A-Fa-f]+)") {
                $rawHandle = [Convert]::ToInt64($Matches[1].Substring(2), 16)
                $handle = [IntPtr]::new($rawHandle)
                Write-Host "Tauri main window handle: $handle"
                return $handle
            }
        }

        Start-Sleep -Milliseconds 100
    }

    Show-Diagnostics
    throw "Timed out waiting for FMS to report its Tauri main window handle."
}

function Wait-ForWindowVisible(
    [System.Diagnostics.Process]$Process,
    [IntPtr]$Handle,
    [int]$TimeoutSeconds = 20
) {
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        if ($Process.HasExited) {
            throw "FMS exited unexpectedly with code $($Process.ExitCode)."
        }

        if (-not [NativeWindow]::IsWindow($Handle)) {
            Show-Diagnostics
            throw "The Tauri main window was destroyed while waiting for it to become visible."
        }

        if ([NativeWindow]::IsWindowVisible($Handle)) {
            return
        }

        Start-Sleep -Milliseconds 100
    }

    Show-Diagnostics
    throw "Timed out waiting for the Tauri main window to become visible."
}

function Get-WindowSize([IntPtr]$Handle) {
    $rect = New-Object NativeWindow+RECT
    if (-not [NativeWindow]::GetWindowRect($Handle, [ref]$rect)) {
        throw "Could not read FMS window bounds."
    }

    return @{
        Width = $rect.Right - $rect.Left
        Height = $rect.Bottom - $rect.Top
    }
}

function Send-QuickFindShortcut {
    if (-not [NativeWindow]::InputDesktopAvailable()) {
        Write-Host 'SKIPPED global shortcut injection: runner has no accessible input desktop.'
        return $false
    }
    if (-not [NativeWindow]::SendShortcut()) {
        throw 'Windows did not accept the full shortcut input sequence; check runner desktop access.'
    }
    return $true
}

function Stop-Fms([System.Diagnostics.Process]$Process) {
    if (-not $Process.HasExited) {
        Stop-Process -Id $Process.Id -Force
        $Process.WaitForExit(5000) | Out-Null
    }
}

# Normal launch should show the full Manager window.
Reset-Diagnostics
$process = Start-Process -FilePath $exe -PassThru
try {
    $managerHandle = Wait-ForTauriMainWindowHandle $process
    Wait-ForWindowVisible $process $managerHandle
    $managerSize = Get-WindowSize $managerHandle
    Write-Host "Manager visible: $($managerSize.Width)x$($managerSize.Height)"

    if ($managerSize.Width -lt 850 -or $managerSize.Height -lt 600) {
        throw "Manager window is unexpectedly small: $($managerSize.Width)x$($managerSize.Height)"
    }

    $webview = @(Get-CimInstance Win32_Process -Filter "Name='msedgewebview2.exe'" | Where-Object { $_.ParentProcessId -eq $process.Id })
    if ($webview.Count -eq 0) { throw 'No WebView2 child process was detected for FMS.' }
    Write-Host 'WebView2 child process detected; this does not establish frontend rendering.'

    $second = Start-Process -FilePath $exe -PassThru
    try {
        if (-not $second.WaitForExit(10000) -or $second.ExitCode -ne 0 -or $process.HasExited) {
            throw 'Second launch did not hand off to the existing FMS instance.'
        }
        if (-not [NativeWindow]::IsWindow($managerHandle)) { throw 'Single-instance handoff destroyed the original window.' }
        Write-Host 'Single-instance handoff passed.'
    } finally { Stop-Fms $second }

    # Exercise WM_CLOSE on the exact HWND Tauri reports for the main window.
    if (-not [NativeWindow]::RequestClose($managerHandle)) {
        $win32Error = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
        throw "Windows did not accept the native close request for FMS (Win32 error $win32Error)."
    }
    Write-Host "Posted WM_CLOSE to Tauri main handle=$managerHandle"

    $hideDeadline = (Get-Date).AddSeconds(5)
    $hidden = $false
    while ((Get-Date) -lt $hideDeadline) {
        if ($process.HasExited) {
            throw "FMS exited after closing the window; background mode should keep it alive."
        }

        if (-not [NativeWindow]::IsWindow($managerHandle)) {
            Show-Diagnostics
            throw "FMS destroyed the Tauri main window instead of hiding it to the background."
        }

        if (-not [NativeWindow]::IsWindowVisible($managerHandle)) {
            $hidden = $true
            break
        }

        Start-Sleep -Milliseconds 100
    }

    if (-not $hidden) {
        Show-Diagnostics
        $process.Refresh()
        Write-Host "Smoke runner state: tauri_handle=$managerHandle tauri_visible=$([NativeWindow]::IsWindowVisible($managerHandle)) process_main_handle=$($process.MainWindowHandle) exited=$($process.HasExited)"
        throw "FMS Tauri main window is still visible five seconds after close-to-background."
    }
    Write-Host "Close-to-background passed; the original Tauri window is hidden and still alive."

    # The global Windows shortcut should restore that same window in compact Quick Find mode.
    if (Send-QuickFindShortcut) {
        Wait-ForWindowVisible $process $managerHandle
        $quickSize = Get-WindowSize $managerHandle
        if ($quickSize.Width -ge $managerSize.Width -or $quickSize.Height -ge $managerSize.Height) {
            throw 'Quick Find did not switch to a compact window after shortcut injection.'
        }
        $shortcutPasses++
        Write-Host 'Ctrl+Shift+F summon passed.'
    }

}
finally {
    Stop-Fms $process
}

# Launch-at-login uses --background. The Tauri window must exist but start hidden,
# then the global shortcut must reveal that same window.
Reset-Diagnostics
$background = Start-Process -FilePath $exe -ArgumentList "--background" -PassThru
try {
    $backgroundHandle = Wait-ForTauriMainWindowHandle $background
    Start-Sleep -Seconds 2

    if ($background.HasExited) {
        throw "FMS exited during --background startup."
    }
    if (-not [NativeWindow]::IsWindow($backgroundHandle)) {
        Show-Diagnostics
        throw "FMS destroyed its Tauri main window during --background startup."
    }
    if ([NativeWindow]::IsWindowVisible($backgroundHandle)) {
        Show-Diagnostics
        throw "FMS should start hidden when launched with --background."
    }
    Write-Host "--background startup is hidden on Tauri handle=$backgroundHandle."

    if (Send-QuickFindShortcut) {
        Wait-ForWindowVisible $background $backgroundHandle
        $backgroundQuickSize = Get-WindowSize $backgroundHandle
        if ($backgroundQuickSize.Width -ge $managerSize.Width -or $backgroundQuickSize.Height -ge $managerSize.Height) {
            throw 'Background summon did not switch to compact Quick Find.'
        }
        $shortcutPasses++
        Write-Host 'Background shortcut summon passed.'
    }

}
finally {
    Stop-Fms $background
}

Write-Host 'Native process/window state checks passed; inspect shortcut coverage separately.'
[pscustomobject]@{ Shortcut = if ($shortcutPasses -eq 2) { 'passed' } else { 'NOT VERIFIED (no input desktop)' } }

