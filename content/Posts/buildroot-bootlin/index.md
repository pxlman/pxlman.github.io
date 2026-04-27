---
title: "Buildroot Deep Dive: Why Every Step Exists, How It Works, and What Breaks Without It"
date: 2026-04-27
tags: ["linux", "embedded", "buildroot", "qemu", "uboot", "squashfs", "bootlin", "arm"]
description: "A deeply explained guide to Buildroot on the Bootlin QEMU ARM lab — covering not just what to run but why each piece exists, how we worked before, what happens if you skip a step, and what alternatives exist."
draft: false
---
### This article should be explaining the original [html](/buildroot.html) the TA Ahmed Ehab made

<a href="./buildroot.html">first </a>
<a href="/buildroot.html"> second</a>

> **Who this is for:** Colleagues who have completed or are working through the Bootlin embedded Linux QEMU labs and want to understand the *reasoning* behind each step, not just the commands.
> **Environment:** `vexpress-v2p-ca9` (ARM Cortex-A9), U-Boot, Buildroot 2026.02.1, Linux 6.19.12.

---


## Prerequisets to make sure u have before starting
- PROJECT=`~/Desktop/embedded-linux-qemu-labs`
- BOOT=`$PROJECT/bootloader`
- BUILDROOT=`$PROJECT/buildroot/buildroot`
- ROOTFS=`$PROJECT/buildroot-rootfs`
- TINY=`$PROJECT/tinysystem/nfsroot`
- SD=`$BOOT/sd.img`
## The big picture — what are we actually doing?

Before touching any command, it helps to understand the problem we are solving.

An embedded Linux system needs at minimum three things to run: a **bootloader** (U-Boot) that initializes hardware and hands control to the kernel, a **kernel** (zImage) that manages hardware and runs processes, and a **root filesystem** (rootfs) that contains every userspace program, library, configuration file, and script.

In the Bootlin lab, all three of these were previously delivered over the network — the kernel over TFTP, the rootfs over NFS. What we are building now is a self-contained storage image (`sd.img`) that holds all three, so the system boots independently of any host machine.

Buildroot is the tool that generates the kernel and rootfs for us from a declarative configuration. Understanding Buildroot means understanding the pipeline:

```
You describe what you want (.config)
       ↓
Buildroot downloads sources, cross-compiles everything
       ↓
Buildroot outputs: zImage + DTB + rootfs.tar
       ↓
You pack rootfs.tar → SquashFS image
       ↓
You write everything to sd.img partitions
       ↓
QEMU boots from sd.img, U-Boot loads kernel, kernel mounts rootfs
```

---

## How we worked before — NFS + TFTP

### The old architecture

```
┌──────────────────────────────────────────────────┐
│                  Host machine                    │
│                                                  │
│  ~/felabs/tftpboot/                              │
│    └── zImage                 ← kernel image     │
│    └── vexpress-v2p-ca9.dtb   ← device tree      │
│                                                  │
│  ~/felabs/nfsroot/            ← entire rootfs    │
│    └── bin/ lib/ etc/ ...                        │
│                                                  │
│  [ TFTP server :69 ]  [ NFS server :2049 ]       │
└──────────┬────────────────────┬─────────────────┘
           │ TFTP (UDP)         │ NFS (TCP)
           │ kernel + dtb       │ rootfs over network
           ▼                    ▼
┌──────────────────────────────────────────────────┐
│              QEMU guest (ARM)                    │
│                                                  │
│  U-Boot:                                         │
│    tftp 0x61000000 zImage                        │
│    tftp 0x62000000 vexpress-v2p-ca9.dtb          │
│    setenv bootargs root=/dev/nfs nfsroot=...     │
│    bootz 0x61000000 - 0x62000000                 │
│                                                  │
│  Kernel mounts / from host NFS export            │
│  Every file read goes back over the network      │
└──────────────────────────────────────────────────┘
```

### Why NFS + TFTP is excellent for development

- You edit a file on your host and the guest sees it immediately — no copying, no rebuilding
- You can drop a new `.ko` kernel module into the NFS directory and `insmod` it on the guest in seconds
- The rootfs is just a directory on your host — easy to inspect, easy to modify
- No storage device to manage or reflash

### Why NFS + TFTP is wrong for anything beyond development

- The guest cannot function without the host machine running and reachable
- A network hiccup kills the entire root filesystem — the system freezes or panics
- It cannot work on a real board without a network cable and a running NFS server
- It is fundamentally not self-contained — it is not a real product

The SD card approach replaces this dependency. After deployment, `sd.img` contains everything and the system boots with no host involvement.

---

## Working paths — why set variables?

```bash
PROJECT=~/Desktop/embedded-linux-qemu-labs
BOOT=$PROJECT/bootloader
BUILDROOT=$PROJECT/buildroot/buildroot # the repo
ROOTFS=$PROJECT/buildroot-rootfs # 
TINY=$PROJECT/tinysystem/nfsroot
SD=$BOOT/sd.img
```

### Why this matters

Embedded lab workflows involve many commands that must be run from specific directories, or that reference absolute paths to other directories. If you forget which directory you are in when you run `dd of=${LOOP}p2`, you could overwrite the wrong block device.

Setting shell variables at the start of a session makes every subsequent command self-documenting and protects against path mistakes. It also makes the command sequence portable — if someone clones the repo to a different machine, they change one line.

