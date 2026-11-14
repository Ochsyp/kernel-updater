# Migrating the stick's Kali entries

This is the walkthrough for the one-time switch that `kernel-updater migrate` makes: from Kali
entries that name a kernel version, which every kernel update breaks, to entries that boot the
links linux-base keeps in `/boot`. Afterwards a kernel update changes nothing on the stick's
partition 1, and kernel-updater only watches.

Do the steps in order, and do not skip a test: each stage builds on the one before, and
system, menu and finalize each keep a backup that `kernel-updater migrate --rollback` restores
(see [Rolling back](#rolling-back)); detect keeps none. Every command prints its plan and asks
before it changes anything; `-n` shows the plan alone.
No message prints an identifier: where this page shows `<boot_luks_uuid>` and the like, read
the value in `/etc/kernel-updater.conf`.

## 1. Back up the menu from Windows

In Windows, copy the folder `BOOT:\multibootusb\grub` from the stick to a safe place. It holds
`grub.cfg`, the menu MultiBootUSB boots, which the menu stage changes. kernel-updater keeps
backups of its own, but this copy works even when Kali does not boot.

## 2. Let Windows leave the stick clean

Turn Fast Startup off in Windows (Control Panel, Power Options, "Choose what the power buttons
do"), and eject the stick in Windows before you boot from it. A volume that Windows hibernated,
kept in its cache or left unclean is never written: kernel-updater then exports the files
instead, and says why.

## 3. Install kernel-updater

In Kali, from the checkout:

```bash
sudo ./install.sh
```

It installs the tool under `/usr/local` and the hooks that refuse a kernel install while
`/boot` is not mounted. They only warn until the next step sets `boot_fs_uuid`.

## 4. Detect the identity

With `/boot` unlocked and mounted, as for any kernel update:

```bash
sudo kernel-updater migrate --stage detect
```

It appends to `/etc/kernel-updater.conf` the UUIDs of `/boot` and of its LUKS container, the
stick's PTUUID and the serial of its partition 1, the `root=` device of the running kernel, and
`grub_floor` from the version of the stick's GRUB. Setting `boot_fs_uuid` arms the hooks. A key
the file sets to another value stops the stage with exit 78, naming the key: correct or remove
that line. Read the values in the file and compare them with `sudo lsblk -o
NAME,LABEL,PTUUID,UUID` and `cat /proc/cmdline` if you like.

## 5. Check the system

```bash
sudo kernel-updater check
```

No item should fail but `grub-pc`, which the system stage settles. Until then `kernel-img`
warns and the items about the links in `/boot` skip; `tripwire` warns while no baseline is
stored, and `kali-menu` skips until the menu stage and warns until the finalize stage.
`boot-identity`, `boot-luks` and `boot-ext` must be `ok`: they say whether `/boot` is the one
the configuration names, and whether the stick's GRUB unlocks and reads it.

## 6. Configure the kernel links

See the plan first, then run the stage:

```bash
sudo kernel-updater migrate --stage system -n
sudo kernel-updater migrate --stage system
```

It sets `do_symlinks = yes` and `link_in_boot = yes` in `/etc/kernel-img.conf`, points
`/boot/vmlinuz` and `/boot/initrd.img` at the newest kernel and `vmlinuz.old` and
`initrd.img.old` at the previous one (the running kernel when it is an older one) with
`linux-update-symlinks`, and moves the old links out of `/` into its backup. A second question
offers to empty grub-pc's install devices, so that a grub-pc upgrade never writes GRUB over the
stick's boot loader; answer yes unless you know better. The old answer is kept nowhere, since it
names devices. Afterwards it checks that each link points at the kernel the plan named. Should
apt install or remove a kernel while the question waits, the stage refuses and changes
nothing: run it again.

It refuses while no installed kernel would boot from the stick, and also while only one would
but `/boot` holds another kernel's image, such as an older kernel whose initrd lacks the key
files: `linux-update-symlinks` takes the `.old` links from the images in `/boot` and would
point them at that one. Rebuild that kernel's initrd (`sudo update-initramfs -u -k VERSION`),
or remove the kernel, first.

## 7. Test both pairs of links at the GRUB prompt

GRUB must follow the new links on `/boot` before the menu relies on them. Boot the stick
natively, and in MultiBootUSB's menu press `c` for the GRUB prompt. Then type, with the values
from `/etc/kernel-updater.conf` (the LUKS UUID without its dashes):

```text
cryptomount -u <boot_luks_uuid without dashes>
search --no-floppy --fs-uuid --set=root <boot_fs_uuid>
linux /vmlinuz root=<root_device>
initrd /initrd.img
linux /vmlinuz.old root=<root_device>
initrd /initrd.img.old
```

`cryptomount` asks for the passphrase of `/boot`. Each `linux` and `initrd` must return to the
prompt without a message; `file not found` or `invalid symlink` means GRUB cannot follow that
link. A plain `ls` proves nothing: it lists the link names even when a link is absolute or
dangles, while only `linux` and `initrd` read through the link as the menu will. Press Esc to
return to the menu, and boot Kali the old way.

Do the same in the VM that boots the stick, since its GRUB reaches the stick through another
path. When either test fails, run `sudo kernel-updater migrate --rollback` and stop here.

## 8. Write the new menu

Natively, where kernel-updater may write partition 1:

```bash
sudo kernel-updater migrate --stage menu -n
sudo kernel-updater migrate --stage menu
```

It writes `multibootusb/grub/kali.cfg`, whose entries boot `/vmlinuz` and `/initrd.img`, and
for the previous kernel `/vmlinuz.old` and `/initrd.img.old`, and replaces the Kali submenu in
`grub.cfg` with a block that loads `kali.cfg` with `source`. The old submenu stays behind that
block as "... (legacy entries)", a fallback until the finalize stage. Every other byte of
`grub.cfg` stays as it was, CRLF line endings included; both files pass `grub-script-check`,
and `kali.cfg` passes `lint` with the stick's own GRUB lists (GRUB 2.02's when those cannot be
read), before anything is written. The
plan lists the entries with their kernel parameters, each change against the old entries, such
as a `cryptdevice=` that goes, and the old entries that are not carried over; a parameter that
may name a device, a UUID or a key file shows as `NAME=<value>`, while `kali.cfg` gets it as
it is. `menu_variants` and `previous_variants` choose the entries. To change them later, edit
them and run the menu stage again while the legacy entries remain: it leaves `grub.cfg` as it
is and writes `kali.cfg` alone anew, with a backup of its own.

Written to partition 1, both files take their entries in the baseline of check's tripwire, if
one is stored. When the plan says that `grub.cfg` differs from that baseline, something changed
it since, such as MultiBootUSB adding an ISO from Windows: look at `grub.cfg` on the stick before
you answer, since what changed outside the Kali submenu stays. Its entry then keeps the old
value, so the tripwire keeps reporting the change until step 11 records it.

In the VM, or with `--deploy export`, the files go to `output_dir` instead: copy them in
Windows, `kali.cfg` first, into `BOOT:\multibootusb\grub\`, as `DEPLOY.txt` there says, then
run `sudo kernel-updater check`, whose `deployed` item compares the stick with the export. Its
`tripwire` item fails for the two files, when a baseline is stored, until step 11. Should a
later stage or rollback write partition 1 itself while such an export is not copied, that
write removes the export, which copied afterwards would undo it.

## 9. Boot the new entries

Boot the stick natively and choose, under the Kali submenu, "Kali GNU/Linux", then "Kali
GNU/Linux (previous kernel)", and the fail-safe ones if you use them. Do the same in the VM.
The legacy entries stay in the menu until the next step, should a new one fail.

## 10. Remove the legacy entries

Only once the new entries booted natively and in the VM:

```bash
sudo kernel-updater migrate --stage finalize
```

It removes the legacy submenu from `grub.cfg`, and nothing else. Written to partition 1, the
new `grub.cfg` takes its entry in the baseline of check's tripwire, or finalize records the
whole baseline when none is stored yet. Where partition 1 differs from a stored baseline, such
as a `grub.cfg` and `kali.cfg` copied from an export or a GRUB file that changed, it names
those files and leaves their entries to the next step, since recorded unseen the tripwire
would never report them.

## 11. Record the baseline

After an export, copy `grub.cfg` from `output_dir` as `DEPLOY.txt` says. Then, and whenever
finalize named files that differ from the baseline, look at those files and record the
baseline, which shows what differs and asks first:

```bash
sudo kernel-updater baseline
```

After that, or when finalize wrote `grub.cfg` and named nothing else, run:

```bash
sudo kernel-updater check
```

No item should fail now: `kali-menu` and `tripwire` are `ok`, and `deployed` is `ok` after an
export you copied, or skips when `output_dir` holds none, as after a write of `migrate`, which
removes an export it makes stale.

## Routine use afterwards

Update as usual with `/boot` unlocked and mounted, `sudo apt full-upgrade`: nothing on the stick
changes. [runbook.md](runbook.md#routine-use) covers routine use, `cleanup` and recovery.

## Rolling back

`sudo kernel-updater migrate --rollback` undoes the newest stage run not rolled back yet, after
checking its backup in `/var/backups/kernel-updater` against the `MANIFEST` there; give a
directory's name, its UTC stamp, to name the run. Stages undo in the reverse order they ran:
finalize, then menu, then system. `-n` shows what it would restore.

- **finalize**: `grub.cfg` gets its legacy entries back.
- **menu**: `grub.cfg` is as it was before, with the old entries, which boot kernels by their
  versions. Once `/boot` holds none of the kernels they name, as after kernel updates removed
  them, the rollback refuses (exit 3), since the stick would be left without a Kali entry that
  boots; the menu stage then stays. `kali.cfg` stays on partition 1, unused, and check's
  `kali-menu` item fails until you delete it from Windows or run the menu stage again. In the
  VM, or with `--deploy export`, the old `grub.cfg` is exported, also when the stick holds it
  already, so that `output_dir` no longer holds the menu stage's export; copy it as
  `DEPLOY.txt` says.
- **menu, run again**: a run that wrote `kali.cfg` alone puts back the `kali.cfg` it replaced.
  One that wrote a missing `kali.cfg` leaves it, since `grub.cfg` sources it.
- **system**: `/etc/kernel-img.conf` is as it was before, and the old links go back to `/`. The
  links in `/boot` stay, and so does grub-pc's answer as the stage left it;
  `dpkg-reconfigure grub-pc` changes it. When the `kernel-img.conf` put back stops linux-base
  from keeping the links in `/boot`, as the one before the first run does, it refuses (exit 3)
  while partition 1's `grub.cfg` still sources `kali.cfg`, as when the rollback of the menu
  stage exported `grub.cfg` and Windows has not copied it yet.
- **detect** keeps no backup: edit `/etc/kernel-updater.conf` by hand.

When `grub.cfg` on the stick changed after the run wrote it, as when MultiBootUSB added an ISO,
the plan says that the rollback drops those changes, and the question asks for that too; copy
`grub.cfg` from the stick first to keep them.

A rolled-back directory is renamed to `STAMP.rolled-back`. The stamps keep the order the runs
happened in: when the clock reads earlier than the newest backup, as on a native boot that
takes Windows' local time for UTC, a new backup is named one second after that one. A backup
that cannot be written whole is removed again, or renamed to `STAMP.failed`, and so is one a
kill or crash left without a `MANIFEST` once the rollback comes across it, so that neither
stands in the way. To change `kali.cfg`, as for other `menu_variants`, run the menu stage
again while the legacy entries remain; after the finalize stage, roll that back first.

## When a new kernel fails

Boot "Kali GNU/Linux (previous kernel)", then follow
[the runbook](runbook.md#when-a-new-kernel-fails).
