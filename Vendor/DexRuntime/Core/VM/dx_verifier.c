// dx_verifier.c — DEX bytecode verifier
// Performs structural verification of method bytecode before execution.
// Single/double pass: builds instruction boundary bitmap, then validates
// branches, register indices, DEX table indices, and payload formats.

#include "../Include/dx_vm.h"
#include "../Include/dx_dex.h"
#include "../Include/dx_log.h"
#include "../Include/dx_runtime.h"
#include <string.h>
#include <stdlib.h>
#include <stdio.h>
#include <stdarg.h>

#define VERIFY_TAG "VERIFY"

// Verification context
typedef struct {
    const uint16_t *code;
    uint32_t code_size;       // insns_size in 16-bit code units
    uint16_t registers_size;
    DxDexFile *dex;
    const char *method_name;  // for error messages
    char error[256];

    // Instruction boundary bitmap: bit N set means code[N] is an instruction start
    uint8_t *insn_bitmap;     // ceil(code_size / 8) bytes
} DxVerifyContext;

// ---- Bitmap helpers ----

static inline void bitmap_set(uint8_t *bm, uint32_t idx) {
    bm[idx >> 3] |= (1u << (idx & 7));
}

static inline bool bitmap_test(const uint8_t *bm, uint32_t idx) {
    return (bm[idx >> 3] & (1u << (idx & 7))) != 0;
}

// ---- Error reporting ----

static DxResult verify_fail(DxVerifyContext *vctx, const char *fmt, ...)
    __attribute__((format(printf, 2, 3)));

static DxResult verify_fail(DxVerifyContext *vctx, const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(vctx->error, sizeof(vctx->error), fmt, ap);
    va_end(ap);
    DX_ERROR(VERIFY_TAG, "%s: %s", vctx->method_name ? vctx->method_name : "?", vctx->error);
    return DX_ERR_VERIFICATION_FAILED;
}

// ---- Register validation helpers ----

// Check that a 4-bit register (0..15) is within registers_size
static inline bool check_reg4(DxVerifyContext *vctx, uint32_t reg) {
    return reg < vctx->registers_size;
}

// Check that an 8-bit register (0..255) is within registers_size
static inline bool check_reg8(DxVerifyContext *vctx, uint32_t reg) {
    return reg < vctx->registers_size;
}

// Check that a 16-bit register is within registers_size
static inline bool check_reg16(DxVerifyContext *vctx, uint32_t reg) {
    return reg < vctx->registers_size;
}

// Check a wide register pair (reg and reg+1 must both be valid)
static inline bool check_reg_wide(DxVerifyContext *vctx, uint32_t reg) {
    return (reg + 1) < vctx->registers_size;
}

// ---- Opcode classification helpers ----

static bool is_return_or_throw(uint8_t op) {
    return op == 0x0E  // return-void
        || op == 0x0F  // return
        || op == 0x10  // return-wide
        || op == 0x11  // return-object
        || op == 0x27; // throw
}

static bool is_unconditional_branch(uint8_t op) {
    return op == 0x28  // goto
        || op == 0x29  // goto/16
        || op == 0x2A; // goto/32
}

static bool is_switch(uint8_t op) {
    return op == 0x2B  // packed-switch
        || op == 0x2C; // sparse-switch
}

// ---- Pass 1: Build instruction boundary bitmap ----

