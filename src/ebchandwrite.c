/*
 * ebchandwrite -- draw to the panel without the compositor.
 *
 * WHY
 * ---
 * Nothing in this project can put a frame on the panel unless SurfaceFlinger
 * composites it. That blocks the lock screensaver (issue #14), a settle pass at
 * the end of motion, and any future daemon-driven refresh. EBC_SEND_UPDATE on
 * its own does not help: it repaints from a driver-owned buffer that our stack
 * never writes, so it faithfully paints white (issue #2).
 *
 * Disassembling the running kernel closes that gap. /dev/ebc has an mmap:
 *
 *     epdc_mmap @ 0x57e690:  dma_buf_mmap(virt_buf_handwrite, vma, 0)
 *
 * and it is real -- mapping succeeds, reports 0x52f000 bytes (1648*824*4), and
 * the memory is writable from userspace. So there IS a buffer we can paint.
 *
 * The driver only reads it in one mode. From epdc_ioctl @ 0x57c920:
 *
 *     w9 = g[0x2c50]            // current upd_scheme
 *     cmp w9, #3
 *     b.ne <normal path>
 *     printk("ERROR! Now is SCHEME_HANDWRITE, reject non HANDWRITE update!!")
 *
 * confirmed by onyx_epdc_scheme_is_handwrite() @ 0x5799f8, which is exactly
 * "g[0x2c50] == 3". The boot log says the driver starts at upd_scheme[2], so 3
 * is a mode it is switched into, and 2 is what to switch back to.
 *
 * SAFETY
 * ------
 * While the scheme is 3 the driver REJECTS ordinary updates, so the display
 * stops responding to the compositor for as long as this runs. Every exit path
 * therefore restores the scheme, including the failure paths. Run it behind
 * scripts/epd-deadman.sh so a wedge costs one automatic reboot rather than the
 * 220 seconds an earlier probe cost -- the SoC watchdog does not help here,
 * because a stuck display pipeline still lets the kernel pet it.
 *
 * EBC_GET_BUFFER (0x7000) is never issued: it blocks forever on this device.
 */

#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <unistd.h>

#define EBC_UPDATE_SCHEME   0x7006   /* SET_EBC_UPDATE_SCHEME */
#define EBC_SEND_UPDATE     0x700c   /* SET_EBC_SEND_UPDATE   */

#define SCHEME_NORMAL       2        /* onyx_epdc_fb_probe(): upd_scheme[2] */
#define SCHEME_HANDWRITE    3        /* onyx_epdc_scheme_is_handwrite()     */

#define PANEL_W 1648
#define PANEL_H 824
#define BPP     4

/*
 * Bit 18 of the update's flags field is what makes an update a HANDWRITE one.
 * From epdc_ioctl, immediately after the 40-byte struct is copied in:
 *
 *     bl   __arch_copy_from_user   ; dst = sp+0x40, len = 0x28
 *     ldr  w8, [sp, #0x60]         ; sp+0x40 + 0x20 -> byte 32 -> flags
 *     tbz  w8, #0x12, <reject>     ; bit 18 clear -> "reject non HANDWRITE"
 *
 * Byte 32 lands exactly on flags in the layout below, which is a useful
 * independent check on the struct itself. Without this bit the driver takes the
 * ordinary path, sees scheme == 3, and refuses the update -- which is precisely
 * what the first run of this probe did.
 */
#define EPDC_FLAG_HANDWRITE 0x40000

/* 40 bytes; see docs/19 and docs/22. Field names follow NXP's
 * mxcfb_update_data, which this driver's update path is derived from. */
struct upd {
    int32_t rect[4];          /* x, y, w, h */
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
    errno = 0;
    int r = ioctl(fd, EBC_UPDATE_SCHEME, &s);
    printf("  scheme <- %d : rc=%d errno=%d (%s)\n",
           v, r, errno, errno ? strerror(errno) : "ok");
    return r;
}

int main(int argc, char **argv)
{
    /* Waveform 6 is A2 on this panel -- the one measured to work, not the one
     * docs/19 originally guessed. 2 is GC16, the full-quality flash. */
    const int wf = (argc > 1) ? atoi(argv[1]) : 2;
    const int32_t flags = (argc > 2)
            ? (int32_t)strtol(argv[2], NULL, 0)
            : (int32_t)(0x31000 | EPDC_FLAG_HANDWRITE);

    fd = open("/dev/ebc", O_RDWR);
    if (fd < 0) {
        printf("open(/dev/ebc): %s\n", strerror(errno));
        return 1;
    }

    size_t n = (size_t)PANEL_W * PANEL_H * BPP;
    void *p = mmap(NULL, n, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (p == MAP_FAILED) {
        printf("mmap: %s\n", strerror(errno));
        close(fd);
        return 1;
    }
    printf("mapped %zu bytes at %p\n", n, p);

    /* Horizontal grey bands. Unmistakable if it lands, and unmistakably
     * different from the white the buffer starts out as. */
    uint32_t *px = p;
    for (int y = 0; y < PANEL_H; y++) {
        unsigned band = (unsigned)(y * 8 / PANEL_H);      /* 0..7 */
        uint32_t g = (uint32_t)(band * 36);               /* 0..252 */
        uint32_t v = 0xff000000u | (g << 16) | (g << 8) | g;
        for (int x = 0; x < PANEL_W; x++) px[y * PANEL_W + x] = v;
    }
    printf("filled 8 grey bands\n");

    int rc = 0;
    if (set_scheme(SCHEME_HANDWRITE) != 0) {
        printf("could not enter handwrite scheme; nothing else to try\n");
        rc = 1;
        goto out;
    }

    struct upd u;
    memset(&u, 0, sizeof u);
    u.rect[0] = 0;
    u.rect[1] = 0;
    u.rect[2] = PANEL_W;
    u.rect[3] = PANEL_H;
    u.waveform_mode = wf;
    u.update_mode = 1;            /* full drive */
    u.update_marker = 0x4857;     /* 'HW' -- greppable in the driver log */
    u.temp = 0x1000;              /* TEMP_USE_AMBIENT */
    u.flags = flags;              /* 0x31000 from the stock stack, | bit 18 */

    errno = 0;
    int r = ioctl(fd, EBC_SEND_UPDATE, &u);
    printf("  SEND_UPDATE wf=%d flags=0x%x : rc=%d errno=%d (%s)\n",
           wf, (unsigned)flags, r, errno, errno ? strerror(errno) : "ok");

    /* Give the waveform time to run before taking the scheme away again;
     * a full GC16 flash is a few hundred ms. */
    usleep(1200 * 1000);

out:
    set_scheme(SCHEME_NORMAL);
    munmap(p, n);
    close(fd);
    return rc;
}
