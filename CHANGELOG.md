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

[Unreleased]: https://github.com/Ochsyp/kernel-updater/commits/main
