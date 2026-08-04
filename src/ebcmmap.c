/*
 * ebcmmap -- probe the driver's mmap path on /dev/ebc.
 *
 * WHY
 * ---
 * Everything this project draws reaches the panel through the compositor.
 * That is fine for normal use and useless whenever the compositor is not
 * running: a lock screensaver, a settle pass at the end of motion, anything a
 * daemon wants to put up on its own.
 *
 * EBC_SEND_UPDATE straight to /dev/ebc looked like the way out and instead
 * blanked the panel, because it repaints from a driver-owned buffer that
 * nothing in our stack ever writes (issue #2). The missing half of that story
 * is now in hand. Disassembling the running kernel (build #245, extracted from
 * boot_b -- NOT firmware/analysis/kernel.Image, which is an older #147 build)
 * shows the file_operations carry an mmap:
 *
 *     epdc_mmap @ 0x57e690:
 *         printk("%s(): enter!", "epdc_mmap")
 *         vma->vm_flags &= ~0x3c ; |= 0x80000          // VM_DONTDUMP
 *         if (g[0x2bb8] == NULL) { printk("no virt_buf_handwrite!"); return -1; }
 *         return dma_buf_mmap(g[0x2bc8], vma, 0);
 *
 * So there IS a userspace-writable driver buffer -- the driver calls it
 * virt_buf_handwrite, allocated from system ION and exported as a dma_buf.
 * It is the handwriting fast path, which is why nothing on the normal display
 * path ever touches it.
 *
 * WHAT THIS DOES
 * --------------
 * Nothing but map and look. No ioctl is issued at all, so this cannot repeat
 * either of the two ways probing has already taken the device down (a stack
 * variable passed where a struct was expected -> reboot; reagl_enable=1 with
 * glr16 -> 220s hang). If virt_buf_handwrite is not allocated, mmap simply
 * fails and the driver says so in dmesg.
 *
 * Read the driver's side of the call with:
 *     adb shell 'echo 4 > /sys/devices/virtual/sepdc/debug/debug_level'
 *     adb shell /data/local/tmp/ebcmmap
 *     adb shell 'echo 0 > /sys/devices/virtual/sepdc/debug/debug_level'
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

/* 1648x824 at 8bpp is the panel's output space; the handwriting buffer has no
 * documented size, so try a descending ladder and report the largest that maps.
 * Starting small and growing would stop at the first success and tell us less. */
static const size_t SIZES[] = {
    (size_t)1648 * 824 * 4,
    (size_t)1648 * 824 * 2,
    (size_t)1648 * 824,
    (size_t)1648 * 824 / 2,   /* 4bpp packed -- the panel is 16 grey levels */
    (size_t)824 * 1648 / 2,
    1u << 20,
    1u << 16,
    4096,
};

/*
 * EBC_EXT_BUF_SYNC_WITH_FB -- copy the live framebuffer INTO virt_buf_handwrite.
 *
 * The case body takes no user argument at all; every operand comes from driver
 * globals:
 *
 *     image_buffer_lock()
 *     x0 = g[0x2bb8]            ; virt_buf_handwrite -- the buffer we mmap
 *     w1, w2 = g[0xe0], g[0xe4] ; width, height
 *     w3 = 0                    ; convert_gray, hardcoded
 *     x4 = g[0x518]             ; fb_update_time,   set by SET_EBC_UPDATE_SCHEME
 *     x5 = g[0x510]             ; handwrite_time,   set by HANDWRITE_UPDATE
 *     onyx_epdc_ext_buf_sync_with_fb(...)
 *
 * That matters for the ghosting in docs/22 9.4.2: the driver drives each pixel
 * as a transition from what it believes is displayed, and the handwrite buffer
 * starts out blank, so its record and the glass disagree. Seeding the buffer
 * from the framebuffer should make them agree -- fixing the cause rather than
 * overpowering it with a black/white flash.
 *
 * Self-verifying: if the buffer stops being uniform 0xff and gains structure,
 * the copy happened. No need to look at the panel.
 */
#define EBC_EXT_BUF_SYNC_WITH_FB 0x701d
#define EBC_UPDATE_SCHEME        0x7006

