# Changelog

All notable changes to this project are listed here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/spec/v2.0.0.html). There are no releases yet.

## [Unreleased]

The script is being redesigned in phases, one pull request each. These entries compare it
with the owner's original script.

### Migration

- `update_kernel.sh` is gone: use `kernel-updater` as `docs/migration.md` describes, and
  `docs/runbook.md` for routine use and recovery.

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
- Finding the stick's partition 1, in `lib/kernel-updater/disk.sh`: from the filesystem at
  `/boot`, `lsblk -s` walks up through the LUKS mapping to the one disk under it, refusing none
  or several, and takes its partition 1, never a `/dev/sdX` or by-id name; `blkid -p` reads
  what `lsblk` leaves empty without udev. Its identity is checked against `disk_ptuuid` and
  `p1_fs_uuid`, and messages name the part that differs, never a value. Partition 1 is reached
  through `p1_path`, a mount that is there, or a private mount in `/run` with
  `nosuid,nodev,noexec`: read-only with `ntfs3` first and `ntfs-3g` second, and read-write
  with `ntfs3` alone, never forced and never clearing what Windows left. Since `ntfs3` replays
  the log Windows left on any read-write mount, a read-write mount of its own waits until
  `ntfs-3g.probe --readwrite` finds partition 1 neither hibernated, nor kept in Windows' cache
  for Fast Startup, nor unclean; `ntfs3` then refuses a volume marked dirty, which `ntfs-3g`
  would mount read-write all the same; and `ntfs-3g` gets `norecover`. `p1_path` serves only
  while it is a mount point that holds `multibootusb/grub/grub.cfg`, the same as partition 1's
  when that can be read, so neither an empty mount point nor another stick's share passes for
  partition 1. A writer takes a mount that is there, or `p1_path`, only while it is read-write,
  no user but root can change its files, its root is root's, and its filesystem is mounted
  nowhere else; it gives up a mount of its own that another one joined meanwhile, and checks
  that it is read-write; a read-write mount that root made is taken as it is; a dry run mounts
  read-only. `systemd-detect-virt` tells whether it runs in a VM, and the deploy
  mode is resolved for phase 6: in a VM `auto` and `direct` export, since the guest never
  writes partition 1, and natively they write directly; `direct` or `path` fall back to an
  export, saying why, when they cannot write, and every export says why it exports. What a
  plan reads to build the new files comes only from a root no user but root can change, for an
  export too, so while a desktop has partition 1 mounted for its user the tool asks to unmount
  it there.
- A safe writer for partition 1 in `lib/kernel-updater/deploy.sh`, for phase 6: it refuses
  with exit 3 when a file changed since the plan read it, a symlink lies on its way or a user
  other than root could change a directory on its path; keeps `NAME.ku-<UTC stamp>.bak`
  backups beside it, the one it makes and the newest others, `backups_keep` in all, even when
  the clock went back; writes a synced temporary file and puts it in the file's place without
  renaming over the file, which `ntfs3` loses when such a rename fails: the file moves aside to
  a free name first, and back should the rename fail, also from the exit trap of a run cut
  short before the new file took the name, after which the exit names the old file aside;
  reads it back from the stick, past the cached pages, but for a file small enough to
  live in its MFT record; and exits 4 when anything fails: with the file unchanged or moved
  back when the temporary file cannot be written or put in place, and else once it put the old
  file back, saying whether that worked, or naming the backup to copy by hand. Given several
  files, it checks them all before it writes the first, and a later failure names the files
  written. It follows no symlink, refuses a source that is one, and
  removes its temporary files on every path, in a subshell too. Bytes are kept as they are,
  CRLF included. `ku_deploy_read` copies a file from partition 1 for a plan, following no
  symlink, with the SHA-256 the write then expects. An export writes the files to
  `output_dir`, a directory of root's with mode 0700, with `SHA256SUMS` and a `DEPLOY.txt`
  that says how to copy them from Windows, after removing the files of the earlier export it
  does not hold, and a verifier compares the stick with it.
- `kernel-updater baseline [--show]`, which records, as root and after asking, the SHA-256 of
  the stick's boot code in `/var/lib/kernel-updater/baseline`: the files
  `share/kernel-updater/baseline.list` names, the MBR boot code and partition 1's boot sector.
  It refuses with 78 while `disk_ptuuid` or `p1_fs_uuid` is not set or names another stick,
  prints how the stick differs from the stored baseline, and supports `--yes` and
  `--dry-run`. `--show` changes nothing and prints the identity verdicts, the stick's GRUB
  version and the comparison, and does not read a partition 1 that mismatches. A disk that
  cannot be read is named by its kind, never by its device. `ku_baseline_update` lets a writer
  record just the files it wrote, and records nothing in a dry run.
