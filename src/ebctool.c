/*
 * ebctool -- probe the Onyx EBC (E-Book Controller) display driver on
 * Boox Palma 2 Pro (and likely other Qualcomm-based Boox devices).
 *
 * Device node: /dev/ebc
 * Driver:      ONYX_EBC_DRIVER_VERSION_2.00
 *
 * Onyx ported Rockchip's EBC driver onto Qualcomm's lito platform. Command
 * numbers are plain integers from base 0x7000 -- NOT _IOR/_IOW encoded. This
 * was confirmed statically: in the stock kernel's ioctl handler, the
 * GET_EBC_BUFFER and SET_EBC_SEND_BUFFER case blocks contain literal
 * `movz w0, #0x7000` / `#0x7001`, matching upstream Rockchip numbering.
 *
 * SCOPE: read-only commands only. The update-submission path
 * (SET_EBC_SEND_UPDATE) is deliberately NOT implemented -- its struct layout
 * has not been confirmed against this driver, and submitting a malformed
 * update can wedge the display controller. `info` and `ident` give us the
 * geometry and the driver identity we need to pin that layout down first.
 *
 * Requires root, and SELinux permission to open /dev/ebc (see docs).
 *
 * Build: scripts/build-ebctool.sh   (Android NDK, aarch64)
 */

#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <unistd.h>

#define EBC_DEVICE "/dev/ebc"

/* Command numbers. The first three are upstream Rockchip and are corroborated
 * by the immediates found in this device's kernel. The rest are Onyx additions
 * whose numeric values are not yet confirmed -- they are listed by name so the
 * mapping can be filled in as it is established, not guessed at here. */
#define EBC_GET_BUFFER       0x7000  /* confirmed: literal in kernel case block */
#define EBC_SEND_BUFFER      0x7001  /* confirmed: literal in kernel case block */
#define EBC_GET_DRIVER_SN    0x7002  /* confirmed on device: returns
                                        "ONYX_EBC_DRIVER_VERSION_2.00".
                                        NOTE: upstream Rockchip puts
                                        GET_BUFFER_INFO here -- Onyx diverges. */
/* Predicted from the kernel's case-block ordering, which is ascending by
 * command number and matches the three confirmed points above. */
#define EBC_GET_BUFFER_INFO  0x7003
#define EBC_SEND_UPDATE      0x700c  /* confirmed by live interception */

/* Candidates to try when hunting for GET_EBC_DRIVER_SN. The driver answers it
 * with a version string, which makes it self-identifying and therefore a safe
 * anchor for mapping the rest of the command space. */
static const int kDriverSnCandidates[] = {
    0x7002,  /* confirmed on this device */
    0x7003, 0x7004, 0x7005, 0x7006, 0x7007, 0x7008,
};

#define DRIVER_SN_NEEDLE "ONYX_EBC_DRIVER_VERSION"

/*
 * SET_EBC_SEND_UPDATE argument -- recovered from the stock kernel's handler.
 *
 * The handler at 0x5b23f8 does:
 *     mov  w2, #0x28            size = 40 bytes
 *     add  x0, sp, #0x10        struct base
 *     bl   copy_from_user
 * so the argument is exactly 40 bytes = 10 int32 fields.
 *
 * Field evidence (sp+0x10 is struct+0x00):
 *
 *   +0x00 .. +0x0c   rect      ldp w4,w3,[sp,#0x10] / ldp w5,w6,[sp,#0x18]
 *                              feed printk "... rect[%d %d %d %d]"
 *   +0x10            waveform  ldp w9,w8,[sp,#0x20]; w9 compared against
 *                              1, 2, 3 and >3 -- a small enum
 *   +0x14            upd_mode  w8 compared against 1
 *   +0x18            marker    printk's update_marker arg; the handwriting
 *                              path adds 60000 to it and stores it back
 *   +0x1c            unknown   not read in the traced path
 *   +0x20            flags     bit-tested at 16, 17 and 18
 *   +0x24            unknown   not read in the traced path; the kernel's
 *                              commit log ends with temp[%d], so probably that
 *
 * NOT yet exercised. Sending an update also requires the buffer flow --
 * GET_EBC_BUFFER, mmap the region, draw into it, then submit -- which is the
 * next increment. Declared here so the layout is recorded where it is used.
 */
struct ebc_send_update {
    int32_t rect[4];
    int32_t waveform_mode;
    int32_t update_mode;
    int32_t update_marker;
    int32_t unknown_1c;
    int32_t flags;
    int32_t unknown_24;   /* likely temperature */
};
_Static_assert(sizeof(struct ebc_send_update) == 40,
               "kernel copy_from_user size is 0x28");

/* Upstream Rockchip layout. Field order is stable across the Rockchip trees;
 * `info` prints raw words too so a mismatch is visible rather than silent. */
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

