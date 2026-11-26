# kernel-updater

Keeps the Kali entries of a multiboot USB stick bootable across kernel updates.

[docs/runbook.md](docs/runbook.md) covers routine use and recovery, [CHANGELOG.md](CHANGELOG.md)
lists what changed, and [CONTRIBUTING.md](CONTRIBUTING.md) describes how changes are made.

## The setup it serves

A USB stick boots several systems through MultiBootUSB, whose GRUB reads
`/multibootusb/grub/grub.cfg` from partition 1: FAT32 with syslinux's boot sector, as
MultiBootUSB makes it, or NTFS. One submenu starts a full Kali install
on the same stick, with an encrypted `/boot` that GRUB unlocks and an encrypted root behind
it. The same install also runs as a virtual machine straight from the stick, booting through
the same menu.

Until `migrate` has run, the Kali entries name a kernel version (`/vmlinuz-<version>`,
`/initrd.img-<version>`). Once apt installs a new kernel and removes the old one, they point at
files that no longer exist. That is the problem `migrate` solves.

## How it works

Debian's own tooling can keep the menu stable. With `link_in_boot = yes` in
`/etc/kernel-img.conf`, every kernel install and removal updates relative links in `/boot`:
`vmlinuz` and `initrd.img` point at the newest kernel, `vmlinuz.old` and `initrd.img.old` at
the previous one. `migrate` moves the Kali entries into a file of their own that boots those
links and changes the stick's menu once, through a safe writer that keeps backups, or exports
the files for Windows to copy. From then on apt does the kernel housekeeping, and a kernel
install or removal changes nothing on the stick's partition 1.
[docs/migration.md](docs/migration.md) walks through the switch.

The rest of the tool:

- Once `boot_fs_uuid` is set, guard hooks refuse a kernel install or removal while the
  encrypted `/boot` is not mounted, and apt-guard refuses such an apt run before dpkg starts.
- `check` reports the state of the system and the stick. Its tripwire compares the stick's
  boot code with the baseline that `baseline` records.
