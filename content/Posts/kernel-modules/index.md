---
title: "Kernel Module 101: hello.ko → What's Next?"
date: 2026-04-21
description: A summary for the basics of kernel modules
tags:
  - note
  - university
  - kernel
  - linux
  - C
  - bootlin
---

## Objectives
We will show and explain a bit for Why/How to implement a kernel module not a normal C program that run as a service in the user-space

> **Audience:** Colleagues who have the [Bootlin embedded Linux labs](https://bootlin.com/training/embedded-linux/) running locally and want to write their first kernel module.

---

## 0. What differs from computer to another?
There are some variables that change from one person to another depending on the environment he have made through the course till now so u need to have these variables in hand first:
1. *KERNEL_DIR*: the path where u cloned the linux kernel source code from github `git clone blabla/linux` this path should end with `linux/`
2. *YOUR_NAME*: of course my name is different than u unless u r me who is reading this (this variables line is just for u to be happy bit it's not important :3 )
3. *NFSROOT*: this is the root itself for ur target machine (usually it's inside tinysystem i think but it completely depends on ur style then)
## 1. Write the module
These files `hello.c` and `Makefile` can be in whatever place u like to program them in can be on ur home directory or ur table or in the garden as if u can build them and copy the `hello.ko` to the *NFSROOT* dir

### `hello.c`

Every kernel module needs an `init` and an `exit` function, plus a license declaration. That's it for a minimal module.

```c
#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/init.h>

MODULE_LICENSE("GPL");
MODULE_AUTHOR("YOUR NAME?"); # optional
MODULE_DESCRIPTION("Hello from kernel space"); # optional

int init_module(void){
	printk(KERN_INFO "Hello Kernel!\n");
	return 0;
}

void cleanup_module(void){
	printk(KERN_INFO "Goodbye Kernel!\n");
}


```

> **Note:** `printk()` writes to the kernel ring buffer, not your terminal. Read it with `dmesg | tail` after `insmod`.
> 
> `KERN_INFO` is the type of the logged info so it's not `ERROR` or `WARN` so it won't be highlighted.

---

### `Makefile`

The Bootlin labs use a Buildroot-generated toolchain. Point `KERNELDIR` at the kernel build tree that Buildroot produced.

```makefile
# Adjust KERNELDIR to your actual Buildroot output path
KERNELDIR ?= KERNEL_DIR

obj-m += hello.o

all:
	make -C $(KERNELDIR) M=$(PWD) ARCH=arm CROSS_COMPILE=arm-linux- modules

clean:
	make -C $(KERNELDIR) M=$(PWD) clean
```

> The Bootlin lab handout tells you the exact `KERNELDIR` path and toolchain prefix — copy them verbatim to avoid version mismatches.

---

### Build output
Inside that path u were developing the module:
```bash
$ make
  Building modules, stage 2.
  MODPOST 1 modules
$ ls *.ko
hello.ko
$ file hello.ko
hello.ko: ELF 32-bit LSB relocatable, ARM, ...
```

---

## 2. Deploy via NFS root

### How the Bootlin QEMU lab works

The guest boots with its root filesystem served over NFS from your **host machine**. This means you can place files into the NFS export directory on your host and the running guest sees them instantly — no reflashing, no rebuilding an image.

**TFTP is only used** to deliver the kernel image (`zImage`) and DTB at boot time. For module deployment, NFS root is all you need.

The file `hello.ko`'s path doesn't really matter cuz the only thing matter is that u make sure u make the command `insmod` cuz this is the real controller that uses this file NOT IT'S PLACE.

```
Host machine
  ~/user/whatever/path/nfsroot/   ← NFS export (your "rootfs") <- NFSROOT
        └─ hello.ko   ← copy it here (or in any path u like it doesn't matter)

QEMU guest
  /hello.ko      ← sees it immediately via NFS mount
```

---

### Step 1 — Copy `hello.ko` into the NFS root (on your host)

```bash
cp hello.ko ${NFSROOT}/
```


---

### Step 2 — Load and verify (inside the QEMU serial console)

```bash
# Load the module
$ insmod /root/hello.ko

# Read the kernel log
$ dmesg | tail -3
[  42.123456] hello: module loaded

# Confirm it's listed
$ lsmod | grep hello
hello                  16384  0

# Remove it cleanly
$ rmmod hello
$ dmesg | tail -1
[  55.654321] hello: module removed
```

---

### Troubleshooting

| Error                       | Likely cause                                    | Fix                                                        |
| --------------------------- | ----------------------------------------------- | ---------------------------------------------------------- |
| `Invalid module format`     | .ko compiled against a different kernel version | Recompile pointing at the exact kernel tree Buildroot used |
| `Operation not permitted`   | Not root inside the guest                       | Check with `whoami` — labs default to root                 |
| `No such file or directory` | NFS share not mounted                           | `mount \| grep nfs` on guest, `exportfs -v` on host        |

---

## 3. What's next?

You have a working kernel module. Here's what to build next — from immediately useful to deeply educational.

---

### For gamers / latency-sensitive use cases

#### Custom input remapper (evdev hook)

Hook into the `evdev` layer at kernel level to remap gamepad buttons or inject key events globally — before any userspace application sees them. No software overhead, works in every app, survives window manager restarts.

**Key concepts:** `input_handler`, `input_dev`, `input_event()`

#### CPU governor / scheduler tuner

Write a `sysfs` interface that lets you switch CPU frequency scaling policy at runtime, or force the scheduler to elevate a specific PID's priority — effectively a real-time gaming mode toggle.

**Key concepts:** `cpufreq_driver`, `sysfs_create_file()`, `sched_setscheduler()`

---

### For power users

#### Filesystem watcher (VFS hooks)

Hook VFS layer operations to watch any directory for file creates, deletes, and renames — faster and more reliable than `inotify` for custom build systems or sync tools.

**Key concepts:** `fsnotify`, `dentry` operations, `inode` hooks

#### Network traffic shaper (Netfilter)

Use Netfilter hooks to inspect, drop, or rewrite packets in-kernel. Block specific apps from the network, QoS a torrent client, or build a custom firewall rule engine.

**Key concepts:** `nf_hook_ops`, `NF_INET_PRE_ROUTING`, `nf_register_net_hook()`

---

### Foundations (learn these first if you want to go deep)

#### Virtual character device (`/dev/mything`)

Create a character device your userspace programs can `open()`, `read()`, and `write()`. This is the building block for hardware drivers, shared-memory IPC, and custom kernel interfaces.

**Key concepts:** `cdev_init()`, `file_operations`, `copy_to_user()` / `copy_from_user()`

```c
// Skeleton — the three things every char device needs
static struct file_operations hello_fops = {
    .owner   = THIS_MODULE,
    .read    = hello_read,
    .write   = hello_write,
    .open    = hello_open,
};
```

#### kprobes / eBPF companion

Attach to any kernel function at runtime and log its arguments without rebooting. Use kprobes directly in a module, or as a stepping stone to writing eBPF programs with full kernel visibility.

**Key concepts:** `kprobe`, `register_kprobe()`, `bpf_prog_load()`

---

## Learning path

```
hello.ko
  └─ add sysfs node  (make it interactive)
       └─ char device  (/dev interface for userspace)
            └─ Netfilter hook  (network-level control)
                 └─ kprobes  (trace anything at runtime)
                      └─ eBPF  (programmable kernel observability)
```

Each step teaches a new kernel subsystem and each one is independently useful in production.

---

## Quick reference

```bash
# Build
make KERNELDIR=~/felabs/buildroot/output/build/linux-6.x ARCH=arm CROSS_COMPILE=arm-linux-

# Deploy (host)
cp hello.ko ~/felabs/nfsroot/root/

# Load (guest)
insmod /root/hello.ko && dmesg | tail

# Unload (guest)
rmmod hello

# Check loaded modules (guest)
lsmod | grep hello

# Module info
modinfo /root/hello.ko
```

---

## References

- [Bootlin Embedded Linux Lab materials](https://bootlin.com/training/embedded-linux/)
- [Linux Kernel Module Programming Guide](https://sysprog21.github.io/lkmpg/)
- [Linux Device Drivers, 3rd ed. (free)](https://lwn.net/Kernel/LDD3/)