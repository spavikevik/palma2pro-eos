/*
 * ebcshow -- put an image on the panel without the compositor.
 *
 * This is src/ebchandwrite.c's experiment turned into something usable. The
 * mechanism and the evidence for it are documented in docs/22 section 9.4; the
 * short version:
 *
 *   1. mmap /dev/ebc            -> virt_buf_handwrite, 1648*824*4, writable
 *   2. ioctl 0x7006, scheme = 3 -> SCHEME_HANDWRITE, the only mode that reads it
 *   3. SEND_UPDATE with flags bit 18 set, or the driver rejects the update
 *   4. ioctl 0x7006, scheme = 2 -> hand the display back to the compositor
 *
 * ORIENTATION
 * -----------
 * The buffer is the panel in *output space*: 1648 wide by 824 tall, landscape,
 * one pixel per pixel with no transform of its own. That was established by
 * drawing bands that vary along buffer-y and observing them come out horizontal
 * when the device is held in landscape.
 *
 * Content, however, is authored portrait -- 824 by 1648, the layer-stack space
 * everything else in this project works in (docs/19), and what
 * scripts/gen-screensaver.py emits. So a portrait image has to be rotated a
 * quarter turn on the way in, which is what rot does.
 *
 * It defaults to 270, established by looking at the panel. Both 90 and 270
 * produce a correctly proportioned frame, so the geometry cannot distinguish
 * them -- 90 simply comes out upside down.
 *
 * USAGE
 *   scripts/gen-screensaver.py art.jpg out/ss.raw       # 824x1648 8-bit grey
 *   adb push out/ss.raw /data/local/tmp/
 *   adb shell /data/local/tmp/ebcshow /data/local/tmp/ss.raw 824 1648
 *
 *   ebcshow <file.raw> <w> <h> [rot 0|90|180|270] [waveform] [hold_ms]
 *
 * HOLDING
 * -------
 * The panel keeps whatever was last driven into it, but only until something
 * else draws. Restore scheme 2 with the screen on and SurfaceFlinger repaints
 * its damaged regions immediately -- which looks like the image "overlapping"
 * the old screen for a moment, then being replaced by it entirely.
 *
 * That is not ghosting and not a coverage problem: at debug_level 4096 the
 * driver reports the update it ran as [l=0 t=0 w=1648 h=824], the whole panel.
 * It is simply the compositor taking the display back.
 *
 * hold_ms keeps scheme 3 set for longer, during which ordinary updates are
 * rejected and the image stays up. It matters for testing with the screen on;
 * it is irrelevant to the screensaver case, where nothing is compositing anyway.
 *
 * SAFETY
 * ------
 * While scheme 3 is set the driver refuses ordinary updates, so the compositor
 * cannot paint. Every exit path here restores scheme 2, including the failures.
 * Run behind scripts/epd-deadman.sh when changing anything: a stuck display
 * pipeline keeps the SoC watchdog fed, so nothing in the kernel will rescue it.
 *
 * EBC_GET_BUFFER (0x7000) is never issued -- it blocks forever on this device.
 */

#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <unistd.h>

#define EBC_UPDATE_SCHEME        0x7006
#define EBC_SEND_UPDATE          0x700c
/* Takes no user argument; every operand comes from driver globals. Copies the
 * live framebuffer into virt_buf_handwrite. See docs/22 section 9.4.2. */
#define EBC_EXT_BUF_SYNC_WITH_FB 0x701d

/*
 * How to reconcile the driver's stale record of the panel before drawing.
 *
 * Only MODE_FLASH works. The other two are kept because they are cheaper and
 * look like they ought to work, and someone will otherwise try them again:
 *
 *   MODE_SYNC    proven to rewrite the whole buffer from the live framebuffer
 *                (stamp the buffer with 0xaa, sync, none of it survives) -- and
 *                the panel still ghosts. So the driver's transition source is
 *                NOT the buffer we mmap.
 *   MODE_CLEAN   runs the driver's own onyx_epdc_clean_screen -- still ghosts,
 *                because it cleans via the normal path, not the handwrite one.
 *
 * Together with cut_frame_num making no difference (3 and 5 both drive exactly
 * 33 frames), that leaves one explanation: the driver keeps a HANDWRITE-SPECIFIC
 * record of what is displayed, refreshed only by handwrite updates. After the
 * compositor has been drawing, that record is stale and nothing outside the
 * handwrite path can correct it. Driving both rails through the handwrite path
 * is the only thing that does.
 *
 * Confirmed by the prediction it makes: draw one image with MODE_FLASH, then a
 * DIFFERENT image with MODE_NONE, and the second is clean. So the flash is a
 * once-per-session cost -- pay it on the first draw after the compositor has
 * been running, then use MODE_NONE for every draw after that (~450ms, no
 * flicker) for as long as nothing else paints the panel.
 */