static DxResult verify_build_bitmap(DxVerifyContext *vctx) {
    uint32_t pc = 0;
    while (pc < vctx->code_size) {
        bitmap_set(vctx->insn_bitmap, pc);

        uint16_t inst = vctx->code[pc];
        uint8_t opcode = inst & 0xFF;
        uint32_t width = dx_opcode_width(opcode);

        // Handle pseudo-opcodes (payloads) embedded in the code stream:
        // 0x0100 = packed-switch-payload, 0x0200 = sparse-switch-payload, 0x0300 = fill-array-data
        if (opcode == 0x00 && inst != 0x0000) {
            uint16_t pseudo_id = inst;
            if (pseudo_id == 0x0100) {
                // packed-switch-payload: size at code[pc+1], total = 4 + size*2 units
                if (pc + 1 >= vctx->code_size) {
                    return verify_fail(vctx, "packed-switch payload truncated at pc=%u", pc);
                }
                uint16_t size = vctx->code[pc + 1];
                width = 4 + (uint32_t)size * 2;
            } else if (pseudo_id == 0x0200) {
                // sparse-switch-payload: size at code[pc+1], total = 2 + size*4 units
                if (pc + 1 >= vctx->code_size) {
                    return verify_fail(vctx, "sparse-switch payload truncated at pc=%u", pc);
                }
                uint16_t size = vctx->code[pc + 1];
                width = 2 + (uint32_t)size * 4;
            } else if (pseudo_id == 0x0300) {
                // fill-array-data-payload: element_width at code[pc+1], count at code[pc+2..3]
                if (pc + 3 >= vctx->code_size) {
                    return verify_fail(vctx, "fill-array-data payload truncated at pc=%u", pc);
                }
                uint16_t element_width = vctx->code[pc + 1];
                uint32_t count = vctx->code[pc + 2] | ((uint32_t)vctx->code[pc + 3] << 16);
                uint32_t data_bytes = (uint32_t)element_width * count;
                // Total size in 16-bit units: header (4 units) + ceil(data_bytes / 2)
                width = 4 + (data_bytes + 1) / 2;
            }
        }

        if (width == 0) width = 1; // safety
        if (pc + width > vctx->code_size) {
            return verify_fail(vctx, "instruction at pc=%u (op=0x%02x, width=%u) overflows code_size=%u",
                               pc, inst & 0xFF, width, vctx->code_size);
        }
        pc += width;
    }
    return DX_OK;
}

// ---- Pass 2: Verify each instruction ----

static DxResult verify_branch_target(DxVerifyContext *vctx, uint32_t pc, int32_t offset) {
    int64_t target64 = (int64_t)pc + offset;
    if (target64 < 0 || target64 >= vctx->code_size) {
        return verify_fail(vctx, "branch at pc=%u targets %lld, out of [0, %u)",
                           pc, (long long)target64, vctx->code_size);
    }
    uint32_t target = (uint32_t)target64;
    if (!bitmap_test(vctx->insn_bitmap, target)) {
        // Target lands in the middle of a wide instruction (e.g., const-wide, goto/32,
        // invoke, or a payload). This would cause the interpreter to decode garbage.
        return verify_fail(vctx, "branch at pc=%u targets pc=%u which is not an instruction "
                           "boundary (lands inside a wide/multi-unit instruction)",
                           pc, target);
    }
    return DX_OK;
}

static DxResult verify_register(DxVerifyContext *vctx, uint32_t pc, uint32_t reg) {
    if (reg >= vctx->registers_size) {
        return verify_fail(vctx, "register v%u at pc=%u exceeds registers_size=%u",
                           reg, pc, vctx->registers_size);
    }
    return DX_OK;
}

static DxResult verify_register_wide(DxVerifyContext *vctx, uint32_t pc, uint32_t reg) {
    if (reg + 1 >= vctx->registers_size) {
        return verify_fail(vctx, "wide register v%u at pc=%u exceeds registers_size=%u",
                           reg, pc, vctx->registers_size);
    }
    return DX_OK;
}

