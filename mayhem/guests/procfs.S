# i386 guest: opens /proc/self/stat, reads it and writes it to stdout; exit(0)
.intel_syntax noprefix
.globl _start
_start:
    mov eax, 5
    lea ebx, [path]
    xor ecx, ecx
    xor edx, edx
    int 0x80
    mov ebx, eax
    mov eax, 3
    lea ecx, [buf]
    mov edx, 256
    int 0x80
    mov edx, eax
    mov eax, 4
    mov ebx, 1
    lea ecx, [buf]
    int 0x80
    mov eax, 1
    xor ebx, ebx
    int 0x80
path:
    .asciz "/proc/self/stat"
.bss
buf:
    .space 256
