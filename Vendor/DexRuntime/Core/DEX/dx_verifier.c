#include "../Include/dx_dex.h"
#include "../Include/dx_log.h"
#include "../Include/dx_runtime.h"
#include <string.h>

#define TAG "Verifier"

// All opcodes are now handled by the interpreter (either executed or gracefully skipped)
static bool is_supported_opcode(uint8_t op) {
    (void)op;
    return true; // interpreter handles all opcodes via default skip path
}

// Verify a code item's bytecode is within our supported subset (unused; retained for future use)
static DxResult dx_verify_code(const DxDexFile *dex, const DxDexCodeItem *code, const char *method_name) {
    if (!code || !code->insns) return DX_ERR_NULL_PTR;

    uint32_t pc = 0;
    uint32_t unsupported_count = 0;

    while (pc < code->insns_size) {
        uint16_t inst = code->insns[pc];
        uint8_t opcode = inst & 0xFF;

        if (!is_supported_opcode(opcode)) {
            DX_WARN(TAG, "Unsupported opcode 0x%02x (%s) at pc=%u in %s",
                    opcode, dx_opcode_name(opcode), pc, method_name ? method_name : "?");
            unsupported_count++;
        }

        // Advance PC by instruction width (Dalvik spec format widths)
        pc += dx_opcode_width(opcode);
    }

    if (unsupported_count > 0) {
        DX_WARN(TAG, "%u unsupported opcodes in %s (will fail at runtime if reached)",
                unsupported_count, method_name ? method_name : "?");
    }

    return DX_OK;
}
