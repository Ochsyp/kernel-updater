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
`boot-menu` names the hypervisor and whether the stick's menu booted the running kernel.
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

Natively, where kernel-updater may write an NTFS partition 1 (a FAT one gets an export, as below):

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

On a FAT partition 1, the VM can write the files itself with `--write-fat`, as the next
section shows. In the VM without it, on a FAT partition 1 without it, or with
`--deploy export`, the files go to `output_dir` instead: copy them in Windows, `kali.cfg` first, into
`BOOT:\multibootusb\grub\`, as `DEPLOY.txt` there says, then
run `sudo kernel-updater check`, whose `deployed` item compares the stick with the export. Its
`tripwire` item fails for the two files, when a baseline is stored, until step 11. Should a
later stage or rollback write partition 1 itself while such an export is not copied, that
write removes the export, which copied afterwards would undo it.

### Writing a FAT partition 1 from the VM

`--write-fat` lets one run write a FAT partition 1, and only under VMware, only when the
stick's menu booted the running kernel, and only when the volume was left clean. Windows must
not use the volume meanwhile: FAT has no journal, and two systems writing it at once corrupt
it. VMware sees to that itself: when the VM starts, it locks and dismounts every Windows volume
on the part of the stick it gives the VM, BOOT among them, and holds them until the VM is off.
Do not take BOOT offline in Windows yourself, as with `mountvol X: /p`: VMware can then not
lock it, and Windows refuses the VM's writes to it ("The device is not ready"). Do steps A to D
for each run that writes: the menu stage, finalize, and a rollback should you need one. `X:`
stands for the drive letter Windows gives BOOT.

`tools/windows` holds steps A, D and E as scripts that find BOOT by its label, so you need not
know its letter. Each refuses with a plain sentence and changes nothing when BOOT is not there,
is there twice, is not on USB, is not FAT or holds no `multibootusb\grub\grub.cfg`. D asks
Windows for administrator rights itself and shows its result in a window of its own. Run each
from PowerShell in the checkout, for example:

```powershell
powershell.exe -NoProfile -ExecutionPolicy RemoteSigned -File .\tools\windows\stick-a-copy-menu.ps1
```

- `stick-a-copy-menu.ps1`: step A. It prints the copy's path and the SHA-256 of `grub.cfg` on
  the stick and in the copy, and ends with `The copy matches the stick.`
- `stick-d-chkdsk.ps1`: step D, without `/f`. It ends with `chkdsk found no problems`.
- `stick-e-restore-menu.ps1`: E. It copies back the newest `stick-grub-*` folder on the Desktop
  once you type `yes`, and prints both SHA-256 sums.

A. In Windows, before you start the VM, keep a copy of the menu. In PowerShell:

```powershell
Copy-Item -Recurse X:\multibootusb\grub "$HOME\Desktop\stick-grub-$(Get-Date -f yyyyMMdd-HHmm)"
```

It prints nothing. It worked when `Get-ChildItem "$HOME\Desktop\stick-grub-*\grub.cfg"` lists
a `grub.cfg` with today's time. Then close every Explorer window and program that uses BOOT.

B. Start the VM through the launcher. Then, in Windows, check that VMware holds BOOT:

```powershell
Test-Path X:\
```

It worked when it prints `False`; Explorer then cannot open BOOT either. When it prints `True`,
Windows still has BOOT: shut the VM down, close what uses BOOT, plug the stick in again if it
stays, and start the VM again. VMware's own log, `vmware.log` beside the VM's `.vmx`, says the
same at each start: `Successfully locked volume` for each volume it took from Windows.

C. In Kali, see the plan first; it writes nothing:

```bash
sudo kernel-updater migrate --stage menu --write-fat -n
```

It worked when it prints `info: --write-fat: VMware, the stick's menu booted the running kernel,
and partition 1 was unmounted cleanly` and the plan. A line that starts with `refusing to write
the FAT partition 1:` says which check failed and what to do; `sudo kernel-updater check`
shows in its `boot-menu` item which menu booted the kernel. Then write:

```bash
sudo kernel-updater migrate --stage menu --write-fat
```

Answer `y` to the plan's question, then `y` to `Write the FAT partition 1 now? In Windows,
Test-Path on BOOT's drive must print False while this VM runs`, which `--yes` does not answer,
once step B printed `False`. It worked when it ends with `info: wrote multibootusb/grub/kali.cfg`
and `info: wrote multibootusb/grub/grub.cfg; the old one is kept as ...` and exits 0, as
`echo $?` shows. For finalize, the second write, use `--stage finalize`; for a rollback,
`--rollback --write-fat`. Where `sudo` does not find `kernel-updater`, as when its
`secure_path` lacks `/usr/local/bin`, type `sudo /usr/local/bin/kernel-updater` instead.

