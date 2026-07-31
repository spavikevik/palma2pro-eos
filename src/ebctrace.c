/*
 * ebctrace -- LD_PRELOAD shim that logs every ioctl() the vendor display stack
 * makes against /dev/ebc and /dev/dri/card0.
 *
 * Why this exists: every kernel-side observation route on this device is
 * unavailable. `debug_level` and `submit_upd_work` have no store handlers,
 * ftrace has no function tracer (`available_tracers: nop`), and there is no
 * kprobe_events. Interposing in userspace is what is left.
 *
 * This is READ-ONLY with respect to the driver: it logs and forwards. It never
 * originates an ioctl of its own. That matters -- synthesising calls to this
 * driver has rebooted the device twice.
 *
 * Note on the signature: bionic declares `int ioctl(int, int, ...)`, NOT the
 * glibc `int ioctl(int, unsigned long, ...)`. Interposition only works if the
 * symbol matches, so this must stay `int`.
 *
 * Build:  scripts/build-ebctrace.sh
 * Log:    /data/local/tmp/ebc_trace.log
 */

#define _GNU_SOURCE
#include <dlfcn.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/types.h>
#include <time.h>
#include <unistd.h>

#define LOGPATH "/data/local/tmp/ebc_trace.log"
#define DUMP_BYTES 48

static int (*real_ioctl)(int, int, ...);
static int logfd = -1;

/* Cache of fds we care about. -1 = unknown, 0 = not interesting, 1 = ebc,
 * 2 = dri. Keyed by fd; small fixed table avoids any allocation on the hot
 * path and avoids re-reading /proc for every call. */
#define MAXFD 1024
static signed char fdkind[MAXFD];

__attribute__((constructor))
static void ebctrace_init(void)
{
    real_ioctl = (int (*)(int, int, ...))dlsym(RTLD_NEXT, "ioctl");
    memset(fdkind, -1, sizeof(fdkind));
    logfd = open(LOGPATH, O_WRONLY | O_CREAT | O_APPEND, 0666);
    if (logfd >= 0) {
        char b[128];
        int n = snprintf(b, sizeof(b), "\n=== ebctrace attached, pid %d ===\n", getpid());
        write(logfd, b, (size_t)n);
    }
}

static void emit(const char *s, size_t n)
{
    if (logfd >= 0)
        write(logfd, s, n);
}

/* Classify an fd by its /proc/self/fd target. Done once per fd. */
static int classify(int fd)
{
    char lnk[64], tgt[256];
    snprintf(lnk, sizeof(lnk), "/proc/self/fd/%d", fd);
    ssize_t n = readlink(lnk, tgt, sizeof(tgt) - 1);
    if (n <= 0)
        return 0;
    tgt[n] = '\0';
    if (strcmp(tgt, "/dev/ebc") == 0)
        return 1;
    if (strncmp(tgt, "/dev/dri/", 9) == 0)
        return 2;
    return 0;
}

static void dump_arg(const char *tag, const void *p)
{
    char out[512];
    int o = snprintf(out, sizeof(out), "    %s:", tag);
    if (!p) {
        o += snprintf(out + o, sizeof(out) - (size_t)o, " (null)\n");
        emit(out, (size_t)o);
        return;
    }
    /* The pointer comes from the caller; a bad one would fault here. Callers of
     * these ioctls are the vendor stack, so it is theirs and valid. */
    const unsigned char *b = p;
    for (int i = 0; i < DUMP_BYTES; i++) {
        if (i % 16 == 0)
            o += snprintf(out + o, sizeof(out) - (size_t)o, "\n      ");
        o += snprintf(out + o, sizeof(out) - (size_t)o, "%02x ", b[i]);
    }
    o += snprintf(out + o, sizeof(out) - (size_t)o, "\n      as int32:");
    const int32_t *w = p;
    for (int i = 0; i < DUMP_BYTES / 4; i++)
        o += snprintf(out + o, sizeof(out) - (size_t)o, " %d", w[i]);
    o += snprintf(out + o, sizeof(out) - (size_t)o, "\n");
    emit(out, (size_t)o);
}

int ioctl(int fd, int request, ...)
{
    va_list ap;
    va_start(ap, request);
    void *arg = va_arg(ap, void *);
    va_end(ap);

    if (!real_ioctl)
        ebctrace_init();

    int kind = 0;
    if (fd >= 0 && fd < MAXFD) {
        if (fdkind[fd] == -1)
            fdkind[fd] = (signed char)classify(fd);
        kind = fdkind[fd];
    }

    if (!kind)
        return real_ioctl(fd, request, arg);

    /* SET_EBC_SEND_UPDATE: decode inline. Field layout confirmed against both
     * the kernel disassembly and live captures. One line per update keeps a
     * long session readable and greppable. */
    if (request == 0x700c && arg) {
        const int32_t *u = arg;
        char line[256];
        int n = snprintf(line, sizeof(line),
                         "UPD rect=(%d,%d)-(%d,%d) wf=%d mode=%d marker=%d "
                         "f1c=%d flags=%#x f24=%d",
                         u[0], u[1], u[2], u[3], u[4], u[5], u[6], u[7],
                         (unsigned)u[8], u[9]);
        int rc0 = real_ioctl(fd, request, arg);
        n += snprintf(line + n, sizeof(line) - (size_t)n, " -> rc=%d\n", rc0);
        emit(line, (size_t)n);
        return rc0;
    }

    char hdr[160];
    int n = snprintf(hdr, sizeof(hdr), "\n[%s] ioctl req=%#x (%d) fd=%d\n",
                     kind == 1 ? "ebc" : "dri", (unsigned)request, request, fd);
    emit(hdr, (size_t)n);
    dump_arg("in ", arg);

    int rc = real_ioctl(fd, request, arg);

    n = snprintf(hdr, sizeof(hdr), "    -> rc=%d\n", rc);
    emit(hdr, (size_t)n);
    dump_arg("out", arg);

    return rc;
}
