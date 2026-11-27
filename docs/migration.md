# Migrating the stick's Kali entries

This is the walkthrough for the one-time switch that `kernel-updater migrate` makes:

- from Kali entries that name a kernel version, which every kernel update breaks;
- to entries that boot the links linux-base keeps in `/boot`.

Afterwards a kernel update changes nothing on the stick's partition 1, and kernel-updater only
watches.

Do the steps in order, and do not skip a test. Each stage builds on the one before.

- The system, menu and finalize stages each keep a backup. `kernel-updater migrate --rollback`
  restores it (see [Rolling back](#rolling-back)).
- The detect stage keeps none.

Every command prints its plan and asks before it changes anything. `-n` shows the plan alone.

No message prints an identifier. Where this page shows `<boot_luks_uuid>` and the like, read
the value in `/etc/kernel-updater.conf`.

## 1. Back up the menu from Windows

In Windows, copy the folder `BOOT:\multibootusb\grub` from the stick to a safe place.

The folder holds `grub.cfg`, the menu MultiBootUSB boots, which the menu stage changes.
kernel-updater keeps backups of its own, but this copy works even when Kali does not boot.

## 2. Let Windows leave the stick clean

In Windows:

- Turn Fast Startup off (Control Panel, Power Options, "Choose what the power buttons do").
- Eject the stick before you boot from it.

kernel-updater never writes a volume that Windows hibernated, kept in its cache or left
unclean. It exports the files instead, and says why.

With `--write-fat`, a FAT volume left unclean makes the run refuse (exit 3) instead. Then
nothing is written or exported.

## 3. Install kernel-updater

In Kali, from the checkout:

```bash
sudo ./install.sh
```

It installs the tool under `/usr/local` and the hooks that refuse a kernel install while
`/boot` is not mounted. They only warn until the next step sets `boot_fs_uuid`.

## 4. Detect the identity

Unlock and mount `/boot`, as for any kernel update. Then run:

```bash
sudo /usr/local/bin/kernel-updater migrate --stage detect
```

The stage appends these values to `/etc/kernel-updater.conf`:

- the UUIDs of `/boot` and of its LUKS container;
- the stick's PTUUID and the serial of its partition 1;
- the `root=` device of the running kernel;
- `grub_floor`, from the version of the stick's GRUB.

Setting `boot_fs_uuid` arms the hooks.

When the file already sets one of these keys to another value, the stage stops with exit 78
and names the key. Correct or remove that line.

Read the values in the file. If you like, compare them with `sudo lsblk -o
NAME,LABEL,PTUUID,UUID` and `cat /proc/cmdline`.

## 5. Check the system

```bash
sudo /usr/local/bin/kernel-updater check
```

No item should fail but `grub-pc`, which the system stage settles. Some items warn or skip for
now:

- Until the system stage, `kernel-img` warns and the items about the links in `/boot` skip.
- `tripwire` warns while no baseline is stored.
- `kali-menu` skips until the menu stage, and warns until the finalize stage.

`boot-menu` names the hypervisor, and whether the stick's menu booted the running kernel.

`boot-identity`, `boot-luks` and `boot-ext` must be `ok`. They say whether `/boot` is the one
the configuration names, and whether the stick's GRUB unlocks and reads it.

## 6. Configure the kernel links

See the plan first, then run the stage:

```bash
sudo /usr/local/bin/kernel-updater migrate --stage system -n
sudo /usr/local/bin/kernel-updater migrate --stage system
```

The stage does this:

- It sets `do_symlinks = yes` and `link_in_boot = yes` in `/etc/kernel-img.conf`.
- With `linux-update-symlinks`, it points `/boot/vmlinuz` and `/boot/initrd.img` at the newest
  kernel. It points `vmlinuz.old` and `initrd.img.old` at the previous one, or at the running
  kernel when that is an older one.
- It moves the old links out of `/` into its backup.

A second question offers to empty grub-pc's install devices. Then a grub-pc upgrade never
writes GRUB over the stick's boot loader. Answer yes unless you know better. The old answer is
kept nowhere, since it names devices.

Afterwards the stage checks that each link points at the kernel the plan named.

Should apt install or remove a kernel while the question waits, the stage refuses and changes
nothing. Run it again.

The stage also refuses in these cases:

- No installed kernel would boot from the stick.
- Only one would, but `/boot` holds another kernel's image, such as an older kernel whose
  initrd lacks the key files. `linux-update-symlinks` takes the `.old` links from the images in
  `/boot`, and would point them at that one. Rebuild that kernel's initrd
  (`sudo update-initramfs -u -k VERSION`), or remove the kernel, first.

## 7. Test both pairs of links at the GRUB prompt

GRUB must follow the new links on `/boot` before the menu relies on them.

Boot the stick natively. In MultiBootUSB's menu, press `c` for the GRUB prompt. Then type these
lines, with the values from `/etc/kernel-updater.conf` (the LUKS UUID without its dashes):

```text
cryptomount -u <boot_luks_uuid without dashes>
search --no-floppy --fs-uuid --set=root <boot_fs_uuid>
linux /vmlinuz root=<root_device>
initrd /initrd.img
linux /vmlinuz.old root=<root_device>
initrd /initrd.img.old
```

- `cryptomount` asks for the passphrase of `/boot`.
- Each `linux` and `initrd` must return to the prompt without a message.
- `file not found` or `invalid symlink` means GRUB cannot follow that link.

A plain `ls` proves nothing. It lists the link names even when a link is absolute or dangles.
Only `linux` and `initrd` read through the link, as the menu will.

Press Esc to return to the menu, and boot Kali the old way.

Do the same in the VM that boots the stick, since its GRUB reaches the stick through another
path.

When either test fails, run `sudo /usr/local/bin/kernel-updater migrate --rollback` and stop
here.

## 8. Write the new menu

Run this natively, where kernel-updater may write an NTFS partition 1. A FAT one gets an
export, as below.

```bash
sudo /usr/local/bin/kernel-updater migrate --stage menu -n
sudo /usr/local/bin/kernel-updater migrate --stage menu
```

The stage writes `multibootusb/grub/kali.cfg`. Its entries boot `/vmlinuz` and `/initrd.img`,
and for the previous kernel `/vmlinuz.old` and `/initrd.img.old`.

It replaces the Kali submenu in `grub.cfg` with a block that loads `kali.cfg` with `source`.
The old submenu stays behind that block as "... (legacy entries)". It is a fallback until the
finalize stage. Every other byte of `grub.cfg` stays as it was, CRLF line endings included.

Before anything is written:

- both files pass `grub-script-check`;
- `kali.cfg` passes `lint` with the stick's own GRUB lists, or with GRUB 2.02's when those
  cannot be read.

The plan lists:

- the entries, with their kernel parameters;
- each change against the old entries, such as a `cryptdevice=` that goes;
- the old entries that are not carried over.

A parameter that may name a device, a UUID or a key file shows in the plan as `NAME=<value>`.
`kali.cfg` gets it as it is.

`menu_variants` and `previous_variants` choose the entries. To change them later, edit them and
run the menu stage again while the legacy entries remain. That run leaves `grub.cfg` as it is.
It writes `kali.cfg` alone anew, with a backup of its own.

When the stage writes partition 1, both files take their entries in the baseline of check's
tripwire, if one is stored.

The plan may say that `grub.cfg` differs from that baseline. Then something changed it since,
such as MultiBootUSB adding an ISO from Windows. Look at `grub.cfg` on the stick before you
answer, since what changed outside the Kali submenu stays. Its entry then keeps the old value,
so the tripwire keeps reporting the change until step 11 records it.

On a FAT partition 1, the VM can write the files itself with `--write-fat`, as the next section
shows.

The files go to `output_dir` instead in these cases:

- in the VM without `--write-fat`;
- on a FAT partition 1 without `--write-fat`;
- with `--deploy export`.

Then do this:

1. In Windows, copy the files into `BOOT:\multibootusb\grub\`, `kali.cfg` first, as
   `DEPLOY.txt` there says.
2. Run `sudo /usr/local/bin/kernel-updater check`. Its `deployed` item compares the stick with
   the export. Its `tripwire` item fails for the two files, when a baseline is stored, until
   step 11.

A later stage or rollback may write partition 1 itself while such an export is not copied.
That write removes the export, since the export, copied afterwards, would undo the write.

### Writing a FAT partition 1 from the VM

`--write-fat` lets one run write a FAT partition 1, and only when all of these hold:

- the VM runs under VMware;
- the stick's menu booted the running kernel;
- the volume was left clean.

Windows must not use the volume meanwhile. FAT has no journal, and two systems writing it at
once corrupt it.

VMware sees to that itself. When the VM starts, VMware locks and dismounts every Windows volume
on the part of the stick it gives the VM, BOOT among them. It holds them until the VM is off.

Do not take BOOT offline in Windows yourself, as with `mountvol X: /p`. VMware can then not lock
it, and Windows refuses the VM's writes to it ("The device is not ready").

Do steps A to D for each run that writes: the menu stage, finalize, and a rollback should you
need one. `X:` stands for the drive letter Windows gives BOOT.

`tools/windows` holds steps A, D and E as scripts. They find BOOT by its label, so you need not
know its letter. Each script refuses with a plain sentence, and changes nothing, when BOOT:

- is not there;
- is there twice;
- is not on USB;
- is not FAT;
- holds no `multibootusb\grub\grub.cfg`.

D asks Windows for administrator rights itself, and shows its result in a window of its own.
Run each script from PowerShell in the checkout, for example:

```powershell
powershell.exe -NoProfile -ExecutionPolicy RemoteSigned -File .\tools\windows\stick-a-copy-menu.ps1
```

- `stick-a-copy-menu.ps1`: step A. It copies the menu to a dated `stick-grub-*` folder in
  `%LOCALAPPDATA%\kernel-updater\stick-grub`, and makes that folder when it is missing. It never
  copies to the Desktop. It prints the copy's path, and the SHA-256 of `grub.cfg` on the stick
  and in the copy. Its last line starts with `The copy matches the stick.`
- `stick-d-chkdsk.ps1`: step D, without `/f`. Its last line starts with
  `chkdsk found no problems`.
- `stick-e-restore-menu.ps1`: E. Once you type `yes`, it copies back the newest `stick-grub-*`
  folder in `%LOCALAPPDATA%\kernel-updater\stick-grub`. It prints both SHA-256 sums.

A. In Windows, before you start the VM, keep a copy of the menu, never on the Desktop.

In PowerShell, first make the folder for it. This prints the folder:

```powershell
New-Item -ItemType Directory -Force "$env:LOCALAPPDATA\kernel-updater\stick-grub"
```

Then copy the menu into it. This prints nothing:

```powershell
Copy-Item -Recurse X:\multibootusb\grub `
    "$env:LOCALAPPDATA\kernel-updater\stick-grub\stick-grub-$(Get-Date -f yyyyMMdd-HHmmss)"
```

It worked when `Get-FileHash X:\multibootusb\grub\grub.cfg` prints the same hash as the command
below. That command takes the newest copy (a copy keeps the stick file's time, not today's):

```powershell
Get-ChildItem "$env:LOCALAPPDATA\kernel-updater\stick-grub\stick-grub-*\grub.cfg" |
    Sort-Object FullName | Select-Object -Last 1 | Get-FileHash
```

Then close every Explorer window and program that uses BOOT.

B. Start the VM through the launcher. Then, in Windows, check that VMware holds BOOT:

```powershell
Test-Path X:\
```

It worked when it prints `False`. Explorer then cannot open BOOT either.

When it prints `True`, Windows still has BOOT. Shut the VM down, and close what uses BOOT. If
BOOT stays, plug the stick in again. Then start the VM again.

VMware's own log says the same at each start. The log is `vmware.log`, beside the VM's `.vmx`.
It shows `Successfully locked volume` for each volume VMware took from Windows.

C. In Kali, see the plan first. This writes nothing:

```bash
sudo /usr/local/bin/kernel-updater migrate --stage menu --write-fat -n
```

It worked when it prints `info: --write-fat: VMware, the stick's menu booted the running kernel,
and partition 1 was unmounted cleanly` and the plan. A line that starts with `refusing to write
the FAT partition 1:` says which check failed and what to do.
`sudo /usr/local/bin/kernel-updater check` shows in its `boot-menu` item which menu booted the
kernel.

Then write:

```bash
sudo /usr/local/bin/kernel-updater migrate --stage menu --write-fat
```

Answer `y` to the plan's question. Then answer `y` to `Write the FAT partition 1 now? In Windows,
Test-Path on BOOT's drive must print False while this VM runs`, which `--yes` does not answer.
Give that second answer only once step B printed `False`.

It worked when it prints `info: wrote multibootusb/grub/kali.cfg` and
`info: wrote multibootusb/grub/grub.cfg; the old one is kept as ...`, and exits 0, as `echo $?`
shows.

For finalize, the second write, use `--stage finalize`. For a rollback, use
`--rollback --write-fat`.

Every command here names `/usr/local/bin/kernel-updater` in full, as the tool's own advice
does. sudo's `secure_path` may lack `/usr/local/bin`, and then a bare `sudo kernel-updater`
answers `command not found`.

D. Shut the VM down. BOOT comes back in Windows once VMware lets go of it. Then, in PowerShell
as administrator:

```powershell
chkdsk X:
```

It worked when it reports that Windows found no problems. Then boot the new entries, step 9.

What can still go wrong, and how to get the old menu back:

- VMware shows "The operation on file ... failed" with Retry, Cancel and Continue while the run
  writes. Windows refused the write, as when BOOT was taken offline before the VM started.
  Choose Cancel, which powers the VM off. When Windows refused every write, as then, nothing
  reached BOOT. Check that with steps A and D: the same SHA-256 and file count as before, and no
  problems. Then start again from A.
- `chkdsk X:` reports errors, as when Windows still used BOOT. Run `chkdsk X: /f`, then E.
- The stick stops at a GRUB prompt or shows a menu error, as after a power loss in the few
  milliseconds between the two renames of `grub.cfg`. Run E from Windows.
- The new entries do not boot. Choose "... (legacy entries)", which stay until finalize. Then
  run `sudo /usr/local/bin/kernel-updater migrate --rollback --write-fat` with steps A to D.
- E. Put back the menu you kept in step A. In PowerShell, run this, with the name of that copy
  in place of `stick-grub-<stamp>`:

  ```powershell
  Copy-Item "$env:LOCALAPPDATA\kernel-updater\stick-grub\stick-grub-<stamp>\*" `
      X:\multibootusb\grub\ -Recurse -Force
  ```

  It prints nothing. It worked when the stick boots its old menu, and
  `Get-FileHash X:\multibootusb\grub\grub.cfg` prints the same hash as this:

  ```powershell
  Get-FileHash "$env:LOCALAPPDATA\kernel-updater\stick-grub\stick-grub-<stamp>\grub.cfg"
  ```

  A `kali.cfg` the run wrote may stay beside it. The old `grub.cfg` does not read it.

## 9. Boot the new entries

Boot the stick natively. Under the Kali submenu, choose "Kali GNU/Linux", then "Kali GNU/Linux
(previous kernel)", and the fail-safe ones if you use them. Do the same in the VM.

The legacy entries stay in the menu until the next step, should a new one fail.

## 10. Remove the legacy entries

Only once the new entries booted natively and in the VM, run:

```bash
sudo /usr/local/bin/kernel-updater migrate --stage finalize
```

The stage removes the legacy submenu from `grub.cfg`, and nothing else.

When it writes partition 1, the new `grub.cfg` takes its entry in the baseline of check's
tripwire. When no baseline is stored yet, finalize records the whole baseline.

Partition 1 may differ from a stored baseline, for example:

- a `grub.cfg` and `kali.cfg` copied from an export;
- a GRUB file that changed.

Then finalize names those files, and leaves their entries to the next step. Recorded unseen,
the tripwire would never report them.

## 11. Record the baseline

After an export, copy `grub.cfg` from `output_dir` as `DEPLOY.txt` says.

Then, and whenever finalize named files that differ from the baseline, look at those files.
Then record the baseline. The command shows what differs, and asks first:

```bash
sudo /usr/local/bin/kernel-updater baseline
```

After that, or when finalize wrote `grub.cfg` and named nothing else, run:

```bash
sudo /usr/local/bin/kernel-updater check
```

No item should fail now:

- `kali-menu` and `tripwire` are `ok`.
- `deployed` is `ok` after an export you copied. It skips when `output_dir` holds none, as
  after a write of `migrate`, which removes an export it makes stale.

## Live and forensic mode

`menu_variants` in `/etc/kernel-updater.conf` can add two more entries for the newest kernel:
`menu_variants = default,failsafe,live,forensic`. Both boot through overlayroot. overlayroot
puts a layer in RAM over the root filesystem, so nothing a session changes reaches the disk:

- live, `overlayroot=tmpfs:recurse=0`: the root alone gets the RAM layer;
- forensic, `overlayroot=tmpfs`: every mounted filesystem gets one, and swap stays off.

The package `overlayroot` must be installed and in the initrd. To check, read-only:

```bash
dpkg -l overlayroot | tail -1; sudo lsinitramfs /boot/initrd.img | grep -c overlayroot
```

An `ii  overlayroot` line and a number above 0 mean it is there. Otherwise, run
`sudo apt install overlayroot`. Then rebuild the initrd of the kernel `/boot/vmlinuz` points
at, and of no other:

```bash
v=$(readlink /boot/vmlinuz); sudo update-initramfs -u -k "${v##*vmlinuz-}"
```

The menu stage refuses `live` and `forensic` while the initrd lacks overlayroot. After the
finalize stage, the menu stage does not rewrite `kali.cfg`. So add them before finalize, or
roll finalize back first.

On some kernels, as 7.1.5 with overlayroot 0.18, overlayroot builds its layer read-only, since
the entries keep `ro` on the kernel line. overlayfs refuses to make it writable later. The
login fails right after the password and comes back, because `/home` is read-only.

The script `contrib/initramfs/overlayroot-rw` fixes that from the initramfs:

- It runs right after overlayroot.
- Only when the root is overlayroot's overlay mounted read-only, it mounts the same layers again
  read-write.
- The disk below stays read-only, and a normal boot is left alone.
- When a step fails, the root stays read-only, as without the script.
- Only if the layers will not mount at all, neither read-write nor read-only, does that boot
  stop. The normal entry still boots.

From the checkout:

```bash
sudo install -m 0755 contrib/initramfs/overlayroot-rw /etc/initramfs-tools/scripts/init-bottom/overlayroot-rw
v=$(readlink /boot/vmlinuz); sudo update-initramfs -u -k "${v##*vmlinuz-}"
```

Each rebuild here takes the newest kernel's initrd alone, as the runbook's
[Rebuild one kernel's initrd](runbook.md#rebuild-one-kernels-initrd) does.

Leave the previous kernel's initrd alone. It is the fallback, and with the default
`previous_variants` its entries do not use overlayroot. It needs the same change only when
`previous_variants` names `live` or `forensic`. Even then, make the change only once the newest
kernel booted with it: the same line with `/boot/vmlinuz.old` in place of `/boot/vmlinuz`.

The next kernel update builds the new kernel's initrd with the script in it.

It worked when all of these hold:

- A boot of the forensic entry logs in.
- `findmnt -no FSTYPE,OPTIONS /` prints `overlay rw,...`.
- `/run/overlayroot-rw.log` has the line `the overlay is mounted
  read-write`, followed by a `fstab:` line and, when `/dev` would not move, `mounted /dev and
  /dev/pts anew`. That log is the full record; the kernel log, marked `overlayroot-rw:`, gets
  only the steps taken while `/dev` is in place.

In a normal boot the log says `no overlayroot
overlay at /root: nothing to do`.

To take the script out again:

```bash
sudo rm /etc/initramfs-tools/scripts/init-bottom/overlayroot-rw
v=$(readlink /boot/vmlinuz); sudo update-initramfs -u -k "${v##*vmlinuz-}"
```

A rebuild with `update-initramfs -u -k all` in these steps also rebuilds the previous kernel's
initrd, which has not booted since. To check that initrd, read-only:

```bash
sudo /usr/local/bin/kernel-updater check --porcelain | grep '^initrd'
```

It is whole when the line reads `initrd`, `ok` and `2 initrd(s) hold their modules, cryptsetup,
the cryptroot configuration`, tab-separated, followed by `and key files` when `/etc/crypttab`
names one. The count is that of the installed kernels. A `fail` names the kernel and what its initrd
lacks.

For full proof, boot it once:

- In the stick's menu, open the Kali submenu and choose "Kali GNU/Linux (previous kernel)".
- Unlock `/boot` and log in. `uname -r` then prints the older version.
- `sudo reboot` and "Kali GNU/Linux" bring the newest kernel back.

Should it not boot, rebuild that kernel's initrd as the runbook's
[Rebuild one kernel's initrd](runbook.md#rebuild-one-kernels-initrd) says.

## Routine use afterwards

Update as usual with `/boot` unlocked and mounted: `sudo apt full-upgrade`. Nothing on the
stick's partition 1 changes, so there is nothing to copy or deploy.
[runbook.md](runbook.md#routine-use) covers routine use, `cleanup` and recovery.

## Rolling back

`sudo /usr/local/bin/kernel-updater migrate --rollback` undoes the newest stage run that is not
rolled back yet. First it checks that run's backup in `/var/backups/kernel-updater` against the
`MANIFEST` there. To name the run, give its directory's name, its UTC stamp.

Stages undo in the reverse order they ran: finalize, then menu, then system. `-n` shows what
the rollback would restore.

- **finalize**: `grub.cfg` gets its legacy entries back.
- **menu**: `grub.cfg` is as it was before, with the old entries, which boot kernels by their
  versions.
  - Once `/boot` holds none of the kernels they name, the rollback refuses (exit 3). That
    happens, for example, after kernel updates removed them. The stick would be left without a
    Kali entry that boots. The menu stage then stays.
  - `kali.cfg` stays on partition 1, unused. Check's `kali-menu` item fails until you delete it
    from Windows or run the menu stage again.
  - In the VM, with `--deploy export`, or on a FAT partition 1 without `--write-fat`, the old
    `grub.cfg` is exported. It is exported also when the stick holds it already, so that the
    menu stage's export is gone from `output_dir`. Copy it as `DEPLOY.txt` says.
- **menu, run again**: a run that wrote `kali.cfg` alone puts back the `kali.cfg` it replaced.
  One that wrote a missing `kali.cfg` leaves it, since `grub.cfg` sources it.
- **system**: `/etc/kernel-img.conf` is as it was before, and the old links go back to `/`.
  - The links in `/boot` stay. So does grub-pc's answer, as the stage left it.
    `dpkg-reconfigure grub-pc` changes it.
  - The rollback refuses (exit 3) when two things hold. First, the `kernel-img.conf` put back
    stops linux-base from keeping the links in `/boot`, as the one before the first run does.
    Second, partition 1's `grub.cfg` still sources `kali.cfg`. That happens, for example, when
    the rollback of the menu stage exported `grub.cfg` and Windows has not copied it yet.
- **detect** keeps no backup: edit `/etc/kernel-updater.conf` by hand.

`grub.cfg` on the stick may have changed after the run wrote it, as when MultiBootUSB added an
ISO. Then the plan says that the rollback drops those changes, and the question asks for that
too. To keep them, copy `grub.cfg` from the stick first.

A rolled-back directory is renamed to `STAMP.rolled-back`.

The stamps keep the order the runs happened in. The clock may read earlier than the newest
backup, as on a native boot that takes Windows' local time for UTC. Then a new backup is named
one second after that one.

A backup that cannot be written whole is removed again, or renamed to `STAMP.failed`. So is one
that a kill or crash left without a `MANIFEST`, once the rollback comes across it. Then neither
stands in the way.

To change `kali.cfg`, as for other `menu_variants`, run the menu stage again while the legacy
entries remain. After the finalize stage, roll that back first.

## When a new kernel fails

Boot "Kali GNU/Linux (previous kernel)", then follow
[the runbook](runbook.md#when-a-new-kernel-fails).