### What happens if you skip this :)

> Nothing immediately — but when you hit a path error three steps later, you will spend time debugging a typo instead of understanding the system, that's why u shouldn't mess with linux :3

---

## SD card partition layout — why two partitions?

```
sd.img
├── p1  FAT32    (~32 MB)   — U-Boot boot partition
└── p2  SquashFS            — root filesystem
```

### Why not one partition for everything?

U-Boot's `fatload` command — which is what loads the kernel into RAM — **only speaks FAT**. It cannot read ext4, SquashFS, or any Linux filesystem. So the boot files (kernel + DTB) must live on a FAT partition that U-Boot can access before the kernel is even running.

The rootfs, on the other hand, is mounted by the kernel — not by U-Boot. The kernel supports many filesystems including SquashFS, ext4, and others.

### Why SquashFS for the rootfs?

SquashFS is read-only and compressed. For this lab that is a feature, not a limitation:

- **Compressed:** the rootfs takes less space on the SD image
- **Read-only:** you cannot accidentally corrupt it by a bad write
- **Simple to deploy:** you write the SquashFS image directly with `dd` — no `mkfs`, no formatting step

The alternative — ext4 — requires you to `mkfs.ext4` the partition first, then mount it, then copy files into it. SquashFS skips all of that: you produce a single `.sqsh` file and `dd` it straight into the partition.

### What happens if you want a writable rootfs?

SquashFS truly cannot be written to. If you need persistent writable storage you have two options:

1. Add a third ext4 partition for data and mount it at `/data` or `/var`
2. Use `overlayfs` — layer a writable `tmpfs` or ext4 on top of the SquashFS mount so the system *appears* writable while the underlying SquashFS stays clean

For this lab, read-only is fine because we do not need persistence between reboots.

### What about a real SD card?

The layout is identical. You write `sd.img` to a real SD card with:

```bash
sudo dd if=sd.img of=/dev/sdX bs=4M status=progress conv=fsync
```

The partition table, FAT p1, and SquashFS p2 transfer exactly. The only thing that changes is the DTB (if ARCH is the same too) — more on that in the U-Boot section.

---

## Toolchain inspection — why inspect before configuring?

```bash
arm-linux-gcc --version
arm-linux-gcc -print-sysroot
find $(arm-linux-gcc -print-sysroot)/usr/include -name version.h | grep linux
```

### Why this step exists

Buildroot validates your external toolchain during configuration. If you tell Buildroot "this toolchain uses GCC 12" but it is actually GCC 14, the build stops immediately with an error. This inspection step exists so you know what values to enter in menuconfig before the build even starts.

### What the three commands tell you

- `arm-linux-gcc --version` → the GCC version (→ use this for "External toolchain gcc version" in Buildroot)
- `-print-sysroot` → the path to the toolchain's system root (→ use this for "Toolchain path" in Buildroot)
- The `find` for `version.h` → the kernel headers series the toolchain was built against (→ use this for "Kernel headers series" in Buildroot)
- `cat` that file then u see something like this
```c
#define LINUX_VERSION_MAJOR 6
#define LINUX_VERSION_PATCHLEVEL 0
#define LINUX_VERSION_SUBLEVEL 12
```
which is likely to be `v6.0.12`

## Before vs now

**Before (manual rootfs / tinysystem labs):** you called `arm-linux-gcc` directly to cross-compile individual programs. You knew the toolchain because you had been using it all along.

**Now (Buildroot):** Buildroot uses the toolchain internally for hundreds of packages. You need to describe the toolchain to Buildroot accurately so it can validate compatibility and generate correct build flags.

---

## Step 1–3: Workspace, clone, and release checkout

```bash
cd ~/Desktop/embedded-linux-qemu-labs
mkdir -p buildroot && cd buildroot
git clone https://gitlab.com/buildroot.org/buildroot.git
cd buildroot
git checkout 2026.02.1
```


---

## Step 4: menuconfig — the Buildroot configuration system

```bash
make menuconfig
```

### What menuconfig actually is

`menuconfig` is a terminal UI that reads Buildroot's `Kconfig` files and writes a `.config` file. The `.config` file is what drives the entire build — it records every decision: which architecture, which toolchain, which kernel version, which packages.

You can also edit `.config` directly in a text editor, but menuconfig validates dependencies so you do not accidentally enable a package that requires something you have not enabled.

### Why the configuration is split into several `make *-menuconfig` calls

Buildroot has sub-configurations for packages that have their own config systems. BusyBox is one — it has hundreds of applets (small programs: `ls`, `cp`, `httpd`, `sh`, etc.) and you configure which ones to include with `make busybox-menuconfig`. This generates a separate BusyBox `.config` that Buildroot stores and uses when it compiles BusyBox.

---

## Configuration: Target options — why these exact values?

```
Target Architecture        → ARM (little endian)
Target Architecture Variant → cortex-A9
Enable NEON SIMD extension  → enabled
Enable VFP extension        → enabled
Target ABI                 → EABIhf
Floating point strategy    → VFPv3-D16
```

### What each option controls

**ARM (little endian):** The vexpress-v2p-ca9 QEMU machine emulates an ARM Cortex-A9 in little-endian mode. Little endian means the least significant byte of a multi-byte value is stored at the lowest memory address. 

