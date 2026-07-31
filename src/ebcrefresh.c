/*
 * ebcrefresh -- ask the panel to redraw what SurfaceFlinger already composited.
 *
 * WHY THIS EXISTS
 * ---------------
 * With Onyx's SurfaceFlinger running (onyx-sf branch) the device boots fully and
 * the EPD hardware demonstrably works -- the panel clears on screen-off. But the
 * screen stays blank in normal use because only TWO updates are ever submitted
 * in a whole session, both from that power-off clear.
 *
 * EPD update regions originate ABOVE SurfaceFlinger: apps call
 * Surface::transferEpdc, the regions ride to SF inside BufferData, and SF
 * forwards them. Our /e/OS framework never calls it -- our libgui has no epdc
 * symbols at all -- so SF is never told anything changed and never refreshes.
 *
 * This is the stopgap: submit the same full-screen update SF itself submits, on
 * a timer, so the panel shows whatever was last composited.
 *
 * EVERY VALUE HERE WAS OBSERVED, NOT GUESSED
 * ------------------------------------------
 * ioctl 0x700c   from the call site in Onyx's SF, 32 bytes after its
 *                "refresh screen (%d, %d - %d, %d) waveform_mode %d flags 0x%x"
 *                log string:
 *                    60812c: mov w1, #0x700c
 *                    608130: bl  <ioctl@plt>
 *                (this also confirms docs/03's previously-unverified guess, and
 *                 it is NOT shifted by Onyx's +1 insertion at 0x7002)
 *
 * rect, mode, flags, marker  from the kernel's own log of SF's calls:
 *     epdc_ioctl(): SET_EBC_SEND_UPDATE -- magic[1] [x=0 y=0 w=1648 h=824]!flags = 0x31000!
 *     SurfaceFlinger: refresh screen (0, 0 - 1648, 824) waveform_mode 2 flags 0x31000 marker 1
 *
 * struct layout  from the kernel handler at 0x5b23f8, which does
 *                `mov w2, #0x28` (40 bytes) before copy_from_user; fields mapped
 *                from the printk arguments. See docs/03-ebc-api.md.
 *
 * SAFETY
 * ------
 * A malformed update can wedge the display controller. Everything below is a
 * replay of parameters the kernel has already accepted from Onyx's own SF, so
 * the risk is materially lower than the earlier probing that hung the device --
 * but it is not zero, and a wedge needs a hard power-cycle.
 *
 * Deliberately does NOT touch EBC_GET_BUFFER (0x7000): that blocks forever on
 * this device, three times proven. We only submit an update for content that is
 * already in the framebuffer.
 */

#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>

#define EBC_DEVICE           "/dev/ebc"
#define EBC_SEND_UPDATE      0x700c   /* from Onyx SF's call site */
#define EBC_GET_BUFFER_INFO  0x7003   /* Onyx numbering (+1 vs upstream) */

/* 40 bytes: the kernel copies exactly 0x28 from user. */
struct ebc_send_update {
    int32_t rect[4];        /* +0x00  left, top, right, bottom            */
    int32_t waveform_mode;  /* +0x10  2 = ordinary composition            */
    int32_t update_mode;    /* +0x14  compared against 1 in the handler   */
    int32_t update_marker;  /* +0x18  SF increments this per submission   */
    int32_t unknown_1c;     /* +0x1c  not read on the traced path         */
    int32_t flags;          /* +0x20  bits 16/17/18 tested by the handler */
    int32_t unknown_24;     /* +0x24  probably temperature                */
};
_Static_assert(sizeof(struct ebc_send_update) == 40, "kernel copies 0x28 bytes");

static volatile sig_atomic_t stop = 0;
static void on_sig(int s) { (void)s; stop = 1; }

int main(int argc, char **argv)
{
    int w = 1648, h = 824, mode = 2, flags = 0x21000, interval_ms = 0, count = 1;
    int quiet = 0;

    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--mode")     && i + 1 < argc) mode = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--flags") && i + 1 < argc) flags = (int)strtol(argv[++i], NULL, 0);
        else if (!strcmp(argv[i], "--interval") && i + 1 < argc) interval_ms = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--count") && i + 1 < argc) count = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--quiet")) quiet = 1;
        else if (!strcmp(argv[i], "--help")) {
            printf("usage: %s [--mode N] [--flags 0xN] [--interval MS] [--count N|-1]\n"
                   "  defaults: mode 2, flags 0x21000, one shot, full screen\n"
                   "  --interval with --count -1 runs as a refresh daemon\n", argv[0]);
            return 0;
        }
    }

    signal(SIGINT, on_sig);
    signal(SIGTERM, on_sig);

    int fd = open(EBC_DEVICE, O_RDWR);
    if (fd < 0) {
        fprintf(stderr, "open %s: %s\n", EBC_DEVICE, strerror(errno));
        return 1;
    }

    /* Take the real geometry from the driver rather than trusting the defaults. */
    int32_t info[16];
    memset(info, 0, sizeof info);
    if (ioctl(fd, EBC_GET_BUFFER_INFO, info) == 0) {
        if (info[3] > 0 && info[2] > 0) { w = info[3]; h = info[2]; }
    }
    if (!quiet) printf("panel %dx%d, mode %d, flags 0x%x\n", w, h, mode, flags);

    for (int i = 0; count < 0 || i < count; i++) {
        if (stop) break;
        struct ebc_send_update u;
        memset(&u, 0, sizeof u);
        u.rect[0] = 0; u.rect[1] = 0; u.rect[2] = w; u.rect[3] = h;
        u.waveform_mode = mode;
        u.update_mode = 1;
        u.update_marker = i + 1;
        u.flags = flags;

        int rc = ioctl(fd, EBC_SEND_UPDATE, &u);
        if (!quiet)
            printf("[%d] SET_EBC_SEND_UPDATE (0,0)-(%d,%d) marker=%d -> rc=%d%s\n",
                   i + 1, w, h, u.update_marker, rc,
                   rc < 0 ? strerror(errno) : "");
        if (rc < 0 && errno == EINVAL) {
            fprintf(stderr, "rejected -- wrong struct or mode; stopping rather "
                            "than repeating a bad command\n");
            break;
        }
        if (interval_ms > 0 && (count < 0 || i + 1 < count))
            usleep((useconds_t)interval_ms * 1000);
    }

    close(fd);
    return 0;
}
