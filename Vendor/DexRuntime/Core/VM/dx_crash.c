#include "../Include/dx_vm.h"
#include "../Include/dx_log.h"
#include <signal.h>
#include <setjmp.h>
#include <string.h>
#include <stdbool.h>
#include <stdio.h>

#define TAG "Crash"

// Thread-local crash recovery state
// (DexLoom is single-threaded for interpreter execution, so static is fine)
static sigjmp_buf s_crash_jmp;
static volatile bool s_handlers_installed = false;
static volatile int s_crash_signal = 0;
static struct sigaction s_old_sigsegv;
static struct sigaction s_old_sigbus;

// The VM pointer for diagnostic capture on crash
static DxVM *s_crash_vm = NULL;

static void crash_signal_handler(int sig) {
    s_crash_signal = sig;

    // Capture diagnostic info if VM is available
    if (s_crash_vm) {
        snprintf(s_crash_vm->error_msg, sizeof(s_crash_vm->error_msg),
                 "Signal %d (%s) caught during bytecode execution",
                 sig, sig == SIGSEGV ? "SIGSEGV" : sig == SIGBUS ? "SIGBUS" : "unknown");

        // Mark diagnostic error
        s_crash_vm->diag.has_error = true;
        if (s_crash_vm->current_frame && s_crash_vm->current_frame->method) {
            DxMethod *m = s_crash_vm->current_frame->method;
            snprintf(s_crash_vm->diag.method_name, sizeof(s_crash_vm->diag.method_name),
                     "%s.%s",
                     m->declaring_class ? m->declaring_class->descriptor : "?",
                     m->name ? m->name : "?");
            s_crash_vm->diag.pc = s_crash_vm->current_frame->pc;
        }
    }

    // Jump back to the recovery point
    siglongjmp(s_crash_jmp, sig);
}

void dx_crash_install_handlers(DxVM *vm) {
    if (s_handlers_installed) return;

    s_crash_vm = vm;
    s_crash_signal = 0;

    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = crash_signal_handler;
    sigemptyset(&sa.sa_mask);
    sa.sa_flags = 0;  // No SA_RESTART so longjmp works cleanly

    sigaction(SIGSEGV, &sa, &s_old_sigsegv);
    sigaction(SIGBUS, &sa, &s_old_sigbus);

    s_handlers_installed = true;
    DX_DEBUG(TAG, "Crash isolation handlers installed");
}

void dx_crash_uninstall_handlers(void) {
    if (!s_handlers_installed) return;

    sigaction(SIGSEGV, &s_old_sigsegv, NULL);
    sigaction(SIGBUS, &s_old_sigbus, NULL);

    s_handlers_installed = false;
    s_crash_vm = NULL;
    s_crash_signal = 0;
    DX_DEBUG(TAG, "Crash isolation handlers removed");
}

int dx_crash_get_signal(void) {
    return s_crash_signal;
}

sigjmp_buf *dx_crash_get_jmpbuf(void) {
    return &s_crash_jmp;
}