// Verify registers encoded in different instruction formats
static DxResult verify_regs_for_insn(DxVerifyContext *vctx, uint32_t pc) {
    uint16_t inst = vctx->code[pc];
    uint8_t op = inst & 0xFF;

    // Format 12x / 11n: vA = bits[11:8], vB = bits[15:12]
    // Format 11x: vAA = bits[15:8]
    // Format 22x: vAA = bits[15:8], vBBBB = code[pc+1]
    // Format 23x: vAA = bits[15:8], vBB = code[pc+1] & 0xFF, vCC = code[pc+1] >> 8
    // etc.

    #define REG_A4  ((inst >> 8) & 0xF)
    #define REG_B4  ((inst >> 12) & 0xF)
    #define REG_AA  ((inst >> 8) & 0xFF)
    #define REG_BB  (vctx->code[pc+1] & 0xFF)
    #define REG_CC  (vctx->code[pc+1] >> 8)
    #define IDX_BBBB (vctx->code[pc+1])

    switch (op) {
        // 12x: move vA, vB
        case 0x01: // move
        case 0x04: // move-wide
        case 0x07: // move-object
            if (verify_register(vctx, pc, REG_A4) != DX_OK) return DX_ERR_VERIFICATION_FAILED;
            if (verify_register(vctx, pc, REG_B4) != DX_OK) return DX_ERR_VERIFICATION_FAILED;
            if (op == 0x04) { // wide: check pairs
                if (verify_register_wide(vctx, pc, REG_A4) != DX_OK) return DX_ERR_VERIFICATION_FAILED;
                if (verify_register_wide(vctx, pc, REG_B4) != DX_OK) return DX_ERR_VERIFICATION_FAILED;
            }
            break;

        // 22x: move/from16 vAA, vBBBB
        case 0x02: // move/from16
        case 0x05: // move-wide/from16
        case 0x08: // move-object/from16
            if (verify_register(vctx, pc, REG_AA) != DX_OK) return DX_ERR_VERIFICATION_FAILED;
            if (verify_register(vctx, pc, IDX_BBBB) != DX_OK) return DX_ERR_VERIFICATION_FAILED;
            break;

        // 32x: move/16 vAAAA, vBBBB
        case 0x03: case 0x06: case 0x09:
            if (verify_register(vctx, pc, vctx->code[pc+1]) != DX_OK) return DX_ERR_VERIFICATION_FAILED;
            if (verify_register(vctx, pc, vctx->code[pc+2]) != DX_OK) return DX_ERR_VERIFICATION_FAILED;
            break;

        // 11x: move-result, move-exception, return, throw, monitor
        case 0x0A: case 0x0B: case 0x0C: case 0x0D:
        case 0x0F: case 0x10: case 0x11:
        case 0x1D: case 0x1E: case 0x27:
            if (verify_register(vctx, pc, REG_AA) != DX_OK) return DX_ERR_VERIFICATION_FAILED;
            if (op == 0x0B || op == 0x10) { // wide
                if (verify_register_wide(vctx, pc, REG_AA) != DX_OK) return DX_ERR_VERIFICATION_FAILED;
            }
            break;

        // 11n: const/4 vA, #+B
        case 0x12:
            if (verify_register(vctx, pc, REG_A4) != DX_OK) return DX_ERR_VERIFICATION_FAILED;
            break;

        // 21s/21h/21c: const/16, const/high16, const-wide/16, const-wide/high16,
        //              const-string, const-class, check-cast, new-instance, sget/sput
        case 0x13: case 0x15: case 0x16: case 0x19:
            if (verify_register(vctx, pc, REG_AA) != DX_OK) return DX_ERR_VERIFICATION_FAILED;
            break;

        // 31i/51l: const, const-wide/32, const-wide
        case 0x14: case 0x17: case 0x18:
            if (verify_register(vctx, pc, REG_AA) != DX_OK) return DX_ERR_VERIFICATION_FAILED;
            break;

        // 21c: const-string
        case 0x1A: {
            if (verify_register(vctx, pc, REG_AA) != DX_OK) return DX_ERR_VERIFICATION_FAILED;
            uint16_t str_idx = IDX_BBBB;
            if (vctx->dex && str_idx >= vctx->dex->string_count) {
                return verify_fail(vctx, "const-string at pc=%u: string index %u >= %u",
                                   pc, str_idx, vctx->dex->string_count);
            }
            break;
        }

        // 31c: const-string/jumbo
        case 0x1B: {
            if (verify_register(vctx, pc, REG_AA) != DX_OK) return DX_ERR_VERIFICATION_FAILED;
            uint32_t str_idx = vctx->code[pc+1] | ((uint32_t)vctx->code[pc+2] << 16);
            if (vctx->dex && str_idx >= vctx->dex->string_count) {
                return verify_fail(vctx, "const-string/jumbo at pc=%u: string index %u >= %u",
                                   pc, str_idx, vctx->dex->string_count);
            }
            break;
        }

        // 21c: const-class, check-cast, new-instance
        case 0x1C: case 0x1F: case 0x22: {
            if (verify_register(vctx, pc, REG_AA) != DX_OK) return DX_ERR_VERIFICATION_FAILED;
            uint16_t type_idx = IDX_BBBB;
            if (vctx->dex && type_idx >= vctx->dex->type_count) {
                return verify_fail(vctx, "type reference at pc=%u: type index %u >= %u",
                                   pc, type_idx, vctx->dex->type_count);
            }
            break;
        }

        // 22c: instance-of vA, vB, type@CCCC
        case 0x20: {
            if (verify_register(vctx, pc, REG_A4) != DX_OK) return DX_ERR_VERIFICATION_FAILED;
            if (verify_register(vctx, pc, REG_B4) != DX_OK) return DX_ERR_VERIFICATION_FAILED;
            uint16_t type_idx = IDX_BBBB;
            if (vctx->dex && type_idx >= vctx->dex->type_count) {
                return verify_fail(vctx, "instance-of at pc=%u: type index %u >= %u",
                                   pc, type_idx, vctx->dex->type_count);
            }
            break;
        }

        // 12x: array-length vA, vB
        case 0x21:
            if (verify_register(vctx, pc, REG_A4) != DX_OK) return DX_ERR_VERIFICATION_FAILED;
            if (verify_register(vctx, pc, REG_B4) != DX_OK) return DX_ERR_VERIFICATION_FAILED;
            break;

        // 22c: new-array vA, vB, type@CCCC
        case 0x23: {
            if (verify_register(vctx, pc, REG_A4) != DX_OK) return DX_ERR_VERIFICATION_FAILED;
            if (verify_register(vctx, pc, REG_B4) != DX_OK) return DX_ERR_VERIFICATION_FAILED;
            uint16_t type_idx = IDX_BBBB;
            if (vctx->dex && type_idx >= vctx->dex->type_count) {
                return verify_fail(vctx, "new-array at pc=%u: type index %u >= %u",
                                   pc, type_idx, vctx->dex->type_count);
            }
            break;
        }

        // 35c: filled-new-array
        case 0x24: {
            uint16_t ref_idx = IDX_BBBB;
            if (vctx->dex && ref_idx >= vctx->dex->type_count) {
                return verify_fail(vctx, "filled-new-array at pc=%u: type index %u >= %u",
                                   pc, ref_idx, vctx->dex->type_count);
            }
            // Register validation for 35c is complex (encoded in inst and code[pc+2]),
            // skip detailed reg checks — the interpreter will handle bounds at runtime
            break;
        }

        // 3rc: filled-new-array/range
        case 0x25: {
            uint16_t ref_idx = IDX_BBBB;
            if (vctx->dex && ref_idx >= vctx->dex->type_count) {
                return verify_fail(vctx, "filled-new-array/range at pc=%u: type index %u >= %u",
                                   pc, ref_idx, vctx->dex->type_count);
            }
            break;
        }

        // 31t: fill-array-data
        case 0x26: {
            if (verify_register(vctx, pc, REG_AA) != DX_OK) return DX_ERR_VERIFICATION_FAILED;
            int32_t offset = (int32_t)(vctx->code[pc+1] | ((uint32_t)vctx->code[pc+2] << 16));
            int64_t target64 = (int64_t)pc + offset;
            if (target64 < 0 || target64 >= vctx->code_size) {
                return verify_fail(vctx, "fill-array-data at pc=%u: payload offset %d -> %lld out of bounds",
                                   pc, offset, (long long)target64);
            }
            uint32_t target = (uint32_t)target64;
            // Validate payload header
            if (target + 3 < vctx->code_size) {
                uint16_t payload_ident = vctx->code[target];
                if (payload_ident != 0x0300) {
                    return verify_fail(vctx, "fill-array-data at pc=%u: payload at %u has bad ident 0x%04x (expected 0x0300)",
                                       pc, target, payload_ident);
                }
            }
            break;
        }

        // 10t: goto +AA (signed byte)
        case 0x28: {
            int8_t offset = (int8_t)(REG_AA);
            if (verify_branch_target(vctx, pc, offset) != DX_OK) return DX_ERR_VERIFICATION_FAILED;
            break;
        }

        // 20t: goto/16
        case 0x29: {
            int16_t offset = (int16_t)IDX_BBBB;
            if (verify_branch_target(vctx, pc, offset) != DX_OK) return DX_ERR_VERIFICATION_FAILED;
            break;
        }

        // 30t: goto/32
        case 0x2A: {
            int32_t offset = (int32_t)(vctx->code[pc+1] | ((uint32_t)vctx->code[pc+2] << 16));
            if (verify_branch_target(vctx, pc, offset) != DX_OK) return DX_ERR_VERIFICATION_FAILED;
            break;
        }

        // 31t: packed-switch, sparse-switch
        case 0x2B: case 0x2C: {
            if (verify_register(vctx, pc, REG_AA) != DX_OK) return DX_ERR_VERIFICATION_FAILED;
            int32_t offset = (int32_t)(vctx->code[pc+1] | ((uint32_t)vctx->code[pc+2] << 16));
            int64_t target64 = (int64_t)pc + offset;
            if (target64 < 0 || target64 >= vctx->code_size) {
                return verify_fail(vctx, "%s at pc=%u: payload offset -> %lld out of bounds",
                                   op == 0x2B ? "packed-switch" : "sparse-switch",
                                   pc, (long long)target64);
            }
            uint32_t target = (uint32_t)target64;
            // Validate payload ident
            uint16_t expected_ident = (op == 0x2B) ? 0x0100 : 0x0200;
            if (target < vctx->code_size) {
                uint16_t payload_ident = vctx->code[target];
                if (payload_ident != expected_ident) {
                    return verify_fail(vctx, "%s at pc=%u: payload at %u has bad ident 0x%04x",
                                       op == 0x2B ? "packed-switch" : "sparse-switch",
                                       pc, target, payload_ident);
                }
                // Validate payload size fits in code
                if (target + 1 < vctx->code_size) {
                    uint16_t size = vctx->code[target + 1];
                    uint32_t payload_size;
                    if (op == 0x2B) {
                        payload_size = 4 + (uint32_t)size * 2; // packed-switch
                    } else {
                        payload_size = 2 + (uint32_t)size * 4; // sparse-switch
                    }
                    if (target + payload_size > vctx->code_size) {
                        return verify_fail(vctx, "%s at pc=%u: payload at %u (size=%u units) overflows code",
                                           op == 0x2B ? "packed-switch" : "sparse-switch",
                                           pc, target, payload_size);
                    }
                    // Validate each switch target is a valid branch on an instruction boundary
                    if (op == 0x2B) {
                        // packed-switch targets start at target+4
                        for (uint16_t i = 0; i < size; i++) {
                            uint32_t toff = target + 4 + (uint32_t)i * 2;
                            if (toff + 1 < vctx->code_size) {
                                int32_t case_offset = (int32_t)(vctx->code[toff] | ((uint32_t)vctx->code[toff+1] << 16));
                                int64_t case_target = (int64_t)pc + case_offset;
                                if (case_target < 0 || case_target >= vctx->code_size) {
                                    return verify_fail(vctx, "packed-switch at pc=%u: case %u target %lld out of bounds",
                                                       pc, i, (long long)case_target);
                                }
                                uint32_t ct = (uint32_t)case_target;
                                if (!bitmap_test(vctx->insn_bitmap, ct)) {
                                    return verify_fail(vctx, "packed-switch at pc=%u: case %u target pc=%u "
                                                       "is not an instruction boundary (lands inside wide instruction)",
                                                       pc, i, ct);
                                }
                            }
                        }
                    } else {
                        // sparse-switch targets: keys at target+2, targets at target+2+size*2
                        uint32_t targets_base = target + 2 + (uint32_t)size * 2;
                        for (uint16_t i = 0; i < size; i++) {
                            uint32_t toff = targets_base + (uint32_t)i * 2;
                            if (toff + 1 < vctx->code_size) {
                                int32_t case_offset = (int32_t)(vctx->code[toff] | ((uint32_t)vctx->code[toff+1] << 16));
                                int64_t case_target = (int64_t)pc + case_offset;
                                if (case_target < 0 || case_target >= vctx->code_size) {
                                    return verify_fail(vctx, "sparse-switch at pc=%u: case %u target %lld out of bounds",
                                                       pc, i, (long long)case_target);
                                }
                                uint32_t ct = (uint32_t)case_target;
                                if (!bitmap_test(vctx->insn_bitmap, ct)) {
                                    return verify_fail(vctx, "sparse-switch at pc=%u: case %u target pc=%u "
                                                       "is not an instruction boundary (lands inside wide instruction)",
                                                       pc, i, ct);
                                }
                            }
                        }
                    }
                }
            }
            break;
        }

        // 23x: cmp-kind vAA, vBB, vCC (0x2D..0x31)
        case 0x2D: case 0x2E: case 0x2F: case 0x30: case 0x31:
            if (verify_register(vctx, pc, REG_AA) != DX_OK) return DX_ERR_VERIFICATION_FAILED;
            if (verify_register(vctx, pc, REG_BB) != DX_OK) return DX_ERR_VERIFICATION_FAILED;
            if (verify_register(vctx, pc, REG_CC) != DX_OK) return DX_ERR_VERIFICATION_FAILED;
            break;

        // 22t: if-test vA, vB, +CCCC (0x32..0x37)
        case 0x32: case 0x33: case 0x34: case 0x35: case 0x36: case 0x37: {
            if (verify_register(vctx, pc, REG_A4) != DX_OK) return DX_ERR_VERIFICATION_FAILED;
            if (verify_register(vctx, pc, REG_B4) != DX_OK) return DX_ERR_VERIFICATION_FAILED;
            int16_t offset = (int16_t)IDX_BBBB;
            if (verify_branch_target(vctx, pc, offset) != DX_OK) return DX_ERR_VERIFICATION_FAILED;
            break;
        }

        // 21t: if-testz vAA, +BBBB (0x38..0x3D)
        case 0x38: case 0x39: case 0x3A: case 0x3B: case 0x3C: case 0x3D: {
            if (verify_register(vctx, pc, REG_AA) != DX_OK) return DX_ERR_VERIFICATION_FAILED;
            int16_t offset = (int16_t)IDX_BBBB;
            if (verify_branch_target(vctx, pc, offset) != DX_OK) return DX_ERR_VERIFICATION_FAILED;
            break;
        }

        // 23x: aget/aput variants (0x44..0x51)
        case 0x44: case 0x45: case 0x46: case 0x47: case 0x48: case 0x49: case 0x4A:
        case 0x4B: case 0x4C: case 0x4D: case 0x4E: case 0x4F: case 0x50: case 0x51:
            if (verify_register(vctx, pc, REG_AA) != DX_OK) return DX_ERR_VERIFICATION_FAILED;
            if (verify_register(vctx, pc, REG_BB) != DX_OK) return DX_ERR_VERIFICATION_FAILED;
            if (verify_register(vctx, pc, REG_CC) != DX_OK) return DX_ERR_VERIFICATION_FAILED;
            break;

        // 22c: iget/iput variants (0x52..0x5F) — vA, vB, field@CCCC
        case 0x52: case 0x53: case 0x54: case 0x55: case 0x56: case 0x57: case 0x58:
        case 0x59: case 0x5A: case 0x5B: case 0x5C: case 0x5D: case 0x5E: case 0x5F: {
            if (verify_register(vctx, pc, REG_A4) != DX_OK) return DX_ERR_VERIFICATION_FAILED;
            if (verify_register(vctx, pc, REG_B4) != DX_OK) return DX_ERR_VERIFICATION_FAILED;
            uint16_t field_idx = IDX_BBBB;
            if (vctx->dex && field_idx >= vctx->dex->field_count) {
                return verify_fail(vctx, "iget/iput at pc=%u: field index %u >= %u",
                                   pc, field_idx, vctx->dex->field_count);
            }
            break;
        }

        // 21c: sget/sput variants (0x60..0x6D) — vAA, field@BBBB
        case 0x60: case 0x61: case 0x62: case 0x63: case 0x64: case 0x65: case 0x66:
        case 0x67: case 0x68: case 0x69: case 0x6A: case 0x6B: case 0x6C: case 0x6D: {
            if (verify_register(vctx, pc, REG_AA) != DX_OK) return DX_ERR_VERIFICATION_FAILED;
            uint16_t field_idx = IDX_BBBB;
            if (vctx->dex && field_idx >= vctx->dex->field_count) {
                return verify_fail(vctx, "sget/sput at pc=%u: field index %u >= %u",
                                   pc, field_idx, vctx->dex->field_count);
            }
            break;
        }

        // 35c: invoke-kind (0x6E..0x72) — method@BBBB
        case 0x6E: case 0x6F: case 0x70: case 0x71: case 0x72: {
            uint16_t method_idx = IDX_BBBB;
            if (vctx->dex && method_idx >= vctx->dex->method_count) {
                return verify_fail(vctx, "invoke at pc=%u: method index %u >= %u",
                                   pc, method_idx, vctx->dex->method_count);
            }
            break;
        }

        // 3rc: invoke-kind/range (0x74..0x78) — method@BBBB
        case 0x74: case 0x75: case 0x76: case 0x77: case 0x78: {
            uint16_t method_idx = IDX_BBBB;
            if (vctx->dex && method_idx >= vctx->dex->method_count) {
                return verify_fail(vctx, "invoke/range at pc=%u: method index %u >= %u",
                                   pc, method_idx, vctx->dex->method_count);
            }
            // Check range register bounds
            uint8_t arg_count_val = (inst >> 8) & 0xFF;
            uint16_t first_reg = vctx->code[pc + 2];
            if (arg_count_val > 0 && (first_reg + arg_count_val) > vctx->registers_size) {
                return verify_fail(vctx, "invoke/range at pc=%u: registers v%u..v%u exceed registers_size=%u",
                                   pc, first_reg, first_reg + arg_count_val - 1, vctx->registers_size);
            }
            break;
        }

        // 12x: unop (0x7B..0x8F)
        case 0x7B: case 0x7C: case 0x7D: case 0x7E: case 0x7F:
        case 0x80: case 0x81: case 0x82: case 0x83: case 0x84:
        case 0x85: case 0x86: case 0x87: case 0x88: case 0x89:
        case 0x8A: case 0x8B: case 0x8C: case 0x8D: case 0x8E: case 0x8F:
            if (verify_register(vctx, pc, REG_A4) != DX_OK) return DX_ERR_VERIFICATION_FAILED;
            if (verify_register(vctx, pc, REG_B4) != DX_OK) return DX_ERR_VERIFICATION_FAILED;
            break;

        // 23x: binop vAA, vBB, vCC (0x90..0xAF)
        case 0x90: case 0x91: case 0x92: case 0x93: case 0x94: case 0x95:
        case 0x96: case 0x97: case 0x98: case 0x99: case 0x9A: case 0x9B:
        case 0x9C: case 0x9D: case 0x9E: case 0x9F: case 0xA0: case 0xA1:
        case 0xA2: case 0xA3: case 0xA4: case 0xA5: case 0xA6: case 0xA7:
        case 0xA8: case 0xA9: case 0xAA: case 0xAB: case 0xAC: case 0xAD:
        case 0xAE: case 0xAF:
            if (verify_register(vctx, pc, REG_AA) != DX_OK) return DX_ERR_VERIFICATION_FAILED;
            if (verify_register(vctx, pc, REG_BB) != DX_OK) return DX_ERR_VERIFICATION_FAILED;
            if (verify_register(vctx, pc, REG_CC) != DX_OK) return DX_ERR_VERIFICATION_FAILED;
            break;

        // 12x: binop/2addr vA, vB (0xB0..0xCF)
        case 0xB0: case 0xB1: case 0xB2: case 0xB3: case 0xB4: case 0xB5:
        case 0xB6: case 0xB7: case 0xB8: case 0xB9: case 0xBA: case 0xBB:
        case 0xBC: case 0xBD: case 0xBE: case 0xBF: case 0xC0: case 0xC1:
        case 0xC2: case 0xC3: case 0xC4: case 0xC5: case 0xC6: case 0xC7:
        case 0xC8: case 0xC9: case 0xCA: case 0xCB: case 0xCC: case 0xCD:
        case 0xCE: case 0xCF:
            if (verify_register(vctx, pc, REG_A4) != DX_OK) return DX_ERR_VERIFICATION_FAILED;
            if (verify_register(vctx, pc, REG_B4) != DX_OK) return DX_ERR_VERIFICATION_FAILED;
            break;

        // 22s: binop/lit16 vA, vB, #+CCCC (0xD0..0xD7)
        case 0xD0: case 0xD1: case 0xD2: case 0xD3:
        case 0xD4: case 0xD5: case 0xD6: case 0xD7:
            if (verify_register(vctx, pc, REG_A4) != DX_OK) return DX_ERR_VERIFICATION_FAILED;
            if (verify_register(vctx, pc, REG_B4) != DX_OK) return DX_ERR_VERIFICATION_FAILED;
            break;

        // 22b: binop/lit8 vAA, vBB, #+CC (0xD8..0xE2)
        case 0xD8: case 0xD9: case 0xDA: case 0xDB: case 0xDC:
        case 0xDD: case 0xDE: case 0xDF: case 0xE0: case 0xE1: case 0xE2:
            if (verify_register(vctx, pc, REG_AA) != DX_OK) return DX_ERR_VERIFICATION_FAILED;
            if (verify_register(vctx, pc, REG_BB) != DX_OK) return DX_ERR_VERIFICATION_FAILED;
            break;

        // 35c/3rc: invoke-custom (0xFC, 0xFD)
        case 0xFC: case 0xFD:
            // call_site index validation would need call_site_count
            break;

        // 21c: const-method-handle, const-method-type (0xFE, 0xFF)
        case 0xFE: case 0xFF:
            if (verify_register(vctx, pc, REG_AA) != DX_OK) return DX_ERR_VERIFICATION_FAILED;
            break;

        // return-void (no registers), nop
        case 0x0E: case 0x00:
            break;

        default:
            // Unknown/unused opcodes: skip silently, interpreter handles them
            break;
    }

    #undef REG_A4
    #undef REG_B4
    #undef REG_AA
    #undef REG_BB
    #undef REG_CC
    #undef IDX_BBBB

    return DX_OK;
}

