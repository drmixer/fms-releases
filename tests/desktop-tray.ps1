$ErrorActionPreference = 'Stop'
$exe = Join-Path $env:RUNNER_TEMP 'FMS desktop test\fms.exe'
if ($env:GITHUB_REPOSITORY -ne 'drmixer/fms-releases' -or $env:RUNNER_ENVIRONMENT -ne 'github-hosted' -or
    $env:FMS_PUBLIC_RUNNER_TEST -ne '1' -or $exe -ne $env:FMS_TEST_EXE) { throw 'Requires disposable FMS desktop test install.' }
Add-Type -AssemblyName UIAutomationClient,UIAutomationTypes,WindowsBase
Add-Type @'
using System;
using System.Runtime.InteropServices;
using System.Text;
public class TrayQA {
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern IntPtr FindWindowEx(IntPtr parent, IntPtr after, string cls, IntPtr name);
    [DllImport("user32.dll")] public static extern IntPtr SetThreadDpiAwarenessContext(IntPtr c);
    [DllImport("user32.dll")] public static extern int GetMenuItemCount(IntPtr menu);
    [DllImport("user32.dll",CharSet=CharSet.Unicode)] public static extern int GetMenuString(IntPtr menu,uint index,StringBuilder s,int max,uint flags);
    [DllImport("user32.dll")] public static extern bool GetMenuItemRect(IntPtr hwnd,IntPtr menu,uint index,out Rect rect);
    [DllImport("user32.dll")] public static extern bool GetMenuBarInfo(IntPtr hwnd,int id,int item,ref MenuBarInfo info);
    [StructLayout(LayoutKind.Sequential)] public struct MenuBarInfo {public uint size;public Rect bounds;public IntPtr menu,submenu;public uint flags;}
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hwnd);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hwnd, out int pid);
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x,int y);
    [DllImport("user32.dll")] public static extern void mouse_event(uint flags,uint x,uint y,uint data,UIntPtr extra);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hwnd, out Rect r);
    public struct Rect { public int left,top,right,bottom; }
}
'@
[void][TrayQA]::SetThreadDpiAwarenessContext([IntPtr]::new(-4))
function Controls($className, $ownerId = 0) {
    $handle = [IntPtr]::Zero
    while (($handle = [TrayQA]::FindWindowEx([IntPtr]::Zero,$handle,$className,[IntPtr]::Zero)) -ne [IntPtr]::Zero) {
        if (-not [TrayQA]::IsWindowVisible($handle)) { continue }
        $owner = 0
        [void][TrayQA]::GetWindowThreadProcessId($handle,[ref]$owner)
        if ($ownerId -and $owner -ne $ownerId) { continue }
        $root = [Windows.Automation.AutomationElement]::FromHandle($handle)
        $root.FindAll([Windows.Automation.TreeScope]::Descendants,[Windows.Automation.Condition]::TrueCondition)
    }
}
function Click-Control($element, $right = $false) {
    $box = $element.Current.BoundingRectangle
    if ($box.IsEmpty -or $box.Width -lt 1 -or $box.Height -lt 1) { throw 'No clickable bounds.' }
    if (-not [TrayQA]::SetCursorPos(($box.Left + $box.Width/2),($box.Top + $box.Height/2))) { throw 'Cannot position pointer.' }
    $down,$up = if ($right) { 8,16 } else { 2,4 }
    [TrayQA]::mouse_event($down,0,0,0,[UIntPtr]::Zero)
    Start-Sleep -Milliseconds 90
    [TrayQA]::mouse_event($up,0,0,0,[UIntPtr]::Zero)
    Start-Sleep -Milliseconds 550
}
function Click-TrayItem($name) {
    $expanded = $false
    for ($attempt=0; $attempt -lt 8; $attempt++) {
        $items = @(foreach ($className in 'Shell_TrayWnd','NotifyIconOverflowWindow','TopLevelWindowForOverflowXamlIsland','XamlExplorerHostIslandWindow') { Controls $className })
        $icon = $null
        foreach ($candidate in $items) {
            if ($candidate.Current.Name -notmatch '^FMS(?:$|\s)' -or $candidate.Current.IsOffscreen) { continue }
            $ancestor = $candidate
            $context = for ($depth=0; $depth -lt 9 -and $ancestor; $depth++) {
                $ancestor.Current.ClassName + '/' + $ancestor.Current.AutomationId + '/' + $ancestor.Current.Name
                $ancestor=[Windows.Automation.TreeWalker]::RawViewWalker.GetParent($ancestor)
            }
            Write-Host ('FMS icon ancestry: ' + ($context -join ' > '))
            if (($context -join '>') -match 'NotifyIcon|SystemTray|TrayNotify|Notification Area|User Promoted|OverflowWindow') { $icon=$candidate; break }
        }
        if ($icon) { break }
        $chevron = $items | Where-Object { $_.Current.Name -match 'hidden icons|notification chevron' -and -not $_.Current.IsOffscreen } | Select-Object -First 1
        if ($chevron -and -not $expanded) { Click-Control $chevron; $expanded = $true }
        Start-Sleep -Milliseconds 350
    }
    if (-not $icon) {
        $items | ForEach-Object { $_.Current.Name } | Where-Object { $_ } | Select-Object -Unique -First 60 | Out-Host
        throw 'Could not reach the FMS notification icon in Explorer.'
    }
    # Invoke through the taskbar's own provider if available.
    $invoke=$null
    if ($icon.TryGetCurrentPattern([Windows.Automation.InvokePattern]::Pattern,[ref]$invoke)) { $invoke.Invoke() }
    else { Click-Control $icon }
    for ($i=0; $i -lt 12; $i++) {
        $handle=[IntPtr]::Zero
        while (($handle=[TrayQA]::FindWindowEx([IntPtr]::Zero,$handle,'#32768',[IntPtr]::Zero)) -ne [IntPtr]::Zero) {
            if (-not [TrayQA]::IsWindowVisible($handle)) { continue }
            $owner=0
            [void][TrayQA]::GetWindowThreadProcessId($handle,[ref]$owner)
            if ($i -eq 0) { Write-Host "Popup owner=$owner FMS=$($app.Id)" }
            if ($owner -ne $app.Id) { continue }
            $info=New-Object TrayQA+MenuBarInfo
            $info.size=[Runtime.InteropServices.Marshal]::SizeOf($info)
            if (-not [TrayQA]::GetMenuBarInfo($handle,-3,0,[ref]$info)) { continue }
            for ($n=0;$n -lt [TrayQA]::GetMenuItemCount($info.menu);$n++) {
                $caption=New-Object Text.StringBuilder 250
                [void][TrayQA]::GetMenuString($info.menu,$n,$caption,250,1024)
                if ($caption.ToString().Replace('&','').Trim() -ne $name) { continue }
                $rect=New-Object TrayQA+Rect
                if (-not [TrayQA]::GetMenuItemRect($handle,$info.menu,$n,[ref]$rect)) { throw 'No menu rectangle.' }
                [void][TrayQA]::SetCursorPos(($rect.left+$rect.right)/2,($rect.top+$rect.bottom)/2)
                [TrayQA]::mouse_event(2,0,0,0,[UIntPtr]::Zero)
                Start-Sleep -Milliseconds 90
                [TrayQA]::mouse_event(4,0,0,0,[UIntPtr]::Zero)
                Start-Sleep -Milliseconds 500
                return
            }
        }
        Start-Sleep -Milliseconds 150
    }
    throw "Missing FMS tray menu item $name."

}
function WindowSize {
    $r = New-Object TrayQA+Rect
    if (-not [TrayQA]::GetWindowRect($main,[ref]$r) -or -not [TrayQA]::IsWindowVisible($main)) { throw 'Expected a visible FMS main window.' }
    return @{ Width=$r.right-$r.left; Height=$r.bottom-$r.top }
}
$env:FMS_SMOKE_DIAGNOSTICS = Join-Path $env:RUNNER_TEMP ('fms-tray-'+[guid]::NewGuid()+'.log')
if (-not [TrayQA]::FindWindowEx([IntPtr]::Zero,[IntPtr]::Zero,'Shell_TrayWnd',[IntPtr]::Zero).ToInt64()) {
    Start-Process explorer.exe
    Start-Sleep -Seconds 4
}
$app = Start-Process -FilePath $exe -PassThru
try {
    for ($i=0; $i -lt 60; $i++) {
        $line = Get-Content $env:FMS_SMOKE_DIAGNOSTICS -ErrorAction SilentlyContinue | Where-Object { $_ -match '^startup-main-window hwnd=0x' } | Select-Object -Last 1
        if ($line -match 'hwnd=0x([0-9a-fA-F]+)') { break }
        Start-Sleep -Milliseconds 250
    }
    if (-not $line) { throw 'FMS did not report its window.' }
    $main = [IntPtr]::new([Convert]::ToInt64($Matches[1],16))
    Start-Sleep -Seconds 2
    $manager = WindowSize
    Click-TrayItem 'Quick Find'
    $quick = WindowSize
    if ($quick.Width -ge $manager.Width -or $quick.Height -ge $manager.Height) { throw 'Quick Find did not open the compact window.' }
    Write-Host 'PASS: Quick Find from the Explorer tray opened the compact window.'
    Click-TrayItem 'Open FMS'
    $full = WindowSize
    if ($full.Width -le $quick.Width -or $full.Height -le $quick.Height) { throw 'Open FMS did not restore the manager.' }
    Write-Host 'PASS: Open FMS from the Explorer tray restored the manager.'
    Click-TrayItem 'Quit FMS'
    if (-not $app.WaitForExit(8000) -or $app.ExitCode -ne 0) { throw 'Tray Quit did not exit cleanly.' }
    Write-Host 'PASS: Quit FMS from the Explorer tray exited normally.'
} finally {
    if (-not $app.HasExited) { $app.Kill() }
}
