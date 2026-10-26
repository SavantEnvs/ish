// Known-answer driver for the emulator: runs hex-encoded x86 code and prints the final
// machine state, which mayhem/test.sh compares against hand-computed values.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "emu_run.h"

int main(int argc, char *argv[]) {
    if (argc != 2 || strlen(argv[1]) % 2 != 0) {
        fprintf(stderr, "usage: %s <hex x86 code>\n", argv[0]);
        return 2;
    }
    size_t size = strlen(argv[1]) / 2;
    uint8_t *code = malloc(size);
    for (size_t i = 0; i < size; i++) {
        unsigned byte;
        if (sscanf(argv[1] + 2 * i, "%2x", &byte) != 1)
            return 2;
        code[i] = byte;
    }

    struct emu_result r;
    emu_run(code, size, NULL, &r);
    struct cpu_state *cpu = &r.cpu;
    printf("eax=%08x ecx=%08x edx=%08x ebx=%08x esp=%08x ebp=%08x esi=%08x edi=%08x\n",
            cpu->eax, cpu->ecx, cpu->edx, cpu->ebx, cpu->esp, cpu->ebp, cpu->esi, cpu->edi);
    printf("eip=%08x int=%d syscalls=%d cf=%d zf=%d sf=%d of=%d\n",
            cpu->eip, r.interrupt, r.syscalls, CF, !!ZF, !!SF, OF);
    free(code);
    return 0;
}
