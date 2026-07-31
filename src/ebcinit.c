/*
 * ebcinit -- replay the four /dev/ebc ioctls Onyx's SurfaceFlinger issues at
 * startup, in the order it issues them, and nothing else.
 *
 * WHY
 * ---
 * Under our SurfaceFlinger the kernel rejects every EPDC plane commit:
 *     __sde_plane_atomic_update_epdc(): error! ... width[1648] height[823] ...
 * Under Onyx's SF there are zero such errors -- yet a full LD_PRELOAD ioctl
 * trace of their SF while it was compositing shows NO per-frame /dev/ebc
 * traffic at all. The only /dev/ebc difference between the two cases is this
 * startup sequence:
 *
 *     0x7029   rc=0, argument unchanged
 *     0x7021   rc=0, driver writes back: first int32 0 -> 1017
 *     0x701e   rc=0
 *     0x7022   rc=0, called with a NULL argument
 *
 * So: does replaying it make our SF's commits succeed? If yes, the EPD needs an
 * init handshake and the per-frame parameters may be optional. If the errors
 * continue, the parameters are required and the QtiLayerCommand route is the
 * only way. Either answer is worth having.
 *
 * SAFETY
 * ------
 * These four are the ONLY commands with evidence of being safe -- each returned
 * rc=0 immediately in the trace. This tool will not issue anything else. In
 * particular it never issues 0x7000 (GET_EBC_BUFFER), which blocks forever and
 * has taken this device down twice; see docs/11-epd-update-path.md.
 *
 * The traced argument buffers were mostly uninitialised stack, so the real
 * structs are smaller than the 48 bytes the tracer dumped. We pass a zeroed
 * page, which is the conservative choice: if the driver reads a field we do not
 * know about it sees 0 rather than garbage.
 *
 * Each step is journalled with fsync() before the ioctl, so if one hangs the
 * last line names it.
 */

#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>

#define EBC_DEVICE "/dev/ebc"

static int log_fd = -1;

static void jot(const char *fmt, ...)
{
    char buf[512];
    va_list ap;
    va_start(ap, fmt);
    int n = vsnprintf(buf, sizeof buf, fmt, ap);
    va_end(ap);
    if (n < 0) return;
    if (n > (int)sizeof buf - 2) n = sizeof buf - 2;
    buf[n++] = '\n';
    fwrite(buf, 1, n, stdout);
    fflush(stdout);
    if (log_fd >= 0) { ssize_t w = write(log_fd, buf, n); (void)w; fsync(log_fd); }
}

/* Onyx SF's startup order, from the LD_PRELOAD trace. */
static const struct { int req; int null_arg; } kSeq[] = {
    { 0x7029, 0 },
    { 0x7021, 0 },   /* driver writes an int32 back here */
    { 0x701e, 0 },
    { 0x7022, 1 },   /* traced with no argument */
};

int main(int argc, char **argv)
{
    const char *logpath = NULL;
    int only = -1;
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--log") && i + 1 < argc) logpath = argv[++i];
        else if (!strcmp(argv[i], "--only") && i + 1 < argc) only = (int)strtol(argv[++i], NULL, 0);
    }
    if (logpath) log_fd = open(logpath, O_WRONLY | O_CREAT | O_APPEND, 0666);

    jot("=== ebcinit (pid %d) ===", getpid());
    int fd = open(EBC_DEVICE, O_RDWR);
    if (fd < 0) { jot("open %s failed: %s", EBC_DEVICE, strerror(errno)); return 1; }
    jot("opened %s fd=%d", EBC_DEVICE, fd);

    for (unsigned i = 0; i < sizeof kSeq / sizeof kSeq[0]; i++) {
        int req = kSeq[i].req;
        if (only >= 0 && req != only) continue;

        /* Zeroed page: bigger than any plausible struct, so the driver cannot
         * read past what we own. */
        static uint8_t arg[4096];
        memset(arg, 0, sizeof arg);

        jot("  >>> ioctl 0x%04x %s -- if the log stops here, THIS hangs",
            req, kSeq[i].null_arg ? "(null arg)" : "(zeroed arg)");
        int rc = kSeq[i].null_arg ? ioctl(fd, req, 0) : ioctl(fd, req, arg);
        int e = rc < 0 ? errno : 0;
        jot("      rc=%d errno=%d (%s)", rc, e, e ? strerror(e) : "ok");
        if (!kSeq[i].null_arg) {
            const int32_t *w = (const int32_t *)arg;
            jot("      out[0..5] = %d %d %d %d %d %d",
                w[0], w[1], w[2], w[3], w[4], w[5]);
        }
    }

    jot("=== sequence complete, survived ===");
    close(fd);
    return 0;
}
