// Feeds fuzzer-chosen x86 machine code and initial register state to iSH's asbestos
// JIT/interpreter, in-process, with no kernel or filesystem underneath.
#include <stddef.h>
#include <stdint.h>
#include <string.h>
#include "emu_run.h"

// Input: 8 x (mode byte, 16-bit value) seeding eax..edi, then the code bytes.
#define HEADER (8 * 3)

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
    if (size <= HEADER)
        return -1;

    uint32_t regs[8];
    for (int i = 0; i < 8; i++) {
        uint8_t mode = data[i * 3] & 3;
        uint32_t value = data[i * 3 + 1] | (uint32_t) data[i * 3 + 2] << 8;
        switch (mode) {
            case 0: regs[i] = value | value << 16; break;
            case 1: regs[i] = EMU_DATA_BASE + value; break;
            case 2: regs[i] = EMU_CODE_BASE + (value & 0x1fff); break;
            default: regs[i] = (uint32_t) (int16_t) value; break;
        }
    }
    regs[4] = EMU_DATA_BASE + 0x8000 + (regs[4] & 0x3fff);

    struct emu_result result;
    emu_run(data + HEADER, size - HEADER, regs, &result);
    return 0;
}
