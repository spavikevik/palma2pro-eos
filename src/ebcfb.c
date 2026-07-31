/*
 * ebcfb -- read-only inspection of the EPD framebuffer.
 *
 * WHY THIS EXISTS
 * ---------------
 * With Onyx's SurfaceFlinger running, the panel stays blank even though:
 *   - the right panel is bound (dsi_display_bind: 'qcom,mdss_dsi_epdc_cmd')
 *   - SF composites full-panel 1648x824 planes, which is exactly what
 *     __sde_plane_atomic_update_epdc requires (it rejects anything whose
 *     fb width/height does not equal the panel's -- see docs/11)
 *   - SET_EBC_SEND_UPDATE is accepted by the kernel (rc=0, and the driver
 *     logs the rect back)
 *
 * That leaves one unanswered question, and it splits the problem in half:
 *
 *     Does the framebuffer the panel scans out actually CONTAIN the UI?
 *
 *   content present -> the blit works; the fault is in the update/waveform
 *                      path (wrong flags, wrong waveform, PMIC not powered)
 *   content absent  -> __sde_plane_atomic_update_epdc is not reaching the
 *                      blit at all, and the plane checks are a red herring
 *
 * Guessing has cost us a lot on this port already. This measures instead.
 *
 * SAFETY
 * ------
 * Read-only by construction. It issues exactly one ioctl,
 * EBC_GET_BUFFER_INFO (0x7003), which ebcrefresh already calls on every run
 * without incident, and then mmap()s PROT_READ.
 *
 * It deliberately does NOT touch EBC_GET_BUFFER (0x7000): that blocks forever
 * on this device, proven three separate times with SF and the composer both
 * stopped. See docs/11. Nothing here may wait on the driver.
 */

#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <unistd.h>

#define EBC_DEVICE          "/dev/ebc"
#define EBC_GET_BUFFER_INFO 0x7003   /* Onyx numbering (+1 vs upstream) */

int main(int argc, char **argv)
{
    size_t map_len = 0;
    int words = 32;

    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--len") && i + 1 < argc)
            map_len = (size_t)strtoul(argv[++i], NULL, 0);
        else if (!strcmp(argv[i], "--words") && i + 1 < argc)
            words = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--help")) {
            printf("usage: %s [--len BYTES] [--words N]\n"
                   "  dumps EBC_GET_BUFFER_INFO then mmaps the buffer read-only\n",
                   argv[0]);
            return 0;
        }
    }

    int fd = open(EBC_DEVICE, O_RDWR);
    if (fd < 0) {
        fprintf(stderr, "open %s: %s\n", EBC_DEVICE, strerror(errno));
        return 1;
    }

    /* Oversized and zeroed: we do not know the struct length, so let the
     * driver write whatever it writes and show all of it. */
    int32_t info[64];
    memset(info, 0, sizeof info);
    int rc = ioctl(fd, EBC_GET_BUFFER_INFO, info);
    printf("EBC_GET_BUFFER_INFO -> rc=%d%s\n", rc,
           rc < 0 ? strerror(errno) : "");
    if (words > 64) words = 64;
    for (int i = 0; i < words; i++)
        printf("  [%2d] %10d  0x%08x\n", i, info[i], (uint32_t)info[i]);

    if (!map_len) {
        /* Default to one 8-bit-per-pixel panel's worth, rounded up. */
        int w = info[3] > 0 ? info[3] : 1648;
        int h = info[2] > 0 ? info[2] : 824;
        map_len = (size_t)w * (size_t)h;
    }
    map_len = (map_len + 0xfff) & ~(size_t)0xfff;

    void *p = mmap(NULL, map_len, PROT_READ, MAP_SHARED, fd, 0);
    if (p == MAP_FAILED) {
        fprintf(stderr, "mmap %zu: %s\n", map_len, strerror(errno));
        close(fd);
        return 2;
    }
    printf("\nmmap ok: %zu bytes at %p\n", map_len, p);

    /* A blank panel buffer is one repeated value. Real composited content is
     * not. A histogram tells those apart without needing to decode the
     * pixel format, which we do not know for certain. */
    unsigned long hist[256];
    memset(hist, 0, sizeof hist);
    const unsigned char *b = p;
    for (size_t i = 0; i < map_len; i++)
        hist[b[i]]++;

    int distinct = 0;
    unsigned long top = 0;
    int topval = 0;
    for (int i = 0; i < 256; i++) {
        if (hist[i]) distinct++;
        if (hist[i] > top) { top = hist[i]; topval = i; }
    }
    printf("distinct byte values: %d\n", distinct);
    printf("most common: 0x%02x  %lu/%zu (%.1f%%)\n",
           topval, top, map_len, 100.0 * (double)top / (double)map_len);
    printf("verdict: %s\n",
           distinct <= 2 ? "UNIFORM -- no image content in this buffer"
                         : "VARIED -- buffer holds real content");

    printf("\nfirst 64 bytes:");
    for (int i = 0; i < 64; i++) {
        if (i % 16 == 0) printf("\n  %04x  ", i);
        printf("%02x ", b[i]);
    }
    /* Sample a row from the middle of the panel, where UI content would be. */
    size_t mid = map_len / 2;
    printf("\n\nmid-buffer (offset 0x%zx):", mid);
    for (int i = 0; i < 64; i++) {
        if (i % 16 == 0) printf("\n  %04zx  ", mid + (size_t)i);
        printf("%02x ", b[mid + (size_t)i]);
    }
    printf("\n");

    munmap(p, map_len);
    close(fd);
    return 0;
}
