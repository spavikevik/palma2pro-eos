/*
 * ebcextbuf -- probe the driver's out-of-band image path.
 *
 * WHY
 * ---
 * Everything we draw reaches the panel through the compositor: SurfaceFlinger
 * composites, the vendor composer commits, and the kernel copies pixels out of
 * the DRM plane's framebuffer per update rectangle. That is fine for normal use
 * and useless for anything that has to draw when the compositor is not running
 * -- a lock screensaver, a settle pass after motion, a daemon-driven refresh.
 *
 * The obvious alternative, EBC_SEND_UPDATE straight to /dev/ebc, blanks the
 * panel: it refreshes from the EBC framebuffer, which nothing in our stack ever
 * writes, so it faithfully repaints an empty buffer. That is issue #2.
 *
 * The driver has a second path. From the shipped kernel (docs/22):
 *
 *     onyx_tcon_display_extbuf
 *     onyx_tcon_display_extbuf_backup_from_fb
 *     _onyx_epdc_extbuf_convert_gray
 *     "extbuf[%p] width[%d] height[%d] convert_gray[%d]"
 *     "SET_EBC_EXTBUF_SYNC_FB_ENABLE set fb_update_time[%lld]."
 *
 * so a caller can apparently hand over a buffer with dimensions and have it
 * displayed. This tool probes that, one ioctl at a time, printing what the
 * kernel returns so the driver's own debug output can be read alongside.
 *
 * SAFETY
 * ------
 * EBC_GET_BUFFER (0x7000) blocks forever on this device and needs a hard power
 * cycle -- it is never called here, deliberately. Every other command is issued
 * only when named on the command line, so nothing happens by accident.
 *
 * Run with the driver narrating:
 *     adb shell 'echo 4 > /sys/devices/virtual/sepdc/debug/debug_level'
 *     adb shell /data/local/tmp/ebcextbuf info
 *     adb shell /data/local/tmp/ebcextbuf syncfb 1
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

/* Recovered from the ioctl jump table; see docs/22 section 8.3. The five marked
 * [V] reproduce numbers obtained independently by disassembly. */
#define EBC_GET_BUFFER                  0x7000  /* [V] NEVER CALL -- hangs */
#define EBC_SEND_BUFFER                 0x7001  /* [V] */
#define EBC_GET_DRIVER_SN               0x7002  /* [V] */
#define EBC_GET_BUFFER_INFO             0x7003  /* [V] */
#define EBC_LUT_ENABLE                  0x7004
#define EBC_UPDATE_SCHEME               0x7006
#define EBC_SEND_UPDATE                 0x700c  /* [V] the working submit */
#define EBC_CLEAR_ALL_UPDATE            0x700f
#define EBC_WAIT_ALL_UPDATE_COMPLETE    0x7010
#define EBC_UPD_LIST_SIZE               0x7016
#define EBC_EXTBUF_SYNC_FB_ENABLE       0x701f  /* the out-of-band path */

#define PANEL_W 1648
#define PANEL_H 824

/* Same 40-byte layout the shim submits; see docs/19 and docs/22 section 2.1.
 * Field names follow NXP's mxcfb_update_data, which this is derived from. */
struct upd {
    int32_t rect[4];
    int32_t waveform_mode;
    int32_t update_mode;
    int32_t update_marker;
    int32_t temp;
    int32_t flags;
    int32_t dither_mode;
};

/* The driver prints width/height/convert_gray for extbuf, so it takes at least
 * those. Layout is a guess -- the point of the probe is to find out. */
struct extbuf_guess {
    uint64_t addr;
    int32_t  width;
    int32_t  height;
    int32_t  convert_gray;
    int32_t  pad;
};

static int ebc_fd = -1;

static int call(unsigned long cmd, void *arg, const char *label)
{
    errno = 0;
    int r = ioctl(ebc_fd, cmd, arg);
    printf("  ioctl 0x%04lx %-26s -> rc=%d errno=%d (%s)\n",
           cmd, label, r, errno, errno ? strerror(errno) : "ok");
    return r;
}

static void usage(void)
{
    printf(
        "usage: ebcextbuf <command>\n"
        "  info            EBC_GET_BUFFER_INFO   (safe, read-only)\n"
        "  sn              EBC_GET_DRIVER_SN     (safe, read-only)\n"
        "  listsize        EBC_UPD_LIST_SIZE\n"
        "  syncfb <0|1>    EBC_EXTBUF_SYNC_FB_ENABLE\n"
        "  extbuf <file>   allocate a buffer, fill from file, try to display\n"
        "\n"
        "EBC_GET_BUFFER (0x7000) is deliberately not reachable: it blocks\n"
        "forever on this device and needs a hard power cycle.\n");
}