- Five partition-1 items for `check`, after the others: `p1-identity`, which also fails when
  the one key that is set names another stick, `grub-version`, which reads the version from
  the stick's `normal.mod` and compares it with `grub_floor`, `tripwire`, `deployed`, which
  warns against copying an export over a stick that changed since, and `kali-cfg`, which lints
  `kali.cfg` with the stick's own command and module lists. `check` reads partition 1
  read-only, never one the configuration rejects, follows no symlink on it, as `baseline`
  does not either, and removes its mount before it exits, also when interrupted;
  `--no-partition` skips the five.
- `disk_ptuuid`, `p1_fs_uuid`, `deploy`, `p1_path`, `output_dir` and `backups_keep` in
  `/etc/kernel-updater.conf`, each with its check, and in `examples/kernel-updater.conf`.
  Paths lose their trailing slashes.
- Test seams `KU_P1_DIR`, `KU_P1_DISK`, `KU_P1_FSTYPES` and `KU_P1_PROBE`, taken from the
  environment only with `KU_TEST=1`, and tests for partition 1, the safe writer and reader, the
  export and the baseline with stub tools, a partition-1 tree and a disk image.
- An `ntfs` job in the tests workflow that runs `tests/ntfs` as root: it builds a synthetic
  stick in a loop file with `sfdisk`, `mkntfs` and `ntfslabel`, finds partition 1 from an ext4
  `/boot` on it, mounts it with `ntfs3` and `ntfs-3g`, has `ntfs-3g.probe` keep a volume
  marked hibernated, and `ntfs3` one marked dirty, from a read-write mount, writes and
  restores through the safe writer,
  turns down a mount a user owns, and has the tripwire catch a changed byte, failing when a
  test is skipped.
- `kernel-updater migrate [--stage detect|system|menu|finalize|all]`, the one-time switch of
  the Kali entries to the links linux-base keeps in `/boot`, after which a kernel install or
  removal changes nothing on partition 1. Each stage runs as root under the lock, prints its
  plan, asks once, changes nothing with `--dry-run`, does nothing when its result is in place,
  and exits 3 naming the stage to run first. `detect` appends the identity of `/boot`, its
  LUKS container, the stick and the root device, and `grub_floor` from the stick's GRUB, to
  `/etc/kernel-updater.conf`, exiting 78 on a key set to another value. `system` refuses while
  check's `boot-luks`, `boot-ext` or `kernels` item fails, no kernel would boot, or only one
  would while `/boot` holds another kernel's image, which `linux-update-symlinks` would take
  for the `.old` links; it sets `do_symlinks` and `link_in_boot` in `/etc/kernel-img.conf`,
  has `linux-update-symlinks` point the links at the newest and the previous kernel, moves the
  old links out of `/`, offers on its own to empty grub-pc's install devices, and checks the
  result, down to the kernel each link points at; links already on the newest kernel and on
  another one that would boot stay, and it refuses before changing anything when the kernels
  or links change while its question waits, as when apt installs a kernel meanwhile. `menu`
  writes `multibootusb/grub/kali.cfg`
  from the new template `share/kernel-updater/kali.cfg.in`, with entries that boot `/vmlinuz`
  and `/initrd.img` and, for the previous kernel, the `.old` links, and the kernel parameters
  of the legacy entries, mended; and replaces the Kali submenu of `grub.cfg` with a block that
  sources `kali.cfg`, keeping the submenu behind it as legacy entries. A byte guard,
  `grub-script-check` and `lint` with the stick's own GRUB lists check both files before
  `kali.cfg` is written, then `grub.cfg`, or both are exported; its plan shows a kernel
  parameter that may name a device, a UUID or a key file as `NAME=<value>`. A write sets the
  baseline entries of the files it wrote, but not that of a file that differed from a stored
  baseline before it, as after a change from Windows: the plan and a warning name it, and
  check's tripwire keeps reporting the change until `kernel-updater baseline` records it, so
  no write of `migrate` hides a change made outside the tool. Run again while
  the legacy entries remain, `menu` writes `kali.cfg` alone anew from them when it is missing
  or differs, as after `menu_variants` changed. `live` and `forensic` need overlayroot in each
  initrd their entries boot. `finalize`
  removes the legacy entries, sets `grub.cfg`'s entry in the stored baseline, as `menu` does,
  and names the files that still differ from it, which `kernel-updater baseline` records once
  checked, or records the whole baseline when none is stored. A write of `menu`, `finalize` or a
  rollback removes an export in `output_dir` that it makes stale. `--deploy` and `--output-dir`
  hold for one run, and an export `--output-dir` takes elsewhere gets a warning, since `check`
  reads only the configured `output_dir`.
