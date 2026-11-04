#include <execinfo.h>
#include <signal.h>
#include <unistd.h>

static void quotaCrashTrace(int value) {
    void *frames[100];
    int count = backtrace(frames, 100);
    backtrace_symbols_fd(frames, count, STDERR_FILENO);
    _exit(128 + value);
}

/* Opt-in diagnostics for reproducing failures on the older Mac. */
void QuotaInstallCrashDiagnostics(void) {
    signal(SIGSEGV, quotaCrashTrace);
    signal(SIGABRT, quotaCrashTrace);
}
