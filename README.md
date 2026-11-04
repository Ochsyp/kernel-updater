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

The redesigned tool is `bin/kernel-updater`. Until phase 4 adds an installer, run it from a
checkout. It needs Bash 4.4 or later, GNU coreutils and awk; `grub-script-check` (Debian
package `grub-common`) adds a syntax check to `lint`. `check` also reads the system through
`findmnt` (util-linux), `mount` and `umount` (Debian package `mount`), `dpkg-query`,
`linux-version` (linux-base), `cryptsetup`, `dumpe2fs`, `lsinitramfs` and `debconf-show`, which
a Kali install has.

```text
kernel-updater [OPTIONS] COMMAND [ARGS]
```

| Command | Does |
|---|---|
| `check` | Reports, as root and without changing anything, whether the system keeps the Kali entries bootable: `/boot`, its links and LUKS container, the kernel packages and their initrds, fstab, crypttab and grub-pc. See [check](#check) |
| `lint FILE...` | Checks GRUB configs for errors GRUB reports only at boot: syntax errors, unknown commands and modules, malformed or misused LUKS and filesystem UUIDs, kernel parameters that do nothing, drives named as `(hdN,...)`, and encrypted entries between MultiBootUSB's `#start` and `#end` markers. Findings name the kind of identifier, never its value |
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
| 2 | Findings: `lint` found an error or a `check` item failed, or either warned with `--strict` |
| 3 | Refused: a check failed and nothing was changed |
| 4 | A write failed and the previous state was restored |
| 10 | Declined, or no terminal to confirm on without `--yes` |
| 64 | Usage error |
| 66 | An input file cannot be read |
| 75 | Busy: another run holds the lock |
| 77 | Not run as root |
| 78 | Bad configuration |
| 128+N | Interrupted by signal N |

### check

```text
kernel-updater check [--strict] [--porcelain]
```

`check` must run as root and exits 77 otherwise. It changes nothing: to look under the `/boot`
mount point it bind-mounts `/` read-only on a private directory in `/run`, never in `TMPDIR`,
and removes that mount before it exits, lazily when it is busy, and also when `check` is
interrupted. Each item is `ok`, `warn`, `fail` or `skip`, the last when it does not apply, such
as the `/boot` items while `/boot` is not mounted. `boot-links`, `stale-root-links` and
`reboot-pending` apply only while `/etc/kernel-img.conf` keeps the links in `/boot`.
`boot-luks` and `boot-ext` judge `/boot` by the GRUB that `grub_floor` names, 2.02 by default.

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

Results go to stdout as aligned `STATUS ITEM DETAIL` lines, or with `--porcelain` as
`ITEM<TAB>STATUS<TAB>DETAIL`, and a summary goes to stderr. Details name kinds and counts,
never a disk identifier, device name or key file. `check` exits 0 unless an item fails, and 2
when one does or, with `--strict`, when one warns.

### Configuration

`/etc/kernel-updater.conf` holds `key = value` lines; a line that starts with `#` is a
comment. The file is parsed, never sourced. A key the tool does not know is ignored with a
warning; a bad line or value and a key set twice exit 78; and when the tool runs as root the
file must be owned by root and not writable by group or others. `examples/kernel-updater.conf` lists the keys:

| Key | Meaning |
|---|---|
| `grub_floor` | Oldest GRUB the stick must run on: 2.02 (the default), 2.06, 2.12 or 2.14. It is the default of `lint --floor`, and `check` judges by it whether GRUB unlocks and reads `/boot` |
| `boot_fs_uuid` | UUID of the ext filesystem mounted at `/boot`, as `findmnt -n -o UUID /boot` prints it. `check` fails when another filesystem is mounted there, and warns while the key is not set |
| `boot_luks_uuid` | UUID of the LUKS container that holds `/boot`, as `cryptsetup luksUUID` prints it. `check` fails when `/boot` is in another container |

Both UUIDs are optional, are written in the 8-4-4-4-12 hex form in either case, and are kept
lower case.

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
  for `uname` and `lsinitramfs`. They run only with `KU_CONTAINER=1` inside a container, fail
  with it set anywhere else, and skip without it; `bats tests/` leaves the subdirectory out.
  The `kali` job of the tests workflow builds the Kali rolling image of `ci/kali/Dockerfile`,
  pinned by digest and updated by Dependabot, and runs them in it, failing when any is
  skipped. To run them locally:

  ```bash
  docker build --tag kernel-updater-kali ci/kali
  docker run --rm --privileged --volume "$PWD:/src:ro" kernel-updater-kali
  ```
- `.githooks/privacy-scan` runs in the tests and before every commit on a clone with the hooks
  turned on (see CONTRIBUTING.md). It refuses CRLF line endings; disk and partition
  identifiers (UUIDs, volume serials, LVM UUIDs, PARTUUIDs) outside the synthetic range;
  private IPv4 and IPv6 addresses; `.lan` host names; user home paths; and e-mail addresses
  other than GitHub no-reply ones. It also refuses any value listed, one per line, in the
  untracked `.git/info/privacy-denylist`. The secret scan applies the same rules, without the
  denylist, to every pushed commit.

## Licence

MIT, see [LICENSE](LICENSE).