**cortex-A9:** This tells GCC which CPU microarchitecture to optimize for.

**NEON and VFP:** NEON is ARM's SIMD (**Single Instruction Multiple Data**) (المواد ساحت على بعض :) extension — it can operate on multiple values in one instruction, useful for audio, video, and math-heavy code. VFP is the floating point unit.

**EABIhf and VFPv3-D16:** `hf` means "hard float" — floating point arguments are passed in VFP registers rather than integer registers. This is faster than soft float (`eabi` without `hf`) because floating point operations do not need to be emulated. VFPv3-D16 is the specific VFP variant in the Cortex-A9 — 16 double-precision registers.


---

## Configuration: Toolchain — why external instead of internal?

```
Toolchain type  → External toolchain
Toolchain       → Custom toolchain
Toolchain path  → /home/YOUR_USERNAME/x-tools/arm-training-linux-musleabihf
```

### What "external toolchain" means

Buildroot can either **build a toolchain from source** (using Crosstool-NG internally) or **use an existing pre-built toolchain** you provide. Building a toolchain from source adds 30–60 minutes to the first build. The Bootlin lab provides a pre-built toolchain at `~/x-tools/`, so we point Buildroot at that.

### Why musl instead of glibc?

musl is a lightweight, standards-compliant C library designed for embedded systems. glibc is the GNU C library used on desktop Linux — it is larger, more complex, and slower to start. For an embedded system with limited RAM and storage, musl is the right choice.

The toolchain path ends in `musleabihf` — this tells you the toolchain was built to use musl (`musl`), with hard float ABI (`eabihf`).

### What happens if toolchain settings mismatch

Buildroot checks the actual GCC binary against what you declared. If you say GCC 12 but the binary reports 14, the build stops with an error like:

```
Buildroot: detected GCC 14.3.0, expected 12.x
```

If you somehow bypassed validation and got a mismatched binary into your rootfs, programs would fail to run at runtime with dynamic linking errors.

---

## Configuration: Kernel — why `arm/vexpress-v2p-ca9` not just `vexpress-v2p-ca9`?

```
Linux Kernel           → enabled
Kernel configuration   → Using in-tree defconfig
Defconfig name         → vexpress
In-tree DTS file names → arm/vexpress-v2p-ca9
```

### What the defconfig and DTS do

The **defconfig** (`vexpress`) is a pre-existing kernel configuration for the Versatile Express family of boards. It enables all the drivers the QEMU vexpress machine needs: the ARM interrupt controller, the PL011 UART for the serial console, the MMC controller for SD access, and the virtio network device.

The **DTS** (Device Tree Source) describes the hardware layout — where peripherals are in memory, which interrupts they use, which clocks feed them. The compiled version (DTB — Device Tree Blob) is loaded by U-Boot at boot time and passed to the kernel so it knows what hardware it is running on.

### Why the `arm/` prefix?

In older kernel versions (pre ~6.6), the DTS file for vexpress lived at (like our old kernel 6.0.12):
```
arch/arm/boot/dts/vexpress-v2p-ca9.dts
```

In newer kernels (6.6+), ARM DTS files were reorganized into vendor subdirectories:
```
arch/arm/boot/dts/arm/vexpress-v2p-ca9.dts
```

Buildroot's DTS field must match the path **relative to** `arch/arm/boot/dts/`. On a newer kernel you must write `arm/vexpress-v2p-ca9`. Writing just `vexpress-v2p-ca9` produces:

```
No rule to make target 'arch/arm/boot/dts/vexpress-v2p-ca9.dtb'
```

This is one of the most common errors in this lab when using a recent Buildroot release.

### What happens without the DTB

U-Boot would boot the kernel but pass it no hardware description. The kernel would panic almost immediately because it cannot find its console, its root device, or its interrupt controller.

---

## Configuration: Packages — what are we actually adding?

``` ts
Target packages  --->
  BusyBox
  System tools  --->
    [*] htop

  Audio and video applications  --->
    alsa-utils
      [*] alsamixer
      [*] speaker-test
    mpd
      [*] alsa
      [*] vorbis
      [*] tcp sockets
    mpd-mpc
```

### How Buildroot packages work

When you enable a package in menuconfig, Buildroot adds it to the build plan. During `make`, Buildroot downloads the package source, cross-compiles it using your toolchain, and installs the resulting binaries and libraries into `output/target/`. Everything in `output/target/` ends up in the rootfs image.

Buildroot handles all dependency resolution — if `mpd` requires `libvorbis`, Buildroot automatically includes `libvorbis` without you having to select it manually.

### Why htop specifically?

Nothing specific it's just simple and easy to use and understand and build
just a cute processes analyser.

### Alternatives

- Instead of Buildroot packages, you could cross-compile `htop` manually and copy it into the rootfs after extracting `rootfs.tar`. This works but is not reproducible — someone else cannot rebuild the same image from your configuration alone.
- You could use `opkg` (a package manager) at runtime on the target to install packages after boot. This requires network access from the target and a package feed, which is more infrastructure than a lab needs.

---

## BusyBox menuconfig — why a separate configuration step?

```bash
make busybox-menuconfig
```

```
Networking Utilities --->
  [*] httpd
```

### Why BusyBox has its own config

