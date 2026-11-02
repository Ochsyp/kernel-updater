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

### Changed

- `update_kernel.sh` takes the `grub.cfg` to edit as its only argument, and exits 64 with a
  usage message on stderr when it gets none or more than one. Before, the path was fixed in
  the script.
- `update_kernel.sh` is stored with LF line endings, and `.gitattributes` keeps every text
  file LF.

[Unreleased]: https://github.com/Ochsyp/kernel-updater/commits/main