static int open_ebc(void)
{
    int fd = open(EBC_DEVICE, O_RDWR);
    if (fd < 0) {
        fprintf(stderr, "open(%s): %s\n", EBC_DEVICE, strerror(errno));
        if (errno == EACCES || errno == EPERM) {
            fprintf(stderr,
                    "\nNeed root, and SELinux must allow this domain to open the\n"
                    "device. Check:  ls -lZ %s   and   dmesg | grep avc\n",
                    EBC_DEVICE);
        } else if (errno == ENOENT) {
            fprintf(stderr,
                    "\nNo %s. Either this is not an Onyx EBC device, or the\n"
                    "driver did not probe. Check: dmesg | grep -i ebc\n",
                    EBC_DEVICE);
        }
    }
    return fd;
}

/* Dump a returned buffer both ways. The driver has already surprised us once by
 * answering a "struct" command with a string, so never trust one view alone. */
static void dump_buffer(const void *buf, size_t len)
{
    const unsigned char *p = buf;

    printf("\n  as ascii: \"");
    for (size_t i = 0; i < len; i++)
        putchar((p[i] >= 32 && p[i] < 127) ? p[i] : (p[i] ? '.' : ' '));
    printf("\"\n");

    printf("  as int32:");
    const int32_t *w = buf;
    for (size_t i = 0; i < len / sizeof(*w); i++) {
        if (i % 6 == 0)
            printf("\n   ");
        printf(" %11d", w[i]);
    }
    printf("\n\n  as hex:");
    for (size_t i = 0; i < len; i++) {
        if (i % 16 == 0)
            printf("\n    %04zx: ", i);
        printf("%02x ", p[i]);
    }
    printf("\n");
}

static int cmd_info(int cmd)
{
    int fd = open_ebc();
    if (fd < 0)
        return 1;

    /* Over-sized so a longer-than-expected reply cannot smash the stack. */
    union {
        struct ebc_buf_info info;
        unsigned char raw[256];
    } u;
    memset(&u, 0, sizeof(u));
    struct ebc_buf_info info;

    printf(">>> ioctl(%#x) on %s\n", cmd, EBC_DEVICE);
    if (ioctl(fd, cmd, &u) < 0) {
        fprintf(stderr, "ioctl(%#x): %s\n", cmd, strerror(errno));
        close(fd);
        return 1;
    }
    memcpy(&info, &u.info, sizeof(info));

    printf("EBC buffer info (%s)\n", EBC_DEVICE);
    printf("  offset      %d\n", info.offset);
    printf("  epd_mode    %d\n", info.epd_mode);
    printf("  resolution  %d x %d\n", info.width, info.height);
    printf("  panel_color %d\n", info.panel_color);
    printf("  window      (%d,%d) - (%d,%d)\n",
           info.win_x1, info.win_y1, info.win_x2, info.win_y2);
    printf("  physical    %d mm x %d mm\n", info.width_mm, info.height_mm);

    dump_buffer(u.raw, 64);

    if (info.width > 0 && info.height > 0 && info.width < 10000 && info.height < 10000)
        printf("\n  => plausible geometry. Expected 824 x 1648 for this panel.\n");
    else
        printf("\n  => geometry implausible; this command is probably not "
               "GET_EBC_BUFFER_INFO. Try a different one.\n");

    close(fd);
    return 0;
}

static int cmd_ident(void)
{
    int fd = open_ebc();
    if (fd < 0)
        return 1;

    /* Generous buffer: we do not know the driver's expected size, so give it
     * far more room than any plausible version string needs. */
    char buf[512];
    int found = 0;

    printf("Hunting GET_EBC_DRIVER_SN (expecting a string containing \"%s\")\n\n",
           DRIVER_SN_NEEDLE);

    for (size_t i = 0; i < sizeof(kDriverSnCandidates) / sizeof(*kDriverSnCandidates); i++) {
        int cmd = kDriverSnCandidates[i];
        memset(buf, 0, sizeof(buf));

        int rc = ioctl(fd, cmd, buf);
        if (rc < 0) {
            printf("  %#06x  -> errno %d (%s)\n", cmd, errno, strerror(errno));
            continue;
        }

        buf[sizeof(buf) - 1] = '\0';
        if (strstr(buf, DRIVER_SN_NEEDLE)) {
            printf("  %#06x  -> MATCH: \"%s\"\n", cmd, buf);
            found = cmd;
        } else {
            /* Succeeded but returned something else -- worth recording, but do
             * not keep poking commands whose effects are unknown. */
            printf("  %#06x  -> rc=%d, no version string\n", cmd, rc);
        }
    }

    printf("\n");
    if (found)
        printf("GET_EBC_DRIVER_SN = %#06x\n", found);
    else
        printf("No match. The command may lie outside the probed range, or may\n"
               "expect a different argument type.\n");

    close(fd);
    return found ? 0 : 1;
}

