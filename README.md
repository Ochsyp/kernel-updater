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
package `grub-common`) adds a syntax check to `lint`.

```text
kernel-updater [OPTIONS] COMMAND [ARGS]
```

| Command | Does |
|---|---|
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
| 2 | Findings: `lint` found an error, or a warning with `--strict` |
| 3 | Refused: a check failed and nothing was changed |
| 4 | A write failed and the previous state was restored |
| 10 | Declined, or no terminal to confirm on without `--yes` |
| 64 | Usage error |
| 66 | An input file cannot be read |
| 75 | Busy: another run holds the lock |
| 77 | Not run as root |
| 78 | Bad configuration |
| 128+N | Interrupted by signal N |

### Configuration

`/etc/kernel-updater.conf` holds `key = value` lines; a line that starts with `#` is a
comment. The file is parsed, never sourced. A key the tool does not know is ignored with a
warning; a bad line or value and a key set twice exit 78; and when the tool runs as root the
file must be owned by root and not writable by group or others. `examples/kernel-updater.conf` lists the keys:

| Key | Meaning |
|---|---|
| `grub_floor` | Default of `lint --floor` |

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
- CI runs the suite on every pull request and every push to `main`
  (`.github/workflows/tests.yml`), with a pinned ShellCheck and with `grub-common`
  installed, and fails when any test is skipped.
- `.githooks/privacy-scan` runs in the tests and before every commit on a clone with the hooks
  turned on (see CONTRIBUTING.md). It refuses CRLF line endings; disk and partition
  identifiers (UUIDs, volume serials, LVM UUIDs, PARTUUIDs) outside the synthetic range;
  private IPv4 and IPv6 addresses; `.lan` host names; user home paths; and e-mail addresses
  other than GitHub no-reply ones. It also refuses any value listed, one per line, in the
  untracked `.git/info/privacy-denylist`. The secret scan applies the same rules, without the
  denylist, to every pushed commit.

## Licence

MIT, see [LICENSE](LICENSE).
