#ifndef DX_FUZZ_H
#define DX_FUZZ_H

#include <stdint.h>
#include <stddef.h>

// Fuzzing entry points designed for libFuzzer (LLVMFuzzerTestOneInput signature)
// but callable standalone. Each returns 0 on success, never crashes.

int dx_fuzz_apk(const uint8_t *data, size_t size);
int dx_fuzz_dex(const uint8_t *data, size_t size);
int dx_fuzz_axml(const uint8_t *data, size_t size);
int dx_fuzz_resources(const uint8_t *data, size_t size);

#endif // DX_FUZZ_H
