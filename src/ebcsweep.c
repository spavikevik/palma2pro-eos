/*
 * ebcsweep -- issue one EPD ioctl with a safe argument and let the driver name it.
 *
 * WHY ONE COMMAND PER PROCESS
 * ---------------------------
 * At least one command in this range blocks forever (0x7000), and at least one
 * more looks like it might: case 0x7019 calls prepare_to_wait_event() and
 * schedule(). A loop inside a single process would stop dead at the first of
 * those and take the rest of the sweep with it. Running one command per
 * invocation means the caller can put a `timeout` in front and keep going.
 *
 * WHY A ZEROED PAGE
 * -----------------
 * Two rules learned the hard way, both documented in docs/22 section 8.6:
 *
 *   - Never hand a setter a small stack variable. `long v; ioctl(fd, cmd, &v)`
 *     REBOOTED this device: these commands copy sizeable structs in, and
 *     copy_from_user reads whatever follows an 8-byte local -- stack garbage
 *     read as pointers and lengths.
 *   - Probe with ZERO, not with a distinctive value. Sweeping with 4321 to get a
 *     read-back signal left the panel rendering inverted, because some of these
 *     commands do things: 0x7014 is a gamma table and 0x7026 is the colour
 *     filter array. Zero identifies a command just as well, because the driver
 *     logs the name regardless of payload.
 *
 * Driver state is not persistent, so a reboot is the reliable undo for anything
 * this disturbs.
 *
 * USAGE
 *   adb shell 'echo 4294967295 > /sys/devices/virtual/sepdc/debug/debug_level'
 *   adb shell 'timeout 5 /data/local/tmp/ebcsweep 0x7011'
 *   adb shell 'echo 0 > /sys/devices/virtual/sepdc/debug/debug_level'
 *
 * debug_level is a BIT FIELD, not a level -- see docs/22 section 9.4.1. Writing
 * small numbers into it is why so many commands were previously recorded as
 * "logs nothing".
 */

#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>

#define EBC_GET_BUFFER 0x7000

int main(int argc, char **argv)
{
    if (argc < 2) {
        fprintf(stderr, "usage: %s <cmd> [u32 value]\n", argv[0]);
        return 2;
    }
    unsigned long cmd = strtoul(argv[1], NULL, 0);

    if (cmd == EBC_GET_BUFFER) {
        printf("0x%04lx REFUSED (blocks forever, needs a power cycle)\n", cmd);
        return 3;
    }

    int fd = open("/dev/ebc", O_RDWR);
    if (fd < 0) {
        printf("open(/dev/ebc): %s\n", strerror(errno));
        return 1;
    }

    static unsigned char page[4096] __attribute__((aligned(4096)));
    memset(page, 0, sizeof page);
    if (argc > 2) ((unsigned int *)page)[0] = (unsigned int)strtoul(argv[2], NULL, 0);

    errno = 0;
    int r = ioctl(fd, cmd, page);
    printf("0x%04lx rc=%d errno=%d (%s)  out: %08x %08x %08x %08x\n",
           cmd, r, errno, errno ? strerror(errno) : "ok",
           ((unsigned int *)page)[0], ((unsigned int *)page)[1],
           ((unsigned int *)page)[2], ((unsigned int *)page)[3]);

    close(fd);
    return 0;
}
