/*
 * ebcprobe -- find, one step at a time, which part of the EBC update path
 * wedges this device.
 *
 * WHY THIS EXISTS
 * ---------------
 * `ebctool refresh 2 --go` took the whole system down: USB dropped, adb gone,
 * only a hard power-off recovered it. That command did four things at once --
 * GET_EBC_BUFFER, mmap, draw a full-screen block, submit a full-screen update --
 * so it told us nothing about which one was fatal. pstore was empty after the
 * power-off, so there was no kernel log either.
 *
 * This runs exactly ONE stage per invocation and journals its progress to a file
 * with fsync() after every line, so the last surviving line names the step that
 * hung even when nothing else comes back.
 *
 * Stages, in increasing order of risk:
 *
 *   0  info        GET_EBC_BUFFER_INFO. Already known safe.
 *   1  getbuf      GET_EBC_BUFFER. Read-only ioctl; prints the raw words.
 *   2  map         mmap the region. No access.
 *   3  read        mmap and READ one page. No write, no ioctl.
 *   4  write       mmap and write a small block. No update submitted.
 *   5  update      submit a SMALL-rect update. flags/marker configurable.
 *
 * A note on the buffer offset: `ebctool info` decoded offset=631979448 and
 * epd_mode=-128, and the physical-size fields came out as nonsense. That means
 * struct ebc_buf_info does NOT match this driver, and mmap()ing at that offset
 * -- which is what `refresh` did -- may well be what killed it. Stages 2-4 are
 * split precisely so that can be established rather than assumed.
 *
 * Usage:
 *   ebcprobe <stage> [--log FILE] [--rect W H] [--flags N] [--marker N]
 *                    [--mode N] [--offset N]
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

#define EBC_DEVICE           "/dev/ebc"
#define EBC_GET_BUFFER       0x7000
#define EBC_GET_BUFFER_INFO  0x7003
#define EBC_SEND_UPDATE      0x700c

static int log_fd = -1;

/* Journal a line and force it to storage. A wedged kernel gives us no second
 * chance, so buffering here would lose the very line that matters. */
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
    if (log_fd >= 0) {
        ssize_t w = write(log_fd, buf, n);
        (void)w;
        fsync(log_fd);
    }
}

static void dump_words(const char *label, const int32_t *w, int count)
{
    char line[512];
    int off = snprintf(line, sizeof line, "%s:", label);
    for (int i = 0; i < count && off < (int)sizeof line - 16; i++)
        off += snprintf(line + off, sizeof line - off, " %d", w[i]);
    jot("%s", line);
}

struct ebc_send_update {
    int32_t rect[4];
    int32_t waveform_mode;
    int32_t update_mode;
    int32_t update_marker;
    int32_t unknown_1c;
    int32_t flags;
    int32_t unknown_24;
};

