# Changelog

All notable changes to this project are listed here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/spec/v2.0.0.html). There are no releases yet.

## [Unreleased]

The script is being redesigned in phases, one pull request each. These entries compare it
with the owner's original script.

### Added

- `update_kernel.sh`, imported from the owner's machine. It is legacy: the README says not to
  run it, and the last phase removes it.
- `examples/grub.cfg`, a synthetic MultiBootUSB config with versioned Kali entries. All of its
  identifiers are made up and start with `5ca1ab1e`.
- A bats test suite in `tests/` that runs without root or Kali. It covers the legacy script's
  argument handling and its grub.cfg rewrite with stub commands, syntax and ShellCheck checks
  of every shell file, `grub-script-check` on the example config, and repository checks for
  line endings, executable bits and privacy.
- `.githooks/privacy-scan`, run by the `pre-commit` hook and by the tests. It refuses CRLF line
  endings, disk and partition identifiers outside the synthetic range, private IPv4 and IPv6
  addresses, `.lan` host names, user home paths, e-mail addresses other than GitHub no-reply
  ones, and values listed in the untracked `.git/info/privacy-denylist`.
- The branch workflow: git hooks in `.githooks` that refuse commits and pushes to `main`,
  `CONTRIBUTING.md`, a pull request template and this changelog.
- A `tests` workflow that runs `bats tests/` on every pull request and every push to `main`,
  with a pinned ShellCheck and `grub-common` installed, and fails when a test is skipped. A
  `secret-scan` workflow runs gitleaks 8.30.1 with the rules of `privacy-scan`, without the
  denylist, in `.gitleaks.toml`. Dependabot updates the pinned actions.
- `LICENSE` (MIT) and `SECURITY.md`.
- `bin/kernel-updater`, the command the redesign builds on, with `lint`, `help` and
  `version`. Its libraries live in `lib/kernel-updater` and its data in
  `share/kernel-updater`, both in a checkout and under an install prefix.
- `kernel-updater lint FILE...` checks GRUB configs for errors GRUB reports only at boot:
  syntax errors through `grub-script-check` when it is installed, unknown commands and
  modules (GRUB 2.02's lists, or a stick's own with `--grub-dir`), malformed LUKS UUIDs and
  ones with dashes below `--floor 2.12`, a LUKS UUID passed to `search --fs-uuid`,
  `cryptdevice=`, `noswap`, unknown `overlayroot` options, `(hdN,...)` drives, and encrypted
  entries between MultiBootUSB's `#start` and `#end` markers. Findings name the kind of
  identifier, never its value; `--porcelain` prints tab-separated fields and `--strict` fails
  on warnings.
- Rails for the commands that will change the system: a root check (exit 77), a
  single-instance lock (75), confirmation on the terminal or `--yes` (10), `--dry-run`, and
  exit traps that run cleanups, exit 130, 143 or 129 on INT, TERM or HUP, and exit 1 on an
  unexpected failure.
- `/etc/kernel-updater.conf`: `key = value` lines that are parsed, never sourced, checked
  key by key, refused when a key repeats, and refused when not owned by root or writable by
  group or others while running as root. Lines that start with `#` are comments.
  `grub_floor` sets the default of `lint --floor`. `examples/kernel-updater.conf` lists the
  keys.
- Tests for the command line, the rails, the configuration and `lint`, with a synthetic
  fixture holding every defect class and the findings it must produce.
- `kernel-updater check [--strict] [--porcelain]` reports, as root (exit 77 otherwise) and
  without changing anything, whether the system keeps the Kali entries bootable, item by item:
  `boot-mounted`, `boot-identity`, `boot-shadowed`, `kernel-img`, `boot-links`,
  `stale-root-links`, `kernels`, `reboot-pending`, `initrd`, `boot-luks`, `boot-ext`,
  `fstab-crypttab` and `grub-pc`. Each is `ok`, `warn`, `fail` or `skip`, with a detail that
  names kinds and counts, never an identifier; `--porcelain` prints tab-separated fields. It
  exits 2 when an item fails, or warns with `--strict`. To look under the `/boot` mount point
  it bind-mounts `/` read-only on a private directory in `/run`, never in `TMPDIR`, and
  removes that mount before it exits, lazily when it is busy; `boot-shadowed` fails when the
  mount stays. `boot-luks` and `boot-ext` judge `/boot` by the GRUB that `grub_floor` names:
  the LUKS versions and keyslot KDFs it unlocks and the incompatible ext features it reads.
- Read-only probes for `check` in `lib/kernel-updater/probe.sh`: the kernel packages and the
  dpkg state of each version from one `dpkg-query` call, removed only when all its packages
  are, ordered by `linux-version` or else `sort -V`; the `/boot` mount, its LUKS header, or
  that `cryptsetup` is missing, and its ext features; `/etc/kernel-img.conf` as linux-base
  reads it; the four links in `/boot`; crypttab and fstab; initrd listings; and the number of
  devices in `grub-pc/install_devices`.
- `boot_fs_uuid` and `boot_luks_uuid` in `/etc/kernel-updater.conf`: the UUIDs `check`
  expects for the filesystem at `/boot` and its LUKS container. Both are optional and kept
  lower case.
