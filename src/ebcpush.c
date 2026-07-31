/*
 * ebcpush -- push one frame to the panel through /dev/ebc's own designed path.
 *
 * WHY THIS MIGHT WORK NOW
 * -----------------------
 * Onyx's /dev/ebc driver is a port of Rockchip's ebc-dev (see
 * docs/13-epd-ecosystem.md). Upstream's userspace flow is:
 *
 *     EBC_GET_BUFFER (0x7000)  -> hands back a free buffer (BLOCKS if none)
 *     mmap at buf_info.offset  -> draw into it
 *     EBC_SEND_BUFFER (0x7001) -> driver displays it
 *
 * Both of those commands sit BELOW Onyx's inserted GET_EBC_DRIVER_SN at 0x7002,
 * so unlike everything above they are NOT shifted and keep upstream's numbers.
 *
 * Previous attempts hung the device on 0x7000. That was not corruption: upstream
 * EBC_GET_BUFFER waits on the driver's free-buffer queue, and the vendor
 * composer holds every buffer. The one variable never tested is stopping the
 * COMPOSER -- earlier runs stopped surfaceflinger only, which is not the process
 * that owns the buffers. Run this with both stopped:
 *
 *     setprop ctl.stop surfaceflinger
 *     setprop ctl.stop vendor.qti.hardware.display.composer
 *
 * STAGES -- run ONE at a time, lowest first
 *   0  info     GET_EBC_BUFFER_INFO (0x7003 here; 0x7002 upstream). Safe.
 *   1  get      GET_EBC_BUFFER. THIS is the one that has hung the device.
 *   2  map      stage 1 + mmap the returned offset. No writes.
 *   3  draw     stage 2 + fill the buffer. Nothing submitted.
 *   4  send     stage 3 + SEND_BUFFER. This is the actual refresh.
 *
 * Every step is journalled with fsync() before the call, so a hang leaves the
 * offending step as the last line.
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
#include <sys/mman.h>
#include <unistd.h>

#define EBC_DEVICE          "/dev/ebc"
#define EBC_GET_BUFFER      0x7000   /* upstream numbering, unshifted */
#define EBC_SEND_BUFFER     0x7001   /* upstream numbering, unshifted */
#define EBC_GET_BUFFER_INFO 0x7003   /* Onyx: +1 vs upstream 0x7002 */

/* Confirmed identical to upstream drivers/gpu/drm/rockchip/ebc-dev/ebc_dev.h */
struct ebc_buf_info {
    int offset;
    int epd_mode;
    int height;
    int width;
    int panel_color;
    int win_x1;
    int win_y1;
    int win_x2;
    int win_y2;
    int width_mm;
    int height_mm;
};

static int log_fd = -1;

static void jot(const char *fmt, ...)
{
    char b[512];
    va_list ap;
    va_start(ap, fmt);
    int n = vsnprintf(b, sizeof b, fmt, ap);
    va_end(ap);
    if (n < 0) return;
    if (n > (int)sizeof b - 2) n = sizeof b - 2;
    b[n++] = '\n';
    fwrite(b, 1, n, stdout);
    fflush(stdout);
    if (log_fd >= 0) { ssize_t w = write(log_fd, b, n); (void)w; fsync(log_fd); }
}

static void dump_info(const char *tag, const struct ebc_buf_info *i)
{
    jot("  %s: offset=%d epd_mode=%d %dx%d panel_color=%d win=(%d,%d)-(%d,%d) %dx%d mm",
        tag, i->offset, i->epd_mode, i->width, i->height, i->panel_color,
        i->win_x1, i->win_y1, i->win_x2, i->win_y2, i->width_mm, i->height_mm);
}