int main(int argc, char **argv)
{
    if (argc < 2) {
        fprintf(stderr,
            "usage: %s <stage 0..5> [--log FILE] [--rect W H] [--flags N]\n"
            "          [--marker N] [--mode N] [--offset N]\n", argv[0]);
        return 2;
    }

    int stage = atoi(argv[1]);
    int rw = 64, rh = 64, flags = 0, marker = 1, mode = 2;
    long forced_offset = -1;
    const char *logpath = NULL;

    for (int i = 2; i < argc; i++) {
        if (!strcmp(argv[i], "--log")   && i + 1 < argc) logpath = argv[++i];
        else if (!strcmp(argv[i], "--rect") && i + 2 < argc) { rw = atoi(argv[++i]); rh = atoi(argv[++i]); }
        else if (!strcmp(argv[i], "--flags")  && i + 1 < argc) flags  = (int)strtol(argv[++i], NULL, 0);
        else if (!strcmp(argv[i], "--marker") && i + 1 < argc) marker = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--mode")   && i + 1 < argc) mode   = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--offset") && i + 1 < argc) forced_offset = strtol(argv[++i], NULL, 0);
    }

    if (logpath) {
        log_fd = open(logpath, O_WRONLY | O_CREAT | O_APPEND, 0644);
        if (log_fd < 0) fprintf(stderr, "warn: cannot open log %s: %s\n",
                                logpath, strerror(errno));
    }

    jot("=== ebcprobe stage %d (pid %d) ===", stage, getpid());

    jot("opening " EBC_DEVICE);
    int fd = open(EBC_DEVICE, O_RDWR);
    if (fd < 0) { jot("open failed: %s", strerror(errno)); return 1; }
    jot("open ok, fd=%d", fd);

    /* Stage 0 -- the known-safe read. */
    int32_t info[16];
    memset(info, 0, sizeof info);
    jot("ioctl GET_EBC_BUFFER_INFO (0x%x)", EBC_GET_BUFFER_INFO);
    int rc = ioctl(fd, EBC_GET_BUFFER_INFO, info);
    jot("  rc=%d errno=%d", rc, rc < 0 ? errno : 0);
    dump_words("  info words", info, 12);
    if (stage == 0) { jot("stage 0 done"); return 0; }

    /* Stage 1 -- GET_EBC_BUFFER. Read-only, but a different handler. */
    int32_t buf[16];
    memset(buf, 0, sizeof buf);
    jot("ioctl GET_EBC_BUFFER (0x%x)", EBC_GET_BUFFER);
    rc = ioctl(fd, EBC_GET_BUFFER, buf);
    jot("  rc=%d errno=%d", rc, rc < 0 ? errno : 0);
    dump_words("  buf words", buf, 12);
    if (stage == 1) { jot("stage 1 done"); return 0; }

    /* Stage 2 -- mmap only.
     *
     * Which word is the offset is NOT settled (see the header note), so it is
     * printed and can be overridden rather than trusted. Mapping one page is
     * enough to prove whether mmap itself is survivable. */
    long off = forced_offset >= 0 ? forced_offset : 0;
    long len = (long)rw * rh * 4;
    if (len < 4096) len = 4096;
    jot("mmap offset=%ld len=%ld", off, len);
    void *p = mmap(NULL, len, PROT_READ | PROT_WRITE, MAP_SHARED, fd, off);
    if (p == MAP_FAILED) { jot("  mmap failed: %s", strerror(errno)); return 1; }
    jot("  mmap ok at %p", p);
    if (stage == 2) { jot("stage 2 done (not touching the mapping)"); return 0; }

    /* Stage 3 -- read one page of the mapping. */
    jot("reading 4096 bytes from the mapping");
    volatile const uint8_t *r = (const uint8_t *)p;
    uint32_t sum = 0;
    for (int i = 0; i < 4096; i++) sum += r[i];
    jot("  read ok, checksum=%u", sum);
    if (stage == 3) { jot("stage 3 done"); return 0; }

    /* Stage 4 -- write a small block into the mapping. No update submitted. */
    jot("writing %dx%d block into the mapping", rw, rh);
    memset(p, 0x00, (size_t)len);
    jot("  write ok");
    if (stage == 4) { jot("stage 4 done (no update submitted)"); return 0; }

    /* Stage 5 -- submit a SMALL update.
     *
     * `ebctool refresh` submitted (0,0)-(1648,824) with flags 0x21000. Both are
     * reduced here: the smallest useful rect, and flags 0 unless overridden,
     * since the handler bit-tests 16/17/18 and we do not know what they select. */
    struct ebc_send_update u;
    memset(&u, 0, sizeof u);
    u.rect[0] = 0; u.rect[1] = 0; u.rect[2] = rw; u.rect[3] = rh;
    u.waveform_mode = mode;
    u.update_mode = 1;
    u.update_marker = marker;
    u.flags = flags;
    jot("SET_EBC_SEND_UPDATE rect=(0,0)-(%d,%d) mode=%d marker=%d flags=0x%x",
        rw, rh, mode, marker, flags);
    jot("  >>> submitting now; if the log stops here, THIS is what hangs");
    rc = ioctl(fd, EBC_SEND_UPDATE, &u);
    jot("  rc=%d errno=%d", rc, rc < 0 ? errno : 0);
    jot("stage 5 done -- survived");
    return 0;
}
