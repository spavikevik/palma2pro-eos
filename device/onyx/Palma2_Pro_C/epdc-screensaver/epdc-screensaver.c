/*
 * epdc-screensaver -- paint the panel when the screen goes off.
 *
 * WHY THIS EXISTS
 * ---------------
 * An e-ink panel holds its last frame indefinitely and with no power. When the
 * device locks, Android stops compositing before the keyguard reaches the glass,
 * so whatever you were looking at stays there -- the home screen, or the page of
 * the book you were reading. The device looks unlocked, and its last screen is
 * readable by anyone who picks it up.
 *
 * WHY IT IS NOT IN SYSTEMUI
 * -------------------------
 * Three attempts were made there and all failed for the same underlying reason:
 * nothing composites at lock time. Adding a window did not help (mScreenState is
 * already OFF), and a wakelock with ACQUIRE_CAUSES_WAKEUP just cancelled the
 * sleep. Writing to /dev/ebc directly did not help either -- that path repaints
 * from a buffer nothing in the stack writes, so it blanks the panel (issue #2).
 *
 * The way out is the driver's handwriting path, which does not involve the
 * compositor at all: mmap /dev/ebc, write pixels, submit with the handwrite flag
 * set. It is documented in docs/22 section 9.4, and -- the point here -- it
 * works with the display already asleep. Verified: 99 waveform frames driven
 * with mWakefulness=Asleep.
 *
 * So this is a plain oneshot binary rather than framework code, started by init
 * when the screen turns off. No Java, no Dagger, no wakelock, no race with the
 * power manager.
 *
 * IMAGES
 * ------
 * Raw pixel planes produced by scripts/gen-screensaver.py, shipped in
 * /system/etc/epdc/screensaver and overridable from /data/misc/epdc/screensaver.
 * Geometry is inferred from file size rather than carried in a header: at the
 * panel's fixed 824x1648 there are exactly two valid sizes, and inferring them
 * avoids inventing a metadata format for two cases.
 *
 * Files are used in rotation, so a device that sleeps repeatedly does not show
 * the same picture every time.
 */

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

#define EBC_UPDATE_SCHEME   0x7006
#define EBC_SEND_UPDATE     0x700c

#define SCHEME_NORMAL       2
#define SCHEME_HANDWRITE    3

/* Without bit 18 the driver takes the ordinary path, sees scheme 3, and logs
 * "reject non HANDWRITE update". */
#define EPDC_FLAG_HANDWRITE 0x40000
#define EPDC_FLAG_STOCK     0x31000

#define PANEL_W 1648
#define PANEL_H 824

/* Content is authored portrait; the panel buffer is landscape output space.
 * The devicetree agrees: onyx_epdc_parse_dt() reports sf_rotation[270]. */
#define SRC_W 824
#define SRC_H 1648
#define ROT   270

#define SIZE_GREY ((size_t)SRC_W * SRC_H)
#define SIZE_RGB  ((size_t)SRC_W * SRC_H * 3)

/* Two directories, searched in this order.
 *
 * The shipped artwork lives in /system/etc and is read-only. Anything the user
 * drops in /data wins, so replacing the picture never means modifying the system
 * image -- and an empty /data directory falls back to what shipped rather than
 * showing nothing. */
#define EPDC_SS_USER  "/data/misc/epdc/screensaver"
#define EPDC_SS_STOCK "/system/etc/epdc/screensaver"
#define EPDC_SS_INDEX "/data/misc/epdc/screensaver.idx"

/* A full-panel GC16 is ~33 frames, a bit under half a second. */
#define PASS_MS 550

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

static int32_t next_marker(void)
{
    static int32_t n;
    return (int32_t)(((getpid() & 0x3fff) << 8) | (++n & 0xff)) | 1;
}

static int send_full(int wf)
{
    struct upd u;
    memset(&u, 0, sizeof u);
    u.rect[2] = PANEL_W;
    u.rect[3] = PANEL_H;
    u.waveform_mode = wf;
    u.update_mode = 1;                 /* full drive */
    u.update_marker = next_marker();
    u.temp = 0x1000;                   /* TEMP_USE_AMBIENT */
    u.flags = EPDC_FLAG_STOCK | EPDC_FLAG_HANDWRITE;
    return ioctl(fd, EBC_SEND_UPDATE, &u);
}

static void blit(uint32_t *dst, const unsigned char *src, int channels)
{
    for (size_t i = 0; i < (size_t)PANEL_W * PANEL_H; i++) dst[i] = 0xffffffffu;

    for (int y = 0; y < SRC_H; y++) {
        for (int x = 0; x < SRC_W; x++) {
            /* rot 270 */
            int dx = y;
            int dy = (SRC_W - 1) - x;
            if (dx < 0 || dx >= PANEL_W || dy < 0 || dy >= PANEL_H) continue;
            const unsigned char *s = &src[((size_t)y * SRC_W + x) * channels];
            uint32_t r, g, b;
            if (channels == 3) { r = s[0]; g = s[1]; b = s[2]; }
            else               { r = g = b = s[0]; }
            dst[(size_t)dy * PANEL_W + dx] =
                0xff000000u | (r << 16) | (g << 8) | b;
        }
    }
}

/* Rotate through the available images. The index is best-effort: if it cannot be
 * read or written the screensaver still works, it just stops rotating. */