/*
 * The userspace refresh path, Rockchip-EBC style:
 *
 *   GET_EBC_BUFFER   (0x7000)  acquire a buffer; driver fills in `offset`
 *   mmap(/dev/ebc)             map the pool, draw at `offset`
 *   SET_EBC_SEND_BUFFER(0x7001) submit; `epd_mode` picks the waveform
 *
 * SET_EBC_SEND_UPDATE is NOT used -- that belongs to the kernel-internal epdc
 * layer, whose fops are not bound to any device node on this device.
 *
 * Unknowns that are safe to get wrong: the pixel format (EBC is usually 4bpp
 * greyscale packed two pixels per byte, but this panel is colour Kaleido) and
 * the exact ebc_buf_info field order. Both only affect what is drawn, not
 * whether the controller survives -- worst case is visual garbage cleared by a
 * refresh or a reboot.
 */
static int cmd_refresh(int waveform, int submit)
{
    int fd = open_ebc();
    if (fd < 0)
        return 1;

    /* Values captured from the vendor stack via LD_PRELOAD interception --
     * see docs/03-ebc-api.md. Not guessed:
     *
     *   UPD rect=(0,0)-(1648,824) wf=2 mode=1 marker=1 f1c=4096 flags=0x31000
     *   UPD rect=(0,0)-(1648,824) wf=2 mode=1 marker=2 f1c=4096 flags=0x21000
     *
     * There is no buffer acquisition: pixel data reaches the EPDC through the
     * DRM/SDE composition path, so this call only asks for a refresh of what is
     * already on screen. That is why the earlier GET_EBC_BUFFER + mmap approach
     * was wrong -- and why it hung the device twice.
     */
    static int marker = 1;
    int32_t upd[10] = {
        0, 0, 1648, 824,   /* rect: x, y, w, h (kernel logs it this way) */
        waveform,          /* waveform_mode: 2 is the observed-good value */
        1,                 /* update_mode */
        marker++,          /* update_marker, increments per call */
        4096,              /* +0x1c */
        0x21000,           /* flags: bits 16,17 as observed */
        0                  /* +0x24 */
    };

    printf("SET_EBC_SEND_UPDATE (%#x) on %s\n", EBC_SEND_UPDATE, EBC_DEVICE);
    printf("  rect=(%d,%d)-(%d,%d) wf=%d mode=%d marker=%d f1c=%d flags=%#x f24=%d\n",
           upd[0], upd[1], upd[2], upd[3], upd[4], upd[5], upd[6], upd[7],
           (unsigned)upd[8], upd[9]);

    if (!submit) {
        printf("\nDRY RUN -- not submitted. Re-run with --go.\n");
        close(fd);
        return 0;
    }

    int rc = ioctl(fd, EBC_SEND_UPDATE, upd);
    if (rc < 0) {
        fprintf(stderr, "ioctl failed: %s\n", strerror(errno));
        close(fd);
        return 1;
    }
    printf("  -> rc=%d   (vendor stack returned 1160 then 0)\n", rc);
    close(fd);
    return 0;
}

static void usage(const char *argv0)
{
    fprintf(stderr,
        "usage: %s <command>\n"
        "\n"
        "  info [cmd]  query geometry; cmd defaults to %#x\n"
        "  ident       locate GET_EBC_DRIVER_SN and read the driver version\n"
        "  refresh [mode] [--go]   acquire buffer, mmap, draw a block, submit\n"
        "              dry-run unless --go is given; mode = epd_mode (default 1)\n"
        "\n"
        "Read-only commands only. The update path (SET_EBC_SEND_UPDATE) is not\n"
        "implemented until its struct layout is confirmed -- a malformed update\n"
        "can wedge the display controller.\n"
        "\n"
        "Needs root and SELinux access to %s.\n",
        argv0, EBC_GET_BUFFER_INFO, EBC_DEVICE);
}

int main(int argc, char **argv)
{
    /* Unbuffered: if a call hangs the kernel or the process is killed, we still
     * want every line printed up to that point. A block-buffered pipe silently
     * ate the diagnostics the one time this mattered. */
    setvbuf(stdout, NULL, _IONBF, 0);
    setvbuf(stderr, NULL, _IONBF, 0);

    if (argc < 2) {
        usage(argv[0]);
        return 2;
    }
    if (!strcmp(argv[1], "info")) {
        int cmd = (argc > 2) ? (int)strtol(argv[2], NULL, 0) : EBC_GET_BUFFER_INFO;
        return cmd_info(cmd);
    }
    if (!strcmp(argv[1], "ident"))
        return cmd_ident();
    if (!strcmp(argv[1], "refresh")) {
        int mode = 1, go = 0;
        for (int i = 2; i < argc; i++) {
            if (!strcmp(argv[i], "--go")) go = 1;
            else mode = (int)strtol(argv[i], NULL, 0);
        }
        return cmd_refresh(mode, go);
    }

    usage(argv[0]);
    return 2;
}
