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

## Release status

**Windows coming soon.** The stable Windows build is still in testing. Windows testers can use the [0.1.1 x64 prerelease and checksums](https://github.com/drmixer/fms-releases/releases/tag/v0.1.1). The free Mac build is in release preparation.

The 0.1.1 tests covered clean installation, upgrades, account linking, credential save and copy, and backup restore. Launch at login has a known issue when the installation folder contains spaces. We still need a standard Windows desktop check of the first-launch prompts and sign-in behavior. [Desktop test results](https://github.com/drmixer/fms-releases/actions/runs/45990995669)

The public-only installer workflow tests a specific checksum-verified binary
on disposable GitHub-hosted runners. It never checks out private application
source and does not replace interactive Windows validation.