- Backups of every `system`, `menu` and `finalize` run in `/var/backups/kernel-updater`, with a
  `MANIFEST` of SHA-256 sums, named by the UTC time of the run, or one second after the newest
  backup when the clock reads no later, so that the names keep the order of the runs, synced to
  disk before the stage changes anything, and removed again when they cannot be written whole;
  and `kernel-updater migrate --rollback [STAMP]`, which undoes the newest run first, passes
  over a backup that a kill left without a `MANIFEST`, renaming it to `STAMP.failed`, refuses a
  backup that does not match its `MANIFEST`, and restores `kernel-img.conf` and the links in
  `/`, `grub.cfg`, or the `kali.cfg` a second `menu` run replaced, byte for byte. In export mode
  it exports the file even when the stick holds it already. When `grub.cfg` changed after the
  run wrote it, its plan and question say that the rollback drops those changes. It refuses to
  write back the `grub.cfg` of a `menu` run once `/boot` holds none of the kernels its Kali
  entries boot, and to undo a `system` run whose `kernel-img.conf` put back would stop
  linux-base from keeping the links in `/boot` while partition 1's `grub.cfg` still sources
  `kali.cfg`.
- `lib/kernel-updater/menu.awk`, which finds the Kali submenu of a GRUB config, braces counted
  outside quotes and comments only, with its entries and their kernel parameters, passing over
  options such as `--class` before a title as GRUB does.
- A `kali-menu` item for `check`, after `kali-cfg`: skips before the migration, warns while the
  legacy entries remain, and fails when `grub.cfg` sources a missing `kali.cfg` or a `kali.cfg`
  exists that `grub.cfg` does not source, as after a rollback of the menu stage, which it then
  says how to settle.
- `root_device`, `menu_variants` and `previous_variants` in `/etc/kernel-updater.conf`, each
  with its check, and in `examples/kernel-updater.conf`.
- `docs/migration.md`, the walkthrough of the migration: the backups from Windows, the stages
  in order, the tests at the GRUB prompt and of the new entries, natively and in the VM,
  routine use afterwards, the rollback of each stage, and what to do when a new kernel fails.
- Tests: `tests/menu.bats` for the scan, the parameters and those a plan hides, the rendering,
  which must equal `tests/fixtures/grub/kali.expected.cfg`, the new `grub.cfg`, which must
  equal `migrate-after.cfg`, also after far more than a pipe holds, and the byte guard;
  `tests/migrate.bats` for every stage and rollback, their refusals and exports, the stale
  export, the baseline and the order of the backups, with stub tools whose
  `linux-update-symlinks` picks the links as linux-base does; `tests/container/migrate.bats`
  with the real `linux-update-symlinks`, `debconf` and `grub-script-check`; and
  `tests/ntfs/migrate.bats`, which lints with the stick's own GRUB lists, writes the new menu to
  real NTFS and rolls it back. The `ntfs` job installs `dmsetup` for it.
- `kernel-updater cleanup [--no-rc] [--no-autoremove] [--no-modules]`, which purges, in one
  apt-get run, the config files removed kernels left and the old kernels apt's autoremove
  names, once a simulation shows apt would remove exactly those. It never purges the running
  kernel or a kernel the links in `/boot` point at, and purges nothing while a reboot into a
  new kernel is pending. Held packages, debug builds, what is no versioned kernel package,
  metapackages included, and the config files of a kernel still installed through another
  package, as `linux-image-V-unsigned`, stay, and the plan says why; an old kernel marked manual
  stays with an `apt-mark auto` hint. Purges cannot be rolled back, so run it with `-n` first. A
  module tree no package owns is removed when empty and otherwise moved to
  `/var/lib/kernel-updater/quarantine`, where it can be moved back until it expires,
  `quarantine_days` after a later run first saw it there; an empty `seen` mark, as a crash can
  leave, counts as none and is written anew. It exits 75 while apt or dpkg holds
  its lock, which it finds in `/proc/locks`, or when the system changed while its question
  waited, and `--porcelain` prints its plan as tab-separated records.
- `quarantine_days` in `/etc/kernel-updater.conf`: 0 to 999 whole days, 30 by default; 0 keeps
  the quarantined module trees until you delete them.
- `docs/runbook.md`: routine use, what the plan of `cleanup` says and what to do when it
  refuses, how to restore or delete a quarantined tree, recovery when a new kernel fails, a
  rebuild of one kernel's initrd, and an optional GRUB default entry.
- Tests for `cleanup`: `tests/cleanup.bats` with stub tools, and `tests/container/cleanup.bats`
  with real apt-get and dpkg runs on dummy kernels, module trees and quarantine entries, and a
  real fcntl lock on dpkg's frontend lock.

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
- `check` reports 18 items: the five partition-1 items follow `grub-pc`. The container suite
  expects them to skip on its tmpfs `/boot`, which lies on no disk.
