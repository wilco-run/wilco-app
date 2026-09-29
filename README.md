# Wilco for Mac (test builds)

Test builds of the Wilco desktop app for macOS. Install and update Wilco from
[wilco.run](https://wilco.run) with the command below. This repository is the archive of every test
build: each one is kept under [Releases](https://github.com/wilco-run/wilco-app/releases)
with its install script and checksums, and the repository itself holds only the install script and
third-party license notices.

These are test builds: they are not signed with an Apple Developer ID and not notarized. Expect rough
edges.

## Requirements

- A Mac with Apple silicon (M1 or later) running macOS 13 Ventura or later.
- A Wilco account. Sign up at [wilco.run](https://wilco.run).

## Install

Run this in Terminal:

```sh
curl -fsSL https://wilco.run/download/app/install.sh | bash
```

The script downloads the current build from wilco.run, checks its SHA-256 checksum and code
signature, removes the quarantine mark and installs `Wilco.app` into `/Applications` (or
`~/Applications` if `/Applications` is not writable). It never uses `sudo`. If Wilco is running, it
asks you to quit it first.

## Updates

Wilco checks wilco.run for new test builds and tells you when one is available; nothing is installed
until you choose to. Running the install command again also updates to the current build.

## An earlier build

Every test build stays in this archive. To install a specific one, pass its tag (the name of its
release here, in the form `v<version>-test.<date>.<n>`):

```sh
curl -fsSL https://wilco.run/download/app/install.sh | bash -s -- --version <tag>
```

To read the script before running it, download `install.sh` from a release (or from
wilco.run/download/app/install.sh) and open it in a text editor; `bash install.sh --help` lists every
option.

## Manual install

1. Download the zip from a release in this archive (`Wilco-<version>-<build>-mac-arm64.zip`) and open
   it; Finder unzips it.
2. Move `Wilco.app` to your Applications folder.
3. Clear the quarantine mark with the installer's `--fix` option:

   ```sh
   curl -fsSL https://wilco.run/download/app/install.sh | bash -s -- --fix
   ```

   If the app is not in `/Applications` or `~/Applications`, add its path after `--fix`. Or clear the
   mark yourself: `xattr -dr com.apple.quarantine /Applications/Wilco.app`

To check the download, compare the output of `shasum -a 256` on the zip with the line for it in
`SHA256SUMS` from the same release.

## "Wilco is damaged and can't be opened"

macOS shows this for unsigned apps downloaded with a web browser; the app is not damaged, and the
install command or `--fix` above clears it.

## Uninstall

```sh
curl -fsSL https://wilco.run/download/app/install.sh | bash -s -- --uninstall
```

This removes the app only. Your settings, sessions and sign-in are kept; the command prints where they
are and how to remove them.

## Support

Use Help > Report a Problem in the app, or email [support@wilco.run](mailto:support@wilco.run).

## Third-party software

License notices for third-party software included in the app are in
[THIRD-PARTY-NOTICES](THIRD-PARTY-NOTICES/).
