#include "../Include/dx_runtime.h"

// Dalvik opcode names for tracing
static const char *opcode_names[256] = {
    [0x00] = "nop",
    [0x01] = "move",
    [0x02] = "move/from16",
    [0x03] = "move/16",
    [0x04] = "move-wide",
    [0x05] = "move-wide/from16",
    [0x06] = "move-wide/16",
    [0x07] = "move-object",
    [0x08] = "move-object/from16",
    [0x09] = "move-object/16",
    [0x0A] = "move-result",
    [0x0B] = "move-result-wide",
    [0x0C] = "move-result-object",
    [0x0D] = "move-exception",
    [0x0E] = "return-void",
    [0x0F] = "return",
    [0x10] = "return-wide",
    [0x11] = "return-object",
    [0x12] = "const/4",
    [0x13] = "const/16",
    [0x14] = "const",
    [0x15] = "const/high16",
    [0x16] = "const-wide/16",
    [0x17] = "const-wide/32",
    [0x18] = "const-wide",
    [0x19] = "const-wide/high16",
    [0x1A] = "const-string",
    [0x1B] = "const-string/jumbo",
    [0x1C] = "const-class",
    [0x1D] = "monitor-enter",
    [0x1E] = "monitor-exit",
    [0x1F] = "check-cast",
    [0x20] = "instance-of",
    [0x21] = "array-length",
    [0x22] = "new-instance",
    [0x23] = "new-array",
    [0x24] = "filled-new-array",
    [0x25] = "filled-new-array/range",
    [0x26] = "fill-array-data",
    [0x27] = "throw",
    [0x28] = "goto",
    [0x29] = "goto/16",
    [0x2A] = "goto/32",
    [0x2B] = "packed-switch",
    [0x2C] = "sparse-switch",
    [0x32] = "if-eq",
    [0x33] = "if-ne",
    [0x34] = "if-lt",
    [0x35] = "if-ge",
    [0x36] = "if-gt",
    [0x37] = "if-le",
    [0x38] = "if-eqz",
    [0x39] = "if-nez",
    [0x3A] = "if-ltz",
    [0x3B] = "if-gez",
    [0x3C] = "if-gtz",
    [0x3D] = "if-lez",
    [0x44] = "aget",
    [0x46] = "aget-object",
    [0x4B] = "aput",
    [0x4D] = "aput-object",
    [0x52] = "iget",
    [0x53] = "iget-wide",
    [0x54] = "iget-object",
    [0x55] = "iget-boolean",
    [0x56] = "iget-byte",
    [0x57] = "iget-char",
    [0x58] = "iget-short",
    [0x59] = "iput",
    [0x5A] = "iput-wide",
    [0x5B] = "iput-object",
    [0x5C] = "iput-boolean",
    [0x5D] = "iput-byte",
    [0x5E] = "iput-char",
    [0x5F] = "iput-short",
    [0x60] = "sget",
    [0x61] = "sget-wide",
    [0x62] = "sget-object",
    [0x63] = "sget-boolean",
    [0x64] = "sget-byte",
    [0x65] = "sget-char",
    [0x66] = "sget-short",
    [0x67] = "sput",
    [0x68] = "sput-wide",
    [0x69] = "sput-object",
    [0x6E] = "invoke-virtual",
    [0x6F] = "invoke-super",
    [0x70] = "invoke-direct",
    [0x71] = "invoke-static",
    [0x72] = "invoke-interface",
    [0x74] = "invoke-virtual/range",
    [0x75] = "invoke-super/range",
    [0x76] = "invoke-direct/range",
    [0x77] = "invoke-static/range",
    [0x78] = "invoke-interface/range",
    [0x90] = "add-int",
    [0x91] = "sub-int",
    [0xB0] = "add-int/2addr",
    [0xB1] = "sub-int/2addr",
    [0xD8] = "add-int/lit8",
    [0xD9] = "rsub-int/lit8",
    [0xFA] = "invoke-polymorphic",
    [0xFB] = "invoke-polymorphic/range",
    [0xFC] = "invoke-custom",
    [0xFD] = "invoke-custom/range",
    [0xFE] = "const-method-handle",
    [0xFF] = "const-method-type",
};

