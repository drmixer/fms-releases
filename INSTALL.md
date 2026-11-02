This prerelease contains the Windows x64 candidate only. Mac downloads are not
published in this release.

# Install FMS

## macOS

Download the DMG for your Mac from the matching GitHub Release, open it, and
drag FMS to Applications. An unsigned build may show a Gatekeeper warning. If
you trust the checksum and download source, use Finder to open the app, then
choose **Open**, or use **Open Anyway** in System Settings > Privacy & Security.
If that fails after checksum verification, remove quarantine only from that
specific verified app bundle: `xattr -dr com.apple.quarantine /Applications/FMS.app`.
Never disable Gatekeeper globally or run terminal commands from random setup guides.

Apple Silicon downloads are labelled `macos-aarch64`; Intel downloads are
labelled `macos-x64` when available. The ZIP is an alternative portable bundle,
not a second version of the app.

## Windows

Download the x64 NSIS `.exe` installer from the GitHub Release. Windows may
show a SmartScreen warning for an unsigned new application. Verify the
published SHA-256 checksum and release source before making a decision. Install
only from the official release page; never accept an installer sent by email or
chat.

## Verify a checksum

macOS:

```sh
shasum -a 256 FMS-*.dmg
```

Windows PowerShell:

```powershell
Get-FileHash .\FMS-*.exe -Algorithm SHA256
```

Compare the result with the same file in `SHA256SUMS` on that release.