BusyBox is a single binary that implements over 300 Unix commands (`ls`, `sh`, `grep`, `httpd`, `tftp`, etc.). Each applet is a compile-time option — enabling it adds code to the BusyBox binary, disabling it removes it.

`httpd` is BusyBox's built-in HTTP server. It is tiny, requires no separate daemon, and serves static files and CGI scripts.

### Before vs now

**Before (tinysystem labs):** you likely copied a pre-built `httpd` binary or wrote your own. You had full control but had to manage the binary yourself.

**Now (Buildroot):** `httpd` is built into BusyBox and installed automatically. The `S99custom` init script starts it at boot. It is part of the reproducible build.

### What happens if you skip this

The `httpd` command is absent from the rootfs. Your web server validation step fails. `curl http://192.168.0.100/index.html` returns a connection refused error.

---

## Root password — the subtlety that breaks most people (u won't be able to login if u forgot this passwd !!!)

```
System configuration --->
  [*] Enable root login with password
  Root password  →  root
```

### Why this is subtle

Checking "Enable root login with password" only tells Buildroot to configure the system to *allow* password login for root. If you leave the password field empty, Buildroot generates an empty password hash in `/etc/shadow`, which many PAM configurations interpret as **"no login allowed"** or "login disabled."

You **must** put an actual password string in the "Root password" field. Buildroot will hash it with `mkpasswd` and write the hash into `output/target/etc/shadow`.

### What `/etc/shadow` actually contains

```
root:$5$xxxxxxxxxxxxxxxxxxxx:0:0:99999:7:::
```

The second field is the hashed password. `$5$` means SHA-256. If this field is `*` or `!` or empty, root login is disabled regardless of what password you type.

These two parts are completely from AI and i'm not sure about how much accurate is this :3
### How to recover without rebuilding

Boot with `init=/bin/sh` in bootargs (debug mode), mount the virtual filesystems manually, and use `passwd` to set the root password. This modifies the SquashFS — which is impossible, SquashFS is read-only. So you must add a writable layer or rebuild SquashFS. This is why fixing `/etc/shadow` before building SquashFS is critical.

### Alternative

Use `debug mode` from the start: boot with `init=/bin/sh`, set the password at runtime, but accept that it does not persist across reboots. This is only useful for one-off debugging.

---

## Filesystem image — why tar and not the direct SquashFS?

```
Filesystem images --->
  [*] tar the root filesystem
```

### Why not enable Buildroot's built-in SquashFS output?

Buildroot can output SquashFS directly (`[*] squashfs root filesystem`). However, the lab workflow adds custom files *after* the Buildroot build completes — the web pages from `tinysystem/nfsroot/www`.

By using `rootfs.tar` as the intermediate:
1. Buildroot builds and packages everything into `rootfs.tar`
2. You extract `rootfs.tar` into `buildroot-rootfs/`
3. You add your custom files to `buildroot-rootfs/`
4. You run `mksquashfs` on the final combined directory

This gives you the reproducibility of Buildroot for everything it knows about, plus the flexibility to add lab-specific files that Buildroot does not manage.

### What would change with a Buildroot overlay (the cleaner alternative)

Buildroot supports "root filesystem overlay directories" — you point Buildroot at a directory and it copies its contents into the rootfs during the build, before generating the image. This makes the custom files part of the build rather than a manual post-processing step.

```
System configuration --->
  Root filesystem overlay directories  →  ~/Desktop/embedded-linux-qemu-labs/my-overlay
```

The lab uses the manual approach because it is more transparent — you can see exactly what is being added and when. The overlay approach is better for real projects.

---

## Build — what `make -j$(nproc)` is actually doing

```bash
make -j$(nproc)
```

### The build pipeline

When you run `make`, Buildroot:

1. Downloads source tarballs for every enabled package (from the internet or a local cache)
2. Extracts and patches each package
3. Cross-compiles each package using your toolchain, in dependency order
4. Installs compiled files into `output/target/` (the fake root)
5. Strips debug symbols from binaries (reduces size)
6. Generates the filesystem images (`rootfs.tar`, `zImage`, `vexpress-v2p-ca9.dtb`)

`-j$(nproc)` runs as many parallel jobs as you have CPU cores. On a modern 8-core machine this can cut build time from 45 minutes to 10 minutes.

### output/ directory breakdown

```
output/
├── build/       ← extracted and compiled source for every package
├── host/        ← tools that run on your host machine (make, pkg-config, etc.)
├── images/      ← final deployable artifacts (zImage, dtb, rootfs.tar)
├── staging/     ← sysroot used by packages that depend on each other
└── target/      ← the actual rootfs tree that becomes your filesystem image
```

You care about `images/` for deployment and `target/` for inspection. You rarely need to touch `build/` or `host/` directly.
`images/` should be like this
```text
output/images/
├── zImage                          → The compressed ARM Linux kernel image
├── vexpress-v2p-ca9.dtb           → The compiled Device Tree Blob
├── rootfs.tar                      → The root filesystem archive
├── rootfs.ext2                     → (Optional, if ext2/3/4 was enabled)
├── rootfs.squashfs                 → (Optional, if SquashFS was enabled in Buildroot)
└── boot.vfat                       → (Optional, if boot partition image was enabled)
```

