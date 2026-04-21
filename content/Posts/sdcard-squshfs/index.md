---

title: "From NFS+TFTP to a Real SD Card: Booting from Partitions in the Bootlin QEMU Lab"
date: 2026-04-21
description: How the old NFS+TFTP boot style works, how to migrate it to a partitioned sd.img, and whether the same image would work on a real board with a real SD card.
tags:
  - note
  - university
  - kernel
  - linux
  - C
  - bootlin

---

> Environment: Bootlin embedded Linux QEMU labs — `vexpress-v2p-ca9` (ARM Cortex-A9), U-Boot, Buildroot. The goal is to replace the NFS root + TFTP kernel delivery with a self-contained `sd.img` that holds everything.

## 0. Notes before reading

u need to have these variables in hand first:
1. *KERNEL_DIR*: the path where u cloned the linux kernel source code from github `git clone blabla/linux` this path should end with `linux/`
2. *YOUR_NAME*: of course my name is different than u unless u r me who is reading this (this variables line is just for u to be happy bit it's not important :3 )
3. *NFSROOT*: this is the root itself for ur target machine (usually it's inside tinysystem i think but it completely depends on ur style then)
4. TFTPDIR: This is where u can find ur `zImage` and the `*.dtb`

For u to understand our initial state in the course
**zImage**: this is the linux kernel image that programmed for `arm cortex a9` so it will work only on any machine with this arch
**vexpress-v2p-ca9.dtb**: this is the mother board table that the kernel need to understand how to access hardware pins and stuff like this so using different mother with the same files might lead to burn something or the best case that it won't work.
**tftp**: we used to use this service to share specific file like the last two i mentioned
**nfsroot**: this is the root dir for the machine root that was shared using a service **NFS** that make a remote file system so u can access any file or directory so fast

## Part 1 — How the old NFS + TFTP style works

Before changing anything, it helps to understand exactly what each piece of the old setup was doing and how they connected.

```
┌─────────────────────────────────────────────────────┐
│                    Host machine                      │
│                                                      │
│   ~/felabs/nfsroot/        ← root/   (files)         │
│   ~/felabs/tftpboot/       ← zImage + *.dtb         │
│                                                      │
│   [ NFS server :2049 ]   [ TFTP server :69 ]        │
└────────────┬──────────────────────┬─────────────────┘
             │ NFS mount            │ TFTP GET
             │ (rootfs over TCP)    │ (kernel + dtb)
             ▼                      ▼
┌─────────────────────────────────────────────────────┐
│                  QEMU guest (ARM)                    │
│                                                      │
│  U-Boot: the commands u-boot used to run to bootup   │ 
|                                                      |
│    tftp 0x61000000 zImage          ← kernel image    │
│    tftp 0x62000000 vexpress.dtb    ← device tree    │
│    setenv bootargs ... root=/dev/nfs nfsroot=...     │
│    bootz 0x61000000 - 0x62000000                     │
│                                                      │
│  Kernel mounts / from host NFS share                 │
│  All file I/O goes back over the network             │
└─────────────────────────────────────────────────────┘
```

#### What each component was responsible for

| Component         | Role                                                    | Lives on                   |
| ----------------- | ------------------------------------------------------- | -------------------------- |
| TFTP server       | Delivers `zImage` and `.dtb` to U-Boot at boot          | Host, `~/felabs/tftpboot/` |
| NFS server        | Serves the entire root filesystem to the kernel         | Host, `~/felabs/nfsroot/`  |
| U-Boot `bootargs` | Tells the kernel where to find rootfs (`root=/dev/nfs`) | U-Boot env                 |
| Kernel            | Mounts NFS as `/` at init time                          | QEMU guest RAM             |

#### Why this works well for development

- You edit files on your host and the guest sees them immediately — no copy step
- Kernel modules (`.ko`) drop straight into the NFS dir and `insmod` finds them
- No storage device to manage

#### Why it doesn't work on a real board

A real embedded board sitting on a desk has no Ethernet connection to your laptop's NFS server. Even if it does, NFS is fragile in production — a network hiccup kills the root filesystem. Real products boot from local storage.

---

### Part 2 — The new style: everything in `sd.img`

#### The two-partition layout

`sd.img` is a raw disk image with a partition table. Two partitions, two jobs:

```
sd.img
├── p1  (FAT32, ~32 MB)   ← U-Boot reads this at boot
│     ├── zImage           ← kernel image
│     └── vexpress-v2p-ca9.dtb
│
└── p2  (raw SquashFS)    ← kernel mounts this as /
      └── [your entire rootfs, compressed]
```

##### Partition 1 — FAT32 boot partition

U-Boot's `fatload` command can only read FAT filesystems. This partition is the handoff point between U-Boot and the kernel: U-Boot reads `zImage` and the DTB from here into RAM, then jumps to the kernel entry point.

- **Filesystem:** FAT32 (required by U-Boot `fatload`)
- **Contents:** `zImage`, `vexpress-v2p-ca9.dtb`
- **Who reads it:** U-Boot only
- **After boot:** The kernel never touches p1 again

##### Partition 2 — SquashFS root filesystem

SquashFS is a read-only compressed filesystem. The kernel mounts this as `/` — it is the entire userland: BusyBox, libraries, `/etc`, your kernel modules, everything.

- **Filesystem:** SquashFS (read-only, compressed)
- **Contents:** Everything that was in `~/felabs/nfsroot/`
- **Who reads it:** The kernel, after it has booted
- **Why SquashFS:** Compact, needs no formatting, written as a raw image with `dd` — no filesystem driver needed at write time on the host

> **Read-only caveat:** SquashFS cannot be written to. If your rootfs needs writable storage (logs, config changes), you add an `overlayfs` on top or a third partition (ext4) for data. For the Bootlin lab, read-only is fine.

---

### Part 3 — The commands, explained one by one

#### Step 1 — Pack the NFS root into a SquashFS image

```bash
mksquashfs tinysystem/nfsroot rootfs.sqsh -noappend
```

| Part                 | Meaning                                                        |
| -------------------- | -------------------------------------------------------------- |
| `tinysystem/nfsroot` | Source directory — your existing NFS root                      |
| `rootfs.sqsh`        | Output file — the compressed image                             |
| `-noappend`          | Overwrite if `rootfs.sqsh` already exists (don't append to it) |

This produces a single file that is a byte-for-byte SquashFS volume. No partitioning yet — just the filesystem image.

---

#### Step 2 — Attach `sd.img` to a loop device

```bash
sudo losetup -fP --show sd.img
# → /dev/loop0   (number varies)
```

| Flag     | Meaning                                                                 |
| -------- | ----------------------------------------------------------------------- |
| `-f`     | Find the first free loop device automatically                           |
| `-P`     | Scan the partition table and create `/dev/loop0p1`, `/dev/loop0p2` etc. |
| `--show` | Print the loop device name so you know which one was assigned           |

After this, the kernel sees `sd.img` as if it were a real block device with partitions. `/dev/loop0p1` is p1, `/dev/loop0p2` is p2.

---

#### Step 3 — Mount p1 and copy the kernel + DTB

```bash
mkdir /mnt/xxx
sudo mount /dev/loop0p1 /mnt/xxx

# Copy the kernel and device tree into the FAT partition
cp zImage               /mnt/xxx/
cp vexpress-v2p-ca9.dtb /mnt/xxx/
```

p1 is FAT32, so a normal `mount` works. You're writing the two files that U-Boot will `fatload` at boot time.

---

#### Step 4 — Write the SquashFS image raw into p2

```bash
sudo dd if=rootfs.sqsh of=/dev/loop0p2 bs=1M status=progress
sync
```

| Part              | Meaning                                                        |
| ----------------- | -------------------------------------------------------------- |
| `if=rootfs.sqsh`  | Input: your SquashFS image                                     |
| `of=/dev/loop0p2` | Output: the raw partition (not a mount point — a block device) |
| `bs=1M`           | Write in 1 MB blocks — much faster than the default 512 bytes  |
| `status=progress` | Show transfer speed and progress                               |
| `sync`            | Flush all pending writes to disk before continuing             |

This is a **raw write** — `dd` copies bytes directly, no filesystem is created on p2 first. The SquashFS format is self-describing, so the kernel can mount it straight from raw block bytes.

> **Do not `mkfs` p2 before this step.** Writing a filesystem on top of SquashFS would corrupt it.

---

#### Step 5 — Unmount and detach the loop device

```bash
sudo umount /dev/loop0p1
sudo losetup -d /dev/loop0
```

Detaching the loop device releases `sd.img` so QEMU can open it exclusively.

---

#### Step 6 — U-Boot environment in QEMU

```
=> setenv bootargs console=ttyAMA0,115200 root=/dev/mmcblk0p2 rootfstype=squashfs rootwait rw
=> setenv bootcmd 'fatload mmc 0:1 0x61000000 zImage; fatload mmc 0:1 0x62000000 vexpress-v2p-ca9.dtb; bootz 0x61000000 - 0x62000000'
=> saveenv
=> boot
```

Breaking down `bootargs`:

| Argument                 | Meaning                                                                                     |
| ------------------------ | ------------------------------------------------------------------------------------------- |
| `console=ttyAMA0,115200` | Serial console — where kernel log output goes                                               |
| `root=/dev/mmcblk0p2`    | The kernel mounts p2 as `/`                                                                 |
| `rootfstype=squashfs`    | Tell the kernel not to probe — it's SquashFS                                                |
| `rootwait`               | Wait for the MMC device to appear before trying to mount (important for SD)                 |
| `rw`                     | Mount read-write (SquashFS ignores this — it's always read-only — but it silences warnings) |

Breaking down `bootcmd`:

```
fatload mmc 0:1 0x61000000 zImage
         │   │   └─ destination RAM address
         │   └─ device:partition  (mmc 0, partition 1 = FAT32)
         └─ mmc = SD/MMC controller 0
```

`bootz 0x61000000 - 0x62000000`

- Load address of zImage
- `-` = no initrd
- DTB address

---

### Part 4 — Would this work on a real SD card and a real board?

**Short answer: yes, with conditions.**

#### What would transfer directly

The partition layout, the SquashFS image, and the U-Boot environment are all architecture-agnostic concepts. If your real board meets the conditions below, the same `sd.img` would work.

#### Conditions for a real board

##### Architecture must match

The `zImage` in p1 was compiled for `ARM` (Cortex-A9, `arm-linux-gnueabihf`). If your real board is also Cortex-A9 (or a compatible ARMv7-A core), the binary will execute. A Cortex-A53 (ARMv8) board would need a recompiled kernel.

##### DTB must match the real board

`vexpress-v2p-ca9.dtb` describes the Versatile Express reference board — a virtual board that only exists inside QEMU. A real board has a different memory map, different peripheral addresses, different interrupt assignments.

**You must use the DTB for your actual board.** This is the single biggest difference. Put the correct `.dtb` in p1 and update `bootcmd` to load it by name.

##### U-Boot must support `fatload mmc`

Most modern U-Boot builds do, but some minimal configurations disable MMC support. Verify with `help fatload` at the U-Boot prompt.

##### `mmcblk0p2` must be the right device node

On some boards the SD card is `mmcblk1` (if `mmcblk0` is eMMC). Check `ls /dev/mmcblk*` on a running system or read the board's U-Boot documentation.

##### Writing to a real SD card

Replace the loop device with the real card:

```bash
# Find your SD card device (check dmesg after inserting)
lsblk

# Write the image — THIS ERASES THE CARD
sudo dd if=sd.img of=/dev/sdX bs=4M status=progress conv=fsync

# Or, if your sd.img is exactly the right size, write partition by partition:
sudo dd if=rootfs.sqsh of=/dev/sdX2 bs=1M status=progress
sync
```

#### Summary table

| Thing                               | Works on real board?         | Notes                                         |
| ----------------------------------- | ---------------------------- | --------------------------------------------- |
| Partition layout (FAT32 + SquashFS) | Yes                          | Universal                                     |
| SquashFS rootfs content             | Yes, if architecture matches | Binaries must be compiled for the right arch  |
| `zImage`                            | Yes, if architecture matches | Recompile for your exact SoC if needed        |
| `vexpress-v2p-ca9.dtb`              | **No**                       | Must be replaced with your board's DTB        |
| U-Boot `bootcmd`                    | Mostly yes                   | Device node (`mmc 0:1`) may differ            |
| U-Boot `bootargs`                   | Mostly yes                   | `mmcblk0p2` may be `mmcblk1p2` on some boards |

---
If you reached this you should thank Allah for this gift
>  قامَ النَّبيُّ صلَّى اللهُ عليه وسلَّم حتَّى تَورَّمَت قدَماه، فقيلَ له: غَفَرَ اللهُ لكَ ما تَقدَّمَ مِن ذَنبِكَ وما تَأخَّرَ،
>   قال: أفلا أكونُ **عَبدًا** **شَكورًا**.

>   وهذا هو تمام الشكر, **العبادة**

---

### Quick reference

```bash
# 1. Build SquashFS from NFS root
mksquashfs tinysystem/nfsroot rootfs.sqsh -noappend

# 2. Attach sd.img as a loop device with partition awareness
sudo losetup -fP --show sd.img        # note the device, e.g. /dev/loop0

# 3. Mount FAT partition and copy boot files
sudo mkdir -p /mnt/boot
sudo mount /dev/loop0p1 /mnt/boot
sudo cp zImage vexpress-v2p-ca9.dtb /mnt/boot/
sudo umount /mnt/boot

# 4. Write SquashFS raw into p2
sudo dd if=rootfs.sqsh of=/dev/loop0p2 bs=1M status=progress
sync

# 5. Detach loop device
sudo losetup -d /dev/loop0

# 6. Boot QEMU with the image
qemu-system-arm \
  -M vexpress-a9 \
  -kernel u-boot \
  -drive file=sd.img,if=sd,format=raw \
  -serial stdio \
  -net nic -net user

# 7. U-Boot environment (at => prompt)
setenv bootargs 'console=ttyAMA0,115200 root=/dev/mmcblk0p2 rootfstype=squashfs rootwait rw'
setenv bootcmd 'fatload mmc 0:1 0x61000000 zImage; fatload mmc 0:1 0x62000000 vexpress-v2p-ca9.dtb; bootz 0x61000000 - 0x62000000'
saveenv
boot
```

---

### References

- [Bootlin Embedded Linux Lab materials](https://bootlin.com/training/embedded-linux/)
- [SquashFS documentation — kernel.org](https://www.kernel.org/doc/html/latest/filesystems/squashfs.html)
- [U-Boot `fatload` command reference](https://u-boot.readthedocs.io/en/latest/usage/cmd/fatload.html)
- [Linux Device Tree — what a DTB is and why it matters](https://www.kernel.org/doc/html/latest/devicetree/usage-model.html)
- [losetup man page](https://man7.org/linux/man-pages/man8/losetup.8.html)