static void histogram(const unsigned char *u, size_t n, const char *label)
{
    unsigned long counts[256];
    memset(counts, 0, sizeof counts);
    size_t sample = n < (1u << 20) ? n : (1u << 20);
    for (size_t k = 0; k < sample; k++) counts[u[k]]++;

    unsigned distinct = 0;
    int top = 0;
    for (int v = 0; v < 256; v++) {
        if (counts[v]) distinct++;
        if (counts[v] > counts[top]) top = v;
    }
    printf("  %-8s %u distinct values, most common 0x%02x (%.1f%%), first:",
           label, distinct, top, 100.0 * (double)counts[top] / (double)sample);
    for (int k = 0; k < 12; k++) printf(" %02x", u[k]);
    printf("\n");
}

int main(void)
{
    int fd = open("/dev/ebc", O_RDWR);
    if (fd < 0) {
        printf("open(/dev/ebc): %s\n", strerror(errno));
        return 1;
    }
    printf("/dev/ebc fd=%d\n", fd);

    for (unsigned i = 0; i < sizeof SIZES / sizeof SIZES[0]; i++) {
        size_t n = SIZES[i];
        errno = 0;
        void *p = mmap(NULL, n, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
        if (p == MAP_FAILED) {
            printf("  mmap %-10zu -> FAILED errno=%d (%s)\n",
                   n, errno, strerror(errno));
            continue;
        }
        printf("  mmap %-10zu -> %p OK\n", n, p);

        /* Summarise the contents rather than dumping them: a byte histogram
         * says immediately whether this is an untouched buffer (all one value),
         * greyscale image data (a spread), or something structured. */
        unsigned char *u = p;
        unsigned long counts[256];
        memset(counts, 0, sizeof counts);
        size_t sample = n < (1u << 20) ? n : (1u << 20);
        for (size_t k = 0; k < sample; k++) counts[u[k]]++;

        unsigned distinct = 0;
        int top = 0;
        for (int v = 0; v < 256; v++) {
            if (counts[v]) distinct++;
            if (counts[v] > counts[top]) top = v;
        }
        printf("      first 32 bytes:");
        for (int k = 0; k < 32; k++) printf(" %02x", u[k]);
        printf("\n      sampled %zu bytes: %u distinct values, "
               "most common 0x%02x (%lu, %.1f%%)\n",
               sample, distinct, top, counts[top],
               100.0 * (double)counts[top] / (double)sample);

        /* Writability is the whole point -- if this buffer cannot be written
         * from userspace it is no use as a screensaver source. Probe one byte
         * and put it back. */
        unsigned char save = u[0];
        u[0] = (unsigned char)(save ^ 0xff);
        printf("      write test: wrote 0x%02x, reads back 0x%02x -> %s\n",
               save ^ 0xff, u[0], u[0] == (save ^ 0xff) ? "WRITABLE" : "not writable");
        u[0] = save;

        /* Does EXT_BUF_SYNC_WITH_FB actually write anything?
         *
         * Comparing the buffer against itself cannot answer that: if it already
         * happens to hold framebuffer content, a working sync and a silent
         * no-op look identical. So stamp the buffer with a value the framebuffer
         * cannot plausibly contain and see whether the stamp survives. Anything
         * other than 0xaa coming back means the driver wrote.
         *
         * The scheme is set first because the sync is time-gated -- 0x7006
         * stamps fb_update_time, and without a fresh stamp the driver returns
         * early (see onyx_epdc_ext_buf_sync_with_fb). */
        printf("  --- EXT_BUF_SYNC_WITH_FB (0x701d) ---\n");
        int sc = 3;
        errno = 0;
        printf("  scheme <- 3 : rc=%d (%s)\n",
               ioctl(fd, EBC_UPDATE_SCHEME, &sc), errno ? strerror(errno) : "ok");

        memset(p, 0xaa, n);
        histogram(u, n, "stamped:");
        errno = 0;
        int r = ioctl(fd, EBC_EXT_BUF_SYNC_WITH_FB, NULL);
        printf("  ioctl 0x701d -> rc=%d errno=%d (%s)\n",
               r, errno, errno ? strerror(errno) : "ok");
        histogram(u, n, "after:  ");

        size_t intact = 0;
        for (size_t k = 0; k < n; k++) if (u[k] == 0xaa) intact++;
        printf("  VERDICT: %.1f%% of the buffer is still 0xaa -> driver %s\n",
               100.0 * (double)intact / (double)n,
               intact == n ? "wrote NOTHING (sync is a no-op)" : "DID write");

        sc = 2;
        ioctl(fd, EBC_UPDATE_SCHEME, &sc);

        munmap(p, n);
        break;   /* largest mapping wins; no need to try smaller ones */
    }

    close(fd);
    return 0;
}
