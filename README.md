# kernel-updater

Keeps the Kali entries of a multiboot USB stick bootable across kernel updates.

> **Status:** under redesign, one phase per pull request. [CONTRIBUTING.md](CONTRIBUTING.md)
> describes the workflow, and [CHANGELOG.md](CHANGELOG.md) lists what changed.

## The setup it serves

A USB stick boots several systems through MultiBootUSB, whose GRUB reads
`/multibootusb/grub/grub.cfg` from an NTFS partition. One submenu starts a full Kali install
on the same stick, with an encrypted `/boot` that GRUB unlocks and an encrypted root behind
it. The same install also runs as a virtual machine straight from the stick, booting through
the same menu.

The Kali entries name a kernel version (`/vmlinuz-<version>`, `/initrd.img-<version>`). Once
apt installs a new kernel and removes the old one, they point at files that no longer exist.

## Current state: `update_kernel.sh` (legacy)

`update_kernel.sh` is the script this project starts from. It stays for reference while the
phases below replace it, and the last phase removes it. **Do not run it.** It:

- rewrites every kernel version in the given `grub.cfg` to the running kernel, so the menu
  never moves to a newly installed kernel and has no entry for the previous one;
- purges kernel packages with `apt-get purge -y` and runs a system-wide
  `apt-get autoremove -y`, with no dry run and no confirmation;
- deletes the `/lib/modules` directory of a kernel it wrongly takes for removed, a held one
  for example;
- rebuilds every initramfs, the known-good fallback's included.

For reference, it is called as:

```text
sudo ./update_kernel.sh GRUB_CFG
```

## The redesign

Debian's own tooling can keep the menu stable. With `link_in_boot = yes` in
`/etc/kernel-img.conf`, every kernel install and removal updates relative links in `/boot`:
`vmlinuz` and `initrd.img` point at the newest kernel, `vmlinuz.old` and `initrd.img.old` at
the previous one. The redesign moves the Kali entries into a file of their own that boots
those links, writes it to the stick once, and leaves kernel housekeeping to apt from then on.
Guard hooks refuse a kernel install while the encrypted `/boot` is not mounted, and a `check`
command reports the state of the stick.

The phases, one pull request each:

1. Repository scaffolding and the imported script
2. Command-line framework, safety rails and an offline `lint` for GRUB configs
3. A read-only `check` of the system and the stick, with a Kali container in CI
4. Guard hooks for kernel installs, and an installer
5. Finding and safely writing the stick's boot partition, an export mode, and a boot-file
   tripwire
6. `migrate`: the one-time switch to the link-based menu, with rollback
7. `cleanup` of leftover kernel packages and module trees, removal of the legacy script, and
   release 1.0.0

## Usage

