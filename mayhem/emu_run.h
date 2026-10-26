// Shared emulator driver for the Mayhem harness and the functional oracle: maps an
// address space, loads x86 code, and runs it through asbestos until it traps.
#ifndef MAYHEM_EMU_RUN_H
#define MAYHEM_EMU_RUN_H

#include <stdint.h>
#include <string.h>
#include "kernel/memory.h"
#include "asbestos/asbestos.h"
#include "emu/cpu.h"
#include "emu/interrupt.h"
#include "emu/tlb.h"

#define EMU_CODE_BASE 0x08048000u
#define EMU_CODE_PAGES 2
#define EMU_DATA_BASE 0x10000000u
#define EMU_DATA_PAGES 16
#define EMU_MAX_STEPS 2048

struct emu_result {
    struct cpu_state cpu;
    int interrupt;
    int syscalls;
};

// Runs `code` with `regs` (eax..edi order); `regs` may be NULL (all zero, esp mid-data).
// The engine only preempts a guest loop when another thread pokes it, so the guest is
// single-stepped (tf) and at most EMU_MAX_STEPS instructions run.
static inline void emu_run(const uint8_t *code, size_t size, const uint32_t regs[8],
        struct emu_result *out) {
    struct mem mem;
    mem_init(&mem);
    pt_map_nothing(&mem, PAGE(EMU_CODE_BASE), EMU_CODE_PAGES, P_READ | P_WRITE | P_EXEC);
    pt_map_nothing(&mem, PAGE(EMU_DATA_BASE), EMU_DATA_PAGES, P_READ | P_WRITE);

    size_t max = (size_t) EMU_CODE_PAGES * PAGE_SIZE;
    if (size > max)
        size = max;
    memcpy(mem_pt(&mem, PAGE(EMU_CODE_BASE))->data->data, code, size);

    struct cpu_state cpu;
    memset(&cpu, 0, sizeof(cpu));
    cpu.mmu = &mem.mmu;
    cpu.eip = EMU_CODE_BASE;
    cpu.fcw = 0x37f;
    if (regs != NULL)
        memcpy(cpu.regs, regs, sizeof(cpu.regs));
    cpu.esp = EMU_DATA_BASE + (EMU_DATA_PAGES / 2) * PAGE_SIZE;

    struct tlb tlb = {};
    tlb_refresh(&tlb, &mem.mmu);
    int interrupt = INT_NONE;
    int syscalls = 0;
    for (int run = 0; run < EMU_MAX_STEPS; run++) {
        cpu.tf = 1;
        read_wrlock(&mem.lock);
        interrupt = cpu_run_to_interrupt(&cpu, &tlb);
        read_wrunlock(&mem.lock);
        if (interrupt == INT_SYSCALL) {
            syscalls++;
            cpu.eax = (uint32_t) -38;
            continue;
        }
        if (interrupt != INT_DEBUG)
            break;
    }
    out->cpu = cpu;
    out->interrupt = interrupt;
    out->syscalls = syscalls;

    mem_destroy(&mem);
}

#endif
