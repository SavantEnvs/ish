# i386 guest: fork; the child exits 3, the parent wait4()s and exits with the child's status
.intel_syntax noprefix
.globl _start
_start:
    mov eax, 2
    int 0x80
    test eax, eax
    jnz parent
    mov eax, 1
    mov ebx, 3
    int 0x80
parent:
    mov eax, 114
    mov ebx, -1
    lea ecx, [status]
    xor edx, edx
    xor esi, esi
    int 0x80
    mov ebx, [status]
    shr ebx, 8
    mov eax, 1
    int 0x80
.bss
status:
    .space 4
