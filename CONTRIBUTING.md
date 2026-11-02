# Contributing

Every change reaches `main` through a pull request, so that it is reviewed before it is
merged. This holds for the maintainer too.

## Workflow

1. Start from an up-to-date `main` and create a branch for the change:
   - `phase/<n>-<slug>` for a phase of the redesign, for example `phase/2-cli-rails-lint`;
   - `fix/<slug>`, `feat/<slug>`, `docs/<slug>` or `chore/<slug>` for anything else.
2. Commit on that branch. Commit messages follow
   [Conventional Commits](https://www.conventionalcommits.org/en/v1.0.0/), for example
   `fix: refuse a grub.cfg without a Kali submenu`.
3. Add an entry for the change under `## [Unreleased]` in [CHANGELOG.md](CHANGELOG.md), on
   the same branch.
4. Run the checks described in the README's Testing section: `bats tests/` passes, and
   ShellCheck reports nothing for any shell file.
5. Push the branch and open a pull request against `main`. The secret scan and the tests run
   on it.
6. Start the next phase only after the pull request is reviewed and merged. Its branch starts
   from the updated `main`.

One pull request holds one phase or one change. Only released versions should reach a stick:
a release pull request moves the Unreleased entries under a new version, and the maintainer
tags it (`vX.Y.Z`) and publishes the release.

## Guard rails

`main` is never committed to or pushed to directly. Git hooks in `.githooks` enforce this on
each clone, whether or not GitHub also protects `main`:

- `pre-commit` refuses a commit while `main` or `master` is checked out, then runs
  `privacy-scan` on the staged files;
- `pre-push` refuses a push to `main` or `master`.

Turn them on once after cloning:

```text
git config core.hooksPath .githooks
```

Do not bypass them with `--no-verify`. After a pull request is merged, bring the local `main`
up to date with `git switch main` and `git pull --ff-only`.

## Test data

Never commit a real `grub.cfg`, `blkid` output or any identifier read from a real disk.
Examples and fixtures use made-up identifiers that start with `5ca1ab1e` (`5CA1-AB1E` for FAT
serials, `5ca1ab` for LVM UUIDs); `privacy-scan` and the secret scan let only those through.
A value that has no recognisable shape, such as a disk signature, can be listed in the
untracked `.git/info/privacy-denylist` so that `privacy-scan` refuses it too.
