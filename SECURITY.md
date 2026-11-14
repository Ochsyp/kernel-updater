# Security policy

kernel-updater has a single maintainer.

## Reporting a problem

Report a vulnerability privately through the repository's Security tab ("Report a
vulnerability"). Never paste a real `grub.cfg`, `blkid` output or logs with disk identifiers
into issues, pull requests or commits.

## Notes

- The tool runs as root on a stick's Kali install, removes kernel packages and edits the boot
  menu. Review every change before it reaches a stick, and copy the stick's
  `multibootusb/grub` folder somewhere safe before running a release that changes the menu.
- The tool reads no secrets. A real `grub.cfg` holds the stick's partition and
  encryption-container identifiers, which tie it to one physical device, so it stays out of
  the repository.

## Automated checks

- gitleaks scans the commits of every push and pull request, and the whole history when the
  workflow is started by hand (`.github/workflows/secret-scan.yml`). `.gitleaks.toml` adds
  rules for disk and partition identifiers, private addresses, `.lan` host names, user home
  paths and e-mail addresses.
- `.githooks/privacy-scan` applies the same rules, plus a local denylist, to the staged files
  before every commit on a clone with the hooks turned on.
- Dependabot keeps the pinned GitHub Actions up to date.