#define MODE_NONE   0    /* neither -- correct only when our own content is up */
#define MODE_FLASH  1    /* black/white rails: the one that works */
#define MODE_SYNC   2    /* seed from the framebuffer: does not fix ghosting */
#define MODE_CLEAN  3    /* driver's own clean: does not fix ghosting */

/* Reading this node RUNS onyx_epdc_clean_screen -- it is a show_ handler that
 * performs the action rather than reporting anything (docs/22 section 4.1). */
#define PANEL_CLEAN "/sys/devices/virtual/sepdc/debug/panel_clean"

#define SCHEME_NORMAL       2      /* onyx_epdc_fb_probe(): upd_scheme[2] */
#define SCHEME_HANDWRITE    3      /* onyx_epdc_scheme_is_handwrite()     */

/* flags bit 18. Without it epdc_ioctl takes the ordinary path, sees scheme 3,
 * and logs "reject non HANDWRITE update". See docs/22 section 9.4. */
#define EPDC_FLAG_HANDWRITE 0x40000
#define EPDC_FLAG_STOCK     0x31000    /* captured from the stock stack */

#define PANEL_W 1648
#define PANEL_H 824

struct upd {
    int32_t rect[4];
    int32_t waveform_mode;
    int32_t update_mode;
    int32_t update_marker;
    int32_t temp;
    int32_t flags;
    int32_t dither_mode;
};

static int fd = -1;

static int set_scheme(int v)
{
    int s = v;
    return ioctl(fd, EBC_UPDATE_SCHEME, &s);
}

/* A full-panel GC16 runs ~33 frames, which the sysfs frame[] counter puts at a
 * bit under half a second. Waiting a little longer than that between passes is
 * cheaper than working out the argument to WAIT_ALL_UPDATE_COMPLETE. */
#define PASS_MS 550

/* Markers must be unique per submission or updates collide and the panel blanks
 * mid-waveform; a pid-derived value is enough for a one-shot tool. Note the
 * driver reports handwrite markers with 0x3e80000 added -- see docs/22 9.4.1. */
static int32_t next_marker(void)
{
    static int32_t n;
    return (int32_t)(((getpid() & 0x3fff) << 8) | (++n & 0xff)) | 1;
}

/* Submit the whole panel. Every update here is full-panel: the clear passes
 * have to be, and the image covers it anyway after rotation. */
static int send_full(int wf, int update_mode)
{
    struct upd u;
    memset(&u, 0, sizeof u);
    u.rect[2] = PANEL_W;
    u.rect[3] = PANEL_H;
    u.waveform_mode = wf;
    u.update_mode = update_mode;
    u.update_marker = next_marker();
    u.temp = 0x1000;                   /* TEMP_USE_AMBIENT */
    u.flags = EPDC_FLAG_STOCK | EPDC_FLAG_HANDWRITE;
    return ioctl(fd, EBC_SEND_UPDATE, &u);
}

/* Rotate the source into the panel buffer.
 *
 * Iterating over the SOURCE and computing the destination writes every source
 * pixel exactly once, so no rounding gaps appear at any angle. Destinations
 * outside the panel are dropped, which lets an oversized image be shown rather
 * than rejected.
 */
