/* ebccfa -- toggle the driver's colour filter array mode.
 *
 * The panel is ED061KC1 and onyx_epdc_parse_dt() reports cfa_mode[1017], so a
 * colour filter array is configured in hardware. epdc_ioctl case 0x7026 logs
 * "%s(): %s cfa mode!" -- an enable/disable pair.
 *
 * Handle with care. 0x7026 was one of two commands implicated when a blind
 * probe sweep left the panel rendering inverted (docs/22 8.6). That sweep passed
 * 4321 as the payload; this passes 0 or 1, which is what the command expects.
 * A reboot clears driver state completely either way -- gamma, LUTs, cfa are
 * none of them persistent -- so the worst case is one power cycle.
 */
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>

#define EBC_ENABLE_CFA_MODE 0x7026

int main(int argc, char **argv)
{
    int on = (argc > 1) ? atoi(argv[1]) : 1;
    int fd = open("/dev/ebc", O_RDWR);
    if (fd < 0) { printf("open: %s\n", strerror(errno)); return 1; }

    /* Hand over a zeroed page, not a stack int: these setters copy a struct in,
     * and passing an 8-byte local rebooted this device once already. */
    static unsigned char page[4096] __attribute__((aligned(4096)));
    memset(page, 0, sizeof page);
    ((int *)page)[0] = on;

    errno = 0;
    int r = ioctl(fd, EBC_ENABLE_CFA_MODE, page);
    printf("cfa <- %d : rc=%d errno=%d (%s)\n",
           on, r, errno, errno ? strerror(errno) : "ok");
    close(fd);
    return 0;
}