`target/` should be like this (something like a normal root)
```text
output/target/
├── bin/          → Essential user binaries (usually symlinked to busybox)
├── sbin/         → System binaries (init, httpd, etc.)
├── lib/          → Libraries (*.so files for musl/glibc and other packages)
├── usr/
│   ├── bin/      → Additional user programs (htop, mpd, alsamixer, etc.)
│   ├── sbin/     → Additional system programs
│   ├── lib/      → Additional libraries
│   └── share/    → Architecture-independent data
├── etc/
│   ├── init.d/   → Startup scripts (S99custom, etc.)
│   ├── shadow    → Password hashes (CRITICAL: must contain hash for root)
│   ├── inittab   → BusyBox init configuration
│   └── passwd    → User account information
├── proc/         → Empty mount point for procfs
├── sys/          → Empty mount point for sysfs
├── dev/          → Device nodes or empty (if using devtmpfs)
├── www/          → Will be created by your S99custom script (or add manually)
└── tmp/          → Temporary files directory
```

### What to verify after build

```bash
ls -lh output/images/ 
file output/images/zImage
# Expected: Linux kernel ARM boot executable zImage (little-endian)

find output/target -name "htop"
find output/target -name "httpd"
grep "CONFIG_HTTPD=y" output/build/busybox-*/.config
```

If `htop` or `httpd` are missing from `output/target`, the package was not enabled correctly in menuconfig. Do not proceed to deployment — go back and fix the configuration.

---

## Deploy: extracting rootfs.tar — why sudo and why chown?

```bash
sudo rm -rf buildroot-rootfs rootfs.sqsh
mkdir buildroot-rootfs

sudo tar xvf buildroot/buildroot/output/images/rootfs.tar \
  -C buildroot-rootfs # extract the rootfs.tar to a new dir buildroot-rootfs

sudo chown -R $USER:$USER buildroot-rootfs # be the owner
```


---

## Deploy: validating /etc/shadow before SquashFS (This is a cool part for manual /etc/shadow edit)

```bash
cat buildroot-rootfs/etc/shadow
```

### What a valid shadow line looks like

```
root:$5$rounds=5000$xxxx$yyyyyyyy:0:0:99999:7:::
```

The second field must be a real hash starting with `$5$` (SHA-256) or `$6$` (SHA-512). If it is `*`, `!`, empty, or absent, login will fail.

### Manual repair (when Buildroot got it wrong)

```bash
cd buildroot-rootfs

mkpasswd -m sha-256 root
# → outputs a hash like $5$xxxx$yyyy...

nano etc/shadow
# Replace the root line's second field with the hash above
```

### When does Buildroot get it wrong?

If the `mkpasswd` utility was not available on your host at Buildroot's configure time, or if the "Root password" field was left empty. Always verify before building SquashFS — it is much cheaper to fix here than after a failed login inside QEMU.

---

## Deploy: adding custom files

```bash
sudo cp -r tinysystem/nfsroot/www buildroot-rootfs/
```

### Why this is a manual step and not a Buildroot package

These files are lab-specific artifacts — your web pages, your deadlock demo binary, your Mini-HTOP implementation. Buildroot does not know about them because they are not in any package feed.

The cleaner engineering alternative is a **Buildroot overlay directory**: a directory tree whose contents get merged into the rootfs during the build. But for a lab where you are still modifying these files frequently, the manual copy is more transparent and faster to iterate on.

### What the /www directory becomes

`/www` is where BusyBox `httpd` looks for files to serve (as set by `-h /www` in the startup script). The `index.html` in `/www` becomes the home page accessible at `http://192.168.0.100/`.

---

## Deploy: S99custom startup script

```bash
nano buildroot-rootfs/etc/init.d/S99custom
chmod +x buildroot-rootfs/etc/init.d/S99custom
```

```sh
#!/bin/sh

mount -t proc none /proc 2>/dev/null
mount -t sysfs none /sys 2>/dev/null
mount -t devtmpfs devtmpfs /dev 2>/dev/null

ifconfig eth0 192.168.0.100 up

mkdir -p /www
/usr/sbin/httpd -h /www

exit 0
```

### How BusyBox init scripts work

BusyBox's `init` looks in `/etc/init.d/` and runs scripts in alphabetical order by name. The `S` prefix means "start" and the `99` means "run last." This script runs after all other init scripts have completed.

### Why mount /proc, /sys, and /dev?

These are virtual filesystems — they do not exist on disk. The kernel creates them in RAM:

- `/proc` exposes kernel and process information (memory, CPU, process list)
- `/sys` exposes device and driver information
- `/dev` holds device nodes for hardware access

Without these mounts, tools like `htop`, `ps`, and `ifconfig` fail because they cannot read from `/proc/stat`, `/proc/net/dev`, etc. The `2>/dev/null` suppresses errors if they are already mounted.

### Why `ifconfig eth0 192.168.0.100 up`?

QEMU's virtual network adapter appears as `eth0` inside the guest. By default it has no IP address. This line assigns the static IP `192.168.0.100`, which is what the host uses to reach the guest when you run `curl http://192.168.0.100/`.

### What if this script does not run?

If you boot with `init=/bin/sh` (debug mode), this script is never executed. You must run its contents manually, which is why the debug mode section shows those exact mount commands.

---

## Deploy: building SquashFS