static void blit(uint32_t *dst, const unsigned char *src, int sw, int sh,
                 int rot, int channels)
{
    for (size_t i = 0; i < (size_t)PANEL_W * PANEL_H; i++) dst[i] = 0xffffffffu;

    for (int y = 0; y < sh; y++) {
        for (int x = 0; x < sw; x++) {
            int dx, dy;
            switch (rot) {
            case 90:  dx = (sh - 1) - y; dy = x;             break;
            case 180: dx = (sw - 1) - x; dy = (sh - 1) - y;  break;
            case 270: dx = y;            dy = (sw - 1) - x;  break;
            default:  dx = x;            dy = y;             break;
            }
            if (dx < 0 || dx >= PANEL_W || dy < 0 || dy >= PANEL_H) continue;
            const unsigned char *s = &src[((size_t)y * sw + x) * channels];
            uint32_t r, g, b;
            if (channels == 3) {
                r = s[0]; g = s[1]; b = s[2];
            } else {
                r = g = b = s[0];
            }
            dst[(size_t)dy * PANEL_W + dx] =
                0xff000000u | (r << 16) | (g << 8) | b;
        }
    }
}

int main(int argc, char **argv)
{
    if (argc < 4) {
        fprintf(stderr,
                "usage: %s <file.raw> <w> <h> [rot] [waveform] [hold_ms] [mode] [ch]\n"
                "  file.raw is w*h*ch bytes: ch=1 greyscale, ch=3 RGB\n"
                "  rot defaults to 270 (portrait content -> landscape panel)\n"
                "  hold_ms keeps the compositor locked out so the image stays up\n"
                "  mode: 0 none, 1 flash (black+white), 2 sync from framebuffer\n",
                argv[0]);
        return 2;
    }
    const char *path = argv[1];
    const int sw = atoi(argv[2]);
    const int sh = atoi(argv[3]);
    /* 270, not 90. Both turn portrait content into a correctly proportioned
     * landscape frame, so aspect ratio cannot tell them apart -- 90 produced an
     * upside-down image on this panel. */
    const int rot = (argc > 4) ? atoi(argv[4]) : 270;
    const int wf = (argc > 5) ? atoi(argv[5]) : 2;   /* 2 = GC16, full quality */
    /* Long enough for a full GC16 flash to land before the scheme is handed
     * back; anything more is only for looking at the result. */
    const int hold_ms = (argc > 6) ? atoi(argv[6]) : 1200;
    /* MODE_FLASH is the only one that works. MODE_SYNC and MODE_CLEAN were both
     * tried on the panel and both still ghost -- see the note above the modes
     * and docs/22 section 9.4.2. */
    const int do_clear = (argc > 7) ? atoi(argv[7]) : MODE_FLASH;
    /* 1 = 8-bit greyscale, 3 = 24-bit RGB. Colour only reaches the glass on a
     * CFA panel with cfa mode enabled; see the note by EBC_ENABLE_CFA_MODE. */
    const int channels = (argc > 8) ? atoi(argv[8]) : 1;

    if (sw <= 0 || sh <= 0) {
        fprintf(stderr, "bad dimensions %dx%d\n", sw, sh);
        return 2;
    }
    if (rot != 0 && rot != 90 && rot != 180 && rot != 270) {
        fprintf(stderr, "rot must be 0, 90, 180 or 270\n");
        return 2;
    }

    if (channels != 1 && channels != 3) {
        fprintf(stderr, "ch must be 1 (grey) or 3 (RGB)\n");
        return 2;
    }

    size_t need = (size_t)sw * sh * channels;
    FILE *f = fopen(path, "rb");
    if (!f) {
        fprintf(stderr, "open %s: %s\n", path, strerror(errno));
        return 1;
    }
    unsigned char *src = malloc(need);
    if (!src) { fclose(f); fprintf(stderr, "out of memory\n"); return 1; }
    size_t got = fread(src, 1, need, f);
    fclose(f);
    if (got != need) {
        fprintf(stderr, "%s: expected %zu bytes for %dx%d x%d, read %zu\n",
                path, need, sw, sh, channels, got);
        free(src);
        return 1;
    }

    fd = open("/dev/ebc", O_RDWR);
    if (fd < 0) {
        fprintf(stderr, "open(/dev/ebc): %s\n", strerror(errno));
        free(src);
        return 1;
    }

    size_t n = (size_t)PANEL_W * PANEL_H * 4;
    uint32_t *dst = mmap(NULL, n, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (dst == MAP_FAILED) {
        fprintf(stderr, "mmap: %s\n", strerror(errno));
        close(fd);
        free(src);
        return 1;
    }

    int rc = 0;

    /* Enter handwrite scheme FIRST, before anything is written into the buffer.
     *
     * 0x7006 does double duty: it selects the scheme and it stamps
     * fb_update_time. That stamp is what gates the sync below, so the order is
     * not arbitrary. Anything blitted before this point would also be destroyed
     * by a sync, so the image goes in afterwards. */
    if (set_scheme(SCHEME_HANDWRITE) != 0) {
        fprintf(stderr, "could not enter handwrite scheme: %s\n", strerror(errno));
        rc = 1;
        goto out;
    }

    /* Deal with the driver's stale idea of what is on the panel.
     *
     * A single GC16 pass leaves the previous screen visibly ghosted through the
     * new one. The driver drives each pixel as a TRANSITION from what it
     * believes is displayed -- it maintains that itself, via
     * onyx_epdc_put_last_image() and onyx_epdc_wb_oldpixel_convert(). The
     * handwrite buffer is a separate buffer, so once the compositor has been
     * drawing through the normal path the driver's record and the glass
     * disagree, and every transition starts from the wrong place.
     *
     * Two ways out, and they differ in kind.
     */
    if (do_clear == MODE_SYNC) {
        /* Ask the driver to seed the buffer FROM the live framebuffer, so its
         * record and the glass agree. This addresses the cause, and costs one
         * ioctl instead of two full-panel passes.
         *
         * It is gated on time. From onyx_epdc_ext_buf_sync_with_fb:
         *
         *     if (fb_update_time  < handwrite_time) return;   // nothing to do
         *     if (last_fb_time    < handwrite_time) return;
         *
         * so a sync straight after a handwrite update is a silent no-op --
         * handwrite_time is the newer stamp. Entering the scheme above is what
         * refreshes fb_update_time and makes this fire. */
        errno = 0;
        if (ioctl(fd, EBC_EXT_BUF_SYNC_WITH_FB, NULL) != 0)
            fprintf(stderr, "sync: %s (continuing)\n", strerror(errno));
    } else if (do_clear == MODE_CLEAN) {
        /* Let the driver clean the panel its own way, then draw. Cheaper than
         * the flash if it works, and it uses whatever sequence Onyx considers
         * correct for this panel rather than one imposed from outside. */
        int cfd = open(PANEL_CLEAN, O_RDONLY);
        if (cfd < 0) {
            fprintf(stderr, "open %s: %s (continuing)\n", PANEL_CLEAN, strerror(errno));
        } else {
            char buf[64];
            ssize_t got = read(cfd, buf, sizeof buf - 1);
            close(cfd);
            if (got > 0) { buf[got] = 0; printf("  panel_clean -> %s", buf); }
            usleep(PASS_MS * 1000);
        }
    } else if (do_clear == MODE_FLASH) {
        /* Overpower the disagreement instead: drive every pixel to full black
         * and then to full white, so the starting state stops mattering. This
         * is the classic e-ink "flashing" refresh, and it is why readers flash
         * on a page turn. Reliable, but two extra full-panel passes and
         * visibly ugly. */
        static const uint32_t rails[2] = { 0xff000000u, 0xffffffffu };
        for (int pass = 0; pass < 2; pass++) {
            for (size_t i = 0; i < (size_t)PANEL_W * PANEL_H; i++)
                dst[i] = rails[pass];
            if (send_full(wf, 1) != 0) {
                fprintf(stderr, "clear pass %d: %s\n", pass, strerror(errno));
                rc = 1;
                goto out;
            }
            usleep(PASS_MS * 1000);
        }
    }

    /* The image goes in last: a sync would have overwritten it, and the rails
     * definitely did. */
    blit(dst, src, sw, sh, rot, channels);

    if (send_full(wf, 1) != 0) {
        fprintf(stderr, "SEND_UPDATE: %s\n", strerror(errno));
        rc = 1;
    } else {
        printf("shown: %s %dx%d rot=%d wf=%d clear=%d ch=%d\n",
               path, sw, sh, rot, wf, do_clear, channels);
    }

    /* Let the waveform finish before taking the scheme away. The panel holds the
     * result once it lands -- but only until the compositor draws again, which
     * is what hold_ms defers. */
    usleep((useconds_t)hold_ms * 1000);

out:
    set_scheme(SCHEME_NORMAL);
    munmap(dst, n);
    close(fd);
    free(src);
    return rc;
}
