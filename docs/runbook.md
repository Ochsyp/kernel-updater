# Runbook

How to keep the stick's Kali install in shape once `kernel-updater migrate` has run, as
[migration.md](migration.md) describes, and what to do when something goes wrong. Every command
that changes the system prints its plan and asks first, and `-n` shows the plan alone. No
message prints a disk identifier. Where this page shows `VERSION` or `RELEASE`, put a kernel
release, such as `uname -r` prints, and where it shows `PACKAGE`, a package name.

## Before anything

Unlock and mount `/boot` with its passphrase, as for any kernel update. The passphrase stays the
only way into `/boot`: nothing in this runbook adds a key file for it or unlocks it
automatically. While `/boot` is not mounted, the hooks refuse kernel installs and removals, and
`migrate` and `cleanup` exit 66.

## Routine use

1. Update with `sudo apt full-upgrade`. The hooks refuse a kernel install while `/boot` is not
   mounted, and check that a new kernel's initrd would boot. A new kernel moves `/boot/vmlinuz`
   and `/boot/initrd.img` to itself, and the `.old` links to the kernel they left; nothing on the
   stick's partition 1 changes.
2. Reboot into "Kali GNU/Linux", which boots the new kernel.
3. Run `sudo kernel-updater check`. No item should fail.
4. Now and then, purge what old kernels leave behind. Read the plan first, then run it:

   ```bash
   sudo kernel-updater cleanup -n
   sudo kernel-updater cleanup
   ```

Why `cleanup`: old kernels stay installed until apt's autoremove removes them, and a kernel that
apt removes leaves its config files behind (`rc` in `dpkg -l`), while `apt-get upgrade` removes
no kernel at all. `cleanup` purges both kinds of leftover in one apt run, and only kernel
packages. It never purges the running kernel or one the links in `/boot` point at; apt's own
autoremove keeps the running kernel and the newest ones, but not always the one
`/boot/vmlinuz.old` points at. Purges cannot be rolled back, so read the plan of `cleanup -n`
before you run `cleanup`.

`cleanup` refuses until `migrate --stage finalize` is done. Until then the legacy entries, and
a rollback of the menu stage, boot kernels by their versions, which a purge would take away.

### What the plan says

Each line starts with `kernel-updater: plan:`. `cleanup --porcelain` prints the same as
`STEP<TAB>ACTION<TAB>OBJECT<TAB>DETAIL` records on stdout once the run ends with 0; they name
packages, releases and paths only.

| Plan line | Means |
|---|---|
| `keep RELEASE (running, vmlinuz) and RELEASE (vmlinuz.old)` | The releases nothing is purged or moved for: the running kernel's and those the links in `/boot` point at. Check that it names the running kernel and the kernels of `/boot/vmlinuz` and `/boot/vmlinuz.old` |
| `purge nothing while a reboot is pending: ...; reboot first` | A kernel install moved `/boot/vmlinuz` to a kernel that is not running yet. Reboot into "Kali GNU/Linux", then run `cleanup` again; the module trees and the quarantine are still looked after meanwhile |
| `purge N packages removed with config files left: ...` | Kernel packages apt removed without purging them; their config files go |
| `leave N packages removed with config files left: PACKAGE (WHY), ...` | Such packages that stay: held, of a kept kernel, of a kernel still installed through another package (as `linux-image-V-unsigned`), a debug build, or headers or build tools the kernels of one ABI share |
| `purge N packages apt autoremove names for old kernels: ...` | The old kernels apt's autoremove would remove, with their headers and build tools, but none of a kept release |
| `leave N packages apt autoremove names: PACKAGE (WHY), ...` | What apt's autoremove names that `cleanup` leaves: anything that is no versioned kernel package, a debug build, a package of a kept kernel or one that shares its version with it, one dpkg does not list as installed, or a held one. Remove the others with apt yourself if you want them gone |
| `leave PACKAGE: marked manual; 'apt-mark auto PACKAGE' lets apt prune it` | An old kernel package marked manual, which apt's autoremove never names; see below |
| `remove the empty directory /usr/lib/modules/RELEASE` | An empty module tree no package owns, which `rmdir` removes |
| `move /usr/lib/modules/RELEASE into the quarantine: no package owns it` | A module tree of a kernel that is gone, which moves to `/var/lib/kernel-updater/quarantine` |
| `keep /usr/lib/modules/RELEASE: WHY` | A module tree that stays, and why, such as `dkms lists modules for it ('dkms remove MODULE/VERSION -k RELEASE')` |
| `leave /usr/lib/modules/RELEASE: WHY` | A tree that cannot move now, or one of a release this run purges, which the next run looks at |
| `delete quarantine entry RELEASE.STAMP: N days old (quarantine_days 30)` | A quarantined tree that expired |
| `keep quarantine entry RELEASE.STAMP: ...` | A quarantined tree that stays, with its age, and whether this run marks it seen |
| `leave quarantine entry RELEASE.STAMP: WHY` or `expire nothing: WHY` | An entry, or the whole quarantine, that expiry leaves alone, such as one that is a symlink or belongs to another user |
| `then sync` | `sync` runs before the last line, which says what the run did |