const char *dx_opcode_name(uint8_t opcode) {
    const char *name = opcode_names[opcode];
    return name ? name : "unknown";
}

// Instruction widths in 16-bit code units (from Dalvik spec)
static const uint8_t opcode_widths[256] = {
    [0x00] = 1, // nop (10x)
    [0x01] = 1, // move (12x)
    [0x02] = 2, // move/from16 (22x)
    [0x03] = 3, // move/16 (32x)
    [0x04] = 1, // move-wide (12x)
    [0x05] = 2, // move-wide/from16 (22x)
    [0x06] = 3, // move-wide/16 (32x)
    [0x07] = 1, // move-object (12x)
    [0x08] = 2, // move-object/from16 (22x)
    [0x09] = 3, // move-object/16 (32x)
    [0x0A] = 1, // move-result (11x)
    [0x0B] = 1, // move-result-wide (11x)
    [0x0C] = 1, // move-result-object (11x)
    [0x0D] = 1, // move-exception (11x)
    [0x0E] = 1, // return-void (10x)
    [0x0F] = 1, // return (11x)
    [0x10] = 1, // return-wide (11x)
    [0x11] = 1, // return-object (11x)
    [0x12] = 1, // const/4 (11n)
    [0x13] = 2, // const/16 (21s)
    [0x14] = 3, // const (31i)
    [0x15] = 2, // const/high16 (21h)
    [0x16] = 2, // const-wide/16 (21s)
    [0x17] = 3, // const-wide/32 (31i)
    [0x18] = 5, // const-wide (51l)
    [0x19] = 2, // const-wide/high16 (21h)
    [0x1A] = 2, // const-string (21c)
    [0x1B] = 3, // const-string/jumbo (31c)
    [0x1C] = 2, // const-class (21c)
    [0x1D] = 1, // monitor-enter (11x)
    [0x1E] = 1, // monitor-exit (11x)
    [0x1F] = 2, // check-cast (21c)
    [0x20] = 2, // instance-of (22c)
    [0x21] = 1, // array-length (12x)
    [0x22] = 2, // new-instance (21c)
    [0x23] = 2, // new-array (22c)
    [0x24] = 3, // filled-new-array (35c)
    [0x25] = 3, // filled-new-array/range (3rc)
    [0x26] = 3, // fill-array-data (31t)
    [0x27] = 1, // throw (11x)
    [0x28] = 1, // goto (10t)
    [0x29] = 2, // goto/16 (20t)
    [0x2A] = 3, // goto/32 (30t)
    [0x2B] = 3, // packed-switch (31t)
    [0x2C] = 3, // sparse-switch (31t)
    [0x2D] = 2, [0x2E] = 2, [0x2F] = 2, [0x30] = 2, [0x31] = 2, // cmpkind (23x)
    [0x32] = 2, [0x33] = 2, [0x34] = 2, [0x35] = 2, [0x36] = 2, [0x37] = 2, // if-test (22t)
    [0x38] = 2, [0x39] = 2, [0x3A] = 2, [0x3B] = 2, [0x3C] = 2, [0x3D] = 2, // if-testz (21t)
    [0x44] = 2, [0x45] = 2, [0x46] = 2, [0x47] = 2, [0x48] = 2, [0x49] = 2, [0x4A] = 2, // aget (23x)
    [0x4B] = 2, [0x4C] = 2, [0x4D] = 2, [0x4E] = 2, [0x4F] = 2, [0x50] = 2, [0x51] = 2, // aput (23x)
    [0x52] = 2, [0x53] = 2, [0x54] = 2, [0x55] = 2, [0x56] = 2, [0x57] = 2, [0x58] = 2, // iget (22c)
    [0x59] = 2, [0x5A] = 2, [0x5B] = 2, [0x5C] = 2, [0x5D] = 2, [0x5E] = 2, [0x5F] = 2, // iput (22c)
    [0x60] = 2, [0x61] = 2, [0x62] = 2, [0x63] = 2, [0x64] = 2, [0x65] = 2, [0x66] = 2, // sget (21c)
    [0x67] = 2, [0x68] = 2, [0x69] = 2, [0x6A] = 2, [0x6B] = 2, [0x6C] = 2, [0x6D] = 2, // sput (21c)
    [0x6E] = 3, [0x6F] = 3, [0x70] = 3, [0x71] = 3, [0x72] = 3, // invoke-kind (35c)
    [0x74] = 3, [0x75] = 3, [0x76] = 3, [0x77] = 3, [0x78] = 3, // invoke-kind/range (3rc)
    [0x7B] = 1, [0x7C] = 1, [0x7D] = 1, [0x7E] = 1, [0x7F] = 1, [0x80] = 1, [0x81] = 1, // unop (12x)
    [0x82] = 1, [0x83] = 1, [0x84] = 1, [0x85] = 1, [0x86] = 1, [0x87] = 1, [0x88] = 1,
    [0x89] = 1, [0x8A] = 1, [0x8B] = 1, [0x8C] = 1, [0x8D] = 1, [0x8E] = 1, [0x8F] = 1,
    [0x90] = 2, [0x91] = 2, [0x92] = 2, [0x93] = 2, [0x94] = 2, [0x95] = 2, [0x96] = 2, // binop (23x)
    [0x97] = 2, [0x98] = 2, [0x99] = 2, [0x9A] = 2, [0x9B] = 2, [0x9C] = 2, [0x9D] = 2,
    [0x9E] = 2, [0x9F] = 2, [0xA0] = 2, [0xA1] = 2, [0xA2] = 2, [0xA3] = 2, [0xA4] = 2,
    [0xA5] = 2, [0xA6] = 2, [0xA7] = 2, [0xA8] = 2, [0xA9] = 2, [0xAA] = 2, [0xAB] = 2,
    [0xAC] = 2, [0xAD] = 2, [0xAE] = 2, [0xAF] = 2,
    [0xB0] = 1, [0xB1] = 1, [0xB2] = 1, [0xB3] = 1, [0xB4] = 1, [0xB5] = 1, [0xB6] = 1, // binop/2addr (12x)
    [0xB7] = 1, [0xB8] = 1, [0xB9] = 1, [0xBA] = 1, [0xBB] = 1, [0xBC] = 1, [0xBD] = 1,
    [0xBE] = 1, [0xBF] = 1, [0xC0] = 1, [0xC1] = 1, [0xC2] = 1, [0xC3] = 1, [0xC4] = 1,
    [0xC5] = 1, [0xC6] = 1, [0xC7] = 1, [0xC8] = 1, [0xC9] = 1, [0xCA] = 1, [0xCB] = 1,
    [0xCC] = 1, [0xCD] = 1, [0xCE] = 1, [0xCF] = 1,
    [0xD0] = 2, [0xD1] = 2, [0xD2] = 2, [0xD3] = 2, [0xD4] = 2, [0xD5] = 2, [0xD6] = 2, // binop/lit16 (22s)
    [0xD7] = 2,
    [0xD8] = 2, [0xD9] = 2, [0xDA] = 2, [0xDB] = 2, [0xDC] = 2, [0xDD] = 2, [0xDE] = 2, // binop/lit8 (22b)
    [0xDF] = 2, [0xE0] = 2, [0xE1] = 2, [0xE2] = 2,
    [0xFA] = 4, [0xFB] = 4, // invoke-polymorphic (45cc / 4rcc)
    [0xFC] = 3, [0xFD] = 3, // invoke-custom (35c / 3rc)
    [0xFE] = 2, [0xFF] = 2, // const-method-handle / const-method-type (21c)
};

uint32_t dx_opcode_width(uint8_t opcode) {
    uint8_t w = opcode_widths[opcode];
    return w ? w : 1; // default to 1 for unknown opcodes
}
