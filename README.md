# FMS releases

This repository is for official, compiled FMS installers and release notes.
Only release documentation and test automation accompany the binaries.
It contains no FMS application source, database, backup, diagnostics, logs,
or source maps.

Download only from the Releases page. Verify the SHA-256 checksum in
`SHA256SUMS` before installing.

FMS is local-first software for finding projects, accounts, resources, and
credential references on your own machine. It is free to use. Optional support
may be offered only through a link chosen and published by the owner.

See [installation](INSTALL.md), [release notes](RELEASE-NOTES.md), and the
[end-user terms](LICENSE.txt). This repository is not an open-source release.

The current release is a [Windows x64 prerelease candidate](https://github.com/drmixer/fms-releases/releases/tag/v0.1.0).
Its [automated installer checks passed](https://github.com/drmixer/fms-releases/actions/runs/41436815099)
on Windows Server 2025 x64 and Windows 11 ARM running the x64 app through
emulation. Mac packages are not published here yet.

The checks covered install, same-version reinstall, uninstall, synthetic account
preservation, native window/background behavior, global shortcuts, and an OS
Credential Manager capability probe. They do not establish rendered UI,
FMS secret save/copy, SmartScreen/UAC, tray menus, normal quitting, sign-in
startup, or an older-version upgrade. This remains a prerelease.

The public-only installer workflow tests a specific checksum-verified binary
on disposable GitHub-hosted runners. It never checks out private application
source and does not replace interactive Windows validation.
