# Changelog

All notable changes to this project are listed here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).
Each version is the GitHub release `vX.Y.Z`.

## [Unreleased]

### Fixed

- The postinst hook, `check`'s `initrd` item and `migrate`'s system stage want key files in the
  initrd only for the `/etc/crypttab` entries the initramfs unlocks: a volume under `/`, or one
  marked `initramfs`. A key file of a volume systemd unlocks later no longer stops a kernel
  configure. When the volumes under `/` cannot be told, every key file counts, as before.
- `lint` ends a MultiBootUSB marker block at a bare `#end` line too, as `migrate` does, so no
  false `mbusb-marker` warning follows it.
- `migrate`'s system stage exits 75 while apt or dpkg holds its lock, before its plan and again
  after its question, as `cleanup` does, and 3 when it cannot tell.
- `baseline` exits 66, recording nothing, when partition 1 holds none of the files
  `baseline.list` names, also on a real disk, whose boot code it always reads; so does the
  baseline `finalize` records when none is stored.
- Windows step E puts back only a copy of the stick that is plugged in: step A notes the stick
  beside each copy. A copy an older step A made is taken only when no copy of this stick is there,
  with a warning.
- Windows step E writes only the files that differ from the stick's, each checked after the copy,
  instead of rewriting all of `multibootusb\grub`. A file whose SHA-256 cannot be read stops the
  Windows steps instead of passing for equal.

## [1.0.0] - 2026-11-28

The first release. kernel-updater replaces the owner's original script, `update_kernel.sh`.
These entries describe the tool as this release ships it, compared with that script: each
feature once.

### Added

- `bin/kernel-updater`, with its libraries in `lib/kernel-updater` and its data in
  `share/kernel-updater`, both in a checkout and under an install prefix. Commands: `check`,
  `baseline`, `migrate`, `cleanup`, `lint`, `hook`, `help` and `version`. Global options go
  before the command: `-c`/`--config`, `-n`/`--dry-run`, `-y`/`--yes`, `-v`/`--verbose`,
  `-q`/`--quiet`, `--porcelain`, `-h`/`--help` and `-V`/`--version`.
- Rails for every command that changes the system: a root check (exit 77), a single-instance lock
  (75), confirmation on the terminal or `--yes` (10 when declined), `--dry-run`, and exit traps that
  run cleanups, exit 130, 143 or 129 on INT, TERM or HUP, and 1 on an unexpected failure. An answer
  may end in a carriage return, as in a file of answers. `--yes` answers every question but the one
  `migrate --write-fat` asks. A message that says what to run next names the tool as `sudo` and the
  resolved path of the script that ran, shell-quoted, as `sudo /usr/local/bin/kernel-updater check`,
  since sudo's `secure_path` may lack `/usr/local/bin`; the hint after a usage error names the same
  path without `sudo`.
- `/etc/kernel-updater.conf`: `key = value` lines that are parsed, never sourced, checked key by
  key, refused (78) when a key repeats, a line or value is bad, or, when the tool runs as root,
  the file is not owned by root or is writable by group or others. Lines that start with `#` are
  comments; keys may hold digits after the first character; paths lose their trailing slashes;
  lists of variants lose the blanks around their commas. The keys are `grub_floor`,
  `boot_fs_uuid`, `boot_luks_uuid`, `verify_action`, `disk_ptuuid`, `p1_fs_uuid`, `deploy`,
  `p1_path`, `output_dir`, `backups_keep`, `root_device`, `menu_variants`, `previous_variants`
  and `quarantine_days`. `examples/kernel-updater.conf` describes each with every key commented
  out, `grub_floor` too, so that a copy leaves it to `migrate`'s detect stage.
