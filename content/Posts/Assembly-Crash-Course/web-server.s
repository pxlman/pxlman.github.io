.intel_syntax noprefix
.section .rodata
OKAYMSG: .asciz "HTTP/1.0 200 OK\r\n\r\n"

.section .text

.global _start
_start:
# socket(AF_INET, SOCK_STREAM, 0)
	mov rdi, 2
	mov rsi, 1
	mov rdx, 0
	mov rax, 41
	syscall
	push rax

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
# listen (socket, 0)
	mov rdi, [rsp+16]
	mov rsi, 0
	mov rax, 50
	syscall

parent:
# accept( socket, null, null )
	mov rdi, [rsp+16]
	mov rsi, 0
	mov rdx, 0
	mov rax, 43
	syscall
	push rax

# fork()
	mov rax, 57
	syscall
# if parent_id loop on acceptance
	cmp rax, 0
	je child
# close(accept)
	mov rdi, [rsp]
	mov rax, 3
	syscall
	pop rax
	jmp parent
child:
# close(socket)
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
# Getting requested path
	xor rbx, rbx
	xor rcx, rcx
findfirstspace:
	mov bl, [rsp+rcx]
	inc rcx
	cmp bl, ' '
	jne findfirstspace
	mov r8, rcx
	add r8, rsp
findsecondspace:
	mov bl, [rsp+rcx]
	inc rcx
	cmp bl, ' '
	je foundsecondspace
	jmp findsecondspace
foundsecondspace:
	sub rcx, 1
	mov byte ptr [rsp+rcx], 0x0

# Getting requested method
	xor rbx, rbx
	mov ebx, [rsp]
	cmp ebx, 0x54534f50 # "POST"
	je POST
	cmp ebx, 0x20544547 # "GET "
	je GET
	jmp neither

GET:
# open ( r8, 0, 0)
	mov rdi, r8
	mov rsi, 0
	mov rdx, 0
	mov rax, 2
	syscall
	add rsp, 512
# read ( open, rsp, 512)
	mov rdi, rax
	sub rsp, 512
	lea rsi, [rsp]
	mov rdx, 512
	push rax
	mov rax, 0
	syscall
# close ( open)
	pop rdi
	push rax
	mov rax, 3
	syscall
# write (accept, 200ok, 19)
	mov rdi, [rsp+520]
	sub rsp, 24
	lea rsi, OKAYMSG
	mov rdx, 19
	mov rax, 1
	syscall
	add rsp, 24
# write (accept, text, 512)
	mov rdi, qword ptr [rsp+520]
	lea rsi, [rsp+8]
	mov rdx, qword ptr [rsp]
	mov rax, 1
	syscall
	add rsp, 8
	add rsp, 512
	jmp neither

POST:
# Getting length
	xor rcx, rcx
	xor rbx, rbx
findcontentlength:
	mov rbx, [rsp+rcx]
	mov rdx, 0x2d746e65746e6f43
	cmp rbx, rdx # "Content-"
	je foundcontentlength
	inc rcx
	jmp findcontentlength
foundcontentlength:
	add rcx, 16 # 8+7 text after "Length: "
	xor rax, rax
	xor rbx, rbx
getlength:
	mov bl, [rsp+rcx]
	cmp bl, 0
	je gotlength
	sub bl, '0'
	cmp bl, 9
	ja gotlength
	imul rax, 10
	add rax, rbx
	inc rcx
	jmp getlength
gotlength:
	mov r15, rax

# Find the start of body
	xor rcx, rcx
	xor rbx, rbx
loopbodystart:
	mov ebx, [rsp+rcx]
	cmp ebx, 0x0a0d0a0d
	je endbodystart	
	inc rcx
	jmp loopbodystart
endbodystart:
	add rcx, 4
	mov r10, rsp
	add r10, rcx

# open(r8, 65, 0644)
	mov rdi, r8
	mov rsi, 65
	mov rdx, 0777
	mov rax, 2
	syscall
	push rax
	# add rsp, 512
# write(open, r10, r15)
	mov rdi, rax
	mov rsi, r10
	mov rdx, r15
	mov rax, 1
	syscall
# close(open)
	pop rdi
	mov rax, 3
	syscall
# write (accept, 200ok, 19)
	mov rdi, [rsp+512]
	sub rsp, 24
	lea rsi, OKAYMSG
	mov rdx, 19
	mov rax, 1
	syscall
	add rsp, 24

neither:
# close ( accept )
	mov rdi, [rsp+512]
	mov rax, 3
	syscall
# exit(0)
	mov rax, 60
	mov rdi, 0
	syscall