D. Shut the VM down; BOOT comes back in Windows once VMware lets go of it. Then, in PowerShell
as administrator:

```powershell
chkdsk X:
```

It worked when it reports that Windows found no problems. Then boot the new entries, step 9.

What can still go wrong, and how to get the old menu back:

- VMware shows "The operation on file ... failed" with Retry, Cancel and Continue while the run
  writes: Windows refused the write, as when BOOT was taken offline before the VM started.
  Choose Cancel, which powers the VM off. When Windows refused every write, as then, nothing
  reached BOOT; check that with steps A and D (the same SHA-256 and file count as before, and no
  problems), then start again from A.
- `chkdsk X:` reports errors, as when Windows still used BOOT: run `chkdsk X: /f`, then E.
- The stick stops at a GRUB prompt or shows a menu error, as after a power loss in the few
  milliseconds between the two renames of `grub.cfg`: E from Windows.
- The new entries do not boot: choose "... (legacy entries)", which stay until finalize, and
  run `sudo kernel-updater migrate --rollback --write-fat` with steps A to D.
- E. Put the menu you kept in step A back, in PowerShell, with the name of that copy in place
  of `stick-grub-<stamp>`:

  ```powershell
  Copy-Item "$HOME\Desktop\stick-grub-<stamp>\*" X:\multibootusb\grub\ -Recurse -Force
  ```

  It prints nothing. It worked when `Get-FileHash X:\multibootusb\grub\grub.cfg` prints the same
  hash as `Get-FileHash "$HOME\Desktop\stick-grub-<stamp>\grub.cfg"`, and the stick boots its
  old menu. A `kali.cfg` the run wrote may stay beside it: the old `grub.cfg` does not read it.

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

## Live and forensic mode

`menu_variants` in `/etc/kernel-updater.conf` can add two more entries for the newest kernel:
`menu_variants = default,failsafe,live,forensic`. Both boot through overlayroot, which puts a
layer in RAM over the root filesystem, so nothing a session changes reaches the disk:

- live, `overlayroot=tmpfs:recurse=0`: the root alone gets the RAM layer;
- forensic, `overlayroot=tmpfs`: every mounted filesystem gets one, and swap stays off.

The package `overlayroot` must be installed and in the initrd. To check, read-only:

```bash
dpkg -l overlayroot | tail -1; sudo lsinitramfs /boot/initrd.img | grep -c overlayroot
```

An `ii  overlayroot` line and a number above 0 mean it is there; otherwise `sudo apt install
overlayroot`, then `sudo update-initramfs -u -k all`. The menu stage refuses `live` and
`forensic` while the initrd lacks it. After the finalize stage the menu stage no longer
rewrites `kali.cfg`, so add them before finalize, or roll finalize back first.

On some kernels, as 7.1.5 with overlayroot 0.18, overlayroot builds its layer read-only, since
the entries keep `ro` on the kernel line, and overlayfs refuses to make it writable later: the
login fails right after the password and comes back, because `/home` is read-only. The script
`contrib/initramfs/overlayroot-rw` fixes that from the initramfs. It runs right after
overlayroot, and only when the root is its overlay mounted read-only, it mounts the same layers
again read-write. The disk below stays read-only and a normal boot is left alone. When a step
fails, the root stays read-only, as before; only if the layers will not mount at all, neither
read-write nor read-only, does that boot stop, and the normal entry still boots. From the
checkout:

```bash
sudo install -m 0755 contrib/initramfs/overlayroot-rw /etc/initramfs-tools/scripts/init-bottom/overlayroot-rw
sudo update-initramfs -u -k all
```

It worked when a boot of the forensic entry logs in, `findmnt -no FSTYPE,OPTIONS /` prints
`overlay rw,...`, and `/run/overlayroot-rw.log` has the line `the overlay is mounted
read-write`, followed by a `fstab:` line and, when `/dev` would not move, `mounted /dev and
/dev/pts anew`. That log is the full record; the kernel log, marked `overlayroot-rw:`, gets
only the steps taken while `/dev` is in place. In a normal boot the log says `no overlayroot
overlay at /root: nothing to do`. To take it out again:

```bash
sudo rm /etc/initramfs-tools/scripts/init-bottom/overlayroot-rw
sudo update-initramfs -u -k all
```

## Routine use afterwards

Update as usual with `/boot` unlocked and mounted, `sudo apt full-upgrade`: nothing on the
stick's partition 1 changes, so there is nothing to copy or deploy.
[runbook.md](runbook.md#routine-use) covers routine use, `cleanup` and recovery.

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