- `kernel-updater lint FILE...` checks GRUB configs for errors GRUB reports only at boot: syntax
  errors through `grub-script-check` when it is installed, unknown commands and modules (GRUB 2.02's
  lists, or a stick's own with `--grub-dir`), malformed LUKS UUIDs and ones with dashes below a
  floor of 2.12, `cryptdevice=`, `noswap`, unknown `overlayroot` options, `(hdN,...)` drives,
  encrypted entries between MultiBootUSB's `#start` and `#end` markers, a bare `#start` line
  included, and a LUKS UUID passed to `search --fs-uuid`, unless `boot_fs_uuid` and `boot_luks_uuid`
  name that same UUID, as when `/boot`'s filesystem shares its container's UUID. `--floor` defaults
  to `grub_floor`. Findings name the kind of identifier, never its value; `--porcelain` prints
  tab-separated fields and `--strict` fails on warnings. It exits 78 on a bad configuration.
- `kernel-updater check [--strict] [--no-partition] [--porcelain]`, a read-only report, as root,
  of whether the system and the stick keep the Kali entries bootable, in 20 items: `boot-mounted`,
  `boot-identity`, `boot-shadowed`, `kernel-img`, `boot-links`, `stale-root-links`, `kernels`,
  `reboot-pending`, `initrd`, `boot-luks`, `boot-ext`, `fstab-crypttab`, `grub-pc`, and the seven
  partition-1 items `p1-identity`, `grub-version`, `tripwire`, `deployed`, `kali-cfg`, `kali-menu`
  and `boot-menu`, which `--no-partition` skips. Each is `ok`, `warn`, `fail` or `skip`, with a
  detail that names kinds and counts, never an identifier. It exits 2 when an item fails, or
  warns with `--strict`, 64 on a usage error, 77 when not root and 78 on a bad configuration.
  - To look under the `/boot` mount point it bind-mounts `/` read-only on a private directory in
    `/run`, never in `TMPDIR`, and removes that mount before it exits.
  - `boot-links` needs each of the four links in `/boot` to be relative and to reach a non-empty
    file in `/boot` that is no symlink itself, since GRUB follows links only on that filesystem.
  - `boot-luks` and `boot-ext` judge `/boot` by the GRUB `grub_floor` names: the LUKS versions
    and keyslot KDFs it unlocks and the ext features it reads.
  - `grub-pc` fails while `grub-pc/install_devices` names a device, warns when `debconf-show`
    cannot read grub-pc's answers, and skips while there is no such answer.
  - Partition 1 is read read-only, never one the configuration rejects, following no symlink
    on it. `grub-version` reads the stick's GRUB version from `normal.mod`; `tripwire` compares
    the stick with the stored baseline; `deployed` compares an export in `output_dir` with the
    stick and fails on one that differs, is missing or has a damaged `SHA256SUMS`; `kali-cfg`
    lints `kali.cfg` with the stick's own command and module lists; `kali-menu` says whether
    `grub.cfg` sources `kali.cfg` and the legacy entries remain; `boot-menu` names the hypervisor
    `systemd-detect-virt` reports and counts the `linux` lines that end with the running
    kernel's command line in the stick's menu and in `/boot/grub/grub.cfg`, which tells which
    menu booted it.
- Read-only probes in `lib/kernel-updater/probe.sh`: the kernel packages and the dpkg state of
  each version from one `dpkg-query` call, ordered by `linux-version` or else `sort -V`; the
  `/boot` mount, read with `blkid -p` when `findmnt` has no UUID, as in a chroot, its LUKS header
  and ext features; `/etc/kernel-img.conf` as linux-base reads it; the four links in `/boot`;
  crypttab and fstab; initrd listings; and the devices in `grub-pc/install_devices`.
- `install.sh`, which installs the tool under `/usr/local`, the kernel hooks in `/etc/kernel` and
  apt-guard's configuration in `/etc/apt/apt.conf.d/50kernel-updater`, in that order, and lists
  every file with its SHA-256 in `/var/lib/kernel-updater/install.manifest`. A newer release's
  `install.sh` updates what changed and removes what that release no longer has; `--uninstall`
  removes what the manifest lists, the APT configuration first, and `/var/lib/kernel-updater`
  only when it is empty; `--dry-run` changes nothing. The manifest lists old and new contents
  while files change, so a run cut short can be run again or undone. It refuses (3), changing
  nothing, when a file in its way was not installed by it or changed since, or a manifest line
  is damaged, and exits 66 when its folder lacks a file. A rerun also puts back a file whose
  owner or mode changed, and warns about each folder the files go in that a user other than
  root can change.
- Kernel hooks, armed while `boot_fs_uuid` is set and only warning until then: `preinst.d`,
  `prerm.d` and `postinst.d/00-kernel-updater` refuse (3) a kernel install, removal or configure
  while `/boot` is not mounted, holds another filesystem than `boot_fs_uuid` names, or `findmnt`
  cannot read the mount table. `postinst.d/kernel-updater`, after initramfs-tools, fails (2) a
  kernel whose vmlinuz is missing or empty, whose initrd is missing, unreadable, or lacks its
  modules, `cryptsetup`, the cryptroot configuration or the key files crypttab names, or, while
  linux-base keeps the links in `/boot`, whose links there are missing, absolute or dangle;
  `verify_action = warn` makes it only warn. The wrappers let everything through while
  `/usr/local/bin/kernel-updater` is missing or not executable. A configuration they cannot use
  stops them with 78, armed or not. `kernel-updater hook boot-guard|verify|apt-guard` runs them.
- apt-guard, a `DPkg::Pre-Install-Pkgs` hook with protocol version 3, armed as the kernel hooks are,
  which refuses an apt run before dpkg starts when it installs, removes or configures a versioned
  `linux-image`, `linux-binary`, `linux-modules` or `linux-base` package (but for its `-dbg` and
  `-dbgsym` packages), `linux-base`, `initramfs-tools`, `initramfs-tools-core` or
  `initramfs-tools-bin` while `/boot` is not the filesystem `boot_fs_uuid` names, or unpacks or
  configures `grub-pc` while `grub-pc/install_devices` names a device or `debconf-show` cannot read
  it. Any other run passes without starting the tool, and every run passes while apt-guard is
  missing or not executable. A refusal names the remedy for its cause.
- Partition 1, in `lib/kernel-updater/disk.sh`, FAT, as MultiBootUSB makes it, or NTFS.
  - It is found from the filesystem at `/boot`: `lsblk -s` walks up through the LUKS mapping to
    the one disk under it, refusing none or several, and takes its partition 1, never by a
    `/dev/sdX` or by-id name; `blkid -p` reads what `lsblk` leaves empty without udev. Its
    identity is checked against `disk_ptuuid` and `p1_fs_uuid`, which takes an NTFS serial or a
    FAT one such as `5CA1-AB1E`; messages name the part that differs, never a value.
  - It is reached through `p1_path`, which serves only while it is a mount point holding the
    same `multibootusb/grub/grub.cfg` as partition 1, a mount that is there, or a private mount
    in `/run` with `nosuid,nodev,noexec`: FAT with `vfat` as root's alone, NTFS read-only with
    `ntfs3` and then `ntfs-3g` with `norecover`, and read-write with `ntfs3` alone, only once
    `ntfs-3g.probe --readwrite` finds the volume neither hibernated, nor kept in Windows' cache
    for Fast Startup, nor unclean, never forced and never clearing what Windows left.
  - A writer takes a root only while no user but root can change its files and its filesystem
    is mounted nowhere else, and what a plan reads comes only from such a root, so while a
    desktop has partition 1 mounted for its user the tool asks to unmount it there. A dry run
    mounts read-only.
  - `deploy` says how files reach it: `auto` writes natively and exports in a VM, where Windows may
    have the volume mounted on the host; `direct` does the same; `export` leaves them in
    `output_dir`; `path` writes through `p1_path`, in a VM too. `auto`, natively, and `direct` fall
    back to an export when partition 1 cannot be written as they find or mount it, as when it is
    mounted read-only or shared, or hibernated, unclean or marked dirty, or a tool or `ntfs3` is
    missing, and `path` when `p1_path` does not serve, each saying why. A FAT partition 1 is
    exported unless `migrate --write-fat` writes it.
- A safe writer for partition 1, in `lib/kernel-updater/deploy.sh`. It exits 75 when a file
  changed since the plan read it, or one exists where the plan read none, a symlink included,
  before it wrote anything, and 3 when a symlink lies on its way or a user other than root could
  change a directory on its path. It keeps `NAME.ku-<UTC stamp>.bak` backups beside each file,
  `backups_keep` in all, even when the clock went back; writes a synced temporary file and puts
  it in place without renaming over the file, which `ntfs3` loses when such a rename fails, so
  the file moves aside first and back should the rename fail, also from the exit trap; reads each
  file back from the stick; and exits 4 when a step fails, saying what the stick holds then.
  Given several files it checks them all before it writes the first. On FAT it syncs the
  filesystem after each step and reads each file back through a new read-only mount. Bytes stay
  as they are, CRLF included. `ku_deploy_read` copies a file from partition 1 for a plan, with
  the SHA-256 the write then expects.
- Exports, also in `deploy.sh`: the files go to `output_dir`, a directory of root's with mode 0700
  on a path no other user can change, which is checked, and made when missing, before anything else
  changes; a dry run checks it, or the path to it, and makes nothing; then `SHA256SUMS` and a
  `DEPLOY.txt` that says how to copy them from Windows. The old `SHA256SUMS` and `DEPLOY.txt` and
  the files of the earlier export that the new one lacks go first, so a failed export leaves
  neither. A verifier compares the stick with the export for check's `deployed` item.
- `kernel-updater baseline [--show]`, which records, as root and after asking, the SHA-256 of the
  stick's boot code in `/var/lib/kernel-updater/baseline`: the files
  `share/kernel-updater/baseline.list` names, the MBR boot code and partition 1's boot sector. On
  FAT the tripwire ignores the boot sector's flags byte, which every mount changes, and
  `baseline.list`'s globs match names in any case. It refuses (78) while `disk_ptuuid` or
  `p1_fs_uuid` is not set or names another stick, exits 66 when partition 1 cannot be found or read
  or holds none of the listed files, prints how the stick differs from the stored baseline, and
  supports `--yes` and `--dry-run`. Names keep every byte, blanks at their ends too, as an NTFS file
  name may have them. `--show` takes no lock, changes nothing, and prints the identity verdicts, the
  stick's GRUB version and the comparison.
- `kernel-updater migrate [--stage detect|system|menu|finalize|all]`, the one-time switch of the
  Kali entries to the links linux-base keeps in `/boot`, after which a kernel install or removal
  changes nothing on partition 1. Each stage runs as root under the lock, prints its plan, asks
  before it changes anything (`system` asks a second question about grub-pc), changes nothing with
  `--dry-run`, does nothing when its result is in place, and exits 3 naming the stage to run first.
  `--deploy` and `--output-dir` hold for one run; `detect`, and `all`, which runs it, take no `-c`.
  - `detect` appends the identity of `/boot`, its LUKS container, the stick and the root device,
    and `grub_floor` from the stick's GRUB while the file sets none, to
    `/etc/kernel-updater.conf`, exiting 78 on a key set to another value.
  - `system` needs `/boot` mounted (66) and the one the configuration names (78), and refuses
    while check's `boot-luks`, `boot-ext` or `kernels` item fails or no kernel would boot. It sets
    `do_symlinks` and `link_in_boot` in `/etc/kernel-img.conf`, has `linux-update-symlinks` point
    the links at the newest and the previous kernel, moves the old links out of `/`, offers to
    empty grub-pc's install devices, and checks the result; it exits 75 when the kernels or links
    change while its question waits.
  - `menu` writes `multibootusb/grub/kali.cfg` from `share/kernel-updater/kali.cfg.in`, with entries
    that boot `/vmlinuz` and `/initrd.img` and, for the variants `previous_variants` names, the
    `.old` links, keeping the legacy entries' kernel parameters, mended; and replaces the Kali
    submenu of `grub.cfg` with a block that sources `kali.cfg`, the submenu following as legacy
    entries. First a byte guard checks that the new `grub.cfg` keeps every byte outside the submenu,
    `grub-script-check`, which `menu` and `finalize` need (3 otherwise), checks both files, and
    `lint` checks `kali.cfg` with the stick's own lists, or GRUB 2.02's when those cannot be read;
    `kali.cfg` is written before `grub.cfg`, or both are exported. Run again while the legacy
    entries remain, it writes `kali.cfg` alone anew when it is missing or differs. `live` and
    `forensic` need overlayroot in each initrd their entries boot. The plan shows a kernel parameter
    that may name a device, a UUID or a key file as `NAME=<value>`.
  - `finalize` removes the legacy entries.
  - A write sets the baseline entries of the files it wrote, but not that of a file that
    differed from a stored baseline before, as after a change from Windows, which the plan and a
    warning name; `finalize` records the whole baseline while none is stored. A write also
    removes an export it makes stale, in the configured `output_dir` and in the one
    `--output-dir` gave.
- Backups of every `system`, `menu` and `finalize` run in `/var/backups/kernel-updater`, named by
  the UTC time of the run, or a second after the newest backup when the clock reads no later. A
  `MANIFEST` of SHA-256 sums seals each, written as `MANIFEST.new`, synced and renamed: for an
  export once `output_dir` passed its checks, otherwise right before the stage's first change, so a
  run stopped before it changed anything leaves no backup. `migrate --rollback [STAMP]` undoes the
  newest run first, passes over a backup without a `MANIFEST`, renaming it to `STAMP.failed`,
  refuses one that does not match its `MANIFEST`, and restores `kernel-img.conf` and the links in
  `/`, `grub.cfg`, or the `kali.cfg` a second `menu` run replaced, byte for byte, or exports the
  file. It refuses to put back a `grub.cfg` whose Kali entries would boot no kernel `/boot` holds,
  and to undo a `system` run whose `kernel-img.conf` put back would stop linux-base keeping the
  links in `/boot` while partition 1's `grub.cfg` still sources `kali.cfg`.
- `migrate --write-fat`, which lets one run write a FAT partition 1 from the VM, and only with
  `deploy` `auto` or `direct`, under VMware, when the running kernel's command line ends a `linux`
  line of the stick's menu and none of `/boot/grub/grub.cfg`, the volume is FAT16 or FAT32, not
  marked dirty and its FAT keeps the clean-shutdown bit, and nothing has it mounted. It refuses (3)
  otherwise and writes nothing, and exits 66 when partition 1 does not mount. Before the first write
  it asks whether Windows no longer has BOOT, which `--yes` does not answer; any answer but `y`, or
  no terminal, exits 10. VMware locks BOOT itself while the VM runs, so it must not be taken offline
  in Windows first. The plan reads partition 1 through a read-only mount; the writes go through a
  read-write one with `flush`.
- `lib/kernel-updater/menu.awk`, which finds the Kali submenu of a GRUB config, braces counted
  outside quotes and comments only, with its entries and their kernel parameters.
- `kernel-updater cleanup [--no-rc] [--no-autoremove] [--no-modules]`, which purges, in one
  apt-get run, the config files removed kernels left and the old kernels apt's autoremove names,
  once a simulation shows apt would remove exactly those.
  - It refuses (3), in a dry run too, until the migration is finished, or while an export, even one
    with a damaged `SHA256SUMS`, waits to bring back a `grub.cfg` whose entries boot kernels by
    version; and also while `boot_fs_uuid` or `boot_luks_uuid` is unset, apt-get,
    apt-mark or dpkg-query is missing, the links are not kept in `/boot` or do not reach their
    files, check's `kernels` item fails, or a dpkg run was interrupted.
  - It never purges the running kernel or one the links in `/boot` point at, and nothing while a
    reboot into a new kernel is pending. Held packages, debug builds, metapackages, and the
    config files of a kernel still installed through another package stay, and the plan says
    why; an old kernel marked manual stays with an `apt-mark auto` hint.
  - A module tree no package owns, of no kept kernel, without `.fresh-install`, and for whose
    release neither `/boot` holds files, nor dpkg lists a package, nor dkms built modules, is
    removed when empty and otherwise moved to `/var/lib/kernel-updater/quarantine`, after a check of
    apt's and dpkg's locks right before each `rmdir` or move. A move needs GNU `mv --no-copy`
    (coreutils 9.2 or later) and a tree on the quarantine's filesystem; otherwise the tree is only
    listed. A
    quarantined tree can be moved back until it expires, `quarantine_days` (30 by default, 0 keeps
    it) after a later run that went ahead first saw it there, unless the clock reads earlier than an
    entry was moved or seen; that run writes a `seen` mark, only after the yes when it asks.
  - It exits 75 while apt or dpkg holds its lock, which it finds in `/proc/locks`, or when the
    system changed while its question waited; 3 when a check refuses while nothing changed; and 4
    once something changed. `--porcelain` prints the plan as tab-separated records once the
    run ends with 0.
- `tools/windows`: PowerShell scripts for the steps in Windows around `migrate --write-fat`.
  Step A copies the stick's menu to `%LOCALAPPDATA%\kernel-updater\stick-grub`, never to the
  Desktop; step D runs `chkdsk` read-only as administrator; step E copies the newest saved menu
  back. Each finds BOOT by its label and refuses, changing nothing, when BOOT is not there.
- `contrib/initramfs/overlayroot-rw`, an opt-in initramfs-tools script for the live and forensic
  entries. On kernels where overlayroot builds its RAM layer read-only and overlayfs refuses to
  make it writable later, their login fails on a read-only `/home`. Right after overlayroot, and
  only then, it mounts the same layers read-write, leaving the disk below read-only, and logs
  each step to `/run/overlayroot-rw.log`. It is installed with a rebuild of the initrd of the
  kernel `/boot/vmlinuz` points at, and of the previous kernel's too only when
  `previous_variants` names `live` or `forensic`.
- Documentation: the README, `docs/migration.md`, the walkthrough of the migration with the
  steps in Windows around each FAT write and the way back, and `docs/runbook.md` for routine use,
  `cleanup`'s plan and refusals, the quarantine, a kernel that fails, a rebuild of one kernel's
  initrd and an optional GRUB default entry. `examples/grub.cfg`, a synthetic MultiBootUSB config
  whose identifiers are all built from `5ca1ab1e`. `LICENSE` (MIT), `SECURITY.md` and
  `CONTRIBUTING.md`.
- The branch workflow, from repository standard 1.4.0 (`.github/standard.conf`): its git hooks
  in `.githooks` refuse commits and pushes to `main`, and a changed copy of the standard, and run
  `privacy-scan` with the `base` and `disk` packs over what a commit or a push brings in, its
  message, names and identities included. A pull request template and this changelog.
- Tests: a bats suite in `tests/` that runs without root or Kali, with stub tools, synthetic
  system trees and disk images, ShellCheck and syntax checks of every shell file, and repository
  checks; a container suite in `tests/container` with real dpkg, apt-get and linux-base runs on
  dummy kernels; `tests/ntfs` and `tests/fat`, which build a synthetic stick in a loop file and
  mount, read and write real NTFS and FAT; and `tests/tools.bats`, which runs the Windows scripts
  under `pwsh`. The standard's `ci` workflow runs them on every pull request, every push to
  `main` and once a week, through `ci/test` and, as root and in the Kali image, `ci/system`, and
  fails when a test is skipped; actions and the Kali image are pinned, and Dependabot updates the
  image. Its `secret-scan` workflow runs gitleaks with its default rules and the privacy packs.
- Releases: the standard's `release` workflow builds `kernel-updater-X.Y.Z.tar.gz`, with its
  manifest `kernel-updater-release.json` and `SHA256SUMS`, and `ci/release-check` checks that the
  archive holds every file `install.sh` installs. The README and the migration guide install a
  release on Kali with `curl`, `sha256sum --check`, `tar` and its `install.sh`. `install.sh
  --list` prints the files it installs, without root.

### Changed

- Repository standard 1.4.0: adopted, with the hooks, checks, workflows and blocks.
- Kernel updates no longer rewrite the stick's menu. The original script rewrote the versioned
  Kali entries of `grub.cfg` after each kernel update; after `migrate`, the entries boot
  `/vmlinuz` and `/initrd.img` and their `.old` counterparts, which linux-base moves on every
  kernel install, so `apt full-upgrade` alone keeps them bootable.

### Removed

- `update_kernel.sh`, the original script, with its tests. Use `kernel-updater` as
  `docs/migration.md` describes, and `docs/runbook.md` for routine use and recovery.

[Unreleased]: https://github.com/Ochsyp/kernel-updater/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/Ochsyp/kernel-updater/releases/tag/v1.0.0