### Old kernels marked manual

A kernel installed by name, as with `sudo apt install linux-image-VERSION`, is marked manual,
and apt's autoremove never names it, so `cleanup` only lists it. To list them all:

```bash
apt-mark showmanual | grep -E '^linux-(image|binary|modules|base|headers)-[0-9]'
```

For an old kernel you no longer want, run `sudo apt-mark auto PACKAGE` for each of its packages,
then `cleanup` again. Never mark the running kernel or the kernels of `/boot/vmlinuz` and
`/boot/vmlinuz.old` auto: `cleanup` keeps them, but a plain `apt autoremove` may not.

## When cleanup refuses

Every refusal changes nothing. Settle the cause, then run `cleanup` again: it plans anew.

- **Exit 3, "apt would also remove X".** The purge would take X along.
  - When X is a metapackage such as `linux-image-amd64` or `linux-headers-amd64`, never purge
    it: without it no kernel update comes in. It still depends on the old kernel, so run
    `sudo apt full-upgrade` first, which moves it to the newest one, or keep the old kernel with
    `sudo apt-mark manual PACKAGE`.
  - When X is a DKMS package, or another one that depends on an old kernel's headers, purge X
    yourself, or keep that kernel with `sudo apt-mark manual PACKAGE`.
- **Exit 3, "apt would also install or configure X"**, or the same about apt's autoremove. apt's
  state is not settled: run `sudo apt full-upgrade`, then `sudo kernel-updater check`.
- **Exit 3, "apt-get cannot simulate ..." or "apt-mark cannot list ...".** apt's own messages
  above it say why; `apt-get -s autoremove --purge` shows them again.
- **Exit 3, "apt-get purge failed ... before dpkg changed anything".** apt or apt-guard refused
  the purge, and their messages above it say why.
