+++
date = '2025-09-14T11:38:14+03:00'
draft = false
title = 'Assembly-Based Web Server (pwn.college)'
description = 'An explanation for the assembly web server i made as a challenge in pwn.college'
tags = ['assembly', 'linux', 'web', 'pwn']
+++

---

# 🛰️ Assembly Web Server

You can do the task with solving the challenge in module `Building a web server` in dojo `Computing 101` in [pwn.college](https://pwn.college/). The original code is [here i think](./web-server.s).

> Quick reminder: Linux syscalls return values in `rax`. On success it's non-negative. On error the kernel returns `-errno` (a negative value). In assembly you usually test `rax` and jump if negative. Think: the kernel is passive-aggressively telling you what went wrong — you must check.

### 📚 How to “understand” each syscall better
1. Your syscalls companion is [x64.syscall.sh](https://x64.syscall.sh/) then use the rule number two `man 2 <SYSCALL>` 
2. `man 2 socket` / `man 2 bind` / `man 2 listen` / `man 2 accept` — kernel API manpages; start here.

---

## 🔧 Syscall patterns

In your server most syscalls are used without robust error checks. Here’s a standard pattern to check result and branch on error (pseudo-assembly):

```asm
    mov rax, 41       # socket()
    syscall
    cmp rax, 0
    js  syscall_error   # jump if sign flag set (negative => error)
    mov rbx, rax        # save fd

syscall_error:
    neg rax              # make it positive errno (optional)
    ; handle error: write to stderr, exit, retry, etc.
```

`js` jumps if the result is negative (since kernel uses negative errno). Another common check:

```asm
    test rax, rax
    js  handle_err
```

Use these around `socket`, `bind`, `listen`, `accept`, `open`, `read`, `write`, `fork`, etc.

---

## 🧩 Socket creation

Assembly in your code:

```asm
# socket(AF_INET, SOCK_STREAM, 0)
	mov rdi, 2
	mov rsi, 1
	mov rdx, 0
	mov rax, 41
	syscall
	push rax # We will need this fd many times later
```

C equivalent (using libc wrapper):

```c
int fd = socket(AF_INET, SOCK_STREAM, 0);
if (fd < 0) { perror("socket"); exit(1); }
```

Explain some jargons:
- `AF_INET` means IPv4. other options like `AF_INET6` (IPv6) and `AF_UNIX` (local sockets).
  - Bluetooth would be `AF_BLUETOOTH`, but that’s a different story.
- `SOCK_STREAM` means TCP (not UDP)
- `protocol = 0` means default protocol for TCP (which is IP). Other protocols exist, but we don’t care.
Think of it like asking the kernel: *“Give me a magic telephone line to the internet.”*
And the kernel hands back a file descriptor like: *“Here, don’t lose it.”*

You can find more at `man 2 socket`.

---

## 📍 Bind — crafting sockaddr

You already build the `sockaddr_in` on the stack. After syscall:
```asm 
# struct { AF_INET, htons(80), htonl("0.0.0.0") }
	sub rsp, 16
	mov word ptr [rsp], 2 # AF_INET
	mov word ptr [rsp+2], 0x5000 # htons(80)
	mov dword ptr [rsp+4], 0 # 0.0.0.0
	mov qword ptr [rsp+8], 0

# bind (socket, struct, 16)
	mov rdi, rax
	mov rsi, rsp
	mov rdx, 16
	mov rax, 49
	syscall
```

C equivalent:

```c
struct sockaddr_in addr;
addr.sin_family = AF_INET;
addr.sin_port = htons(80); // port 80
addr.sin_addr.s_addr = htonl("0.0.0.0");

bind(fd, (struct sockaddr*)&addr, sizeof(addr));
```

> Tip: `htons(80)` and `htonl(INADDR_ANY)` are used to convert to network byte order. In assembly the bytes were written as `0x5000` which is `htons(80)` for little-endian machines — neat trick.
`htons(80)` is just making the bytes order with least significant byte first (little-endian). For `htons` that work for unsigned short int (word) `0x0050` to be `0x5000`.
`htonl(INADDR_ANY)` is `0` in network byte order, so writing `0` directly works.
For another address like `127.0.0.1` for the localhost, you’d write `0x7F000001` in little-endian with `htonl` (works for unsigned int which is DWORD) as `0x0100007F`.

---

## 🗣️ Listen

Assembly:

```asm
# listen (socket, 0)
	mov rdi, [rsp+16]
	mov rsi, 0
	mov rax, 50
	syscall
```
> The backlog argument defines the maximum length to which the queue of pending connections for sockfd may grow.  If a  connection  request  arrives  when the queue is full, the client may receive an error with an indication of ECONNREFUSED or, if the underlying protocol supports retransmission, the request may be ignored so that a later reattempt at connection succeeds.

`man 2 listen` for details.

---

## 🤝 Accept

Assembly:

```asm
parent:
# accept( socket, null, null )
	mov rdi, [rsp+16]
	mov rsi, 0
	mov rdx, 0
	mov rax, 43
	syscall
	push rax # client fd
```
This waits for an incoming connection and returns a new socket fd for that client.

---


## 👨‍👩‍👧‍👦 Forking

Your server calls `fork()` per connection:

Assembly:

```asm
# fork()
	mov rax, 57
	syscall # opens a new parallel process now
# Fork returns 0 in child, child's pid in parent
	cmp rax, 0
	je child
# close(accept) close the accepted socket in parent cuz we don't need it here
	mov rdi, [rsp]
	mov rax, 3
	syscall
	pop rax
	jmp parent # loop back to accept a new request
```
- **The Parent** goes back to accept more connections.
- **The Child** should now handle the client request.

---

## 📖 Read / Parse request

### Reading the request to the stack
Assembly:

```asm
child:
# close(socket) close the listening socket in child cuz we don't need it here
	mov rdi, [rsp+24]
	mov rax, 3
	syscall
# read ( accept, STRING, SIZE )
	mov rdi, qword ptr [rsp]
	sub rsp, 512
	mov rsi, rsp
	mov rdx, 512
	mov rax, 0
	syscall
```

### Parsing the path from the HTTP request

```asm
# Getting requested path
	xor rbx, rbx
	xor rcx, rcx # making rbx,rcx zero
findfirstspace:
	mov bl, [rsp+rcx] # read 1 byte at rsp+rcx into bl (which is the accepted request)
	inc rcx
	cmp bl, ' '
	jne findfirstspace
	mov r8, rcx
	add r8, rsp # r8 = rsp+rcx now points to the path start
findsecondspace:
	mov bl, [rsp+rcx]
	inc rcx
	cmp bl, ' '
	jne findsecondspace
foundsecondspace:
	sub rcx, 1
	mov byte ptr [rsp+rcx], 0x0 # null terminate the path. with this the r8=rsp+rcx is starting at the path and ends with the null terminator here and this is how C strings work
```

### Parsing the method (GET/POST)

```asm
# Getting requested method
	xor rbx, rbx
	mov ebx, [rsp]
	cmp ebx, 0x54534f50 # "POST" Use little-endian
	je POST
	cmp ebx, 0x20544547 # "GET " Use little-endian
	je GET
	jmp neither
```

### 

Parsing notes:

* You search for spaces to isolate method/path — ok for simple requests, but HTTP can be trickier (long headers, chunked encoding).
* For production: use a robust HTTP parser (e.g., `http-parser`, `llhttp`) or implement stronger stateful parsing.

---

## 📂 Open, write, close (file I/O)

GET flow:

* `open(path, O_RDONLY)`
* `read(fd, buffer, size)`
* `write(client, buffer, bytes)`
* `close(fd)`

C snippet:

```c
int f = open(path, O_RDONLY);
ssize_t r = read(f, buf, sizeof buf);
write(client, ok_msg, strlen(ok_msg));
write(client, buf, r);
close(f);
```

Assembly code:
```asm
# open ( r8, 0, 0)
	mov rdi, r8
	mov rsi, 0
	mov rdx, 0
	mov rax, 2
	syscall
	add rsp, 512
# read (open, rsp, 512)
	mov rdi, rax
	sub rsp, 512
	lea rsi, [rsp]
	mov rdx, 512
	push rax
	mov rax, 0
	syscall
# close (open)
	pop rdi
	push rax
	mov rax, 3
	syscall
# write (accept, 200ok, 19)
	mov rdi, [rsp+520]
	lea rsi, OKAYMSG # this is defined at the start of the file
	mov rdx, 19
	mov rax, 1
	syscall
# write (accept, text, 512) writing the file content to the client meaning sending it basically
	mov rdi, qword ptr [rsp+520] # 512 (read buffer) + 8 (openfile fd)
	lea rsi, [rsp+8]
	mov rdx, qword ptr [rsp]
	mov rax, 1
	syscall
	add rsp, 512 # cleaning up the stack from the read buffer
	add rsp, 8 # cleaning up the stack from the openfile fd
	jmp neither
```

POST path (your code writes uploaded body to file):

* Consider `open(path, O_CREAT|O_WRONLY|O_TRUNC, 0644)` — create or truncate and set permissions.
* Use `write` loop: `while (left) { ssize_t w = write(...); handle partial writes }`

> You can read the POST part from the source code it's similar idea but with addition to reading the body of the request it's a tough part to implement correctly so you can enjoy understanding it urself :)

---


## 🛡️ Security caveats (must mention)

* You currently trust the request path directly — can be path traversal (`../etc/passwd`). Always sanitize paths.
* No checks on `Content-Length` vs buffer sizes — could be abused.
* No TLS — everything is plaintext.
* No limits on uploaded file size — put caps (max size) and quota.

---

## 🧪 Debugging & inspection tools

* `strace -f ./yourserver` — see syscalls and arguments. Amazing for syscall-level debugging.
* `ltrace` — library calls.
* `gdb` — step assembly, inspect registers.

---

