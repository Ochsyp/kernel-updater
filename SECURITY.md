# Security policy

kernel-updater has a single maintainer. It runs as root on a stick's Kali install, from the
command line, the kernel hooks and an apt hook.

<!-- standard:begin reporting -->
## Reporting a vulnerability

Report a vulnerability through GitHub's private vulnerability reporting: the **Security** tab,
then **Report a vulnerability**. Do not open a public issue.
<!-- standard:end reporting -->

## Trust model

The tool removes kernel packages and edits the stick's boot menu, so review every change before
it reaches a stick, and keep a copy of the stick's `multibootusb/grub` folder before a release
that changes the menu. It trusts root's own files: its configuration, which must be root's and
writable by no one else, and the paths it writes, which no user but root may be able to change.
It refuses a symlink on its way and settings taken from the environment, but for the test seams
that only `KU_TEST=1` opens.

## Known exposure

The tool runs as root, from the command line and from the kernel hooks on every kernel install.
apt-guard runs as root on every apt run that starts dpkg, and starts the tool only when the run
touches kernel, initramfs-tools or grub-pc packages. A change merged here reaches root on the
stick's Kali once it is installed there by hand, so the maintainer's review of each pull request
is the gate.

Partition 1 is FAT or NTFS, which Windows, and any user who mounts it, can change. The tool
follows no symlink there, writes it only through its safe writer, and check's tripwire reports a
change to its boot code. It cannot stop such a change.

## Network

kernel-updater makes no connection of its own. `cleanup` runs `apt-get`, which uses the system's
own apt sources.

## Data that stays private

The tool reads no secrets. A real `grub.cfg` holds the stick's partition and
encryption-container identifiers, which tie it to one physical device, so it stays out of the
repository, and the tool's messages name kinds and counts, never such a value. Never paste a real
`grub.cfg`, `blkid` output or logs with disk identifiers into issues, pull requests or commits.

<!-- standard:begin automated-checks -->
## Automated checks

- **Secret scan.** The `secret-scan` workflow runs gitleaks (MIT, pinned by version and SHA-256,
  always with its default rules) and this repository's rule packs. It scans the commits of each
  pull request and each push to `main`, and the whole history every Monday and when run by hand.
  Positive controls run first, so a scanner that finds nothing fails. Findings are redacted.
  GitHub's secret scanning and push protection are on as well. GitHub turns the Monday run off
  after 60 days without activity in this repository; repo-standard's `tools/status` reports it.
- **Hooks.** The hooks in `.githooks/` check every commit and push on the maintainer's machine:
  content, path names, messages, ref names and identities, against the rule packs and a denylist
  that never leaves that machine. The maintainer also checks regularly, with repo-standard's
  `tools/status`, what reached GitHub, pull request texts and release notes included.
- **CI and releases.** The `ci` workflow checks the standard's copies, the privacy rules over the
  tree, the version, the changelog and the pull request, and runs the tests. The `release`
  workflow builds, attests and drafts each release, and verifies it once it is published.
- **Dependencies.** Dependabot watches the ecosystems in `.github/dependabot.yml`, with security
  updates on.

If a secret is ever committed, rotate it first, then remove it from the history.
<!-- standard:end automated-checks -->