- **Exit 3, "kernels: ... run dpkg --configure -a" or "dpkg was interrupted".** A kernel
  package is stuck between states, or a dpkg run was cut short. Run `sudo dpkg --configure -a`,
  then `sudo kernel-updater check`. When a new kernel's initrd fails its check, see
  [When a new kernel fails](#when-a-new-kernel-fails); `cleanup` refuses while the kernel is
  half-configured. When the message says that the running kernel is not installed, boot one
  that is.
- **"... after dpkg began to change its database"**, with exit 4 when apt-get failed, or 130
  or 129 when Ctrl-C or a closed terminal cut the purge short. Run `sudo dpkg --configure -a`,
  then `sudo kernel-updater check`, then `cleanup` again, which plans anew from what is left.
  When a purge cut short says that nothing was purged instead, only run `cleanup` again.
- **Exit 4 after "the purge ran, but the check of the links and kernels after it fails".** Run
  `sudo kernel-updater check` and settle what fails before the next reboot.
- **Exit 75.** Another kernel-updater run, apt or dpkg is running, and the message names its PID
  and command; or the system changed while the question waited. Wait until the other run is
  done.
- **Exit 66 or 78.** `/boot` is not mounted, or it is not the one the configuration names:
  unlock and mount the stick's `/boot`. A 78 that names a key or a line of
  `/etc/kernel-updater.conf` means that the file needs a fix.
- **Exit 66 or 78, saying "cleanup cannot tell whether the migration is finished".** `cleanup`
  could not read the menu on partition 1, or the stick is not the one the configuration names.
  While a desktop has partition 1 mounted for its user, unmount it there first. Settle what the
  message names, then run `cleanup` again. No option skips this check.
- **Exit 3, naming `migrate --stage detect`, `system`, `menu` or `finalize`.** The migration is
  not done: see [migration.md](migration.md). When the message names an export, copy it to the
  stick from Windows as its `DEPLOY.txt` says, unless you have done so already: a second copy
  undoes what changed on the stick since.
- **Exit 3, "the export in output_dir waits to put back a menu".** A rollback in the VM exported
  a menu with entries that boot kernels by version. Copy it to the stick, unless you have done so
  already, as a second copy undoes what changed on the stick since. Then finish the migration
  again. Or delete the export if you no longer want that rollback. This holds while the export's
  `SHA256SUMS` is damaged too, since cleanup cannot tell whether the stick holds it.
- **Exit 3, starting with `kali-menu:`.** The menu on partition 1 is damaged, as the message says.
  Run `sudo kernel-updater check`, and settle its `kali-menu` item first.
- **"purge nothing while a reboot is pending".** Reboot into "Kali GNU/Linux". When the new
  kernel does not boot, see [When a new kernel fails](#when-a-new-kernel-fails).
- **A tree kept because "dkms lists modules for it".** Remove those modules with the command the
  plan names, `sudo dkms remove MODULE/VERSION -k RELEASE`.
- **A tree listed but not moved**, as "leave /usr/lib/modules/RELEASE: no package owns it, but
  ...". It may lie on another filesystem than the quarantine, or `mv` may be older than
  coreutils 9.2, which `cleanup` needs to move a tree without copying it. Leave the tree, or
  move or delete it by hand once you know nothing needs it.

## Restore or delete a quarantined tree

`cleanup` moves a module tree no package owns to
`/var/lib/kernel-updater/quarantine/RELEASE.STAMP/tree`, `STAMP` being the UTC time of the move.
The entry also holds `origin`, which says where the tree came from and why it moved, and, once a
later run found the entry, `seen`. Everything there is root's alone:

```bash
sudo ls -l /var/lib/kernel-updater/quarantine
sudo cat /var/lib/kernel-updater/quarantine/RELEASE.STAMP/origin
```

To restore a tree, move it back to the path `origin` names, here `/usr/lib/modules/RELEASE`,
while nothing is there, then remove what is left of the entry, `seen` only when it is there:

```bash
sudo mv -T /var/lib/kernel-updater/quarantine/RELEASE.STAMP/tree /usr/lib/modules/RELEASE
sudo rm /var/lib/kernel-updater/quarantine/RELEASE.STAMP/origin
sudo rm /var/lib/kernel-updater/quarantine/RELEASE.STAMP/seen
sudo rmdir /var/lib/kernel-updater/quarantine/RELEASE.STAMP
```

A restored tree that no package owns goes into the quarantine again on the next `cleanup` run.
Install the kernel it belongs to first, or run `cleanup --no-modules` meanwhile.

To free the space before an entry expires, or when `quarantine_days` is 0, delete it by hand:

```bash
sudo rm -r --one-file-system /var/lib/kernel-updater/quarantine/RELEASE.STAMP
```

`install.sh --uninstall` leaves the quarantine, the baseline in `/var/lib/kernel-updater` and
`migrate`'s backups in `/var/backups/kernel-updater` in place: delete them by hand once you no
longer need them.

## When a new kernel fails

The postinst hook checks each new kernel once initramfs-tools has built its initrd. When the
check fails, it stops the kernel's configure and the package stays half-configured, but the
links in `/boot` already point at the new kernel. Do not reboot into "Kali GNU/Linux" until the
check passes. If you did reboot and the new kernel fails, choose "Kali GNU/Linux (previous
kernel)", which boots the kernel the `.old` links point at. Then do one of these:

- **Fix the cause the hook names**, such as a package the initrd needs or a key file
  `/etc/crypttab` names that the initrd lacks, then rebuild the initrd and finish the configure:

  ```bash
  sudo update-initramfs -u -k VERSION
  sudo dpkg --configure -a
  sudo kernel-updater check
  ```

- **Or give the kernel up.** List its packages with `dpkg -l '*-VERSION'` and purge them all in
  one apt run, `sudo apt purge PACKAGE...`: `linux-image-VERSION` and, for kernels split as
  Kali's are since 6.19, `linux-binary-VERSION`, `linux-modules-VERSION` and
  `linux-base-VERSION`, and `linux-headers-VERSION` when it is installed. linux-base then points
  the links back at the kernels left, which `sudo kernel-updater check` confirms. When
  `linux-image-amd64` depends on that exact version, as it does on the newest kernel, apt
  removes it too, and kernel updates stop until you install it again with
  `sudo apt install linux-image-amd64`, once Kali ships a fixed kernel. A later `cleanup` purges
  what is left.

As a last resort, when neither Kali entry boots: in the GRUB menu, highlight "Kali GNU/Linux
(previous kernel)" and press `e`. Change only the kernel and initrd paths, `/vmlinuz.old` and
`/initrd.img.old` on every line that names them, to those of an older kernel in `/boot`,
`/vmlinuz-VERSION` and `/initrd.img-VERSION`, then press Ctrl-X to boot it. `cryptomount` still
asks for the passphrase of `/boot`, and the edit is not saved. The values such an entry needs
also stand in `multibootusb/grub/kali.cfg` on partition 1, which Windows can read;
`/etc/kernel-updater.conf` sits on the encrypted root and cannot be read then.

When the menu itself is damaged, copy back from Windows the copy of `BOOT:\multibootusb\grub`
you keep, as step 1 of [migration.md](migration.md) made one. A copy from before the migration
brings back entries that name kernel versions, which boot only while `/boot` holds those
kernels. Then run `sudo kernel-updater check`: its `tripwire` item shows what changed.

## Rebuild one kernel's initrd

After a change to `/etc/crypttab`, cryptsetup-initramfs, the root key file or the
initramfs-tools configuration, rebuild the initrd of the kernel `/boot/vmlinuz` points at
(`readlink /boot/vmlinuz` names it) and of no other. Never use `-k all`: the `.old` kernel's
initrd is the fallback and stays as it is until the new one has booted.

1. Copy the current initrd to `/root`: `sudo cp -p /boot/initrd.img-VERSION /root/`. It holds
   the key files `/etc/crypttab` names, so never copy it to partition 1 or to Windows.
2. Rebuild it: `sudo update-initramfs -u -k VERSION`.
3. Run `sudo kernel-updater check`. Its `initrd` item checks that the initrd holds the kernel's
   modules, `cryptsetup`, the cryptroot configuration and the key files, and warns when group or
   others can read it.
4. Boot "Kali GNU/Linux".
5. When it fails, boot "Kali GNU/Linux (previous kernel)" and put the copy back:
   `sudo cp -p /root/initrd.img-VERSION /boot/`.
6. Once the new initrd has booted, delete the copy: `sudo rm /root/initrd.img-VERSION`.
7. Rebuild the `.old` kernel's initrd, if it needs the change too, only after that boot, the
   same way.

## An optional GRUB default entry

Unless `grub.cfg` sets a default, GRUB starts the first entry of MultiBootUSB's menu once its
timeout runs out. To have it start "Kali GNU/Linux" instead, edit partition 1's
`multibootusb/grub/grub.cfg` by hand from Windows, keeping its CRLF line endings, and add this
line after the one that sets `timeout`, or change the line that sets `default` when there is
one:

```text
set default="kali>kali-default"
```

- kernel-updater never sets a default.
- The entry still stops at `cryptomount` and asks for the passphrase of `/boot`.
- The stick boots several systems, so a default changes what boots unattended.
- GRUB's `fallback` only applies to an automatic boot, and only to failures inside GRUB, not to
  a kernel that fails once it runs.
- MultiBootUSB may rewrite `grub.cfg` when it adds an ISO, which can drop the line.
- After an edit, run `kernel-updater lint` on the file, or on a copy of it, then
  `sudo kernel-updater baseline`, which shows that `grub.cfg` changed and records it once you
  confirm; until then check's `tripwire` item fails.
- To undo it, remove the line, then lint the file and record the baseline again.

## What this runbook never suggests

A key file for `/boot` or any other automatic unlock, a conversion of `/boot`'s LUKS1
container to LUKS2 or Argon2, `update-initramfs -k all`, and `update-grub` for the stick, whose
menu MultiBootUSB's GRUB reads from partition 1.