static unsigned load_index(void)
{
    unsigned v = 0;
    FILE *f = fopen(EPDC_SS_INDEX, "r");
    if (f) {
        if (fscanf(f, "%u", &v) != 1) v = 0;
        fclose(f);
    }
    return v;
}

static void store_index(unsigned v)
{
    FILE *f = fopen(EPDC_SS_INDEX, "w");
    if (f) { fprintf(f, "%u\n", v); fclose(f); }
}

static int scan(const char *dir, char names[][256], int n, int max)
{
    DIR *d = opendir(dir);
    if (!d) return n;
    struct dirent *e;
    while ((e = readdir(d)) && n < max) {
        size_t len = strlen(e->d_name);
        if (len < 5 || strcmp(e->d_name + len - 4, ".raw") != 0) continue;
        snprintf(names[n], sizeof names[n], "%s", e->d_name);
        n++;
    }
    closedir(d);
    return n;
}

static int pick(char *out, size_t outsz)
{
    char names[64][256];
    const char *dir = EPDC_SS_USER;
    int n = scan(EPDC_SS_USER, names, 0, 64);
    if (n == 0) {
        dir = EPDC_SS_STOCK;
        n = scan(EPDC_SS_STOCK, names, 0, 64);
    }
    if (n == 0) return -1;

    /* Sort so the rotation order is stable across boots; readdir order is not. */
    for (int i = 1; i < n; i++) {
        char tmp[256];
        snprintf(tmp, sizeof tmp, "%s", names[i]);
        int j = i - 1;
        while (j >= 0 && strcmp(names[j], tmp) > 0) {
            snprintf(names[j + 1], sizeof names[j + 1], "%s", names[j]);
            j--;
        }
        snprintf(names[j + 1], sizeof names[j + 1], "%s", tmp);
    }

    unsigned idx = load_index() % (unsigned)n;
    store_index((idx + 1) % (unsigned)n);
    snprintf(out, outsz, "%s/%s", dir, names[idx]);
    return 0;
}

int main(void)
{
    char path[512];
    if (pick(path, sizeof path) != 0) {
        /* No artwork installed is not an error -- the feature is simply off. */
        return 0;
    }

    struct stat st;
    if (stat(path, &st) != 0) return 1;

    int channels;
    if ((size_t)st.st_size == SIZE_RGB)       channels = 3;
    else if ((size_t)st.st_size == SIZE_GREY) channels = 1;
    else {
        fprintf(stderr, "epdc-screensaver: %s is %lld bytes, expected %zu or %zu\n",
                path, (long long)st.st_size, SIZE_GREY, SIZE_RGB);
        return 1;
    }

    unsigned char *src = malloc((size_t)st.st_size);
    if (!src) return 1;
    FILE *f = fopen(path, "rb");
    if (!f) { free(src); return 1; }
    size_t got = fread(src, 1, (size_t)st.st_size, f);
    fclose(f);
    if (got != (size_t)st.st_size) { free(src); return 1; }

    fd = open("/dev/ebc", O_RDWR);
    if (fd < 0) {
        fprintf(stderr, "epdc-screensaver: /dev/ebc: %s\n", strerror(errno));
        free(src);
        return 1;
    }

    size_t n = (size_t)PANEL_W * PANEL_H * 4;
    uint32_t *dst = mmap(NULL, n, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (dst == MAP_FAILED) {
        fprintf(stderr, "epdc-screensaver: mmap: %s\n", strerror(errno));
        close(fd);
        free(src);
        return 1;
    }

    if (set_scheme(SCHEME_HANDWRITE) != 0) {
        fprintf(stderr, "epdc-screensaver: scheme: %s\n", strerror(errno));
        munmap(dst, n);
        close(fd);
        free(src);
        return 1;
    }

    /* Flash both rails before the image.
     *
     * The driver drives each pixel as a transition from what it believes is
     * displayed, and it keeps a HANDWRITE-SPECIFIC record of that which only
     * handwrite updates refresh. The compositor has just been drawing, so that
     * record is stale and a single pass ghosts the old screen through the new
     * one. Saturating black then white makes the starting state irrelevant.
     *
     * This is the only thing that works: seeding the buffer from the framebuffer
     * (ioctl 0x701d) and the driver's own panel_clean were both tried and both
     * still ghost. See docs/22 section 9.4.2.
     *
     * Nobody is looking at the panel during this -- the screen is already off --
     * so the ~1.1s and the visible flashing cost nothing here.
     */
    static const uint32_t rails[2] = { 0xff000000u, 0xffffffffu };
    for (int pass = 0; pass < 2; pass++) {
        for (size_t i = 0; i < (size_t)PANEL_W * PANEL_H; i++) dst[i] = rails[pass];
        if (send_full(2) != 0) break;
        usleep(PASS_MS * 1000);
    }

    blit(dst, src, channels);
    free(src);

    if (send_full(2) != 0)
        fprintf(stderr, "epdc-screensaver: update: %s\n", strerror(errno));
    usleep(PASS_MS * 1000);

    /* Always hand the display back, or the compositor stays locked out and the
     * device appears frozen on the next wake. */
    set_scheme(SCHEME_NORMAL);
    munmap(dst, n);
    close(fd);
    return 0;
}