- `lint` finds errors in GRUB configs that GRUB reports only at boot.
- `cleanup` purges the old kernels apt's autoremove names and the config files removed kernels
  left, and removes or quarantines the module trees no package owns. See [cleanup](#cleanup).

The commands that change the system, `baseline`, `migrate` and `cleanup`, run as root under the
tool's lock, print a plan and ask before they carry it out, and change nothing with
`--dry-run`.

## Usage

The tool is `bin/kernel-updater`. Run it from a checkout, or install it, together
with its hooks, with `install.sh` (see [Installing](#installing)). It needs Bash 4.4 or later,
GNU coreutils and awk; `grub-script-check` (Debian package `grub-common`) adds a syntax check
to `lint`. `check` and the hooks also read the system through `findmnt`, `lsblk` and `blkid`
(util-linux), `mount` and `umount` (Debian package `mount`), `dpkg-query`, `linux-version`
(linux-base), `cryptsetup`, `dumpe2fs`, `lsinitramfs` and `debconf-show`, which a Kali install
has. `check` and `baseline` mount the stick's partition 1 read-only: FAT with the kernel's
`vfat` driver, NTFS with `ntfs3`, or with `ntfs-3g` (Debian package `ntfs-3g`). Writing it,
which only `migrate` does, needs on NTFS `ntfs3` and `ntfs-3g.probe`, from the same package,
and on FAT `vfat` and `migrate --write-fat` under VMware; `systemd-detect-virt` tells the
writer whether it runs in a VM, and which, and `check` which hypervisor runs it. `migrate` also runs `linux-update-symlinks` (linux-base),
`debconf-set-selections` and, for the new menu, `grub-script-check`, which it needs. `cleanup`
runs `apt-get` and `apt-mark` (apt), `dpkg-query`, and `dkms` when it is installed; it moves a
module tree into its quarantine only with GNU `mv` from coreutils 9.2 on, whose `--no-copy`
keeps a move from turning into a copy, and with an older `mv` only lists such a tree.

```text
kernel-updater [OPTIONS] COMMAND [ARGS]
```

| Command | Does |
|---|---|
| `check` | Reports, as root and without changing anything, whether the system keeps the Kali entries bootable: `/boot`, its links and LUKS container, the kernel packages and their initrds, fstab, crypttab and grub-pc, then the stick's partition 1. See [check](#check) |
| `baseline` | Records, as root, the SHA-256 of the stick's boot code, which check's tripwire compares with; `--show` compares without recording. See [baseline](#baseline) |
| `migrate` | Moves, once and as root, the Kali entries onto the links linux-base keeps in `/boot`, in stages that each back up what they change; `--rollback` undoes them. See [migrate](#migrate) and [docs/migration.md](docs/migration.md) |
| `cleanup` | Purges, as root and after one question, what old kernels leave behind, never the running kernel or one the links in `/boot` point at: in one `apt-get purge`, the config files removed kernels left and the old kernels apt's autoremove names; then removes or moves into a quarantine the module trees no package owns, and deletes quarantined trees once they expire. See [cleanup](#cleanup) and [docs/runbook.md](docs/runbook.md) |
| `lint FILE...` | Checks GRUB configs for errors GRUB reports only at boot: syntax errors, unknown commands and modules, malformed or misused LUKS and filesystem UUIDs, kernel parameters that do nothing, drives named as `(hdN,...)`, and encrypted entries between MultiBootUSB's `#start` and `#end` markers. Findings name the kind of identifier, never its value |
| `hook NAME ARGS...` | Runs a hook for the files `install.sh` puts in `/etc/kernel` and `/etc/apt`, not by hand. See [Hooks](#hooks) |
| `help`, `version` | Print the usage or the version |

`lint` takes `--floor VERSION`, the oldest GRUB the files must run on: 2.02 (the default),
2.06, 2.12 or 2.14. Below 2.12, LUKS UUIDs written with dashes are errors, because older GRUB
never matches them. `--grub-dir DIR` takes the command and module names from a stick's own
`command.lst` and `moddep.lst`, `--strict` fails on warnings too, and `--porcelain` prints
tab-separated fields.

Global options: `-c`/`--config FILE`, `-n`/`--dry-run`, `-y`/`--yes`, `-v`/`--verbose`,
`-q`/`--quiet`, `--porcelain`, `-h`/`--help` and `-V`/`--version`. Results go to stdout and
messages to stderr.

| Exit code | Meaning |
|---|---|
| 0 | Success |
| 1 | Unexpected error |
| 2 | Findings: `lint` found an error or a `check` item failed, or either warned with `--strict`; the postinst hook found a kernel that may not boot |
| 3 | Refused before a change: a check failed, apt-guard refused an apt run, a guard hook refused a kernel install, removal or configure (by the time a configure is refused, the kernel's postinst has moved the links), the writer found a file on partition 1 reached through a symlink, or on a path other users can change, a `migrate` stage refused, needs another stage first, or found a backup that does not match its `MANIFEST`, or `cleanup` refused: a check before its plan failed, apt's simulation failed, would install or configure a package or would remove other packages than planned, `dpkg-query` failed before anything changed, or apt or apt-guard refused the purge before dpkg changed anything |
| 4 | A write failed. The message says what that left: nothing changed, the previous state put back, a backup to copy back or a file to remove by hand, the files written before it, or an `output_dir` that holds no complete export, so that the export must run again. For `cleanup`, a purge that stopped after dpkg began to change its database, a check of the links and kernels that fails after the purge, or a module tree or quarantine entry that could not be removed, moved or deleted: the message says what is done and what is left |
| 10 | Declined, or no terminal to confirm on without `--yes` |
| 64 | Usage error |
| 66 | An input file cannot be read, `/boot` is not mounted for `migrate` or `cleanup` or the LUKS header of its container cannot be read, the stick's partition 1 cannot be found or read, or `migrate --rollback` finds no backup |
| 75 | Busy: another run holds the lock, or, for `cleanup`, apt or dpkg holds its lock, named by PID and command; or the system changed while the question of `cleanup` or of `migrate`'s system stage waited, as when apt ran meanwhile, so that its plan no longer holds; or a file on partition 1 changed, or appeared where there was none, after the plan of a `migrate` stage or rollback read it and before the writer wrote anything. Nothing was changed: run it again once the other run is done |
| 77 | Not run as root |
| 78 | Bad configuration, a stick other than the one `disk_ptuuid` and `p1_fs_uuid` name, or for `migrate` and `cleanup` a `/boot` or LUKS container other than the configuration names |
| 128+N | Interrupted by signal N |

### Installing

```bash
sudo ./install.sh
```

`install.sh` copies the tool from the checkout to `/usr/local/lib/kernel-updater`,
`/usr/local/share/kernel-updater` and `/usr/local/bin/kernel-updater`, the kernel hooks to
`/etc/kernel/{preinst,prerm,postinst}.d` and last apt-guard's configuration to
`/etc/apt/apt.conf.d/50kernel-updater`, and lists every file with its SHA-256 in
`/var/lib/kernel-updater/install.manifest`. Run it again after updating the checkout: it
replaces what changed and removes the files the checkout no longer has. Before it changes a
file, the manifest lists both its old and its new contents, so a run cut short can be run
again or undone with `--uninstall`. It refuses with exit 3, before changing anything, when a
file in its way was not installed by it or has changed since; move that file away and run it
again. `--dry-run` (`-n`) prints what would change, and
`--uninstall` removes every file the manifest lists, the APT configuration first. It leaves
alone `/etc/kernel-updater.conf`, `migrate`'s backups in `/var/backups/kernel-updater` and what
`/var/lib/kernel-updater` holds besides the manifest: the baseline and `cleanup`'s quarantine,
whose module trees stay whole. It needs root (exit 77 otherwise) and takes the tool's lock
(exit 75 while another run holds it).

The hooks only warn until `boot_fs_uuid` is set, and `install.sh` says so while it is not. To
arm them, mount `/boot`, copy the example config and set `boot_fs_uuid` in it to the UUID that
`findmnt` prints:

```bash
sudo install -m 0644 examples/kernel-updater.conf /etc/kernel-updater.conf
findmnt -n -o UUID /boot
```

Then `sudo kernel-updater check` should report `boot-identity` as `ok`. `check` also looks at
the stick's partition 1; to have it check that partition 1 is the stick's, set `disk_ptuuid`
and `p1_fs_uuid` to the PTUUID of the stick and the UUID of its partition labelled BOOT, then
record the baseline of its boot code:

```bash
sudo lsblk -o NAME,LABEL,PTUUID,UUID
sudo kernel-updater baseline
```

### check

```text
kernel-updater check [--strict] [--no-partition] [--porcelain]
```

`check` must run as root and exits 77 otherwise. It changes nothing: to look under the `/boot`
mount point it bind-mounts `/` read-only on a private directory in `/run`, never in `TMPDIR`,
and removes that mount before it exits, lazily when it is busy, and also when `check` is
interrupted. Each item is `ok`, `warn`, `fail` or `skip`, the last when it does not apply, such
as the `/boot` items while `/boot` is not mounted. `boot-links`, `stale-root-links` and
`reboot-pending` apply only while `/etc/kernel-img.conf` keeps the links in `/boot`.
`boot-luks` and `boot-ext` judge `/boot` by the GRUB that `grub_floor` names, 2.02 by default.

The last seven items look at the stick's partition 1 (see [Partition 1](#partition-1)).
`check` reads it through `p1_path` while that serves, through a mount that is there, or else
through a read-only mount of its own on a private directory in `/run`, which it removes before
it exits, also when interrupted. The six after `p1-identity` skip, saying why, when partition 1
cannot be found from `/boot`, is another than the configuration names, or cannot be read;
another partition 1 is never read. `--no-partition` skips all seven and leaves partition 1
alone.

| Item | Checks |
|---|---|
| `boot-mounted` | `/boot` is a mount point of its own; fails when it is not |
| `boot-identity` | The filesystem at `/boot` and its LUKS container are the ones `boot_fs_uuid` and `boot_luks_uuid` name; fails on another one or when `cryptsetup` cannot read the container, and warns while `boot_fs_uuid` is not set |
| `boot-shadowed` | Nothing hides under the `/boot` mount point, such as a kernel installed while `/boot` was not mounted; warns with the number of entries, and fails when the bind mount it looks through cannot be removed |
| `kernel-img` | `/etc/kernel-img.conf` has linux-base keep the links in `/boot` (`link_in_boot = yes`); warns while it does not, or while `do_symlinks` is off |
| `boot-links` | `vmlinuz`, `vmlinuz.old`, `initrd.img` and `initrd.img.old` in `/boot` are relative links that reach non-empty files in `/boot`; fails otherwise |
| `stale-root-links` | No `vmlinuz*` or `initrd.img*` entries are left in `/`, where no kernel install updates them any more; warns about them |
| `kernels` | No kernel package is stuck between states (fails, naming `dpkg --configure -a` as the remedy) and the running kernel is installed (fails otherwise). Kernels removed with their config files left warn, a version counting as removed only when all its packages are; held ones are counted |
| `reboot-pending` | The running kernel is the one `/boot/vmlinuz` points at; warns otherwise |
| `initrd` | The initrd of each installed kernel exists, `lsinitramfs` reads it, and it holds the kernel's modules, `cryptsetup` and the cryptroot configuration, and key files when `/etc/crypttab` names one; fails otherwise, and warns when an initrd with key files is readable by group or others |
| `boot-luks` | `/boot` is in a LUKS container the GRUB of `grub_floor` unlocks: LUKS1 for 2.02, LUKS1 or LUKS2 from 2.06 on, with PBKDF2 keyslots, and from 2.14 on Argon2 keyslots too; fails otherwise, and when `cryptsetup` is not installed |
| `boot-ext` | The ext filesystem at `/boot` has no incompatible feature the GRUB of `grub_floor` refuses: 2.02 reads `filetype`, `extent`, `flex_bg`, `meta_bg` and `64bit` and ignores `needs_recovery` and `mmp`, 2.06 also reads `encrypt`, and 2.12 also ignores `metadata_csum_seed` and `large_dir`. Fails on any other, such as `inline_data` or `casefold` |
| `fstab-crypttab` | `/etc/fstab` and `/etc/crypttab` name devices by `UUID=` or another name that stays; warns on kernel names such as `/dev/sdX` and on `/dev/disk/by-path` and `/dev/disk/by-id` names, which change with the port or in a VM |
| `grub-pc` | The debconf answer `grub-pc/install_devices` is empty, so a grub-pc upgrade cannot write GRUB over the stick's boot loader; fails while it names a device |
| `p1-identity` | Partition 1, found from `/boot`, is the FAT or NTFS filesystem `p1_fs_uuid` names, on the disk `disk_ptuuid` names; fails when it is another, naming the disk or partition 1 but no value, also when only one of the keys is set and names another, and, with both keys set, when it cannot be found; skips otherwise while either key is not set |
| `grub-version` | The stick's GRUB, whose version `multibootusb/grub/i386-pc/normal.mod` holds, is at least as new as `grub_floor`, or lint and check would trust features it lacks; fails when it is older, warns when its version is unknown, and names the higher floor a newer GRUB allows |
| `tripwire` | The stick's boot code matches the baseline `kernel-updater baseline` recorded: the files `share/kernel-updater/baseline.list` names, the MBR boot code and partition 1's boot sector; fails naming what changed, is new or is missing, a file that is or passes a symlink counting as missing, and warns while no baseline is stored |
| `deployed` | The files exported to `output_dir` match those on partition 1, as its `SHA256SUMS` lists them; fails naming each one that differs or is missing, and skips while nothing was exported. Copy the export only when you have not yet: copied again after the stick changed, it would undo that change |
| `kali-cfg` | `multibootusb/grub/kali.cfg`, which the menu stage of `migrate` writes, passes `lint` with the stick's own command and module lists; fails on errors and when it or a directory on its way is a symlink, warns on warnings, and skips while the file does not exist |
| `kali-menu` | `grub.cfg` holds the block `migrate` writes, which sources `kali.cfg`, and `kali.cfg` exists; skips while neither is there, before the migration, warns while the legacy Kali entries remain (until `migrate --stage finalize`), and fails when only one of the block and `kali.cfg` is there, as after a rollback of the menu stage until `kali.cfg` is deleted or the stage runs again, or when `grub.cfg` or a directory on its way is a symlink |
| `boot-menu` | Which menu booted the running kernel, and which hypervisor runs this system, as `systemd-detect-virt` names it (`none` on bare metal): counts the `linux` lines that end with the kernel's command line, as GRUB passed it without `BOOT_IMAGE=`, in the stick's `grub.cfg` and `kali.cfg` and in this system's `/boot/grub/grub.cfg`, whatever blanks and line endings they have. Only reports, so it is `ok`, or skips when `/proc/cmdline` holds nothing beside `BOOT_IMAGE=`, or a file of the stick's menu cannot be read or is a symlink. `migrate --write-fat` writes a FAT partition 1 only when this says that the stick's menu booted it |

Results go to stdout as aligned `STATUS ITEM DETAIL` lines, or with `--porcelain` as
`ITEM<TAB>STATUS<TAB>DETAIL`, and a summary goes to stderr. Details name kinds and counts,
never a disk identifier, device name or key file. `check` exits 0 unless an item fails, and 2
when one does or, with `--strict`, when one warns.

### baseline

```text
kernel-updater baseline [--show] [--yes] [--dry-run] [--porcelain]
```

`baseline` records the SHA-256 of the stick's boot code in `/var/lib/kernel-updater/baseline`
(directory mode 0700, file mode 0600, written through a temporary file and a rename): every
file on partition 1 that `share/kernel-updater/baseline.list` names, such as the boot menus,
GRUB's core image and modules and syslinux's files, plus the MBR boot code (bytes 0 to 439 of
the disk, `mbr:boot-code`) and partition 1's boot sector (its first 512 bytes, where syslinux
keeps its own code, `p1:boot-sector`). In a FAT boot sector the flags byte counts as 0: Linux
and Windows mark it on every mount, and an unplug without an eject leaves the mark, which says
nothing about the boot code. On FAT the globs of `baseline.list` match names in any case, as an
old FAT tool may store them in capitals. Files that do not exist are not recorded. check's
`tripwire` then fails when any of them changes, so record the baseline anew after you change
the stick on purpose.

It runs as root (77 otherwise) and takes the tool's lock (75). It finds partition 1 from
`/boot` and refuses with 78, before it reads anything, while `disk_ptuuid` or `p1_fs_uuid` is
not set or names another stick; it exits 66 when partition 1 cannot be found or read. It reads
partition 1 read-only, prints how it differs from the stored baseline (`same` with a count,
then each `changed`, `new` and `missing` entry, or `baseline none` when none is stored), and
asks before it records the new one: `--yes` answers for you, a declined or unanswered question
exits 10, and `--dry-run` records nothing. When nothing changed since the stored baseline, it
says so and asks nothing.

`--show` changes nothing and exits 0. It prints whether the disk and partition 1 match the
configuration: `match`, `mismatch` or `not configured`, never a value, or `not found` when
partition 1 cannot be found from `/boot`. Then the version of the stick's GRUB, or `unknown`,
and the comparison with the stored baseline, or `baseline` with `none`, `damaged` or
`not compared` when there is nothing to compare. A partition 1 that mismatches is not read at
all. `--porcelain` prints the lines as `KEY<TAB>VALUE`.

### migrate

```text
kernel-updater migrate [--stage STAGE] [--deploy MODE] [--output-dir DIR] [--write-fat] [-n] [-y]
kernel-updater migrate --rollback [STAMP] [--write-fat] [-n] [-y]
```

`migrate` makes the one-time switch to the link-based menu: afterwards a kernel install or
removal changes nothing on partition 1, since the Kali entries boot `/vmlinuz` and
`/initrd.img`, which linux-base points at the newest kernel, and `/vmlinuz.old` and
`/initrd.img.old`, at the previous one. [docs/migration.md](docs/migration.md) walks through
it, with the tests to make between the stages. It runs as root (77) under the tool's lock
(75), a dry run too. Each stage prints its plan on stderr and asks once (10 when declined;
`--yes` answers), changes nothing with `-n`, and says so and exits 0 when its result is in
place already; a stage whose predecessor is not done exits 3, naming the stage to run first.
Messages name kinds and counts, never an identifier; the root device shows as
`root=<root_device>`, and a kernel parameter that may name a device, a UUID, a label or a key
file as `NAME=<value>`.

| Stage | Does |
|---|---|
| `detect` | Appends to `/etc/kernel-updater.conf`, under a comment line, what it lacks of `boot_fs_uuid`, `boot_luks_uuid`, `disk_ptuuid`, `p1_fs_uuid` and `root_device`, read from the mount of `/boot`, its LUKS container, the stick found from `/boot` and the running kernel's command line, and `grub_floor` from the stick's GRUB when the file sets none. A key the file sets to another value exits 78, naming the key. The file is written through a temporary file renamed over it and keeps every other line. Setting `boot_fs_uuid` arms the hooks |
| `system` | Needs the identity in place (78 otherwise) and refuses (3) while check's `boot-luks`, `boot-ext` or `kernels` item fails, no installed kernel would boot (a non-empty `vmlinuz` and an initrd that passes the postinst check), only one would while `/boot` holds another kernel's image, from which `linux-update-symlinks` would take the `.old` links, or one of the four link names in `/boot` is no symlink. It backs up `/etc/kernel-img.conf` and the links in `/`, sets `do_symlinks = yes` and `link_in_boot = yes`, keeping every other line, has `linux-update-symlinks` point the links in `/boot` at the newest kernel and the `.old` ones at the previous one (the running kernel when it is an older one), moves the old links out of `/` into the backup, asks on its own whether to empty grub-pc's install devices, and exits 4 unless the four links come out relative, reach their files and point at those two kernels, and `kernel-img.conf` has linux-base keep them in `/boot`. Links already on the newest kernel and on another one that would boot stay as they are. When the kernels or the links change while its question waits, as when apt installs a kernel meanwhile, it exits 75 before changing anything, since its plan no longer holds; run it again once apt is done |
| `menu` | Needs `system` done, `grub-script-check` and a partition 1 it may reach (66). It finds the one top-level submenu of `grub.cfg` whose quoted title holds Kali (3 for none, several, one between MultiBootUSB's `#start` and `#end` markers, or one that shares a line with other commands), takes each variant's kernel parameters from its entries (dropping `root=`, `cryptdevice=`, `BOOT_IMAGE=` and `initrd=`, turning `noswap` into `systemd.swap=0` and overlayroot's `resurce=` into `recurse=`), renders `multibootusb/grub/kali.cfg` from `share/kernel-updater/kali.cfg.in`, and replaces the submenu in `grub.cfg` with a block that sources `kali.cfg`, the submenu following as "... (legacy entries)". Every byte outside the submenu must come through (3 otherwise), both files must pass `grub-script-check` and `kali.cfg` `lint` with the stick's own command and module lists, or GRUB 2.02's when those cannot be read; then it backs up both, writes `kali.cfg` before `grub.cfg` with the safe writer and updates their baseline entries, or exports both. A file that differed from a stored baseline before the write keeps its old entry, so that check's tripwire keeps reporting a change made outside the tool, as from Windows, until `kernel-updater baseline` records it; the plan and a warning name it. Run again while the legacy entries remain, it leaves `grub.cfg` as it is and writes `kali.cfg` alone anew from them when it is missing or differs, as after `menu_variants` changed, with a backup of its own |
| `finalize` | Needs `menu` done. Removes the legacy submenu from `grub.cfg` and nothing else, after a question that asks for the boot tests first, and writes it or exports it. After a write it sets `grub.cfg`'s entry in the stored baseline, unless `grub.cfg` differed from it before, and names, in a warning, the files that still differ from it, which `kernel-updater baseline` then shows and records once checked; it records the whole baseline only when none is stored. A rollback that writes `grub.cfg` or `kali.cfg` treats their entries as `menu` does |
| `all` | The default: `detect`, `system` and `menu` in turn. A dry run stops after the first stage that would change something, as the later plans build on it. `finalize` never runs with them |

`--write-fat` lets this run write a FAT partition 1, which every run without it exports, and
only as the Partition 1 section below says: under VMware, when the stick's menu booted the
running kernel, the volume was left clean, and you answer `y` to its question whether Windows
no longer has BOOT, which `--yes` does not answer. Otherwise it refuses (3), or exits 10 on any
other answer, and writes nothing. On NTFS it changes nothing and says so.
[docs/migration.md](docs/migration.md#writing-a-fat-partition-1-from-the-vm) lists what to do in
Windows before and after.
`--deploy` and `--output-dir` stand in for `deploy` and `output_dir` for one run; an export
that `--output-dir` takes elsewhere than the configured `output_dir` gets a warning, since
check's `deployed` item and later runs read only that one. A write of `menu`, `finalize` or a
rollback to partition 1 removes an export in `output_dir` that lists other contents for the
files it wrote, since that export, copied afterwards, would undo the write. Each run of
`system`, `menu` and `finalize` keeps what it changes in `/var/backups/kernel-updater/STAMP`
(mode 0700), with a `MANIFEST` of SHA-256 sums, and syncs it to disk before it changes
anything. `STAMP` is the UTC time of the run, or one second after the newest backup there
when the clock reads no later, as for two runs in one second or a native boot that takes
Windows' local time for UTC, so that the names keep the order the runs happened in. A backup
that cannot be written whole is removed again, or renamed to `STAMP.failed`, and so is one a
kill or crash left without a `MANIFEST` once `--rollback` comes across it.
`--rollback [STAMP]` undoes the newest run not rolled back yet, which `STAMP` must name when
given, since stages undo in the reverse order they ran: it refuses (3) a backup that does not
match its `MANIFEST` or holds anything else, puts back `/etc/kernel-img.conf` and the links
moved out of `/` for `system`, `grub.cfg` for `menu` and `finalize`, and `kali.cfg` for a run
of `menu` that wrote it alone, then renames the directory to `STAMP.rolled-back`. The links in
`/boot`, grub-pc's answer as `system` left it, and `kali.cfg` after a `menu` run stay. When
`grub.cfg` changed after the run wrote it, as when MultiBootUSB added an ISO, the plan and the
question say that the rollback drops those changes. In export mode a rollback exports the file
even when the stick holds it already, so that `output_dir` no longer holds the stage's own
export. The rollback of `menu` refuses (3) once `/boot` holds none of the kernels the old Kali
entries boot, and that of a `system` run whose `kernel-img.conf` put back would stop linux-base
from keeping the links in `/boot` refuses while partition 1's `grub.cfg` still sources
`kali.cfg`, as before Windows copied the `grub.cfg` a rollback of `menu` exported.

### cleanup

```text
kernel-updater cleanup [--no-rc] [--no-autoremove] [--no-modules] [-n] [-y] [--porcelain]
```

`cleanup` purges what old kernels leave behind, in one `apt-get purge` run after one question:
the config files of kernel packages that were removed but not purged, and the old kernels apt's
autoremove names. Then it removes or moves aside the module trees no package owns, and deletes
the quarantined trees that expired. Purged packages cannot be rolled back, so read the plan with
`-n` first. It refuses until `migrate --stage finalize` is done: until then the legacy entries,
and a rollback of the menu stage, boot kernels by their versions.
[docs/runbook.md](docs/runbook.md) says when to run it and what to do when it refuses.

`--no-rc` leaves the config files of removed kernels alone, `--no-autoremove` the old kernels
apt's autoremove names, and `--no-modules` the module trees and the quarantine. `-n` prints the
plan and changes nothing, not even a quarantine entry's `seen`, and `-y` answers the question.

It runs as root (77) under the tool's lock (75), a dry run too, and first checks that it may
run: `boot_fs_uuid` and `boot_luks_uuid` must be set (3 otherwise, naming
`migrate --stage detect`); `/boot` must be mounted with a LUKS header that can be read (66),
and be the filesystem and container they name (78); `apt-get`, `apt-mark` and `dpkg-query` must
be installed (3); neither apt nor dpkg may hold its lock (75, naming the process by its PID and
command, which it finds in `/proc/locks`, since apt and dpkg lock with `fcntl`, which `flock`
cannot test); `/etc/kernel-img.conf` must have linux-base keep the links in `/boot`, relative
and reaching the kernels' files (3, naming `migrate --stage system`); check's `kernels` item
must pass, so that no kernel package is stuck between states and the running kernel is
installed (3); no interrupted dpkg run may wait for `dpkg --configure -a` (3); and check's
`kali-menu` item must be `ok`, read read-only from a partition 1 whose files no user but root
can change, before the question and again after it (3 while it is not, naming an export that
waits to be copied, and also while an export, as from a rollback in a VM, waits to bring back
entries that boot kernels by version; 66 when partition 1 cannot be found or read so, as while
a desktop has it mounted for its user; 78 on another stick or one the configuration does not
name).

- **What it keeps.** The running kernel's release and the releases the four links in `/boot`
  point at: no package named for them is purged and no module tree of theirs is touched,
  whatever apt says. Of what apt's autoremove names, neither is a package that shares its
  version with an installed package of theirs, as the headers the kernels of one ABI share do.
  While a reboot is pending, as after
  a kernel install, when the kernel `/boot/vmlinuz` points at is not the one running, it purges
  nothing and says to reboot first; the module trees and the quarantine are still looked after.
- **What it purges.** Of the kernel packages removed with their config files left (`rc` in
  `dpkg -l`), the images, binaries, modules, bases and headers of releases it does not keep;
  held ones, those of kept releases and those whose release is still installed through another
  package, as when `linux-image-V-unsigned` replaced `linux-image-V`, are skipped, and debug
  builds and the headers and build tools an ABI's kernels share are only listed. Of what apt's
  autoremove names, as its simulation of `apt-get autoremove --purge` shows, the versioned
  kernel packages of releases it does not keep, shared headers and build tools included; held
  ones are skipped, and debug builds and anything else, metapackages included, are only
  listed. apt never names an old kernel marked manual, which the plan lists with the hint
  `apt-mark auto PACKAGE`.
- **Only the planned set.** A simulation of the purge, with the options of the real one, must
  remove exactly the planned packages and install or configure none. Otherwise it refuses with
  3 and names what apt would also remove, or would not, such as a metapackage or a DKMS package
  that depends on an old kernel's headers. After the question it plans and simulates again and
  checks the locks, dpkg's status, apt's auto marks and the links anew: when any of them
  changed, as when apt ran meanwhile, it exits 75 and changes nothing. The purge runs as
  `apt-get -y -q -o DPkg::Lock::Timeout=0 -o APT::Get::AutomaticRemove=false
  -o APT::Get::AutomaticRemove::Kernels=false purge PACKAGE...`, with apt's output on stderr,
  and the tools cleanup runs inherit no `DPKG_ROOT`, `DPKG_ADMINDIR`, `DPKG_FORCE`,
  `APT_CONFIG`, `DPKG_FRONTEND_LOCKED` or `SOURCE_DATE_EPOCH`. It runs no `apt-get autoremove`,
  force option, `dkms remove`, `update-initramfs` or `update-grub` of its own; the purged
  packages' own scripts run as in any apt run.
- **A purge that fails** exits 4 once dpkg began to change its database, naming
  `dpkg --configure -a` and `kernel-updater check`; 75 while apt or dpkg holds its lock; and 3
  otherwise, as when apt-guard refused it. One that a signal cuts short, as Ctrl-C or a closed
  terminal does, says "the purge was cut short after dpkg began to change its database: run
  'dpkg --configure -a', then 'kernel-updater check'", or that nothing was purged, and exits
  128+N. After the purge, check's `boot-links` and `kernels` items must pass, or it exits 4 and
  leaves the module trees alone.
- **Module trees.** A tree in `/usr/lib/modules`, and in `/lib/modules` when `/usr` is not
  merged, that belongs to no installed kernel stays, and the plan says why, while `dpkg-query -S`
  finds a package that owns it or files in it under either path, dpkg lists a package named for
  its release in any state but not installed, its release is kept, `/boot` holds a file of that
  release, it holds `.fresh-install`, or `dkms status` lists modules for it, for which the plan
  names the `dkms remove` command. Any other tree is removed with `rmdir` when it is empty, and
  otherwise moved into the quarantine. The tree of a release this run purges packages of waits
  for the next run. Right before it removes or moves a tree, cleanup checks the locks and each
  reason again, and leaves the tree, with a warning, when one holds now.
- **The quarantine.** A tree moves to `/var/lib/kernel-updater/quarantine/RELEASE.STAMP/tree`,
  `STAMP` being the UTC time as `YYYYmmddTHHMMSSZ`, in one rename with `mv --no-copy -T`,
  beside an `origin` file written first, which names the path it came from, the release, the
  stamp, why it moved, the SHA-256 of dpkg's status file and the tool's version. The quarantine
  and each entry are directories of root's with mode 0700. A tree is only listed, so that no
  tree is ever copied, when it lies on another filesystem than the quarantine, when `mv` is
  older than coreutils 9.2, or when a symlink leads to the quarantine, it is no directory of
  root's with mode 0700, or a user other than root can change the directory that holds it.
  `sudo mv -T ENTRY/tree PATH`, `PATH` being the path `origin` names, moves a tree back while
  nothing is there; one that no package owns then goes into the quarantine again on the next
  run. [docs/runbook.md](docs/runbook.md) has the steps.
- **Expiry.** The first run that finds an entry, unless it is a dry run, writes its own time
  into a `seen` file there. Once more than `quarantine_days` whole days, 30 by default, have
  passed since the newer of the entry's stamp and its `seen`, a run deletes it after the
  question: its tree with `rm -r --one-file-system`, then `origin` and `seen`, then the entry
  with `rmdir`, skipping a part it lacks. So no entry expires in the run that made it or in the
  first run that finds it, and none expires while the clock reads earlier than any entry was
  made or seen, which the run warns about; the plan shows each entry's age. An entry of another
  name, kind, owner or filesystem, or one that holds anything else, is only listed, and so is
  the whole quarantine when a symlink leads to it or it is no directory of root's with mode
  0700. `quarantine_days = 0` keeps every entry. Expiry is the only step that deletes a module
  tree.
- **The plan** goes to stderr before the question, whatever the verbosity: the releases kept,
  then each package, module tree and quarantine entry with what happens to it and why, then
  `sync`. With `--porcelain` its records also go to stdout as
  `STEP<TAB>ACTION<TAB>OBJECT<TAB>DETAIL` lines, `STEP` being `protect`, `rc`, `autoremove`,
  `modules` or `expire` and `ACTION` `keep`, `purge`, `list`, `skip`, `rmdir`, `quarantine` or
  `delete`, but only once the run ends with 0, so that a run that fails, is declined or is cut
  short leaves stdout empty.

A step that stops partway exits 4 and says what is done and what is left; a re-check that keeps
a planned tree or entry only warns, and the run exits 0. `sync` runs before the last line, which
says what the run did, and on any other exit once the run began to change the system. Messages
and records name packages, releases and paths, never a disk identifier.

### Partition 1

The tool finds and reaches the stick's partition 1, the FAT or NTFS partition labelled BOOT
that holds MultiBootUSB, so that `migrate` can write its menu there safely; only `migrate`
writes it. A FAT partition 1 is written only by a run with `--write-fat` that passes every
check below; every other stage that would write it leaves its files in `output_dir` for
Windows to copy, and says why.

- **Finding it.** The tool never trusts a `/dev/sdX` or `/dev/disk/by-id` name, which change
  with the port and in a VM. It starts from the filesystem mounted at `/boot`, walks up with
  `lsblk -s` through the LUKS mapping to the one disk under it, refusing none or several, and
  takes that disk's partition 1. `blkid -p` reads what `lsblk` leaves empty without udev.
- **Telling it apart.** The disk's PTUUID must be `disk_ptuuid` and partition 1 must be FAT
  (`vfat`) or NTFS with the serial `p1_fs_uuid`. A VM that has the whole stick attached, as
  through a raw-disk VMDK, shows the same identifiers, so both checks hold natively and in such a VM. Messages
  say which part differs, never a value.
- **Reaching it.** A reader, which only hashes and lints what it reads, takes `p1_path` while
  it serves: while it is a mount point that holds `multibootusb/grub/grub.cfg` and, when
  partition 1 can be read, the same `grub.cfg` as partition 1, so that neither the empty mount
  point of a share that is not mounted, as on a native boot, nor another stick's share passes
  for it. Otherwise it takes a mount of partition 1 that is there, and else mounts it
  read-only on a private directory in `/run` with `nosuid,nodev,noexec`: FAT with `vfat` and
  `uid=0,gid=0,umask=077`, as FAT keeps no owners, and NTFS trying `ntfs3`, then `ntfs-3g`,
  which gets `norecover`. A read-only mount writes nothing with any of them. Readers
  follow no symlink on partition 1, which Windows or a user who owns a mount of it could have
  made: a file that is or passes one counts as missing to the tripwire and to the `deployed`
  item, its GRUB version as unknown, and `kali-cfg` fails.
- **Writing FAT.** FAT has no journal, and in the VM Windows may have the volume mounted on
  the host at the same time, which would corrupt it. So a FAT partition 1 is written only with
  `migrate --write-fat`, and only when all of these hold, or the run refuses (3) and writes
  nothing: `deploy` is `auto` or `direct`; nothing has partition 1 mounted; `systemd-detect-virt`
  names `vmware`; the running kernel's command line, without `BOOT_IMAGE=`, ends a `linux` line
  of the stick's `grub.cfg` or `kali.cfg` and none of `/boot/grub/grub.cfg`, so that the menu it
  writes is the one that booted it; and the volume was left clean: its boot sector is not
  marked dirty, and the FAT's entry 1 keeps the clean-shutdown bit, which Windows clears while
  it uses the volume, and the bit for no disk errors (FAT32 and FAT16; FAT12 is refused). The
  plan is read through a read-only mount of its own. VMware locks and dismounts BOOT in Windows
  while the VM runs; taken offline in Windows beforehand, it cannot, and Windows then refuses
  the VM's writes. Before the first write the run asks whether Windows no longer has BOOT, a
  y/N question that `--yes` does not answer, checks the volume once more, and mounts it read-write
  with `vfat` and `flush` in the same place. The writer below then syncs the filesystem after
  each step: the backup, the temporary file, the move aside, the rename and the removal of the
  old file. It reads each file back through a new read-only mount, so that the read comes from
  the stick and not from what `vfat` kept, and mounts it read-write again; a read-back that
  differs puts the old file back. A power loss between the move aside and the rename, a few
  milliseconds, leaves no `grub.cfg`; every other moment leaves the old or the new one, and a
  volume that `chkdsk` finds in order but for the dirty mark and the count of free clusters,
  which it recounts.
- **Writing it.** On NTFS a writer goes the same way as a reader, but takes `p1_path` only with
  `deploy = path`, and a mount that is there only while it is read-write; both only while no user but root can
  change their files, which rules out the mount a desktop makes for its user, since such a
  user could swap a file for a symlink while root writes. A mount of partition 1, or the share
  at `p1_path`, serves a writer only while it is mounted nowhere else, as mounts of one
  filesystem share their files, and the writer gives up a mount of its own that another one
  joined meanwhile, or whose root shows another owner than root. A read-write mount of its own
  is never forced, never removes the hibernation file and never clears the log Windows left:
  `ntfs3` replays that log on any read-write mount and has no option to refuse, so it waits
  until `ntfs-3g.probe --readwrite` finds partition 1 neither hibernated, nor kept in Windows'
  cache for Fast Startup, nor unclean; then it takes `ntfs3` alone, which refuses a volume
  marked dirty, as Windows marks one it wants to check, while `ntfs-3g` would mount that one
  read-write all the same. It checks that the mount is read-write. A read-write mount that
  root made itself took the volume as it was, so the writer takes it as it is. A dry run
  mounts read-only and does not probe.
- **Deploying.** Without `--write-fat`, every mode exports a FAT partition 1's files: `auto`
  says so as info, and `direct` and `path` warn. In a VM, where Windows may have partition 1 mounted on the host,
  the guest never writes partition 1 itself: `deploy = auto` and `direct` export there, and only `path`
  writes, through the host's share. Natively, `auto` and `direct` write directly. `direct` and
  `path` fall back to an export, saying why, when they get no root they may write, as when
  their own read-write mount finds partition 1 hibernated, unclean or marked dirty, or the
  kernel has no `ntfs3`; `path`, and a read-write mount that root made, are written as they
  are. What a plan reads from
  partition 1 to build the new files comes only from a root no user but root can change, for
  an export too: while a desktop has partition 1 mounted for its user there is none, and the
  tool asks you to unmount it there and run again.
- **The safe writer** replaces one file at a time: it exits 75 when the file changed since the
  plan read it, or exists where the plan found none, as a run that plans anew can then
  succeed, and refuses with exit 3 when a symlink lies on its way, or a user other than root
  could change a directory on its path; copies it to `NAME.ku-<UTC stamp>.bak` beside it and keeps
  that backup and the newest others, `backups_keep` in all, so that a clock that went back
  never costs the backup a restore needs; writes the new bytes, CRLF line endings and all, to
  a synced temporary file and puts that in the file's place without ever renaming over it,
  since `ntfs3` unlinks a file that a rename replaces before it renames, so that an error
  after that loses it: the file moves aside to a free name, `.NAME.ku-<UTC stamp>.old`, and
  the temporary file into the name then free; syncs the filesystem and reads the file back
  from the stick, past the pages the write left in memory, and then removes the file it moved
  aside. A file small enough for NTFS to keep inside its MFT record, some hundreds of bytes,
  `ntfs3` answers from memory all the same, so for such a file the read-back checks the write
  but not the stick. It follows no symlink, and removes its temporary file on every path. When
  the temporary file cannot be written or put in place, it exits 4 with the file unchanged or
  moved back, and when the read-back fails, it puts the old file back and exits 4, saying
  whether that worked. A run cut short between moving the file aside and renaming the new one
  into place moves it back as it exits; cut short later, before the read-back ended, it
  leaves the new file in place and says that the old one waits beside it under its aside
  name. When moving it back fails, the message names the backup to copy by hand, and the old
  file waits beside it under its aside name. Given several files, it runs the checks of every
  file before it writes the first, so that a file that changed (75), a symlink or a path other
  users can change (3) stops it before anything is written; a backup name taken within the same
  second shows only when its file's turn comes, and a later failure, a file that changed
  meanwhile included, exits 4 and names the files it wrote.
  `migrate` reads what it builds on with `ku_deploy_read`, which follows no symlink either,
  since one on partition 1 could lead root to a file such as the LUKS key, and records in the
  tripwire's baseline just the files it wrote, with `ku_baseline_update`.
- **The export** writes the files to `output_dir` (mode 0700, owned by root; refused with 78
  otherwise), with `SHA256SUMS` and `DEPLOY.txt`, which says to copy them to
  `BOOT:\multibootusb\grub\` from Windows and to run `sudo kernel-updater check`, whose
  `deployed` item then compares the stick with the export. It first removes the files of the
  earlier export that the new one lacks, so that none is left for Windows to copy.

### Hooks

`install.sh` installs four kernel hooks, which `linux-run-hooks` runs from the maintainer
scripts of every kernel package, and apt-guard, which APT runs before dpkg. They are armed
while `boot_fs_uuid` is set. Until then they run the same checks but only warn, so the tool
never blocks apt on a system it was not set up for. While armed:

| Hook | Runs | Refuses |
|---|---|---|
| `/etc/kernel/preinst.d/00-kernel-updater` | Before a kernel package is unpacked | The install while `/boot` is not mounted or another filesystem is; a new kernel ends not installed, and an upgrade or reinstall leaves the installed one as it was |
| `/etc/kernel/prerm.d/00-kernel-updater` | Before a kernel package is removed | The removal in the same case; the package stays installed |
| `/etc/kernel/postinst.d/00-kernel-updater` | When a kernel package is configured, before linux-base copies the kernel to `/boot` and initramfs-tools builds its initrd there | The configure in the same case; the package stays half-configured |
| `/etc/kernel/postinst.d/kernel-updater` | After initramfs-tools has built the initrd | A kernel whose `/boot/vmlinuz-VERSION` is missing or empty, whose initrd is missing, unreadable, or lacks its modules, `cryptsetup`, the cryptroot configuration or the key files `/etc/crypttab` names, or, with `link_in_boot = yes`, whose links in `/boot` are absolute or dangle. The package stays half-configured; with `verify_action = warn` the hook only warns |
| apt-guard, run through `/etc/apt/apt.conf.d/50kernel-updater` | Before dpkg, with the actions APT is about to take | An apt run that installs, removes or configures a versioned `linux-image`, `linux-binary`, `linux-modules` or `linux-base` package, `linux-base` or `initramfs-tools` while `/boot` is not the filesystem `boot_fs_uuid` names, or that unpacks or configures `grub-pc` while `grub-pc/install_devices` names a device. A refused run changes nothing |

apt-guard covers the split kernel packages, whose `linux-binary` part can be unpacked before
the `linux-image` preinst runs the hooks, and runs that only remove kernels. `cryptsetup`,
`dkms` and the other GRUB packages pass, and any run without the packages above passes at
once. While `apt-guard` is missing or not executable, the APT configuration lets every run
through. The kernel hooks back apt-guard up for `dpkg -i` and `dpkg --configure -a`, and let
everything through while `/usr/local/bin/kernel-updater` is missing. A kernel's own postinst
moves the links before any hook runs, so a configure refused while `/boot` is not mounted can
still leave links under the mount point (`check` reports them as `boot-shadowed`), and one
refused while another filesystem is mounted there moves the links on that filesystem.

A refusal says why and what to do: unlock and mount `/boot`; or, when another filesystem is
mounted there, mount the stick's `/boot` instead, or set `boot_fs_uuid` anew if `/boot` was
made anew; or mount `/proc` in a chroot, where `findmnt` cannot read the mount table. Then run
apt again, or `dpkg --configure -a` for a half-configured kernel. When a new kernel fails the
check with the links in `/boot`, `/boot/vmlinuz` and `/boot/initrd.img` already point at it:
until it passes, boot the previous kernel, which the `.old` links point at. Fix the cause,
rebuild its initrd with `update-initramfs -u -k VERSION`, then run `dpkg --configure -a`. The
messages name kinds, never a disk identifier or key file. To get past the hooks on purpose,
comment out `boot_fs_uuid`, which disarms them, or run `install.sh --uninstall`. The hooks
take no lock and need no terminal; `kernel-updater hook` runs them for the installed files.

### Configuration

`/etc/kernel-updater.conf` holds `key = value` lines; a line that starts with `#` is a
comment. The file is parsed, never sourced. A key the tool does not know is ignored with a
warning; a bad line or value and a key set twice exit 78; and when the tool runs as root the
file must be owned by root and not writable by group or others. `examples/kernel-updater.conf` lists the keys:

| Key | Meaning |
|---|---|
| `grub_floor` | Oldest GRUB the stick must run on: 2.02 (the default), 2.06, 2.12 or 2.14. It is the default of `lint --floor`, and `check` judges by it whether GRUB unlocks and reads `/boot` |
| `boot_fs_uuid` | UUID of the ext filesystem mounted at `/boot`, as `findmnt -n -o UUID /boot` prints it. Setting it arms the [hooks](#hooks), which refuse while another filesystem or none is mounted there. `check` fails when another filesystem is mounted there, and warns while the key is not set |
| `boot_luks_uuid` | UUID of the LUKS container that holds `/boot`, as `cryptsetup luksUUID` prints it. `check` fails when `/boot` is in another container |
| `verify_action` | What the postinst hook does with a new kernel that may not boot: `fail` (the default) stops its configure, `warn` only warns |
| `disk_ptuuid` | The stick's disk, as the PTUUID `lsblk -o NAME,LABEL,PTUUID,UUID` prints for it: 8 hex digits, the disk signature of an MBR disk, or a UUID for a GPT disk; kept lower case. With `p1_fs_uuid` it tells the stick apart: `check` fails and `baseline` refuses on another disk |
| `p1_fs_uuid` | The serial of the stick's partition 1, labelled BOOT, as the same command prints its UUID: two groups of 4 hex digits for FAT, such as `5CA1-AB1E`, or 16 hex digits for NTFS; kept upper case |
| `deploy` | How the files `migrate` writes reach partition 1: `auto` (the default) writes through a mount of partition 1 natively and exports in a VM; `direct` writes through a mount of partition 1 too, and in a VM exports all the same, since the guest never writes partition 1; `export` leaves them in `output_dir` for Windows to copy; `path` writes through `p1_path`, in a VM too, where the host then writes. See [Partition 1](#partition-1) |
| `p1_path` | An absolute path where partition 1's root is mounted already, such as a VirtualBox shared folder. It serves only while it is a mount point that holds `multibootusb/grub/grub.cfg`, the same as partition 1's when that can be read; then `check` and `baseline` read there, and otherwise partition 1 itself. `deploy = path` writes there, and a plan reads there what it builds on, only while no user but root can change its files, as with a share mounted with `uid=0,gid=0,dmode=0700,fmode=0600`, and while the share is mounted nowhere else, as VirtualBox's automount of it would be; otherwise a plan reads partition 1 itself |
| `output_dir` | Where an export goes, an absolute path: `/root/kernel-updater/out` by default. It must be a directory of root's closed to group and others (mode 0700), and holds the latest export only |
| `backups_keep` | How many dated backups of each file the safe writer keeps beside it: 1 to 99, 5 by default |
| `root_device` | What the entries of `kali.cfg` pass the kernel as `root=`: an absolute device path, such as `/dev/mapper/kali--vg-root`, or `UUID=` and a UUID. `migrate --stage detect` sets it from the running kernel's command line |
| `menu_variants` | The entries `kali.cfg` gets, comma-separated, in order: `default`, which comes first and must be there, then any of `failsafe`, `live` and `forensic`; `default,failsafe` by default. `live` and `forensic` boot through overlayroot, so the menu stage refuses them while the initrd `/boot/initrd.img` points at lacks it, or the one `/boot/initrd.img.old` points at when `previous_variants` holds them. Where the overlay comes up read-only and the login fails, `contrib/initramfs/overlayroot-rw` mounts it read-write ([docs/migration.md](docs/migration.md#live-and-forensic-mode)) |
| `previous_variants` | The variants that also get an entry for the previous kernel, which boots `/vmlinuz.old` and `/initrd.img.old`: a comma-separated part of `menu_variants`; `default,failsafe` by default, of which a variant `menu_variants` lacks is left out unless this key is set |
| `quarantine_days` | How many whole days a module tree `cleanup` moved into its quarantine stays there, counted from the later of the move and the first `cleanup` run after it that saw the tree there: 0 to 999, without a leading zero, 30 by default. A `cleanup` run after that deletes it, unless the clock reads earlier than an entry there was moved or seen. 0 keeps every tree until you delete it. See [cleanup](#cleanup) |

The UUIDs of `/boot` are optional, are written in the 8-4-4-4-12 hex form in either case, and
are kept lower case. Paths lose their trailing slashes, and lists of variants the blanks
around their commas. Every key is optional; `disk_ptuuid` and `p1_fs_uuid` must both be set
before `baseline` records anything, and the five keys `migrate --stage detect` fills before the
later stages run.

## Examples

`examples/grub.cfg` is a synthetic MultiBootUSB config with versioned Kali entries of the kind
`migrate` replaces. Every identifier in it is made up and starts with `5ca1ab1e`. Keep real
configs out of the repository: `.gitignore` excludes a `grub.cfg` in the repository root,
any `*.real.cfg` and `*.bak` copies.

## Testing

The tests use [bats-core](https://github.com/bats-core/bats-core) 1.5 or later with stub
commands, so they need neither root nor Kali. Run them from the repository root, in Git Bash
or on Linux:

```bash
bats tests/
```

- The tests point the tool at a fixture tree, a terminal file and a lock file of their own
  through `KU_ROOT`, `KU_TTY` and `KU_LOCKFILE`. The tool takes those from the environment only
  with `KU_TEST=1`, which the tests set, so a stray `KU_ROOT` never reaches the hooks. The same
  holds for the partition-1 seams: `KU_P1_DIR`, a directory that stands in for partition 1's
  root, so nothing is found or mounted; `KU_P1_DISK`, a disk image whose MBR boot code and first
  partition's boot sector the baseline hashes; `KU_P1_FSTYPES`, the types a read-only mount
  tries; and `KU_P1_PROBE`, the command that checks partition 1 before a read-write mount.
- `disk.bats`, `deploy.bats` and `baseline.bats` run the partition-1 code with stub `lsblk`,
  `blkid`, `findmnt`, `mount`, `stat`, `ntfs-3g.probe` and `systemd-detect-virt`: the stick
  found as `sda` or `sdb` through a crypt mapping, the identity check, the mount order and
  options, the probe's verdicts, mounts that other users can change or that share the
  partition with another, `p1_path` mounted, empty, missing or another stick's, the deploy
  modes in and out of a VM and with `--dry-run`, their fallbacks and the root they leave for a
  plan's reads, the safe writer's refusals, backups (a clock that went back included),
  failures and restores, several files checked before the first is written, the reader, the
  export, and the baseline with a disk image.
- `menu.bats` runs migrate's reading and writing of GRUB menus: `menu.awk`'s scan of the Kali
  submenu, with braces in quotes and comments, options before titles, nested entries, CRLF and
  LF, none, two and a marked one; the kernel parameters taken from the legacy entries and each
  rewrite, and those a plan hides; `kali.cfg` rendered for
  `tests/fixtures/grub/migrate-before.cfg`, which must equal `kali.expected.cfg`; the new
  `grub.cfg`, which must equal `migrate-after.cfg`, CRLF kept, also with far more after the
  submenu than a pipe holds; the byte guard; and finalize's removal of the legacy entries. The
  fixtures are stored LF, and the tests make the CRLF copies MultiBootUSB writes.
  `migrate.bats` runs every stage and `--rollback` on a `KU_ROOT` tree and
  a partition-1 tree with stub tools, its `linux-update-symlinks` choosing the links as
  linux-base 4.17 does: detect's appends and refusals, the system stage's preconditions, a lone
  bootable kernel beside another image, the order of its `linux-update-symlinks` calls, its edit
  of `kernel-img.conf` and a write of it that fails, the links left in `/`, grub-pc's question,
  results that fail its check, links kept on another kernel that boots and a kernel install
  while it asks; menu and finalize written and exported, their refusals, a `grub.cfg` that
  changes while menu asks, the stick's own GRUB lists, the parameters a plan hides, the initrds
  `live` needs, `kali.cfg` written anew, the export a write makes stale, the baseline finalize
  leaves to `baseline`, and the baseline entries every write keeps for files changed outside
  the tool; byte-exact
  rollbacks, written and exported, and their refusals: a backup that does not match its
  `MANIFEST`, a menu whose kernels are gone, and a stick that still sources `kali.cfg`, and the
  changes to `grub.cfg` a rollback drops; backups named in the order of the runs, removed while
  unfinished and passed over without a `MANIFEST`; and the exit codes.
- `cleanup.bats` runs `cleanup` on a `KU_ROOT` tree of a migrated system with stub tools, its
  `apt-get` answering the simulations and logging every call: the checks before the plan, a
  migration that is not finished, apt's and dpkg's locks as `/proc/locks` under `KU_ROOT` shows
  them, the releases it keeps and a pending reboot;
  what the purge of the config files removed kernels left and that of the old kernels apt's
  autoremove names take, keep and only list, kernels marked manual, the one purge with its exact
  options, a simulation that differs from the plan, changes while the question waits, a purge
  that fails or that a signal cuts short, and the check after it; each reason that keeps a
  module tree, an owner each of `dpkg-query -S`'s four patterns finds alone, an empty tree
  removed with `rmdir` and another moved into the quarantine, a kill before the move, trees
  that are only listed, and merged and separate modules directories; the quarantine's `seen`,
  expiry and its order, `quarantine_days`, a clock that is behind and the entries that are only
  listed; the dry run, the question, the records `--porcelain` prints, and the tools'
  environment.
- `KU_AWK`, the awk the lint tests run `lint.awk` under, is also taken only with `KU_TEST=1`,
  since `check` lints `kali.cfg` as root.
- ShellCheck must report nothing for any shell file. That test is skipped when `shellcheck`
  is not on PATH.
- `grub-script-check` (Debian package `grub-common`) checks the example configs and a syntax
  error for `lint`, and the lint fixture runs under both `mawk` and `gawk`. Those tests are
  skipped where the tools are missing, as on Windows, and so is the test with a real `flock`.
- CI runs the suite on every pull request, every push to `main` and once a week
  (`.github/workflows/tests.yml`), with a pinned ShellCheck and with `grub-common`
  installed, and fails when any test is skipped.
- `tests/container` holds tests that change the system they run on: they build dummy kernel
  packages with equivs whose maintainer scripts call `linux-update-symlinks` as real kernels
  do, install, hold and remove them, mount a tmpfs on `/boot`, and run `check` with stubs only
  for `uname` and `lsinitramfs`. `hooks.bats` installs kernel-updater with `install.sh` and
  drives its hooks through real `dpkg`, `apt-get` and `linux-run-hooks` runs, with dummy
  kernels whose maintainer scripts run the hooks as real ones do and an ext4 image with a
  synthetic UUID loop-mounted on `/boot`. `migrate.bats` runs migrate's system stage with the
  real `linux-update-symlinks`, then has kernel installs and removals move the links without
  the tool, rolls the stage back, and has the real `grub-script-check` take the files the menu
  stage writes. `cleanup.bats` purges dummy kernels with the real `apt-get` and `dpkg`: one
  removed with its config files left, and the old kernel apt's autoremove names once the dummies
  are marked auto, in one run, while the kernel `vmlinuz.old` points at stays when apt keeps
  another; it purges nothing while a reboot is pending, refuses a purge that would take along a
  package that depends on an old kernel's headers, removes the empty module tree a kernel
  install the `/boot` guard refused leaves, quarantines a tree once a `dkms` stub lists no
  modules for it, expires a back-dated quarantine entry, and finds a real `fcntl` lock on dpkg's
  frontend lock in `/proc/locks`. They run only with `KU_CONTAINER=1` inside a
  container, fail with it set anywhere else, and skip without it; `bats tests/` leaves the
  subdirectory out.
  The `kali` job of the tests workflow builds the Kali rolling image of `ci/kali/Dockerfile`,
  pinned by digest and updated by Dependabot, and runs them in it, failing when any is
  skipped. To run them locally:

  ```bash
  docker build --tag kernel-updater-kali ci/kali
  docker run --rm --privileged --volume "$PWD:/src:ro" kernel-updater-kali
  ```
- `tests/ntfs` holds tests that write real NTFS. They build a synthetic stick in a loop file
  with `sfdisk`: an MBR with the disk signature `5ca1ab1e`, partition 1 made with `mkntfs`
  and given the serial `5CA1AB1E00000001` with `ntfslabel`, and partition 2 with ext4, which
  they mount as `/boot` under their `KU_ROOT`. On it they find partition 1 from `/boot` and
  check its identity, mount it with `ntfs3` and with `ntfs-3g`, see `ntfs-3g.probe` keep a
  volume marked hibernated, and `ntfs3` one marked dirty, from a read-write mount, write a
  CRLF `grub.cfg` with the safe writer, see a failed rename put it back as it was and a failed
  read-back restore it, see a read-only mount send `direct` to export and a mount a
  user owns serve no writer, and
  record a baseline that catches one changed byte of a file and of the MBR boot code. Their
  `migrate.bats` runs the menu stage end to end, `/boot` on a device-mapper device over
  partition 2 as the stick's unlocked `/boot` is, lints `kali.cfg` with the stick's own GRUB
  lists, and writes `kali.cfg` and the new `grub.cfg` to NTFS, CRLF kept, then has
  `--rollback` put `grub.cfg` back byte for byte. They
  run only with `KU_NTFS=1`, fail with it when not run as root, and skip without it. The
  `ntfs` job of the tests workflow installs `ntfs-3g` and `dmsetup`, loads `ntfs3` and runs
  them with `sudo env "PATH=$PATH" KU_NTFS=1 bats --tap tests/ntfs`, failing when any is
  skipped. Run them only on a machine you can spare, as root.
- `tests/contrib.bats` runs `contrib/initramfs/overlayroot-rw` with stub `mount`, `umount` and
  `mkdir` and a mounts file in place of `/proc/mounts`: it leaves a root that is no overlay or
  is read-write alone, remounts a read-only overlay's layers read-write while it moves only the
  top mounts, mounts `/dev` anew when it will not move, leaves the root read-only when a step
  fails, and goes on, saying so, when it cannot edit the fstab or mount `/dev` anew.
- `tests/tools.bats` runs the Windows scripts in `tools/windows`, the steps around
  `migrate --write-fat` that docs/migration.md lists, under `pwsh` with a stub `Get-Volume`:
  each refuses, changing nothing, when BOOT is not there, is there twice, is not FAT or holds
  no MultiBootUSB menu. It skips without `pwsh`.
- `tests/fat` holds the same kind of tests for a FAT partition 1, as MultiBootUSB makes it:
  partition 1 made FAT32 with `mkfs.vfat` and the serial `5CA1-AB1E`, and `syslinux` installed
  in `multibootusb`, which writes its boot sector. On it they find partition 1 from `/boot` and
  check its identity, mount it read-only with `vfat` as root's alone, read names stored in
  capitals, see a mount a user owns serve no plan, see every deploy mode export instead of
  writing, and see the tripwire pass a real "not cleanly unmounted" flag but catch any other
  changed byte of the boot sector. Their `migrate.bats` runs `detect` on the stick and the menu
  stage, which leaves its files in `output_dir` and partition 1 byte for byte as it was, and,
  with `--write-fat` under a stub VMware, writes the menu and rolls it back. Their
  `write.bats` sees each check before a FAT write refuse with partition 1 byte for byte as it
  was, the writer read back through a new mount, a failed rename and a failed read-back put
  back, FAT16 too, and a copy of partition 1 after every step the writer syncs, as a power loss
  would leave it, pass `fsck.vfat -n` with the old or the new `grub.cfg`, or none only between
  the move aside and the rename. They
  run only with `KU_FAT=1`, as root; the `fat` job installs `dosfstools`, `syslinux`, `mtools`
  and `dmsetup` and runs them with `sudo env "PATH=$PATH" KU_FAT=1 bats --tap tests/fat`.
- `.githooks/privacy-scan` runs in the tests and before every commit on a clone with the hooks
  turned on (see CONTRIBUTING.md). It refuses CRLF line endings; disk and partition
  identifiers (UUIDs, volume serials, LVM UUIDs, PARTUUIDs) outside the synthetic range;
  private IPv4 and IPv6 addresses; `.lan` host names; user home paths; and e-mail addresses
  other than GitHub no-reply ones. It also refuses any value listed, one per line, in the
  untracked `.git/info/privacy-denylist`. The secret scan applies the same rules, without the
  denylist, to every pushed commit.

## Licence

MIT, see [LICENSE](LICENSE).