```bash
mksquashfs buildroot-rootfs rootfs.sqsh -noappend
```

### What mksquashfs does

`mksquashfs` walks the source directory, compresses each file using the default compression algorithm (gzip, or xz with `-comp xz`), and writes a single self-contained SquashFS volume to `rootfs.sqsh`. It embeds file permissions, ownership, and timestamps from the source directory.

### The `-noappend` flag

Without `-noappend`, if `rootfs.sqsh` already exists, `mksquashfs` would append to it — adding the new files alongside the old ones in a single image. This is almost never what you want and produces a bloated, confusing image. `-noappend` forces a clean rebuild from scratch.

### Checking the output

```bash
file rootfs.sqsh
# → rootfs.sqsh: Squashfs filesystem, little endian, version 4.0, ...

unsquashfs -stat rootfs.sqsh
# Shows: number of inodes, compression, block size, total size
```

### Alternative compression

```bash
mksquashfs buildroot-rootfs rootfs.sqsh -noappend -comp xz
```

XZ compression produces a significantly smaller image (often 20–30% smaller than gzip) at the cost of slower compression and decompression. For a lab this tradeoff rarely matters, but for a real product with storage constraints, xz is often worth it.

---

## Deploy: loop device — the key that unlocks sd.img

```bash
LOOP=$(sudo losetup -fP --show sd.img)
echo $LOOP
```

### What a loop device is

A loop device is a kernel mechanism that makes a regular file look like a block device. `/dev/loop0` behaves exactly like `/dev/sda` — you can partition it, format partitions, read and write sectors. The kernel translates block device operations into file read/write operations transparently.

### What `-fP` means

- `-f` — find the first free loop device automatically (do not hardcode `/dev/loop0`)
- `-P` — scan the partition table in the image and create partition device nodes (`/dev/loop0p1`, `/dev/loop0p2`) for each partition

Without `-P`, you get `/dev/loop0` but no `/dev/loop0p1` or `/dev/loop0p2`. You cannot mount or write to individual partitions.

### Why store the result in `$LOOP`

The loop device number (`0`, `1`, `2`...) changes depending on what other loop devices are already in use on your machine. If you hardcode `loop0` and loop0 is already attached to a Docker image or a snap package, you will write to the wrong device. Always use `$LOOP`.

### What happens if you forget to detach

```bash
losetup -a | grep sd.img
# → /dev/loop0: []: (.../sd.img)
```

If you try to open `sd.img` in QEMU while the loop device is still attached, QEMU may fail to open the file exclusively, or you may corrupt the image by having two simultaneous writers.

---

## Deploy: writing SquashFS raw to partition 2 (this depends on ur path of the sqsh and the loop device no.)

```bash
sudo dd if=~/Desktop/embedded-linux-qemu-labs/rootfs.sqsh \
  of=${LOOP}p2 bs=1M status=progress
sync
```

### Why raw dd and not a filesystem copy?

SquashFS is not a filesystem you mount and copy files into — it is an image that you write byte-for-byte to a block device. The SquashFS format is self-contained: the superblock at the start of the image tells the kernel its size, compression, and layout. You do not need to `mkfs` the partition first.

If you tried to `mkfs.squashfs /dev/loop0p2` — that command does not exist. SquashFS images are created by `mksquashfs` on the host and written with `dd`.

### The `sync` command

`dd` may return before all data is actually written to the underlying file. `sync` flushes the kernel's write cache, ensuring `sd.img` is fully updated before you unmount and detach.

### What `bs=1M` does

`dd` defaults to 512-byte blocks. Reading and writing 512 bytes at a time for a 100 MB rootfs requires 200,000 system calls. `bs=1M` reads and writes 1 MB at a time, reducing that to ~100 system calls and dramatically improving throughput.

---

## Deploy: mounting FAT p1 and copying boot files

```bash
sudo mkdir -p /mnt/boot
sudo mount ${LOOP}p1 /mnt/boot

sudo cp .../images/zImage /mnt/boot/
sudo cp .../images/vexpress-v2p-ca9.dtb /mnt/boot/

sync
sudo umount /mnt/boot
sudo losetup -d $LOOP
```

### Why copy to a mount point instead of dd?