- Keys in `/etc/kernel-updater.conf` may hold digits after the first character, as
  `p1_path` does.
- The check that a directory's entries only root can rename, which the shadow scan of `check`
  uses, moved to `common.sh` as `ku_root_only_dir`, so the private mount of partition 1 uses
  it too; `common.sh` also gains `ku_sha256`, and `lint.sh` shares its findings with `check`
  through `ku_lint_findings`.
- `tests/static.bats` also covers `disk.sh`, `deploy.sh`, `baseline.sh` and the NTFS suite,
  and `tests/helpers.bash` runs library code under the tool's strict mode with `run_ku_lib`.
- `KU_AWK`, the awk that runs `lint.awk`, is taken from the environment only with
  `KU_TEST=1`, as the other seams are, since `check` now lints `kali.cfg` as root.
- `check` reports 19 items: `kali-menu` follows `kali-cfg`, and `--no-partition` skips the six
  partition-1 items. Its probes start anew when they run twice in one process, and
  `ku_check_items` lets `migrate` run the `boot-luks`, `boot-ext` and `kernels` items without
  printing them; their results do not change.
- `ku_confirm` builds on the new `ku_ask`, which returns 1 on a no, and keeps the terminal open
  for the questions that follow, so that each reads the next answer.
- `ku_config_load` records in `KU_CONF_SET` which keys the file sets, and lists of variants
  lose the blanks around their commas.
- `ku_probe_kernel_img` reads a given copy of `kernel-img.conf` too, so that a rollback of
  `migrate`'s `system` stage can tell what the copy it puts back sets.
- `ku_grub_floor_for` gives the highest `grub_floor` a GRUB version reaches, which check's
  `grub-version` item and `migrate`'s `detect` share, and `ku_baseline_record` records the
  whole baseline for `migrate`'s `finalize` while none is stored.
- `tests/static.bats` also covers `migrate.sh` and runs `menu.awk`, and `tests/helpers.bash`
  loads `migrate.sh`.
- `migrate` and `cleanup` share `ku_plan` and `ku_join`, now in `common.sh`, and
  `ku_boot_identity`, now in `check.sh`.
- `tests/static.bats` also covers `cleanup.sh`, `tests/helpers.bash` loads it, and
  `tests/cli.bats` expects `cleanup` among the commands.
- `ku_probe_kernels` shares its reading of kernel package names with the new
  `ku_probe_kernel_packages`, which lists every versioned kernel package, headers, `-common`,
  kbuild and debug builds included, with its kind and release for `cleanup`; what `check`
  reports does not change.
- The container suite's `reset_system` also purges the split, modules, base and headers
  dummies and the dummy that depends on headers, removes the module trees of the dummies'
  releases and empties `cleanup`'s quarantine, and `run_container_cleanup` runs `cleanup` there
  with `KU_TEST=1`, which lets `SOURCE_DATE_EPOCH` through to apt.
- `install.sh --uninstall` removes `/var/lib/kernel-updater` only when it is empty, and leaves
  every directory inside it, such as one in a quarantined module tree, as it is.
- The README describes the finished tool and links the runbook, which `docs/migration.md` now
  points to for routine use and for a kernel that fails. `SECURITY.md` drops its warning about
  the original script.
- `migrate` exits 75 instead of 3 when the kernels or their links changed while the question of
  its system stage waited, as `cleanup` does when the system changes while its question waits.
- The safe writer exits 75 instead of 3 when a file on partition 1 changed since the plan read
  it, or appeared where the plan read none, before it wrote anything, so that a `migrate` stage
  or rollback then exits 75, as `cleanup` does when the system changes while its question
  waits; once it wrote an earlier file of the same run, it still exits 4 and names the files
  written.
- `cleanup` refuses, in a dry run too, until the migration is finished, because a purge could
  take away the kernel the legacy entries boot. It reads check's `kali-menu` item read-only from
  a partition 1 whose files no user but root can change, before its question and again after
  it: exit 3 while the menu stage or `finalize` is outstanding, naming an export that waits to
  be copied, while an export, even one with a damaged `SHA256SUMS`, waits to bring back entries
  that boot kernels by version, or when
  the menu is damaged; 66 when partition 1 cannot be found or read so, as while a
  desktop has it mounted for its user; and 78 on another stick or one the configuration does not
  name.

### Removed

- `update_kernel.sh`, the original script, with its tests in `tests/legacy.bats` and their
  runner `run_legacy` in `tests/helpers.bash`; `tests/static.bats` and `tests/repo.bats` no
  longer list it.

[Unreleased]: https://github.com/Ochsyp/kernel-updater/commits/main