int main(int argc, char **argv)
{
    if (argc < 2) { usage(); return 2; }

    ebc_fd = open("/dev/ebc", O_RDWR);
    if (ebc_fd < 0) {
        printf("open(/dev/ebc): %s\n", strerror(errno));
        return 1;
    }
    printf("/dev/ebc fd=%d\n", ebc_fd);

    if (!strcmp(argv[1], "info")) {
        /* Geometry struct is unknown; give the kernel more room than it can
         * plausibly need so a larger-than-expected copy_to_user cannot corrupt
         * our stack. */
        unsigned char buf[256];
        memset(buf, 0, sizeof buf);
        call(EBC_GET_BUFFER_INFO, buf, "GET_BUFFER_INFO");
        printf("  first 64 bytes:\n   ");
        for (int i = 0; i < 64; i++) {
            printf(" %02x", buf[i]);
            if ((i & 15) == 15 && i != 63) printf("\n   ");
        }
        printf("\n");
        /* Interpret the head as u32s -- geometry usually lands here. */
        uint32_t *w = (uint32_t *)buf;
        printf("  as u32: %u %u %u %u %u %u %u %u\n",
               w[0], w[1], w[2], w[3], w[4], w[5], w[6], w[7]);
    } else if (!strcmp(argv[1], "sn")) {
        unsigned char buf[128];
        memset(buf, 0, sizeof buf);
        call(EBC_GET_DRIVER_SN, buf, "GET_DRIVER_SN");
        printf("  as text: %.63s\n", (char *)buf);
    } else if (!strcmp(argv[1], "listsize")) {
        int v = 0;
        call(EBC_UPD_LIST_SIZE, &v, "UPD_LIST_SIZE");
        printf("  value=%d\n", v);
    } else if (!strcmp(argv[1], "syncfb")) {
        if (argc < 3) { usage(); return 2; }
        int v = atoi(argv[2]);
        /* Try as pointer-to-int first, then as a direct value: setters in this
         * driver are inconsistent about which they take, and a wrong guess
         * shows up as EFAULT or EINVAL rather than doing damage. */
        call(EBC_EXTBUF_SYNC_FB_ENABLE, &v, "EXTBUF_SYNC_FB_ENABLE(&v)");
        call(EBC_EXTBUF_SYNC_FB_ENABLE, (void *)(long)v,
             "EXTBUF_SYNC_FB_ENABLE(v)");
    } else if (!strcmp(argv[1], "extbuf")) {
        if (argc < 3) { usage(); return 2; }
        FILE *f = fopen(argv[2], "rb");
        if (!f) { printf("open %s: %s\n", argv[2], strerror(errno)); return 1; }

        size_t n = (size_t)PANEL_W * PANEL_H;
        void *mem = mmap(NULL, n, PROT_READ | PROT_WRITE,
                         MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
        if (mem == MAP_FAILED) { printf("mmap: %s\n", strerror(errno)); return 1; }
        memset(mem, 0xff, n);                       /* white */
        size_t got = fread(mem, 1, n, f);
        fclose(f);
        printf("  buffer %p, %zu bytes, %zu read from file\n", mem, n, got);

        struct extbuf_guess eb;
        memset(&eb, 0, sizeof eb);
        eb.addr = (uint64_t)(uintptr_t)mem;
        eb.width = PANEL_W;
        eb.height = PANEL_H;
        eb.convert_gray = 0;
        call(EBC_EXTBUF_SYNC_FB_ENABLE, &eb, "EXTBUF(struct)");

        struct upd u;
        memset(&u, 0, sizeof u);
        u.rect[0] = 0; u.rect[1] = 0; u.rect[2] = PANEL_W; u.rect[3] = PANEL_H;
        u.waveform_mode = 2;        /* GC16 */
        u.update_mode = 1;          /* full drive */
        u.update_marker = 0x5150;
        u.temp = 0x1000;            /* TEMP_USE_AMBIENT */
        u.flags = 0x31000;          /* captured from stock */
        call(EBC_SEND_UPDATE, &u, "SEND_UPDATE");
    } else if (!strcmp(argv[1], "raw")) {
        /* Arbitrary command, for controlled probing. Always probe a number that
         * is ABSENT from the jump table first (0x7005, 0x7028) -- if the default
         * case also returns 0 then rc==0 proves nothing about a command being
         * implemented, and every "it worked" reading is worthless. */
        unsigned long cmd = strtoul(argv[2], NULL, 0);
        if (cmd == EBC_GET_BUFFER) {
            printf("  refusing 0x7000: blocks forever, needs a power cycle\n");
            return 3;
        }
        /* Always hand the kernel a PAGE, never a small stack variable.
         *
         * Probing with `long v; ioctl(fd, cmd, &v)` rebooted this device. The
         * command numbers are fine; the argument is not. These setters expect
         * sizeable structs, and copy_from_user reads whatever follows an 8-byte
         * local -- stack garbage interpreted as pointers and lengths. A zeroed
         * page is large enough for any of them and contains no addresses. */
        static unsigned char page[4096] __attribute__((aligned(4096)));
        memset(page, 0, sizeof page);
        if (argc > 3) {
            long v = strtol(argv[3], NULL, 0);
            memcpy(page, &v, sizeof v);
        }
        call(cmd, page, "raw(page)");
        printf("  first u32s: %u %u %u %u\n",
               ((uint32_t *)page)[0], ((uint32_t *)page)[1],
               ((uint32_t *)page)[2], ((uint32_t *)page)[3]);
    } else {
        usage();
        return 2;
    }

    close(ebc_fd);
    return 0;
}
