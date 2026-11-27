# Contributing

kernel-updater keeps the Kali entries of a MultiBootUSB stick bootable across kernel updates. One
maintainer runs it. Only released versions should reach a stick.

<!-- standard:begin workflow -->
## Workflow

Every change reaches `main` through a pull request that the maintainer reviews and merges. This
holds for the maintainer too.

1. Branch from an up-to-date `main`: `phase/<n>-<slug>` for a phase of the plan, or `fix/`,
   `feat/`, `docs/` or `chore/` plus a short slug.
2. Write commit messages and the pull request title as Conventional Commits (`feat:`, `fix:`,
   `docs:`, `chore:`, `ci:`, `test:`, `refactor:`).
3. Add a line under `## [Unreleased]` in `CHANGELOG.md`. Three kinds of pull request add none
   there: a release pull request (`chore/release-X.Y.Z`), which moves the lines into the new
   version; the fix of a draft release (`fix/release-X.Y.Z-<slug>`), whose line goes into that
   version's section; and a Dependabot pull request, whose updates the next release pull request
   sums up.
4. Run the checks in Checks below, and fix what they find.
5. Push the branch and open a pull request against `main`. Before every `gh pr create` and
   `gh pr edit`, run `.github/standard/bin/pr-text` on the title and the body: it refuses
   denylist terms and rule pack hits, and never prints them.
6. Start the next phase only after the pull request is merged.

One pull request holds one phase or one change.

Repository work happens only on a machine with the maintainer's git configuration, never in a
hosted environment such as a codespace or a cloud workspace. That configuration turns the hooks
on and loads the denylists for every clone of this repository's GitHub URL. A clone made from a
local path gets no hooks, so run `git config core.hooksPath .githooks` in it right after cloning.

An outside contributor's pull request is reviewed in the browser and through CI. Hooks run from
the checked-out tree with the maintainer's credentials, even during a fetch, so:
- never check out a fork's pull request branch in a clone with the hooks on;
- clone a fork only with `git clone <fork URL>` or `gh repo clone <fork> <folder> --no-upstream`,
  into a scratch folder, and never add a remote for this repository there.
<!-- standard:end workflow -->

<!-- standard:begin guard-rails -->
## Guard rails

GitHub's ruleset on `main` blocks direct pushes, force pushes and its deletion, and the merge
of a pull request whose `all-passed` or `scan` check failed.

The hooks in `.githooks/` guard every commit and push:
- `pre-commit` refuses a commit while `main` or `master` is checked out. It also refuses a changed
  copy of the standard, a staged file above `MAX_BLOB_KB`, and staged content, path names, author
  or committer that hold a denylist term or a rule pack hit. `pre-merge-commit` does the same for
  a merge.
- `commit-msg` refuses such a term or hit in the message.
- `pre-push` refuses a push to `main` or `master`, and a branch or tag name with a term or hit. It
  refuses every tag push except a `v*` tag under `RELEASE_KIND=legacy`; otherwise release tags
  come from publishing a release. It also refuses a term or hit in what the pushed commits bring
  in, which covers rebase, cherry-pick and `am` too.

The denylists hold names that must never be committed and never leave the maintainer's machine.
The rule packs in `.githooks/rules/` hold the patterns: private addresses, local host names, MAC
addresses, home paths and e-mail addresses, and disk and VM identifiers where the config enables
them. A refusal names the file, the line and the kind of finding, never the value.

The maintainer's git configuration turns the hooks on for every clone of this repository's GitHub
URL. Anywhere else, such as a clone made from a local path, turn them on once after cloning:
`git config core.hooksPath .githooks`. Never use `--no-verify`.
<!-- standard:end guard-rails -->

<!-- standard:begin standard -->
## The repository standard

Files listed in `.github/standard/MANIFEST` are copies of the repository standard. Never edit
them here: change repo-standard, release it, and sync with a `chore/standard-X.Y.Z` pull request.
CI fails when a copy differs or changes on another branch. An exemption, an accepted finding or a
dropped check comes in a `chore/privacy-*` pull request of its own.

When a private repository goes public, it does so in this order. A pull request sets
`VISIBILITY=public`, and `tools/sync` writes the public block texts into it. The maintainer
switches the repository to public on GitHub and turns on the security settings and the ruleset
those texts promise. A new commit on that branch reruns its checks; a rerun from the Actions page
keeps the old private flag. Then that pull request merges before anything else: until it does,
`main` says private while GitHub says public, and CI on `main` and `tools/status` fail.
<!-- standard:end standard -->

## Checks

- `bats tests/` runs the suites that need no root and no Kali. Where a tool is missing, as
  `grub-script-check`, `flock`, `mawk` or `pwsh` on Windows, its tests skip locally; in CI none
  may skip.
- ShellCheck reports nothing for any shell file: `tests/static.bats` runs it with `-x`.
- `sh .githooks/privacy-scan --tracked` passes, with the `base` and `disk` packs the config
  selects.
- `bats .github/standard/tests/` runs the standard's own suites, one file at a time in Git Bash
  on Windows.

CI's `ci` workflow adds two stages of this repository's own:
- `ci/test` runs `bats tests/` with `grub-script-check`, `mawk` and `gawk` installed;
- `ci/system` runs the container suite in `tests/container` on a Kali rolling image built from
  `ci/kali`, and `tests/ntfs` and `tests/fat` as root on a synthetic stick in a loop file.

Both fail on any failed or skipped test. Neither can prove a boot of a real stick: after a
change to the menu or the hooks, boot the stick's Kali natively and in the VM.

## Test data

Never commit a real `grub.cfg`, `blkid` output or any identifier read from a real disk.
Examples and fixtures use made-up identifiers built from `5ca1ab1e` (`5CA1-AB1E` for FAT
serials, `5ca1ab` for LVM UUIDs), which the `disk` pack lets through, and by-id names with
`Synthetic`. A value that looks private only as a whole, as an ISO 9660 date that has the shape
of a MAC address, is built from fragments at run time. A value with no recognisable shape, such
as a disk signature, can go in the clone's untracked `.git/info/privacy-denylist`, so that the
hooks refuse it too. The config sets no exemption and no accepted finding.
