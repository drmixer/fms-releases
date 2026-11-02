# FMS 0.1.0 Windows candidate

This is an unsigned Windows x64 prerelease for installer and runtime validation.
Automated Windows checks are pending. It is not a stable release.

Download `FMS-0.1.0-windows-x64-nsis.exe` and verify its SHA-256 against
`SHA256SUMS`. See `INSTALL.md` for SmartScreen and installation guidance.
Mac packages are not included in this prerelease.

FMS finds local projects, accounts, resources, and credential references.
Metadata export/restore is included; backups exclude secret values, encryption
keys, notes, and discovery caches. They cannot recover encrypted credentials
without the original system key.

There is no automatic updater. First-release testing covers reinstall rather
than an older-version upgrade. SmartScreen/UAC, rendered UI, app credential
save/copy, tray menus, normal quitting, and sign-in startup still need desktop
validation. Native process/window checks alone do not establish those results.
