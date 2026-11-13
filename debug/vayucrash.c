// vayucrash: LD_PRELOAD crash reporter for the vayu 26.04 debug build.
// On SIGSEGV/SIGBUS/SIGABRT/SIGILL/SIGFPE it writes signal info, registers,
// a backtrace and /proc/self/maps to $HOME/vayu-crash-N.txt (N=1..5, first free),
// then re-raises the signal so systemd still sees the crash.
// Build: aarch64-linux-gnu-gcc -shared -fPIC -O1 -o libvayucrash.so vayucrash.c
#define _GNU_SOURCE
#include <execinfo.h>
#include <fcntl.h>
#include <pthread.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/syscall.h>
#include <ucontext.h>
#include <unistd.h>

static char dir[512] = "/tmp";

static void wr(int fd, const char *s) { (void)!write(fd, s, strlen(s)); }

static void wrhex(int fd, const char *label, unsigned long v) {
    char b[64]; int n = snprintf(b, sizeof b, "%s0x%016lx\n", label, v);
    (void)!write(fd, b, n);
}

static void copyfile(int fd, const char *path) {
    int in = open(path, O_RDONLY); char b[4096]; ssize_t n;
    if (in < 0) return;
    while ((n = read(in, b, sizeof b)) > 0) (void)!write(fd, b, n);
    close(in);
}

static void handler(int sig, siginfo_t *si, void *ctx) {
    char path[600]; int fd = -1;
    for (int i = 1; i <= 5 && fd < 0; i++) {
        snprintf(path, sizeof path, "%s/vayu-crash-%d.txt", dir, i);
        fd = open(path, O_WRONLY | O_CREAT | O_EXCL, 0644);
    }
    if (fd >= 0) {
        char b[256]; char comm[64] = "?"; char cp[64];
        snprintf(cp, sizeof cp, "/proc/self/task/%ld/comm", (long)syscall(SYS_gettid));
        int c = open(cp, O_RDONLY);
        if (c >= 0) { ssize_t n = read(c, comm, sizeof comm - 1); if (n > 0) comm[n - 1] = 0; close(c); }
        int n = snprintf(b, sizeof b, "signal %d (%s) code %d pid %d tid %ld thread '%s'\n",
                         sig, strsignal(sig), si->si_code, getpid(), (long)syscall(SYS_gettid), comm);
        (void)!write(fd, b, n);
        wrhex(fd, "fault addr ", (unsigned long)si->si_addr);
#if defined(__aarch64__)
        ucontext_t *uc = ctx;
        wrhex(fd, "pc ", uc->uc_mcontext.pc);
        wrhex(fd, "lr ", uc->uc_mcontext.regs[30]);
        wrhex(fd, "sp ", uc->uc_mcontext.sp);
        for (int r = 0; r < 30; r++) { snprintf(b, sizeof b, "x%-2d ", r); wrhex(fd, b, uc->uc_mcontext.regs[r]); }
#endif
        wr(fd, "\n--- cmdline\n"); copyfile(fd, "/proc/self/cmdline");
        wr(fd, "\n--- backtrace\n");
        void *bt[64]; int cnt = backtrace(bt, 64);
        backtrace_symbols_fd(bt, cnt, fd);
        wr(fd, "\n--- maps\n"); copyfile(fd, "/proc/self/maps");
        fsync(fd); close(fd);
    }
    signal(sig, SIG_DFL);
    raise(sig);
}

static const int sigs[] = { SIGSEGV, SIGBUS, SIGABRT, SIGILL, SIGFPE };

static void arm(void) {
    struct sigaction sa, old; memset(&sa, 0, sizeof sa);
    sa.sa_sigaction = handler; sa.sa_flags = SA_SIGINFO | SA_ONSTACK;
    for (unsigned i = 0; i < sizeof sigs / sizeof *sigs; i++) {
        if (sigaction(sigs[i], NULL, &old) == 0 && old.sa_sigaction == handler) continue;
        sigaction(sigs[i], &sa, NULL);
    }
}

// Mir/Qt may install their own fatal-signal handlers later: re-arm ours.
static void *rearm(void *arg) {
    (void)arg;
    for (int i = 0; i < 120; i++) { arm(); sleep(1); }
    return NULL;
}

__attribute__((constructor)) static void init(void) {
    const char *h = getenv("HOME");
    if (h && *h) snprintf(dir, sizeof dir, "%s", h);
    void *tmp[2]; backtrace(tmp, 2);           // preload libgcc_s outside the signal handler
    static char altstack[65536];
    stack_t ss = { .ss_sp = altstack, .ss_size = sizeof altstack };
    sigaltstack(&ss, NULL);
    arm();
    pthread_t t;
    if (pthread_create(&t, NULL, rearm, NULL) == 0) pthread_detach(t);
}