static DxResult verify_instructions(DxVerifyContext *vctx) {
    uint32_t pc = 0;
    uint32_t last_insn_pc = 0;
    uint8_t last_opcode = 0;
    bool has_insn = false;

    while (pc < vctx->code_size) {
        uint16_t inst = vctx->code[pc];
        uint8_t opcode = inst & 0xFF;
        uint32_t width = dx_opcode_width(opcode);

        // Handle pseudo-opcodes (payloads)
        if (opcode == 0x00 && inst != 0x0000) {
            uint16_t pseudo_id = inst;
            if (pseudo_id == 0x0100) {
                if (pc + 1 >= vctx->code_size) {
                    return verify_fail(vctx, "packed-switch payload truncated at pc=%u", pc);
                }
                uint16_t size = vctx->code[pc + 1];
                width = 4 + (uint32_t)size * 2;
            } else if (pseudo_id == 0x0200) {
                if (pc + 1 >= vctx->code_size) {
                    return verify_fail(vctx, "sparse-switch payload truncated at pc=%u", pc);
                }
                uint16_t size = vctx->code[pc + 1];
                width = 2 + (uint32_t)size * 4;
            } else if (pseudo_id == 0x0300) {
                if (pc + 3 >= vctx->code_size) {
                    return verify_fail(vctx, "fill-array-data payload truncated at pc=%u", pc);
                }
                uint16_t element_width = vctx->code[pc + 1];
                uint32_t count = vctx->code[pc + 2] | ((uint32_t)vctx->code[pc + 3] << 16);
                uint32_t data_bytes = (uint32_t)element_width * count;
                width = 4 + (data_bytes + 1) / 2;
            }
            // Skip payloads — they're data, not instructions to verify
            if (width == 0) width = 1;
            pc += width;
            continue;
        }

        // Verify register and index bounds for this instruction
        DxResult res = verify_regs_for_insn(vctx, pc);
        if (res != DX_OK) return res;

        has_insn = true;
        last_insn_pc = pc;
        last_opcode = opcode;

        if (width == 0) width = 1;
        pc += width;
    }

    // Check 7: Code flow off-end detection
    // The last real instruction must be a return, throw, or unconditional branch
    if (has_insn && !is_return_or_throw(last_opcode) && !is_unconditional_branch(last_opcode)
        && !is_switch(last_opcode)) {
        // This is a warning rather than a hard fail — some compilers produce code
        // where the last instruction is a goto target that happens to be a branch.
        // Also, methods may end with switch payloads after the last real instruction.
        // Be lenient: only fail if the last instruction clearly falls through.
        DX_WARN(VERIFY_TAG, "%s: last instruction at pc=%u (op=0x%02x) may fall off end of code",
                vctx->method_name ? vctx->method_name : "?", last_insn_pc, last_opcode);
    }

    return DX_OK;
}