p1 is a FAT32 filesystem — it has a directory structure and a filesystem journal. You cannot `dd` individual files into it. You must mount it (the kernel's FAT driver handles the filesystem operations) and then `cp` files in.

### The order matters

Detach in this order:
1. `sync` — flush writes
2. `umount /mnt/boot` — release the FAT filesystem
3. `losetup -d $LOOP` — release the loop device

If you `losetup -d` before `umount`, the kernel loses access to the block device while the filesystem is still mounted. On Linux this usually results in the umount failing with "device is busy" or worse — corrupted FAT data.

---

### The next titles are completely from AI and i didn't check them cuz i'm so tired and the article can't be more late so good luck i wish it has no missleading information and to remind u and me

> قال صلى الله عليه وسلم: المُؤمِنُ القَويُّ خَيرٌ وأحَبُّ إلى اللهِ مِنَ المُؤمِنِ الضَّعيفِ، وفي كُلٍّ خَيرٌ. احرِصْ على ما يَنفَعُكَ، واستَعِنْ باللهِ ولا تَعجِزْ، وإن أصابَكَ شَيءٌ فلا تَقُلْ: لو أنِّي فعَلتُ كان كَذا وكَذا، ولَكِن قُلْ: قدَرُ اللهِ وما شاءَ فعَلَ؛ فإنَّ (لو) تَفتَحُ عَمَلَ الشَّيطانِ.
> الراوي : أبو هريرة | المحدث : مسلم | المصدر : صحيح مسلم

استعن بالله ولا تعجز
وان اصابك شيء فلا تقل **لو** اني فعلت كان كذا وكذا
ولكن قل: قدر الله وما شاء فعل


---

## QEMU launch script

```bash
sudo qemu-system-arm \
  -M vexpress-a9 \
  -m 128M \
  -nographic \
  -kernel u-boot/u-boot \
  -sd sd.img \
  -net tap,script=./qemu-myifup \
  -net nic \
  -audio none
```

### What each flag does

| Flag | Meaning |
|---|---|
| `-M vexpress-a9` | Emulate a Versatile Express A9 board — defines the memory map and peripherals |
| `-m 128M` | 128 MB of RAM — enough for kernel + rootfs + userspace |
| `-nographic` | No graphical window — use the terminal as the serial console |
| `-kernel u-boot/u-boot` | Load U-Boot as the "kernel" — QEMU starts U-Boot, not Linux directly |
| `-sd sd.img` | Attach sd.img as the SD card (appears as `/dev/mmcblk0` to U-Boot and Linux) |
| `-net tap,...` | Connect a TAP network device — allows real TCP/IP between host and guest |
| `-audio none` | Disable audio emulation — removes spurious ALSA warnings |

### Why QEMU loads U-Boot, not zImage directly?

QEMU can boot a Linux kernel directly, bypassing U-Boot. But the lab exists to practice the real embedded Linux boot flow where U-Boot is involved. Loading U-Boot as the "kernel" means QEMU starts U-Boot, U-Boot reads `sd.img`'s FAT partition, loads `zImage` and the DTB, and boots Linux — exactly what happens on a real board.

---

## U-Boot environment — why these exact commands?

```
=> setenv bootcmd 'fatload mmc 0:1 0x61000000 zImage; fatload mmc 0:1 0x62000000 vexpress-v2p-ca9.dtb; bootz 0x61000000 - 0x62000000'
=> setenv bootargs 'console=ttyAMA0,115200 root=/dev/mmcblk0p2 rootfstype=squashfs rootwait rw'
=> saveenv
=> reset
```

### Anatomy of `bootcmd`

```
fatload mmc 0:1 0x61000000 zImage
         │   │   └─ destination address in RAM
         │   └─ device:partition  (MMC controller 0, partition 1 = FAT p1)
         └─ mmc = SD/MMC interface
```

U-Boot reads `zImage` from FAT partition 1 and places it at physical RAM address `0x61000000`. Then it reads the DTB to `0x62000000`. Then:

```
bootz 0x61000000 - 0x62000000
      │           │   └─ DTB address
      │           └─ initrd address (- means none)
      └─ zImage address
```

`bootz` is the U-Boot command for booting a compressed ARM Linux kernel (zImage). It hands control to the kernel at `0x61000000` with the DTB at `0x62000000`.

### Anatomy of `bootargs`

These become the kernel command line — the kernel reads them at startup:

| Argument | Meaning | What breaks without it |
|---|---|---|
| `console=ttyAMA0,115200` | Serial console device and baud rate | No kernel log output — you are blind |
| `root=/dev/mmcblk0p2` | Root filesystem block device | Kernel panic: cannot find rootfs |
| `rootfstype=squashfs` | Filesystem type hint | Kernel probes all filesystem types — slower and may fail |
| `rootwait` | Wait for block device to appear | Kernel tries to mount before MMC is ready — panic |
| `rw` | Mount read-write | No effect on SquashFS (always RO) but silences a mount warning |

### The difference from the old NFS bootargs

**Before:**
```
root=/dev/nfs nfsroot=192.168.0.1:/path/to/nfsroot,v3,tcp ip=192.168.0.100
```

**Now:**
```
root=/dev/mmcblk0p2 rootfstype=squashfs rootwait
```

The kernel no longer needs network initialization before mounting root. It reads directly from the SD card, which is already initialized by U-Boot.

### What happens on a real board?

Everything in `bootcmd` and `bootargs` transfers directly — **except** the DTB filename. `vexpress-v2p-ca9.dtb` describes a virtual board that does not exist in hardware. You replace it with your real board's DTB:

```
fatload mmc 0:1 0x62000000 your-real-board.dtb
```

Also check that `mmcblk0p2` is correct — on boards with eMMC, the SD slot might be `mmcblk1p2`.

### `saveenv` and why it matters

`saveenv` writes the U-Boot environment variables to a reserved area of the SD card (or flash). Without `saveenv`, the variables are lost on every reset and you must re-enter them every time. After `saveenv`, U-Boot reads the environment automatically on boot and executes `bootcmd` without user intervention.

---

## Debug mode — init=/bin/sh

```
=> setenv bootargs '... init=/bin/sh'
```

### What this does

Normally, the kernel's last step is to execute `/sbin/init` (or BusyBox `init`), which reads `/etc/inittab` and starts all init scripts. `init=/bin/sh` replaces that final exec with a shell — you get a root shell directly, before any init scripts run.

### When to use it

- You cannot log in (bad shadow file) and need to fix it at runtime
- An init script is crashing and preventing login
- You need a writable environment to debug something (note: SquashFS is still read-only, but you can write to tmpfs)

### What to mount after getting a shell

```sh
mount -t proc none /proc
mount -t sysfs none /sys
mount -t devtmpfs devtmpfs /dev
```

Without these, most tools fail because they read from `/proc` and `/sys`. `ifconfig`, `ps`, `htop`, `cat /proc/cpuinfo` — all of these need these virtual filesystems.

### Why not save init=/bin/sh as the permanent bootargs

If you `saveenv` with `init=/bin/sh` in bootargs, the system always boots to a raw shell and never runs your init scripts. `httpd` never starts, `eth0` never gets an IP, your web server validation fails.

---

## Validation — what success looks like

```bash
# Inside QEMU
login: root
password: root

which htop      # → /usr/bin/htop
which httpd     # → /usr/sbin/httpd
htop            # Opens the process monitor

# From the host
curl http://192.168.0.100/index.html
# → <html>...Buildroot httpd is working...</html>
```

### Why validate each component separately?

A working boot does not mean packages are present. A present `htop` binary does not mean it is executable (wrong architecture). A running `httpd` does not mean it is serving the right directory.

Each validation command tests a specific layer:
- `which htop` — the package was built and installed in the rootfs
- `htop` — the binary is executable on this architecture and links correctly
- `curl` — the network is configured, `httpd` is running, and the webroot is correct

---

## Full cheat sheet

### Configure and build

```bash
cd ~/Desktop/embedded-linux-qemu-labs/buildroot/buildroot
make busybox-menuconfig   # enable httpd
make menuconfig           # set all target/toolchain/kernel/package/password options
make -j$(nproc)
```

### Prepare rootfs

```bash
cd ~/Desktop/embedded-linux-qemu-labs

sudo rm -rf buildroot-rootfs rootfs.sqsh
mkdir buildroot-rootfs

sudo tar xvf buildroot/buildroot/output/images/rootfs.tar \
  -C buildroot-rootfs
sudo chown -R $USER:$USER buildroot-rootfs

# Verify shadow
cat buildroot-rootfs/etc/shadow

# Add custom files
sudo cp -r tinysystem/nfsroot/www buildroot-rootfs/
sudo cp -r tinysystem/nfsroot/deadlock buildroot-rootfs/
sudo cp tinysystem/nfsroot/usr/bin/mini_htop_v2 buildroot-rootfs/usr/bin/

# Build SquashFS
mksquashfs buildroot-rootfs rootfs.sqsh -noappend
```

### Deploy to SD and boot

```bash
cd ~/Desktop/embedded-linux-qemu-labs/bootloader

LOOP=$(sudo losetup -fP --show sd.img)
echo $LOOP

# Write rootfs
sudo dd if=~/Desktop/embedded-linux-qemu-labs/rootfs.sqsh \
  of=${LOOP}p2 bs=1M status=progress
sync

# Write boot files
sudo mkdir -p /mnt/boot
sudo mount ${LOOP}p1 /mnt/boot
sudo cp ~/Desktop/embedded-linux-qemu-labs/buildroot/buildroot/output/images/zImage /mnt/boot/
sudo cp ~/Desktop/embedded-linux-qemu-labs/buildroot/buildroot/output/images/vexpress-v2p-ca9.dtb /mnt/boot/
sync
sudo umount /mnt/boot
sudo losetup -d $LOOP

./run6-qemu.sh
```

### U-Boot (at `=>` prompt)

```
setenv bootcmd 'fatload mmc 0:1 0x61000000 zImage; fatload mmc 0:1 0x62000000 vexpress-v2p-ca9.dtb; bootz 0x61000000 - 0x62000000'
setenv bootargs 'console=ttyAMA0,115200 root=/dev/mmcblk0p2 rootfstype=squashfs rootwait rw'
saveenv
reset
```

---

## Key engineering lessons

**Buildroot gives reproducibility.** Configuration drives the system. When you encode your choices in `.config` and commit it, anyone can reconstruct the exact same image.

**Every step has a reason.** `chown`, `sync`, `-noappend`, `-fP`, `saveenv` — none of these are cargo cult. Each one prevents a specific, real failure mode described above.

**The NFS+TFTP approach is not wrong — it is a different tool.** Use NFS during development when you need rapid iteration. Use the SD image when you need a self-contained, deployable system. Knowing both and knowing when to switch is the real skill.

---

## References

- [Bootlin Embedded Linux Lab materials](https://bootlin.com/training/embedded-linux/)
- [Buildroot manual](https://buildroot.org/downloads/manual/manual.html)
- [SquashFS kernel documentation](https://www.kernel.org/doc/html/latest/filesystems/squashfs.html)
- [U-Boot fatload command](https://u-boot.readthedocs.io/en/latest/usage/cmd/fatload.html)
- [Linux kernel command-line parameters](https://www.kernel.org/doc/html/latest/admin-guide/kernel-parameters.html)
- [Linux Device Tree usage model](https://www.kernel.org/doc/html/latest/devicetree/usage-model.html)
- [BusyBox httpd documentation](https://busybox.net/downloads/BusyBox.html#httpd)