int main(int argc, char **argv)
{
    if (argc < 2) { fprintf(stderr,
        "usage: %s <stage 0..4> [--log FILE] [--mode N] [--pattern black|white|checker]\n",
        argv[0]); return 2; }

    int stage = atoi(argv[1]);
    int mode = 2;                    /* docs/03: what the vendor stack uses */
    const char *logpath = NULL, *pattern = "checker";
    for (int i = 2; i < argc; i++) {
        if (!strcmp(argv[i], "--log") && i + 1 < argc) logpath = argv[++i];
        else if (!strcmp(argv[i], "--mode") && i + 1 < argc) mode = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--pattern") && i + 1 < argc) pattern = argv[++i];
    }
    if (logpath) log_fd = open(logpath, O_WRONLY | O_CREAT | O_APPEND, 0666);

    jot("=== ebcpush stage %d (pid %d) ===", stage, getpid());
    int fd = open(EBC_DEVICE, O_RDWR);
    if (fd < 0) { jot("open failed: %s", strerror(errno)); return 1; }
    jot("opened %s fd=%d", EBC_DEVICE, fd);

    struct ebc_buf_info info;
    memset(&info, 0, sizeof info);
    jot("ioctl GET_EBC_BUFFER_INFO (0x%x)", EBC_GET_BUFFER_INFO);
    int rc = ioctl(fd, EBC_GET_BUFFER_INFO, &info);
    jot("  rc=%d errno=%d", rc, rc < 0 ? errno : 0);
    dump_info("info", &info);
    if (stage == 0) { jot("stage 0 done"); return 0; }

    struct ebc_buf_info buf;
    memset(&buf, 0, sizeof buf);
    buf.epd_mode = mode;
    buf.width  = info.width;
    buf.height = info.height;
    buf.win_x1 = 0; buf.win_y1 = 0;
    buf.win_x2 = info.width; buf.win_y2 = info.height;

    jot(">>> ioctl GET_EBC_BUFFER (0x%x) -- if the log stops here, the free-buffer",
        EBC_GET_BUFFER);
    jot("    queue is still empty; the composer has not released its buffers");
    rc = ioctl(fd, EBC_GET_BUFFER, &buf);
    jot("  rc=%d errno=%d -- RETURNED", rc, rc < 0 ? errno : 0);
    dump_info("buf", &buf);
    if (rc < 0) { jot("no buffer, stopping"); return 1; }
    if (stage == 1) { jot("stage 1 done"); return 0; }

    /* Upstream: one byte per pixel, 4bpp packed on some panels. Map generously
     * and let the driver's own geometry decide what we touch. */
    size_t len = (size_t)info.width * info.height;
    if (len < 4096) len = 4096;
    jot("mmap len=%zu offset=%d", len, buf.offset);
    void *p = mmap(NULL, len, PROT_READ | PROT_WRITE, MAP_SHARED, fd, buf.offset);
    if (p == MAP_FAILED) { jot("  mmap failed: %s", strerror(errno)); return 1; }
    jot("  mmap ok at %p", p);
    if (stage == 2) { jot("stage 2 done (mapping untouched)"); return 0; }

    jot("filling buffer, pattern=%s", pattern);
    uint8_t *b = p;
    if (!strcmp(pattern, "black")) memset(b, 0x00, len);
    else if (!strcmp(pattern, "white")) memset(b, 0xFF, len);
    else {
        for (int y = 0; y < info.height; y++)
            for (int x = 0; x < info.width; x++)
                b[(size_t)y * info.width + x] =
                    (((x / 64) + (y / 64)) & 1) ? 0xFF : 0x00;
    }
    jot("  filled");
    if (stage == 3) { jot("stage 3 done (nothing submitted)"); return 0; }

    jot(">>> ioctl EBC_SEND_BUFFER (0x%x) mode=%d -- THIS should refresh the panel",
        EBC_SEND_BUFFER, mode);
    rc = ioctl(fd, EBC_SEND_BUFFER, &buf);
    jot("  rc=%d errno=%d", rc, rc < 0 ? errno : 0);
    jot("=== stage 4 done -- look at the panel ===");
    return 0;
}
