# i386 guest for the oracle and a fuzzing seed: write(1, msg, len); exit(7)
.intel_syntax noprefix
.globl _start
_start:
    mov eax, 4
    mov ebx, 1
    lea ecx, [msg]
    mov edx, 15
    int 0x80
    mov eax, 1
    mov ebx, 7
    int 0x80
msg:
    .ascii "hello from ish\n"
