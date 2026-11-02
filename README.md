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

The current release is a Windows x64 prerelease candidate. Its automated
[Windows checks](https://github.com/drmixer/fms-releases/actions/workflows/windows-installer.yml)
are pending. Mac packages are not published here yet.

The public-only installer workflow tests a specific checksum-verified binary
on disposable GitHub-hosted runners. It never checks out private application
source and does not replace interactive Windows validation.