- Tests for the probes and `check` with stub tools and a synthetic system tree, and a
  container suite in `tests/container` that runs only with `KU_CONTAINER=1`: dummy kernel
  packages built with equivs, whose maintainer scripts call `linux-update-symlinks` as real
  kernels do, show how linux-base moves the links in `/boot` on install, reinstall and
  removal, which states dpkg gives held, removed and half-configured kernels, and how `check`
  reports a real system.
- A `kali` job in the tests workflow that builds a Kali rolling image from
  `ci/kali/Dockerfile`, pinned by digest, and runs the container suite in it with
  `docker run --privileged`, failing when a test is skipped. Dependabot updates the image.
- `install.sh`, which installs the tool from the checkout under `/usr/local`, the kernel hooks
  in `/etc/kernel` and apt-guard's configuration in `/etc/apt/apt.conf.d/50kernel-updater`, in
  that order, and lists every file with its SHA-256 in `/var/lib/kernel-updater/install.manifest`.
  A rerun updates what changed and removes files the checkout no longer has; `--uninstall`
  removes what the manifest lists, the APT configuration first; `--dry-run` changes nothing.
  The manifest lists old and new contents while files change, so a run cut short can be run
  again or undone. It refuses with exit 3, before changing anything, when a file in its way was
  not installed by it or changed since, and needs root.
- Kernel hooks: `preinst.d`, `prerm.d` and `postinst.d/00-kernel-updater` refuse, with exit 3,
  to let a kernel be installed, removed or configured while `/boot` is not mounted or holds
  another filesystem than `boot_fs_uuid` names. `postinst.d/kernel-updater`, which runs after
  initramfs-tools, fails a kernel whose vmlinuz is missing or empty, whose initrd is missing,
  unreadable, or lacks its modules, `cryptsetup`, the cryptroot configuration or the key files
  crypttab names, or whose links in `/boot` are absolute or dangle, leaving the package
  half-configured; with the links in `/boot` it says they already point at that kernel and
  that the `.old` links boot the previous one. The wrappers let everything through, with a
  warning, while `/usr/local/bin/kernel-updater` is missing.
- apt-guard, a `DPkg::Pre-Install-Pkgs` hook with protocol version 3 in
  `lib/kernel-updater/apt-guard`, refuses an apt run before dpkg starts when it installs,
  removes or configures a versioned `linux-image`, `linux-binary`, `linux-modules` or
  `linux-base` package, `linux-base` or `initramfs-tools` while `/boot` is not the filesystem
  `boot_fs_uuid` names, or unpacks or configures `grub-pc` while `grub-pc/install_devices`
  names a device. Any other run passes without starting the tool, and every run passes while
  apt-guard is missing or not executable. A refusal names the remedy for its cause: an
  unmounted `/boot`, another filesystem there, or a mount table `findmnt` cannot read.
- `kernel-updater hook boot-guard|verify|apt-guard`, which the installed hooks run. The hooks
  are armed while `boot_fs_uuid` is set; until then they only warn.
- `verify_action` in `/etc/kernel-updater.conf`: `fail`, the default, or `warn`, which makes the
  postinst check only warn.
- Tests for the hooks, apt-guard with protocol versions 3, 2 and 1, and the installer, and a
  container suite, `tests/container/hooks.bats`, that installs kernel-updater and drives the
  hooks through real dpkg, apt-get and linux-run-hooks runs, with dummy kernels whose
  maintainer scripts run the hooks as real ones do and an ext4 image loop-mounted on `/boot`.
  The Kali image adds e2fsprogs for it.

### Changed

- `update_kernel.sh` takes the `grub.cfg` to edit as its only argument, and exits 64 with a
  usage message on stderr when it gets none or more than one. Before, the path was fixed in
  the script.
- `update_kernel.sh` is stored with LF line endings, and `.gitattributes` keeps every text
  file LF.
- `examples/grub.cfg` no longer falls back to `terminal gfxterm`, a command GRUB 2.02 does
  not have.
- `tests/lint.bats` is now `tests/static.bats`. It also syntax-checks and ShellChecks
  `bin/kernel-updater` and the libraries, and runs `lint.awk` under the system awk.
- `tests/static.bats` also covers `probe.sh`, `check.sh` and the container suite, and fails
  when a library in `lib/kernel-updater` is missing from its list.
- The tests workflow also runs once a week, so a change in Kali rolling shows up without a
  push.
- The `/boot` probe behind `check` and the hooks reads the filesystem's UUID with `blkid -p`
  when `findmnt` has none, as in a chroot or container without udev, and looks inside `/boot`
  first, so an automount is mounted before it is probed.
- `KU_ROOT`, `KU_TTY` and `KU_LOCKFILE` are taken from the environment only with `KU_TEST=1`,
  which the tests set, so a stray `KU_ROOT` in root's environment cannot steer the hooks.
- `check`'s initrd and link rules are shared with the postinst hook; its results do not change.
- `tests/static.bats` and `tests/repo.bats` also cover `install.sh`, `hook.sh`, apt-guard and
  the kernel hooks.

[Unreleased]: https://github.com/Ochsyp/kernel-updater/commits/main