The redesigned tool is `bin/kernel-updater`. Run it from a checkout, or install it, together
with its hooks, with `install.sh` (see [Installing](#installing)). It needs Bash 4.4 or later,
GNU coreutils and awk; `grub-script-check` (Debian package `grub-common`) adds a syntax check
to `lint`. `check` and the hooks also read the system through `findmnt`, `lsblk` and `blkid`
(util-linux), `mount` and `umount` (Debian package `mount`), `dpkg-query`, `linux-version`
(linux-base), `cryptsetup`, `dumpe2fs`, `lsinitramfs` and `debconf-show`, which a Kali install
has. `check` and `baseline` mount the stick's NTFS partition read-only with the kernel's `ntfs3`
driver, or with `ntfs-3g` (Debian package `ntfs-3g`). Writing it, which phase 6 adds, needs
`ntfs3` and `ntfs-3g.probe`, from the same package, and `systemd-detect-virt` tells the
writer whether it runs in a VM.

```text
kernel-updater [OPTIONS] COMMAND [ARGS]
```

| Command | Does |
|---|---|
| `check` | Reports, as root and without changing anything, whether the system keeps the Kali entries bootable: `/boot`, its links and LUKS container, the kernel packages and their initrds, fstab, crypttab and grub-pc, then the stick's partition 1. See [check](#check) |
| `baseline` | Records, as root, the SHA-256 of the stick's boot code, which check's tripwire compares with; `--show` compares without recording. See [baseline](#baseline) |
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
| 3 | Refused before a change: a check failed, apt-guard refused an apt run, a guard hook refused a kernel install, removal or configure (by the time a configure is refused, the kernel's postinst has moved the links), or the writer found a file on partition 1 changed since it was read, reached through a symlink, or on a path other users can change |
| 4 | A write failed. The message says what that left: nothing changed, the previous state put back, a backup to copy back or a file to remove by hand, the files written before it, or an `output_dir` that holds no complete export, so that the export must run again |
| 10 | Declined, or no terminal to confirm on without `--yes` |
| 64 | Usage error |
| 66 | An input file cannot be read, or the stick's partition 1 cannot be found or read |
| 75 | Busy: another run holds the lock |
| 77 | Not run as root |
| 78 | Bad configuration, or a stick other than the one `disk_ptuuid` and `p1_fs_uuid` name |
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
`--uninstall` removes every file the manifest lists, the APT configuration first, and leaves
`/etc/kernel-updater.conf` alone. It needs root (exit 77 otherwise) and takes the tool's lock
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

The last five items look at the stick's partition 1 (see [Partition 1](#partition-1)). `check`
reads it through `p1_path` while that serves, through a mount that is there, or else through a
read-only mount of its own on a private directory in `/run`, which it removes before it exits,
also when interrupted. The four after `p1-identity` skip, saying why, when partition 1 cannot
be found from `/boot`, is another than the configuration names, or cannot be read; another
partition 1 is never read. `--no-partition` skips all five and leaves partition 1 alone.

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
| `p1-identity` | Partition 1, found from `/boot`, is the NTFS filesystem `p1_fs_uuid` names, on the disk `disk_ptuuid` names; fails when it is another, naming the disk or partition 1 but no value, also when only one of the keys is set and names another, and, with both keys set, when it cannot be found; skips otherwise while either key is not set |
| `grub-version` | The stick's GRUB, whose version `multibootusb/grub/i386-pc/normal.mod` holds, is at least as new as `grub_floor`, or lint and check would trust features it lacks; fails when it is older, warns when its version is unknown, and names the higher floor a newer GRUB allows |
| `tripwire` | The stick's boot code matches the baseline `kernel-updater baseline` recorded: the files `share/kernel-updater/baseline.list` names, the MBR boot code and partition 1's boot sector; fails naming what changed, is new or is missing, a file that is or passes a symlink counting as missing, and warns while no baseline is stored |
| `deployed` | The files exported to `output_dir` match those on partition 1, as its `SHA256SUMS` lists them; fails naming each one that differs or is missing, and skips while nothing was exported. Copy the export only when you have not yet: copied again after the stick changed, it would undo that change |
| `kali-cfg` | `multibootusb/grub/kali.cfg`, which phase 6 writes, passes `lint` with the stick's own command and module lists; fails on errors and when it or a directory on its way is a symlink, warns on warnings, and skips while the file does not exist |

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
keeps its own code, `p1:boot-sector`). Files that do not exist are not recorded. check's
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

### Partition 1

Phase 5 finds and reaches the stick's partition 1, the NTFS partition labelled BOOT that holds
MultiBootUSB, so that phase 6 can write its menu there safely. Nothing in phase 5 writes it.

- **Finding it.** The tool never trusts a `/dev/sdX` or `/dev/disk/by-id` name, which change
  with the port and in a VM. It starts from the filesystem mounted at `/boot`, walks up with
  `lsblk -s` through the LUKS mapping to the one disk under it, refusing none or several, and
  takes that disk's partition 1. `blkid -p` reads what `lsblk` leaves empty without udev.
- **Telling it apart.** The disk's PTUUID must be `disk_ptuuid` and partition 1 must be NTFS
  with the serial `p1_fs_uuid`. A VM that has the whole stick attached, as through a raw-disk
  VMDK, shows the same identifiers, so both checks hold natively and in such a VM. Messages
  say which part differs, never a value.
- **Reaching it.** A reader, which only hashes and lints what it reads, takes `p1_path` while
  it serves: while it is a mount point that holds `multibootusb/grub/grub.cfg` and, when
  partition 1 can be read, the same `grub.cfg` as partition 1, so that neither the empty mount
  point of a share that is not mounted, as on a native boot, nor another stick's share passes
  for it. Otherwise it takes a mount of partition 1 that is there, and else mounts it
  read-only on a private directory in `/run` with `nosuid,nodev,noexec`, trying `ntfs3`, then
  `ntfs-3g`, which gets `norecover`. A read-only mount writes nothing with either. Readers
  follow no symlink on partition 1, which Windows or a user who owns a mount of it could have
  made: a file that is or passes one counts as missing to the tripwire and to the `deployed`
  item, its GRUB version as unknown, and `kali-cfg` fails.
- **Writing it.** A writer goes the same way, but takes `p1_path` only with `deploy = path`,
  and a mount that is there only while it is read-write; both only while no user but root can
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
- **Deploying.** In a VM, where Windows may have partition 1 mounted on the host, the guest
  never writes partition 1 itself: `deploy = auto` and `direct` export there, and only `path`
  writes, through the host's share. Natively, `auto` and `direct` write directly. `direct` and
  `path` fall back to an export, saying why, when they get no root they may write, as when
  their own read-write mount finds partition 1 hibernated, unclean or marked dirty, or the
  kernel has no `ntfs3`; `path`, and a read-write mount that root made, are written as they
  are. What a plan reads from
  partition 1 to build the new files comes only from a root no user but root can change, for
  an export too: while a desktop has partition 1 mounted for its user there is none, and the
  tool asks you to unmount it there and run again.
- **The safe writer** replaces one file at a time: it refuses with exit 3 when the file
  changed since the plan read it, a symlink lies on its way, or a user other than root could
  change a directory on its path; copies it to `NAME.ku-<UTC stamp>.bak` beside it and keeps
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
  file before it writes the first, so that a file that changed, a symlink or a path other
  users can change refuses before anything is written; a backup name taken within the same
  second shows only when its file's turn comes, and a later failure names the files it wrote.
  Phase 6 reads what it builds on with `ku_deploy_read`, which follows no symlink either,
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
| `p1_fs_uuid` | The serial of the stick's NTFS partition 1, labelled BOOT, as the same command prints its UUID: 16 hex digits, kept upper case |
| `deploy` | How the files phase 6 writes reach partition 1: `auto` (the default) writes through a mount of partition 1 natively and exports in a VM; `direct` writes through a mount of partition 1 too, and in a VM exports all the same, since the guest never writes partition 1; `export` leaves them in `output_dir` for Windows to copy; `path` writes through `p1_path`, in a VM too, where the host then writes. See [Partition 1](#partition-1) |
| `p1_path` | An absolute path where partition 1's root is mounted already, such as a VirtualBox shared folder. It serves only while it is a mount point that holds `multibootusb/grub/grub.cfg`, the same as partition 1's when that can be read; then `check` and `baseline` read there, and otherwise partition 1 itself. `deploy = path` writes there, and a plan reads there what it builds on, only while no user but root can change its files, as with a share mounted with `uid=0,gid=0,dmode=0700,fmode=0600`, and while the share is mounted nowhere else, as VirtualBox's automount of it would be; otherwise a plan reads partition 1 itself |
| `output_dir` | Where an export goes, an absolute path: `/root/kernel-updater/out` by default. It must be a directory of root's closed to group and others (mode 0700), and holds the latest export only |
| `backups_keep` | How many dated backups of each file the safe writer keeps beside it: 1 to 99, 5 by default |

The UUIDs of `/boot` are optional, are written in the 8-4-4-4-12 hex form in either case, and
are kept lower case. Paths lose their trailing slashes. Every key is optional; `disk_ptuuid`
and `p1_fs_uuid` must both be set before `baseline` records anything.

## Examples

`examples/grub.cfg` is a synthetic MultiBootUSB config with the versioned Kali entries the
legacy script edits. Every identifier in it is made up and starts with `5ca1ab1e`. Keep real
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
  synthetic UUID loop-mounted on `/boot`. They run only with `KU_CONTAINER=1` inside a
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
  record a baseline that catches one changed byte of a file and of the MBR boot code. They
  run only with `KU_NTFS=1`, fail with it when not run as root, and skip without
  it. The `ntfs` job of the tests workflow installs `ntfs-3g`, loads `ntfs3` and runs them with
  `sudo env "PATH=$PATH" KU_NTFS=1 bats --tap tests/ntfs`, failing when any is skipped. Run
  them only on a machine you can spare, as root.
- `.githooks/privacy-scan` runs in the tests and before every commit on a clone with the hooks
  turned on (see CONTRIBUTING.md). It refuses CRLF line endings; disk and partition
  identifiers (UUIDs, volume serials, LVM UUIDs, PARTUUIDs) outside the synthetic range;
  private IPv4 and IPv6 addresses; `.lan` host names; user home paths; and e-mail addresses
  other than GitHub no-reply ones. It also refuses any value listed, one per line, in the
  untracked `.git/info/privacy-denylist`. The secret scan applies the same rules, without the
  denylist, to every pushed commit.

## Licence

MIT, see [LICENSE](LICENSE).
