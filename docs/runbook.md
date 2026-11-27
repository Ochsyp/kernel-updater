# Runbook

This page says how to keep the stick's Kali install in shape once `kernel-updater migrate` has
run, as [migration.md](migration.md) describes. It also says what to do when something goes
wrong.

- Every command that changes the system prints its plan and asks first.
- `-n` shows the plan alone.
- No message prints a disk identifier.
- Where this page shows `VERSION` or `RELEASE`, put a kernel release, such as `uname -r` prints.
- Where it shows `PACKAGE`, put a package name.

## Before anything

Unlock and mount `/boot` with its passphrase, as for any kernel update.

The passphrase stays the only way into `/boot`. Nothing in this runbook adds a key file for it
or unlocks it automatically.

While `/boot` is not mounted:

- the hooks refuse kernel installs and removals;
- `cleanup` exits 66;
- the detect, system and menu stages of `migrate` exit 66.

## Routine use

1. Update with `sudo apt full-upgrade`.
   - The hooks refuse a kernel install while `/boot` is not mounted.
   - They check that a new kernel's initrd would boot. When that check fails, see
     [When a new kernel fails](#when-a-new-kernel-fails).
   - A new kernel moves `/boot/vmlinuz` and `/boot/initrd.img` to itself. The `.old` links move
     to the kernel they left.
   - Nothing on the stick's partition 1 changes.
2. Reboot into "Kali GNU/Linux". It boots the new kernel. When the new kernel fails, see
   [When a new kernel fails](#when-a-new-kernel-fails).
3. Run `sudo /usr/local/bin/kernel-updater check`. No item should fail.
4. Now and then, purge what old kernels leave behind. Read the plan first, then run it:

   ```bash
   sudo /usr/local/bin/kernel-updater cleanup -n
   sudo /usr/local/bin/kernel-updater cleanup
   ```

   When `cleanup` refuses, see [When cleanup refuses](#when-cleanup-refuses).

Why `cleanup`:

- Old kernels stay installed until apt's autoremove removes them.
- A kernel that apt removes leaves its config files behind (`rc` in `dpkg -l`).
- `apt-get upgrade` removes no kernel at all.

`cleanup` purges both kinds of leftover in one apt run, and only kernel packages. It never
purges the running kernel, or one the links in `/boot` point at. apt's own autoremove keeps the
running kernel and the newest ones. It does not always keep the one `/boot/vmlinuz.old` points
at.

Purges cannot be rolled back. Read the plan of `cleanup -n` before you run `cleanup`.

`cleanup` refuses until `migrate --stage finalize` is done. Until then, the legacy entries boot
kernels by their versions, and so does a rollback of the menu stage. A purge would take those
kernels away.

### What the plan says

Each line starts with `kernel-updater: plan:`.

`cleanup --porcelain` prints the same as records on stdout:
`STEP<TAB>ACTION<TAB>OBJECT<TAB>DETAIL`. It prints them once the run ends with 0. They name
packages, releases and paths only.

| Plan line | Means |
|---|---|
| `keep RELEASE (running, vmlinuz) and RELEASE (vmlinuz.old)` | The releases for which nothing is purged or moved. They are the running kernel's, and those the links in `/boot` point at. Check that the line names the running kernel and the kernels of `/boot/vmlinuz` and `/boot/vmlinuz.old` |
| `purge nothing while a reboot is pending: ...; reboot first` | A kernel install moved `/boot/vmlinuz` to a kernel that is not running yet. Reboot into "Kali GNU/Linux", then run `cleanup` again. Meanwhile the module trees and the quarantine are still looked after |
| `purge N packages removed with config files left: ...` | Kernel packages apt removed without purging them. Their config files go |
| `leave N packages removed with config files left: PACKAGE (WHY), ...` | Such packages that stay. WHY is one of: held; of a kept kernel; of a kernel still installed through another package (as `linux-image-V-unsigned`); a debug build; headers or build tools the kernels of one ABI share |
| `purge N packages apt autoremove names for old kernels: ...` | The old kernels apt's autoremove would remove, with their headers and build tools. None of them is of a kept release |
| `leave N packages apt autoremove names: PACKAGE (WHY), ...` | What apt's autoremove names that `cleanup` leaves. That is: anything that is no versioned kernel package; a debug build; a package of a kept kernel, or one that shares its version with it; one dpkg does not list as installed; a held one. Remove the others with apt yourself if you want them gone |
| `leave PACKAGE: marked manual; 'apt-mark auto PACKAGE' lets apt prune it` | An old kernel package marked manual. apt's autoremove never names it. See below |
| `remove the empty directory /usr/lib/modules/RELEASE` | An empty module tree that no package owns. `rmdir` removes it |
| `move /usr/lib/modules/RELEASE into the quarantine: no package owns it` | A module tree of a kernel that is gone. It moves to `/var/lib/kernel-updater/quarantine` |
| `keep /usr/lib/modules/RELEASE: WHY` | A module tree that stays, and why, such as `dkms lists modules for it ('dkms remove MODULE/VERSION -k RELEASE')` |
| `leave /usr/lib/modules/RELEASE: WHY` | A tree that cannot move now, or one of a release this run purges. The next run looks at it |
| `delete quarantine entry RELEASE.STAMP: N days old (quarantine_days 30)` | A quarantined tree that expired |
| `keep quarantine entry RELEASE.STAMP: ...` | A quarantined tree that stays. The line gives its age, and whether this run marks it seen |
| `leave quarantine entry RELEASE.STAMP: WHY` or `expire nothing: WHY` | An entry, or the whole quarantine, that expiry leaves alone. An example is one that is a symlink or belongs to another user |
| `then sync` | `sync` runs before the last line. The last line says what the run did |

### Old kernels marked manual

A kernel installed by name is marked manual, as with `sudo apt install linux-image-VERSION`.
apt's autoremove never names it, so `cleanup` only lists it. To list them all:

```bash
apt-mark showmanual | grep -E '^linux-(image|binary|modules|base|headers)-[0-9]'
```

For an old kernel you no longer want, run `sudo apt-mark auto PACKAGE` for each of its packages.
Then run `cleanup` again.

Never mark these kernels auto: the running kernel, and the kernels of `/boot/vmlinuz` and
`/boot/vmlinuz.old`. `cleanup` keeps them, but a plain `apt autoremove` may not.

## When cleanup refuses

Every refusal changes nothing. Settle the cause, then run `cleanup` again. It plans anew.

- **Exit 3, "apt would also remove X".** The purge would take X along.
  - X may be a metapackage such as `linux-image-amd64` or `linux-headers-amd64`. Never purge it:
    without it, no kernel update comes in. It still depends on the old kernel. Run
    `sudo apt full-upgrade` first, which moves it to the newest one. Or keep the old kernel with
    `sudo apt-mark manual PACKAGE`.
  - X may be a DKMS package, or another one that depends on an old kernel's headers. Purge X
    yourself, or keep that kernel with `sudo apt-mark manual PACKAGE`.
- **Exit 3, "apt would also install or configure X"**, or the same about apt's autoremove. apt's
  state is not settled. Run `sudo apt full-upgrade`, then
  `sudo /usr/local/bin/kernel-updater check`.
- **Exit 3, "apt-get cannot simulate ..." or "apt-mark cannot list ...".** apt's own messages
  above it say why. `apt-get -s autoremove --purge` shows them again.
- **Exit 3, "apt-get purge failed ... before dpkg changed anything".** apt or apt-guard refused
  the purge. Their messages above it say why.
- **Exit 3, "kernels: ... run dpkg --configure -a" or "dpkg was interrupted".** A kernel package
  is stuck between states, or a dpkg run was cut short. Run `sudo dpkg --configure -a`, then
  `sudo /usr/local/bin/kernel-updater check`.
  - When a new kernel's initrd fails its check, see
    [When a new kernel fails](#when-a-new-kernel-fails). `cleanup` refuses while the kernel is
    half-configured.
  - When the message says that the running kernel is not installed, boot one that is.
- **"... after dpkg began to change its database".** The exit status is 4 when apt-get failed.
  It is 130, 129 or 143 when Ctrl-C, a closed terminal or a kill cut the purge short.
  1. Run `sudo dpkg --configure -a`.
  2. Run `sudo /usr/local/bin/kernel-updater check`.
  3. Run `cleanup` again. It plans anew from what is left.

  When a purge cut short says instead that nothing was purged, only run `cleanup` again.
- **Exit 4 after "the purge ran, but the check of the links and kernels after it fails".** Run
  `sudo /usr/local/bin/kernel-updater check`. Settle what fails before the next reboot.
- **Exit 75.** One of these holds:
  - Another kernel-updater run, apt or dpkg is running. For apt and dpkg, the message names the
    PID and command.
  - The system changed while the question waited.

  Wait until the other run is done.
- **Exit 66 or 78.** `/boot` is not mounted, or it is not the one the configuration names.
  Unlock and mount the stick's `/boot`. A 78 that names a key or a line of
  `/etc/kernel-updater.conf` means that the file needs a fix.
- **Exit 66 or 78, saying "cleanup cannot tell whether the migration is finished".** `cleanup`
  could not read the menu on partition 1, or the stick is not the one the configuration names.
  - While a desktop has partition 1 mounted for its user, unmount it there first.
  - Settle what the message names, then run `cleanup` again.

  No option skips this check.
- **Exit 3, naming `migrate --stage detect`, `system`, `menu` or `finalize`.** The migration is
  not done. See [migration.md](migration.md). When the message names an export, copy it to the
  stick from Windows as its `DEPLOY.txt` says. Skip the copy if you have done so already: a
  second copy undoes what changed on the stick since.
- **Exit 3, "the export in output_dir waits to put back a menu".** A rollback in the VM exported
  a menu with entries that boot kernels by version. Do one of these:
  - Copy it to the stick, then finish the migration again. Skip the copy if you have done so
    already: a second copy undoes what changed on the stick since.
  - Delete the export, if you no longer want that rollback.

  This holds while the export's `SHA256SUMS` is damaged too, since cleanup cannot tell whether
  the stick holds it.
- **Exit 3, starting with `kali-menu:`.** The menu on partition 1 is damaged, as the message
  says. Run `sudo /usr/local/bin/kernel-updater check`, and settle its `kali-menu` item first.
- **"purge nothing while a reboot is pending".** Reboot into "Kali GNU/Linux". When the new
  kernel does not boot, see [When a new kernel fails](#when-a-new-kernel-fails).
- **A tree kept because "dkms lists modules for it".** Remove those modules with the command the
  plan names: `sudo dkms remove MODULE/VERSION -k RELEASE`.
- **A tree listed but not moved**, as "leave /usr/lib/modules/RELEASE: no package owns it, but
  ...". Possible causes:
  - The tree may lie on another filesystem than the quarantine.
  - `mv` may be older than coreutils 9.2. `cleanup` needs coreutils 9.2 to move a tree without
    copying it.

  Leave the tree, or move or delete it by hand once you know nothing needs it.

## Restore or delete a quarantined tree

`cleanup` moves a module tree that no package owns to
`/var/lib/kernel-updater/quarantine/RELEASE.STAMP/tree`. `STAMP` is the UTC time of the move.
The entry also holds:

- `origin`, which says where the tree came from and why it moved;
- `seen`, once a later run found the entry.

Everything there is root's alone:

```bash
sudo ls -l /var/lib/kernel-updater/quarantine
sudo cat /var/lib/kernel-updater/quarantine/RELEASE.STAMP/origin
```

To restore a tree, move it back to the path `origin` names, here `/usr/lib/modules/RELEASE`. Do
this only while nothing is at that path. Then remove what is left of the entry. Remove `seen`
only when it is there:

```bash
sudo mv -T /var/lib/kernel-updater/quarantine/RELEASE.STAMP/tree /usr/lib/modules/RELEASE
sudo rm /var/lib/kernel-updater/quarantine/RELEASE.STAMP/origin
sudo rm /var/lib/kernel-updater/quarantine/RELEASE.STAMP/seen
sudo rmdir /var/lib/kernel-updater/quarantine/RELEASE.STAMP
```

A restored tree that no package owns goes into the quarantine again on the next `cleanup` run.
Install the kernel it belongs to first, or run `cleanup --no-modules` meanwhile.

To free the space before an entry expires, or when `quarantine_days` is 0, delete the entry by
hand:

```bash
sudo rm -r --one-file-system /var/lib/kernel-updater/quarantine/RELEASE.STAMP
```

`install.sh --uninstall` leaves these in place:

- the quarantine;
- the baseline in `/var/lib/kernel-updater`;
- `migrate`'s backups in `/var/backups/kernel-updater`.

Delete them by hand once you no longer need them.

## When a new kernel fails

The postinst hook checks each new kernel once initramfs-tools has built its initrd. When the
check fails:

- the hook stops the kernel's configure;
- the package stays half-configured;
- the links in `/boot` already point at the new kernel.

Do not reboot into "Kali GNU/Linux" until the check passes. If you did reboot and the new kernel
fails, choose "Kali GNU/Linux (previous kernel)". It boots the kernel the `.old` links point at.
Then do one of these:

- **Fix the cause the hook names.** Examples are a package the initrd needs, or a key file that
  `/etc/crypttab` names and the initrd lacks. Then rebuild the initrd and finish the configure:

  ```bash
  sudo update-initramfs -u -k VERSION
  sudo dpkg --configure -a
  sudo /usr/local/bin/kernel-updater check
  ```

- **Or give the kernel up.** List its packages with `dpkg -l '*-VERSION'`. Purge them all in one
  apt run, `sudo apt purge PACKAGE...`. The packages are:
  - `linux-image-VERSION`;
  - for kernels split as Kali's are since 6.19: `linux-binary-VERSION`, `linux-modules-VERSION`
    and `linux-base-VERSION`;
  - `linux-headers-VERSION`, when it is installed.

  linux-base then points the links back at the kernels left.
  `sudo /usr/local/bin/kernel-updater check` confirms that.

  `linux-image-amd64` may depend on that exact version, as it does on the newest kernel. Then
  apt removes it too, and kernel updates stop. Once Kali ships a fixed kernel, install it again
  with `sudo apt install linux-image-amd64`. A later `cleanup` purges what is left.

As a last resort, when neither Kali entry boots, edit the entry in GRUB:

1. In the GRUB menu, highlight "Kali GNU/Linux (previous kernel)" and press `e`.
2. Change only the kernel and initrd paths, `/vmlinuz.old` and `/initrd.img.old`, on every line
   that names them. Change them to those of an older kernel in `/boot`: `/vmlinuz-VERSION` and
   `/initrd.img-VERSION`.
3. Press Ctrl-X to boot it.

`cryptomount` still asks for the passphrase of `/boot`. The edit is not saved.

The values such an entry needs also stand in `multibootusb/grub/kali.cfg` on partition 1, which
Windows can read. `/etc/kernel-updater.conf` sits on the encrypted root and cannot be read then.

When the menu itself is damaged, copy back from Windows the copy of `BOOT:\multibootusb\grub`
you keep. Step 1 of [migration.md](migration.md) made one. A copy from before the migration
brings back entries that name kernel versions. Those boot only while `/boot` holds those
kernels. Then run `sudo /usr/local/bin/kernel-updater check`. Its `tripwire` item shows what
changed.

## Rebuild one kernel's initrd

Rebuild an initrd after a change to any of these:

- `/etc/crypttab`;
- cryptsetup-initramfs;
- the root key file;
- the initramfs-tools configuration.

Rebuild the initrd of the kernel `/boot/vmlinuz` points at, and of no other.
`readlink /boot/vmlinuz` names that kernel. Never use `-k all`. The `.old` kernel's initrd is the
fallback, and it stays as it is until the new one has booted.

1. Copy the current initrd to `/root`: `sudo cp -p /boot/initrd.img-VERSION /root/`. The copy
   holds the key files `/etc/crypttab` names. Never copy it to partition 1 or to Windows.
2. Rebuild it: `sudo update-initramfs -u -k VERSION`.
3. Run `sudo /usr/local/bin/kernel-updater check`. Its `initrd` item checks that the initrd
   holds the kernel's modules, `cryptsetup`, the cryptroot configuration and the key files. It
   warns when group or others can read the initrd.
4. Boot "Kali GNU/Linux".
5. When it fails, boot "Kali GNU/Linux (previous kernel)" and put the copy back:
   `sudo cp -p /root/initrd.img-VERSION /boot/`.
6. Once the new initrd has booted, delete the copy: `sudo rm /root/initrd.img-VERSION`.
7. If the `.old` kernel's initrd needs the change too, rebuild it the same way. Do it only after
   that boot.

## An optional GRUB default entry

Unless `grub.cfg` sets a default, GRUB starts the first entry of MultiBootUSB's menu once its
timeout runs out. To have it start "Kali GNU/Linux" instead:

1. From Windows, edit partition 1's `multibootusb/grub/grub.cfg` by hand. Keep its CRLF line
   endings.
2. Add this line after the one that sets `timeout`. When a line sets `default` already, change
   that line instead:

   ```text
   set default="kali>kali-default"
   ```

- kernel-updater never sets a default.
- The entry still stops at `cryptomount` and asks for the passphrase of `/boot`.
- The stick boots several systems, so a default changes what boots unattended.
- GRUB's `fallback` only applies to an automatic boot. It only applies to failures inside GRUB,
  not to a kernel that fails once it runs.
- MultiBootUSB may rewrite `grub.cfg` when it adds an ISO, which can drop the line.
- After an edit, run `/usr/local/bin/kernel-updater lint` on the file, or on a copy of it. Then
  run `sudo /usr/local/bin/kernel-updater baseline`. It shows that `grub.cfg` changed, and
  records it once you confirm. Until then, check's `tripwire` item fails.
- To undo it, remove the line. Then lint the file and record the baseline again.

## What this runbook never suggests

- A key file for `/boot`, or any other automatic unlock.
- A conversion of `/boot`'s LUKS1 container to LUKS2 or Argon2.
- `update-initramfs -k all`.
- `update-grub` for the stick, whose menu MultiBootUSB's GRUB reads from partition 1.
