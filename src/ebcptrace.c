/*
 * ebcptrace -- ptrace-based ioctl tracer for the Onyx EBC driver.
 *
 * Why not LD_PRELOAD: init grants SurfaceFlinger capabilities, which sets
 * AT_SECURE, and bionic ignores LD_PRELOAD for AT_SECURE processes. Launching
 * SF outside init makes the preload work but the framework never finishes
 * booting (no init uid / SELinux context / socket handoff). ptrace attaches to
 * the already-running, correctly-started process, so it sidesteps both.
 *
 * Attaches to every thread of the target, single-steps syscalls, and logs
 * ioctl() calls whose request number is in the EBC range. Detaches cleanly
 * after a bounded window -- stopping SF on every syscall is expensive and a
 * long trace risks a watchdog kill.
 *
 * READ-ONLY with respect to the driver: it observes, never originates.
 *
 * usage: ebcptrace <pid> <seconds>
 */

#define _GNU_SOURCE
#include <dirent.h>
#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ptrace.h>
#include <sys/uio.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#ifndef PTRACE_SEIZE
#define PTRACE_SEIZE 0x4206
#endif
#ifndef PTRACE_INTERRUPT
#define PTRACE_INTERRUPT 0x4207
#endif
#ifndef NT_PRSTATUS
#define NT_PRSTATUS 1
#endif

#define AARCH64_NR_ioctl 29
#define EBC_LO 0x7000
#define EBC_HI 0x7300
#define MAXTID 65536

struct arm64_regs {
    uint64_t regs[31];
    uint64_t sp, pc, pstate;
};

static unsigned char in_syscall[MAXTID];

static int read_regs(pid_t tid, struct arm64_regs *r)
{
    struct iovec io = { .iov_base = r, .iov_len = sizeof(*r) };
    return ptrace(PTRACE_GETREGSET, tid, (void *)NT_PRSTATUS, &io);
}

static int peek_mem(pid_t pid, uint64_t addr, void *out, size_t len)
{
    struct iovec l = { .iov_base = out, .iov_len = len };
    struct iovec r = { .iov_base = (void *)(uintptr_t)addr, .iov_len = len };
    return process_vm_readv(pid, &l, 1, &r, 1, 0) == (ssize_t)len ? 0 : -1;
}

static void fd_path(pid_t pid, int fd, char *out, size_t n)
{
    char lnk[64];
    snprintf(lnk, sizeof(lnk), "/proc/%d/fd/%d", pid, fd);
    ssize_t k = readlink(lnk, out, n - 1);
    out[k > 0 ? k : 0] = '\0';
}

/* Attach to every thread. SurfaceFlinger is heavily multithreaded and the
 * display ioctls do not necessarily come from the main thread. */
static int attach_all(pid_t pid, pid_t *tids, int max, int main_only)
{
    char dir[64];
    snprintf(dir, sizeof(dir), "/proc/%d/task", pid);
    DIR *d = opendir(dir);
    if (!d) {
        perror("opendir /proc/pid/task");
        return 0;
    }
    int n = 0;
    struct dirent *e;
    while ((e = readdir(d)) && n < max) {
        if (e->d_name[0] < '0' || e->d_name[0] > '9')
            continue;
        pid_t tid = (pid_t)atoi(e->d_name);
        /* Tracing every thread traps so many syscalls that the compositor
         * stops reaching its update path -- the observer suppresses the
         * event. Restricting to the main thread cuts that ~24x. */
        if (main_only && tid != pid)
            continue;
        /* SEIZE does not stop the tracee, so INTERRUPT it and wait for the
         * stop before PTRACE_SYSCALL -- otherwise that call fails ESRCH and
         * nothing is ever traced. TRACECLONE follows threads spawned later. */
        long opts = PTRACE_O_TRACESYSGOOD | PTRACE_O_TRACECLONE;
        if (ptrace(PTRACE_SEIZE, tid, 0, (void *)(uintptr_t)opts) != 0)
            continue;
        if (ptrace(PTRACE_INTERRUPT, tid, 0, 0) != 0)
            continue;
        int st;
        if (waitpid(tid, &st, __WALL) < 0)
            continue;
        tids[n++] = tid;
    }
    closedir(d);
    return n;
}

int main(int argc, char **argv)
{
    setvbuf(stdout, NULL, _IONBF, 0);
    if (argc < 3) {
        fprintf(stderr, "usage: %s <pid> <seconds> [main]\n", argv[0]);
        return 2;
    }
    pid_t pid = (pid_t)atoi(argv[1]);
    int secs = atoi(argv[2]);

    static pid_t tids[4096];
    int main_only = (argc > 3 && strcmp(argv[3], "main") == 0);
    int ntid = attach_all(pid, tids, 4096, main_only);
    if (!ntid) {
        fprintf(stderr, "could not seize any thread of %d: %s\n", pid, strerror(errno));
        return 1;
    }
    printf("# seized %d threads of pid %d, tracing %ds\n", ntid, pid, secs);

    for (int i = 0; i < ntid; i++)
        ptrace(PTRACE_SYSCALL, tids[i], 0, 0);

    time_t deadline = time(NULL) + secs;
    long hits = 0;

    while (time(NULL) < deadline) {
        int st;
        pid_t t = waitpid(-1, &st, __WALL | WNOHANG);
        if (t <= 0) {
            struct timespec ts = { 0, 200000 };   /* 0.2 ms */
            nanosleep(&ts, NULL);
            continue;
        }
        if (WIFEXITED(st) || WIFSIGNALED(st))
            continue;

        int sig = WSTOPSIG(st);
        if (sig == (SIGTRAP | 0x80)) {
            unsigned idx = (unsigned)t % MAXTID;
            int entering = !in_syscall[idx];
            in_syscall[idx] = (unsigned char)entering;

            if (entering) {
                struct arm64_regs r;
                if (read_regs(t, &r) == 0 && r.regs[8] == AARCH64_NR_ioctl) {
                    uint64_t req = r.regs[1];
                    if (req >= EBC_LO && req <= EBC_HI) {
                        char p[256];
                        fd_path(pid, (int)r.regs[0], p, sizeof(p));
                        if (strstr(p, "/dev/ebc") || strstr(p, "/dev/dri")) {
                            int32_t u[10];
                            printf("tid=%d %s req=%#llx", t, p,
                                   (unsigned long long)req);
                            if (r.regs[2] &&
                                peek_mem(pid, r.regs[2], u, sizeof(u)) == 0) {
                                if (req == 0x700c)
                                    printf("  UPD rect=(%d,%d)-(%d,%d) wf=%d "
                                           "mode=%d marker=%d f1c=%d flags=%#x f24=%d",
                                           u[0], u[1], u[2], u[3], u[4],
                                           u[5], u[6], u[7], (unsigned)u[8], u[9]);
                                else
                                    printf("  arg[0..3]=%d %d %d %d",
                                           u[0], u[1], u[2], u[3]);
                            }
                            printf("\n");
                            hits++;
                        }
                    }
                }
            }
            ptrace(PTRACE_SYSCALL, t, 0, 0);
        } else {
            /* Forward any real signal so we do not alter the target's behaviour. */
            ptrace(PTRACE_SYSCALL, t, 0, (void *)(uintptr_t)
                   (sig == SIGTRAP || sig == SIGSTOP ? 0 : sig));
        }
    }

    for (int i = 0; i < ntid; i++)
        ptrace(PTRACE_DETACH, tids[i], 0, 0);
    printf("# detached, %ld ebc/dri ioctls seen\n", hits);
    return 0;
}