// ---- Public API ----

DxResult dx_verify_method(DxDexFile *dex, DxMethod *method) {
    if (!method) return DX_ERR_NULL_PTR;
    if (!method->has_code) return DX_OK;  // abstract/native — nothing to verify
    if (method->verified) return DX_OK;   // already verified

    const uint16_t *code = method->code.insns;
    uint32_t code_size = method->code.insns_size;
    uint16_t registers_size = method->code.registers_size;

    if (!code || code_size == 0) {
        method->verified = true;
        return DX_OK;
    }

    // Build method name for diagnostics
    char method_name[256];
    snprintf(method_name, sizeof(method_name), "%s.%s",
             method->declaring_class ? method->declaring_class->descriptor : "?",
             method->name ? method->name : "?");

    // Allocate bitmap
    uint32_t bitmap_bytes = (code_size + 7) / 8;
    uint8_t *bitmap = (uint8_t *)calloc(1, bitmap_bytes);
    if (!bitmap) return DX_ERR_OUT_OF_MEMORY;

    DxVerifyContext vctx;
    memset(&vctx, 0, sizeof(vctx));
    vctx.code = code;
    vctx.code_size = code_size;
    vctx.registers_size = registers_size;
    vctx.dex = dex;
    vctx.method_name = method_name;
    vctx.insn_bitmap = bitmap;

    // Pass 1: Build instruction boundary bitmap
    DxResult res = verify_build_bitmap(&vctx);
    if (res != DX_OK) {
        free(bitmap);
        return res;
    }

    // Pass 2: Verify each instruction
    res = verify_instructions(&vctx);
    free(bitmap);

    if (res == DX_OK) {
        method->verified = true;
    }

    return res;
}
