#include <unicorn/unicorn.h>
#include <stdio.h>
#include <stdint.h>

/* MOV X0, #42; ADD X0, X0, #1. Guest instructions must run without host JIT. */
int main(void) {
    const unsigned char code[] = {0x40, 0x05, 0x80, 0xd2, 0x00, 0x04, 0x00, 0x91};
    uc_engine *engine = NULL;
    uc_err error = uc_open(UC_ARCH_ARM64, UC_MODE_ARM, &engine);
    if (error == UC_ERR_OK) error = uc_mem_map(engine, 0x1000, 0x1000, UC_PROT_ALL);
    if (error == UC_ERR_OK) error = uc_mem_write(engine, 0x1000, code, sizeof(code));
    if (error == UC_ERR_OK) error = uc_emu_start(engine, 0x1000, 0x1000 + sizeof(code), 1000000, 2);
    uint64_t result = 0;
    if (error == UC_ERR_OK) error = uc_reg_read(engine, UC_ARM64_REG_X0, &result);
    if (engine) uc_close(engine);
    if (error != UC_ERR_OK || result != 43) {
        fprintf(stderr, "ARM64 interpreter failed: %s, result=%llu\n", uc_strerror(error), (unsigned long long)result);
        return 1;
    }
    puts("ARM64 interpreter executed guest code: 43");
    return 0;
}
