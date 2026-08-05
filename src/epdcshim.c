/*
 * epdcshim -- supply the EPD update rectangles the composer never sets.
 *
 * WHY THIS EXISTS
 * ---------------
 * The kernel copies pixels into the EPD buffer *per update rectangle*. The
 * rectangles arrive as two Onyx-added DRM plane properties:
 *
 *     EPDC_UPDATE_PARMS_ADDR   userspace pointer, copy_from_user'd (320 bytes)
 *     EPDC_UPDATE_CNT          how many of the 8 entries are valid
 *
 * On stock they are set by the composer (CommitEpdc / onyx_epdc_update_to_display
 * -> libsdedrm DRMPlane::SetEpdcUpdParmsAddr / SetEpdcUpdCnt), fed from Onyx's
 * SurfaceFlinger, which gets damage regions from Onyx's libgui. Our system side
 * has none of that -- `hwc_epdc_llist` exists in no library we ship -- so the
 * count is structurally always 0.
 *
 * With count 0 the kernel's submit iterates zero rectangles and copies nothing.
 * Measured directly: with our SF compositing and full-panel planes passing the
 * size check, /dev/ebc is still 100% 0xff (src/ebcfb.c). The panel is not
 * failing to display; it is faithfully displaying an empty buffer.
 *
 * This shim adds those two properties to the atomic commit the composer already
 * makes every frame, with one rectangle covering the whole panel.
 *
 * WHY INTERPOSITION WORKS HERE
 * ----------------------------
 * libsdedrm.so, which owns the epdc setters, has libdrm.so as a NEEDED entry,
 * and so does the composer binary. Both therefore resolve drmModeAtomic* through
 * the global symbol table, where an LD_PRELOAD'd definition wins.
 *
 * HOW IT PICKS THE PLANE
 * ----------------------
 * Adding a property for an object that is not otherwise in the atomic request
 * pulls that object into the request, which can make an otherwise valid commit
 * fail. So we never guess: drmModeAtomicAddProperty is hooked purely to record
 * which object ids the composer itself put in the current request, and at commit
 * time we only touch those. Objects that turn out not to be planes, or planes
 * without the epdc properties, are cached as "no" and skipped forever after.
 *
 * SCOPE
 * -----
 * A full-screen rectangle every commit is deliberately crude: it makes the
 * panel flash and ghost. It exists to prove the mechanism and to give a usable
 * screen, not to be shipped. Proper partial updates need the damage regions
 * plumbed from the framework -- see docs/11, option C.
 *
 * Built freestanding (-nostdlib) so it drags no libc into a bionic process:
 * the only symbol it imports is dlsym, and everything else is looked up at
 * runtime from libraries the composer has already loaded.
 */

typedef unsigned int   u32;
typedef signed   int   i32;
typedef unsigned long  u64;
typedef unsigned long  usize;

/* Freestanding: no stdint.h. Provide the two types the shared contract needs,
 * then pull in the contract itself so the layout cannot drift from the writer. */
typedef unsigned int uint32_t;
typedef signed   int int32_t;
#define EPDC_DAMAGE_NO_STDINT 1
#include "epdc_damage.h"

#define RTLD_NEXT    ((void *)-1L)
#define RTLD_DEFAULT ((void *)0)

extern void *dlsym(void *handle, const char *symbol);

/* libdrm's public structs. Reproduced rather than included so the build needs
 * no vendor headers; layouts are stable ABI (xf86drmMode.h). */
typedef struct {
    u32 count_props;
    u32 *props;
    u64 *prop_values;
} objprops_t;

typedef struct {
    u32 prop_id;
    u32 flags;
    char name[32];
    int count_values;
    u64 *values;
    int count_enums;
    void *enums;
    int count_blobs;
    u32 *blob_ids;
} propres_t;

#define DRM_MODE_OBJECT_PLANE 0xeeeeeeeeu

/* The update-parameter struct, recovered from the kernel's own printk field
 * order at plane_state+0x7dc (docs/11). 40 bytes; the kernel always copies 8
 * of them (320 bytes) regardless of how many are valid. */
struct upd {
    i32 rect[4];        /* +0x00  full screen: x/y/w/h and l/t/r/b coincide */
    i32 waveform_mode;  /* +0x10  2 = ordinary composition                  */
    i32 update_mode;    /* +0x14                                            */
    i32 update_marker;  /* +0x18  incremented per submission                */
    i32 temp;           /* +0x1c  temperature index                         */
    i32 flag;           /* +0x20  0x31000 is what stock sends               */
    i32 dither_mode;    /* +0x24  see below; we called this 'reserved'       */
};
_Static_assert(sizeof(struct upd) == 40, "kernel copies 8 x 40 bytes");

static struct upd g_parms[8];

/* Monotonic source for update_marker, shared by every path that submits an
 * update (commits and settles alike). Markers must never repeat -- docs/19
 * §4.4 -- and there is more than one thread submitting, so reserve a block
 * atomically rather than incrementing in place. Skips 0 and wraps positive:
 * the driver treats the marker as a plain token, but a 0 or negative one has
 * never been observed from stock, so stay inside the range we know works. */
static i32 g_marker;

static i32 next_marker(int n)
{
    i32 base = __atomic_fetch_add(&g_marker, n, __ATOMIC_RELAXED);
    if (base <= 0 || base > 0x7fff0000) {
        __atomic_store_n(&g_marker, n + 1, __ATOMIC_RELAXED);
        base = 1;
    }
    return base;
}

#define PANEL_W 1648
#define PANEL_H 824

/* Live tunables, re-read every RECHECK commits so modes can be swept with
 * setprop alone -- no rebuild, no composer restart:
 *
 *   persist.epdcshim.enable    1/0            master switch
 *   persist.epdcshim.wf        waveform_mode  2 = GC16 full flash (Onyx's own
 *                                             choice for whole-screen refresh,
 *                                             hence very visible flashing)
 *   persist.epdcshim.upd       update_mode
 *   persist.epdcshim.flag      hex, e.g. 0x21000
 *   persist.epdcshim.interval  ms between injections; 0 = every commit
 *   persist.epdcshim.defer     ms of quiet before drawing; while commits keep
 *                              arriving faster than this, nothing is submitted,
 *                              so an animation never reaches the panel and only
 *                              its final frame does. 0 = off
 *   persist.epdcshim.defermax  frames to suppress before forcing one
 */
#define RECHECK 30
static int t_enable   = 1;
static int t_wf       = 2;
static int t_upd      = 0;    /* partial; 1 flashes the whole panel */
/* 0x31000 is what stock sends. We shipped 0x21000 for weeks and icons came
 * out washed out and barely legible -- a drive-voltage problem that presents
 * as a ghosting problem. docs/19 §4.5. Defaults matter here: a fresh flash
 * has no persist props yet, so the default IS the shipped behaviour. */
static int t_flag     = 0x31000;
static int t_interval;
static int t_fastwf;      /* waveform to use while the screen is in motion   */
static int t_fastms  = 250;
static int t_fullevery;   /* force a full-flash clean every N updates        */
/* Flash every N frames while still moving, to bound how much trail the fast
 * waveform can accumulate mid-scroll. 0 = only clean when motion ends. */
static int t_fastclean = 6;
/* Temperature index. NXP's i.MX EPDC uapi -- which this struct is derived from,
 * field for field -- defines TEMP_USE_AMBIENT as 0x1000, meaning "read the
 * ambient sensor". A plain 0 there is not "driver decides", it is 0 degrees C:
 * the coldest waveform band. E-ink waveforms are strongly temperature
 * compensated, so sending 0 on a warm panel drives it with the wrong timings.
 * Default stays 0 until this is confirmed on hardware. See docs/19 4.6. */
static int t_temp;
/* dither_mode, the field previously labelled 'reserved'. i.MX:
 *   0 PASSTHROUGH (off)  1 FLOYD_STEINBERG  2 ATKINSON  3 ORDERED  4 QUANT_ONLY
 * Hardware dithering, free of charge, if Onyx kept the semantics. */
static int t_dither;
/* update_mode for the end-of-motion clean. 1 = full drive (slow, ~600-900ms
 * on a full panel), 0 = partial. Whether a partial pass can lift what the
 * additive overlay laid down is an empirical question, not a known one. */
static int t_cleanmode = 1;
static int fast_frames;   /* consecutive frames drawn with t_fastwf          */

/* Page-turn mode. See the comment in init_parms: while moving, submit nothing,
 * so a slide animation never reaches the panel and only its final state does. */
static int t_defer;       /* ms of quiet required before drawing; 0 = off     */
static long last_commit_ms;   /* every commit, not just injected ones          */
static int defer_pending;     /* content changed while we were suppressing     */
static int t_defermax = 90;  /* let one through after this many suppressed    */
static int deferred_frames;
static int commits_since_recheck = RECHECK;   /* force a read on first commit */
static long last_inject_ms;
static int updates_since_full;

/* DRM_MODE_ATOMIC_TEST_ONLY: a validation pass, not a real frame. Injecting
 * there would ask the panel to redraw for every check the composer makes. */
#define ATOMIC_TEST_ONLY 0x0100

/* --- resolved lazily from the process's already-loaded libraries --------- */
static int  (*real_add)(void *, u32, u32, u64);
static int  (*real_commit)(int, void *, u32, void *);
static objprops_t *(*p_get_objprops)(int, u32, u32);
static void (*p_free_objprops)(objprops_t *);
static propres_t  *(*p_get_prop)(int, u32);
static void (*p_free_prop)(propres_t *);
static void (*p_log)(int, const char *, const char *, ...);
static int  (*p_prop_get)(const char *, char *);
static int  (*p_clock_gettime)(int, void *);
static int  (*p_open)(const char *, int, ...);
static void *(*p_mmap)(void *, usize, int, int, int, long);
static int  (*p_ioctl)(int, unsigned long, ...);
static int  (*p_close)(int);
static int  (*p_nanosleep)(const void *, void *);
static int  (*p_pthread_create)(unsigned long *, const void *, void *(*)(void *), void *);

/* Damage published by SurfaceFlinger, if it is running a build that does so.
 * Absent -> we fall back to one full-panel rectangle, i.e. previous behaviour,
 * so an unpatched SF still gets a working display. */
static const volatile struct epdc_damage_shm *g_dmg;
static int g_dmg_tried = RECHECK;   /* try immediately, then every RECHECK */
static u32 last_dmg_seq;

#define LOGI(...) do { if (p_log) p_log(4, "epdcshim", __VA_ARGS__); } while (0)

/* --- per-object property-id cache --------------------------------------- */
#define MAX_OBJ 32
static u32 c_obj[MAX_OBJ];
static u32 c_parms_prop[MAX_OBJ];
static u32 c_cnt_prop[MAX_OBJ];
static int c_n;

/* object ids the composer itself placed in the current request, and the FB_ID
 * it set on each. A commit that presents the same buffers as the one we last
 * acted on has nothing new to show, so driving the panel for it is pure
 * flashing -- SurfaceFlinger keeps committing at idle (clock, cursor, settling
 * animations) and every one of those was costing a full-panel repaint. */
static u32 pend[MAX_OBJ];
static u32 pend_fb[MAX_OBJ];
static int n_pend;
static u32 g_fbid_prop;          /* learned from the property enumeration */
static u32 last_fb_sig;
static int t_skipsame = 1;

static int str_eq(const char *a, const char *b)
{
    while (*a && *a == *b) { a++; b++; }
    return *a == *b;
}

static void resolve(void)
{
    if (real_add) return;
    real_add        = dlsym(RTLD_NEXT, "drmModeAtomicAddProperty");
    real_commit     = dlsym(RTLD_NEXT, "drmModeAtomicCommit");
    p_get_objprops  = dlsym(RTLD_DEFAULT, "drmModeObjectGetProperties");
    p_free_objprops = dlsym(RTLD_DEFAULT, "drmModeFreeObjectProperties");
    p_get_prop      = dlsym(RTLD_DEFAULT, "drmModeGetProperty");
    p_free_prop     = dlsym(RTLD_DEFAULT, "drmModeFreeProperty");
    p_log           = dlsym(RTLD_DEFAULT, "__android_log_print");
    p_prop_get      = dlsym(RTLD_DEFAULT, "__system_property_get");
    p_clock_gettime = dlsym(RTLD_DEFAULT, "clock_gettime");
    p_open          = dlsym(RTLD_DEFAULT, "open");
    p_mmap          = dlsym(RTLD_DEFAULT, "mmap");
    p_ioctl         = dlsym(RTLD_DEFAULT, "ioctl");
    p_close         = dlsym(RTLD_DEFAULT, "close");
    p_nanosleep     = dlsym(RTLD_DEFAULT, "nanosleep");
    p_pthread_create = dlsym(RTLD_DEFAULT, "pthread_create");
}

static long now_ms(void);   /* defined below, with the other tunable helpers */

/* --- settle pass ---------------------------------------------------------
 *
 * Borrowed from Modos Caster, which drives pixels in a fast binary mode while
 * they are changing and re-renders them in greyscale once they stop. Its
 * version is per-pixel in FPGA gateware; ours is per-screen in a timer, but the
 * user-visible behaviour is the same: responsive while moving, clean once still.
 *
 * This needs no atomic commit and no damage. The composited content is already
 * in the EPD buffer -- the panel simply has not been driven with a quality
 * waveform. So a settle is one SET_EBC_SEND_UPDATE straight to /dev/ebc, the
 * same call src/ebcrefresh.c makes.
 *
 * Deliberately fires only when the screen has been quiet for `settlems`. That
 * is the flaw in a plain `fullevery` counter, which fires on a count and so can
 * flash in the middle of a scroll -- exactly when the user is least willing to
 * pay for it.
 */
#define EBC_DEVICE           "/dev/ebc"
#define EBC_SEND_UPDATE      0x700c
/* The handwriting path -- what makes a settle actually show something.
 *
 * EBC_SEND_UPDATE alone repaints from a driver buffer nothing in our stack
 * writes, so it faithfully paints white. That is issue #2, and it is why this
 * whole pass was disabled. The missing pieces, all established in docs/22 9.4:
 *
 *   0x7006 scheme=3   SCHEME_HANDWRITE, the only mode that reads virt_buf_handwrite
 *   0x701d            copy the LIVE framebuffer into that buffer -- no compositor
 *                     involved, and no commit needed from the app
 *   flags bit 18      or the driver rejects the update outright
 *
 * 0x701d is time-gated: it returns early unless fb_update_time is newer than
 * handwrite_time. Setting the scheme with 0x7006 refreshes fb_update_time,
 * which is why it has to come first. */
#define EBC_UPDATE_SCHEME    0x7006
#define EBC_SYNC_FROM_FB     0x701d
#define SCHEME_NORMAL        2
#define SCHEME_HANDWRITE     3
#define EPDC_FLAG_HANDWRITE  0x40000

struct ebc_upd {
    i32 rect[4];
    i32 waveform_mode;
    i32 update_mode;
    i32 update_marker;
    i32 temp;
    i32 flag;
    i32 reserved;
};

static int g_settle_pending;      /* something was drawn since the last settle */

/* Quiet period before the anti-ghosting pass, in ms. 0 disables it.
 *
 * DISABLED ON PURPOSE -- this pass does not work on our stack, and enabling it
 * BLANKS THE PANEL a second or two after you stop touching it.
 *
 * Why: settle_now() drives /dev/ebc directly with EBC_SEND_UPDATE. That is
 * Onyx's own path and it refreshes the panel from the EBC framebuffer. Our
 * pixels never go there -- they reach the panel only because the kernel copies
 * them out of the DRM PLANE's framebuffer, per rectangle, at commit time. So
 * the settle dutifully repaints the whole panel from a buffer nothing has
 * written, and the screen goes empty. The framework is unaffected, so a
 * screencap at that moment looks perfectly normal -- which is exactly the trap
 * CLAUDE.md warns about: screencap proves compositing, not what is on glass.
 * Same buffer confusion as issue #4.
 *
 * Issue #2 was filed as "the settle thread never fires". It fires correctly;
 * it was simply switched off, and switching it on revealed that the mechanism
 * is wrong for this stack rather than merely untuned.
 *
 * The anti-ghosting job belongs on the COMMIT path, which is the only path
 * that has real content: see t_fullevery, which forces a full flash every N
 * updates from inside init_parms. */
static int t_settlems;            /* 0 = off; see above before changing */
static int t_settlewf = 2;        /* GC16: the quality mode */
/* update_mode for the settle: 1 flashes, 0 does not. Moot while t_settlems is
 * 0, kept so the mechanism can be re-tested if it is ever moved onto a commit. */
static int t_settlemode = 1;

static void settle_now(void)
{
    if (!p_open || !p_ioctl) return;
    int fd = p_open(EBC_DEVICE, 2 /* O_RDWR */);
    if (fd < 0) return;

    struct ebc_upd u;
    for (usize i = 0; i < sizeof u; i++) ((unsigned char *)&u)[i] = 0;
    u.rect[0] = 0; u.rect[1] = 0; u.rect[2] = PANEL_W; u.rect[3] = PANEL_H;
    u.waveform_mode = t_settlewf;
    u.update_mode   = t_settlemode;
    /* Markers MUST be unique. The driver tracks them and blocks in
     * onyx_epdc_fb_wait_updates_complete() until the marker it is waiting on
     * completes; sending the same marker every time made each settle collide
     * with the previous one, which left the panel mid-waveform and BLANK. The
     * symptom was 'Waiting for update marker magic[1] complete' repeating
     * forever in dmesg.
     *
     * This draws from the SAME counter as the commit path. It used to have a
     * private one, which meant the two could independently arrive at the same
     * value and collide with each other -- the identical failure, just rarer
     * and harder to reproduce. This runs on the settle thread while the commit
     * path runs on the composer's, hence the atomic. */
    u.update_marker = next_marker(1);
    u.flag          = t_flag | EPDC_FLAG_HANDWRITE;

    /* Enter handwrite scheme, seed the buffer from what is actually on screen,
     * draw it, and hand the display straight back.
     *
     * While scheme 3 is set the driver REJECTS ordinary updates, so the
     * compositor cannot paint. That window is kept to a single update, and the
     * scheme is restored on every path out -- leaving it set would freeze the
     * display for the compositor entirely. */
    int scheme = SCHEME_HANDWRITE;
    if (p_ioctl(fd, EBC_UPDATE_SCHEME, &scheme) == 0) {
        p_ioctl(fd, EBC_SYNC_FROM_FB, 0);
        p_ioctl(fd, EBC_SEND_UPDATE, &u);
        scheme = SCHEME_NORMAL;
        p_ioctl(fd, EBC_UPDATE_SCHEME, &scheme);
    }
    if (p_close) p_close(fd);
}

static void *settle_thread(void *arg)
{
    (void)arg;
    struct { long sec; long nsec; } ts = { 0, 50 * 1000 * 1000 };  /* 50 ms */
    for (;;) {
        if (p_nanosleep) p_nanosleep(&ts, 0);
        if (!t_settlems || !g_settle_pending) continue;
        long quiet = now_ms() - last_inject_ms;
        if (quiet < t_settlems) continue;
        g_settle_pending = 0;
        settle_now();
    }
    return 0;
}

static void start_settle_thread(void)
{
    static int started;
    if (started || !p_pthread_create) return;
    started = 1;
    unsigned long tid;
    if (p_pthread_create(&tid, 0, settle_thread, 0) == 0)
        LOGI("settle thread running");
}

/* Attach to SurfaceFlinger's damage mapping.
 *
 * Retried rather than attempted once: the composer is a `class hal` service and
 * issues commits during boot animation and continuous splash, well before
 * SurfaceFlinger first runs finishFrame and creates the file. A one-shot
 * attempt always lost that race and left the shim in full-screen mode for the
 * entire session. */
static void attach_damage(void)
{
    if (g_dmg) return;
    if (++g_dmg_tried < RECHECK) return;
    g_dmg_tried = 0;
    if (!p_open || !p_mmap) { LOGI("damage: open=%p mmap=%p", p_open, p_mmap); return; }

    int dfd = p_open(EPDC_DAMAGE_PATH, 0 /* O_RDONLY */);
    if (dfd < 0) { LOGI("damage: open(%s) -> %d", EPDC_DAMAGE_PATH, dfd); return; }
    void *m = p_mmap(0, 4096, 1 /* PROT_READ */, 1 /* MAP_SHARED */, dfd, 0);
    if (!m || m == (void *)-1L) { LOGI("damage: mmap -> %p", m); return; }

    const volatile struct epdc_damage_shm *s = m;
    if (s->magic != EPDC_DAMAGE_MAGIC || s->version != EPDC_DAMAGE_VERSION) {
        LOGI("damage map present but magic/version mismatch (%u/%u)",
             s->magic, s->version);
        return;
    }
    g_dmg = s;
    LOGI("attached to SurfaceFlinger damage at %s", EPDC_DAMAGE_PATH);
}

/* Seqlock read. Returns rectangle count, 0 if the region is unusable or
 * unchanged; *changed says whether SF composited anything new. */
static int read_damage(struct epdc_damage_rect *out, int *full, int *changed)
{
    *full = 0;
    *changed = 1;
    if (!g_dmg) return 0;

    for (int attempt = 0; attempt < 4; attempt++) {
        u32 s1 = __atomic_load_n(&g_dmg->seq, __ATOMIC_ACQUIRE);
        if (s1 & 1u) continue;                  /* writer mid-update */

        u32 n = g_dmg->count;
        u32 f = g_dmg->full;
        if (n > EPDC_DAMAGE_MAX) n = EPDC_DAMAGE_MAX;
        for (u32 i = 0; i < n; i++) {
            out[i].left   = g_dmg->rect[i].left;
            out[i].top    = g_dmg->rect[i].top;
            out[i].right  = g_dmg->rect[i].right;
            out[i].bottom = g_dmg->rect[i].bottom;
        }

        u32 s2 = __atomic_load_n(&g_dmg->seq, __ATOMIC_ACQUIRE);
        if (s1 != s2) continue;                 /* torn -- retry */

        *changed = (s1 != last_dmg_seq);
        last_dmg_seq = s1;
        *full = (int)f;
        return (int)n;
    }
    return 0;                                   /* contended: full screen */
}

static long parse_num(const char *s, long dflt)
{
    if (!s || !*s) return dflt;
    int neg = 0, base = 10;
    if (*s == '-') { neg = 1; s++; }
    if (s[0] == '0' && (s[1] == 'x' || s[1] == 'X')) { base = 16; s += 2; }
    long v = 0;
    int any = 0;
    for (; *s; s++) {
        int d;
        if (*s >= '0' && *s <= '9') d = *s - '0';
        else if (base == 16 && *s >= 'a' && *s <= 'f') d = *s - 'a' + 10;
        else if (base == 16 && *s >= 'A' && *s <= 'F') d = *s - 'A' + 10;
        else break;
        v = v * base + d;
        any = 1;
    }
    if (!any) return dflt;
    return neg ? -v : v;
}

static long prop_num(const char *name, long dflt)
{
    if (!p_prop_get) return dflt;
    char buf[92];
    buf[0] = 0;
    p_prop_get(name, buf);
    return parse_num(buf, dflt);
}

static long now_ms(void)
{
    if (!p_clock_gettime) return 0;
    struct { long sec; long nsec; } ts = { 0, 0 };
    p_clock_gettime(1 /* CLOCK_MONOTONIC */, &ts);
    return ts.sec * 1000 + ts.nsec / 1000000;
}

static void refresh_tunables(void)
{
    if (++commits_since_recheck < RECHECK) return;
    commits_since_recheck = 0;
    t_enable   = (int)prop_num("persist.epdcshim.enable", 1);
    t_wf       = (int)prop_num("persist.epdcshim.wf", 2);
    t_upd      = (int)prop_num("persist.epdcshim.upd", 0);
    t_flag     = (int)prop_num("persist.epdcshim.flag", 0x31000);
    t_interval = (int)prop_num("persist.epdcshim.interval", 0);
    t_fastwf   = (int)prop_num("persist.epdcshim.fastwf", 0);
    t_fastms   = (int)prop_num("persist.epdcshim.fastms", 250);
    t_fastclean= (int)prop_num("persist.epdcshim.fastclean", 6);
    t_defer    = (int)prop_num("persist.epdcshim.defer", 0);
    t_defermax = (int)prop_num("persist.epdcshim.defermax", 90);
    t_temp     = (int)prop_num("persist.epdcshim.temp", 0);
    t_dither   = (int)prop_num("persist.epdcshim.dither", 0);
    t_cleanmode= (int)prop_num("persist.epdcshim.cleanmode", 1);
    t_fullevery= (int)prop_num("persist.epdcshim.fullevery", 0);
    t_skipsame = (int)prop_num("persist.epdcshim.skipsame", 1);
    /* Default is longer than a GC16 takes (~450 ms). A shorter window lets a
     * settle land inside an update that is still running. */
    t_settlems = (int)prop_num("persist.epdcshim.settlems", 0);
    t_settlewf = (int)prop_num("persist.epdcshim.settlewf", 2);
    t_settlemode = (int)prop_num("persist.epdcshim.settlemode", 1);
}

/* There is no damage information available: the DRM planes expose no
 * FB_DAMAGE_CLIPS, and under client composition (which this panel requires,
 * since __sde_plane_atomic_update_epdc drops any plane smaller than the panel)
 * there is a single full-screen plane whose CRTC rect is always the whole
 * display. So every update is unavoidably full-screen until real damage is
 * plumbed down from SurfaceFlinger.
 *
 * What is left is the refresh *policy*, which is where e-readers get their
 * feel. Two levers, both standard (Kobo/KOReader, PineNote):
 *
 *   motion   while frames are arriving quickly the content is moving, so
 *            quality is wasted -- use a fast waveform and let it be rough
 *   cleanup  partial waveforms leave residue, so every N updates do one
 *            full-flash pass to clear the panel
 *
 * dt is measured against the previous *injected* update, so a burst of commits
 * counts as motion even when we are throttling.
 */
/* Fills g_parms[] and returns how many rectangles to submit. */
static int init_parms(long dt_ms, const struct epdc_damage_rect *dmg, int n_dmg,
                      int force_full)
{
    int wf  = t_wf;
    int upd = t_upd;

    /* Motion state machine.
     *
     * EPD_OVERLAY (1) is ~4x faster than GC16, measured, but it is ADDITIVE:
     * it drives pixels one direction only, so each frame lays new content over
     * whatever was there and the panel keeps a visible trail of old frames.
     * Alone it is unusable for scrolling -- which is what we shipped for about
     * an hour and had to back out.
     *
     * It becomes usable when paired with a clean-up pass, and the pass must be
     * a FLASH (update_mode 1). Falling back to a *partial* GC16 does not lift
     * the trail; only a full drive of every pixel does. That was the missing
     * piece: the fallback to t_wf already happened, it just was not forceful
     * enough to undo what the overlay had done.
     *
     *   moving                      -> t_fastwf, cheap, accumulates a trail
     *   moving, every t_fastclean   -> flash, to bound the trail mid-scroll
     *   motion ends                 -> flash, to clear it
     *
     * The end-of-motion flash rides the first commit that arrives after the
     * scroll stops. If nothing ever commits again the trail survives until
     * something does -- t_fastclean is the bound on how bad that can get. */
    /* Page-turn mode: draw the destination, never the journey.
     *
     * A real Kindle does not animate a page turn -- the old page is there, then
     * the new one is. The Android app slides instead, and on e-ink that costs
     * about 46 panel updates for one turn, each of them a frame of a picture
     * nobody wants to see.
     *
     * It cannot be turned off in the app. Android's animation scales are
     * already 0 here and the slide continues, so it is not driven by platform
     * animators but by the app's own frame loop, and no preference in its
     * shared_prefs controls it.
     *
     * So it is suppressed here instead: while frames are arriving quickly,
     * submit NOTHING. The panel simply holds the old page. When motion stops,
     * the existing end-of-motion branch below flashes once, and that flash
     * carries whatever is on screen by then -- the settled page.
     *
     * KNOWN FAILURE MODE, and it is why this is off by default. The end-of-
     * motion flash rides the next commit that arrives after the burst. If an
     * app ends a page turn and then commits nothing at all, the panel keeps
     * showing the old page until something else happens -- a tap that appears
     * to do nothing. t_defermax bounds that: after this many suppressed frames
     * one is allowed through regardless, so the worst case is a late redraw
     * rather than a stuck one.
     *
     * Deliberately not app-aware. The shim cannot see which app is in front;
     * per-app policy is set from outside by writing these properties when the
     * foreground app changes, which is what eink-appwatch.sh does and what the
     * epdcd daemon is meant to take over.
     */
    const int moving = (t_fastwf > 0 && dt_ms >= 0 && dt_ms < t_fastms);

    if (moving) {
        wf = t_fastwf;
        /* Count EVERY moving frame, unconditionally. This used to be
         * `t_fastclean > 0 && ++fast_frames >= t_fastclean`, where a
         * t_fastclean of 0 short-circuited the increment away -- so
         * fast_frames stayed 0, the end-of-motion branch below could never
         * fire, and the additive overlay accumulated every frame ever drawn
         * onto the panel with no clean pass at all. fastclean=0 must mean
         * "clean only when motion ends", not "never clean". */
        fast_frames++;
        if (t_fastclean > 0 && fast_frames >= t_fastclean) {
            fast_frames = 0;
            wf = t_wf;
            upd = t_cleanmode;
            force_full = 1;
        }
    } else if (fast_frames > 0) {
        fast_frames = 0;
        deferred_frames = 0;
        wf = t_wf;
        upd = t_cleanmode;
        force_full = 1;
    }

    if (t_fullevery > 0 && ++updates_since_full >= t_fullevery) {
        updates_since_full = 0;
        force_full = 1;
        wf  = t_wf;                          /* quality waveform ... */
        upd = 1;                             /* ... and a full flash */
    }

    int n = (force_full || n_dmg <= 0) ? 0 : n_dmg;
    if (n > (int)EPDC_DAMAGE_MAX) n = (int)EPDC_DAMAGE_MAX;

    const i32 base = next_marker(n ? n : 1);

    for (int i = 0; i < (n ? n : 1); i++) {
        if (n) {
            /* Clamp: a rectangle outside the panel is rejected outright, and a
             * single bad one would cost the whole update. */
            i32 l = dmg[i].left, t = dmg[i].top;
            i32 r = dmg[i].right, b = dmg[i].bottom;
            if (l < 0) l = 0;
            if (t < 0) t = 0;
            if (r > PANEL_W) r = PANEL_W;
            if (b > PANEL_H) b = PANEL_H;
            if (r <= l || b <= t) { l = 0; t = 0; r = PANEL_W; b = PANEL_H; }
            g_parms[i].rect[0] = l; g_parms[i].rect[1] = t;
            g_parms[i].rect[2] = r; g_parms[i].rect[3] = b;
        } else {
            g_parms[i].rect[0] = 0; g_parms[i].rect[1] = 0;
            g_parms[i].rect[2] = PANEL_W; g_parms[i].rect[3] = PANEL_H;
        }
        g_parms[i].waveform_mode = wf;
        g_parms[i].update_mode   = upd;
        /* Unique per rectangle, not per commit. Each entry in the array is a
         * separate update as far as the driver is concerned, and it blocks on
         * a marker until that one completes (docs/19 §4.4) -- so N rectangles
         * sharing a marker collide with each other exactly the way successive
         * commits used to, leaving the panel mid-waveform. Harmless while
         * n_dmg was always 1; a latent blank-screen bug the moment it is not. */
        g_parms[i].update_marker = base + i;
        g_parms[i].flag          = t_flag;
        g_parms[i].temp          = t_temp;
        g_parms[i].dither_mode   = t_dither;
    }
    n = n ? n : 1;
    return n;
}

/* Returns index into the cache, adding an entry (possibly a negative one) if
 * this object has not been looked at yet. -1 means "cache full". */
static int lookup(int fd, u32 obj)
{
    for (int i = 0; i < c_n; i++)
        if (c_obj[i] == obj) return i;
    if (c_n >= MAX_OBJ) return -1;
    if (!p_get_objprops || !p_get_prop) return -1;

    int idx = c_n++;
    c_obj[idx] = obj;
    c_parms_prop[idx] = 0;
    c_cnt_prop[idx] = 0;

    objprops_t *op = p_get_objprops(fd, obj, DRM_MODE_OBJECT_PLANE);
    if (!op) return idx;                       /* not a plane -- remembered */
    /* Dump the property vocabulary once. We need to know whether the composer
     * exposes FB_DAMAGE_CLIPS: that is the standard DRM plane property carrying
     * changed regions, and the kernel takes up to 8 update rects, so it would
     * let this shim do real partial updates instead of a blanket full-screen
     * one. Logged only for the first plane examined. */
    static int dumped;
    for (u32 i = 0; i < op->count_props; i++) {
        propres_t *pr = p_get_prop(fd, op->props[i]);
        if (!pr) continue;
        if (!dumped) LOGI("  prop[%u] %s", pr->prop_id, pr->name);
        if (str_eq(pr->name, "FB_ID"))
            g_fbid_prop = pr->prop_id;
        if (str_eq(pr->name, "EPDC_UPDATE_PARMS_ADDR"))
            c_parms_prop[idx] = pr->prop_id;
        else if (str_eq(pr->name, "EPDC_UPDATE_CNT"))
            c_cnt_prop[idx] = pr->prop_id;
        if (p_free_prop) p_free_prop(pr);
    }
    dumped = 1;
    if (p_free_objprops) p_free_objprops(op);

    if (c_parms_prop[idx] && c_cnt_prop[idx])
        LOGI("plane %u: EPDC_UPDATE_PARMS_ADDR=%u EPDC_UPDATE_CNT=%u",
             obj, c_parms_prop[idx], c_cnt_prop[idx]);
    return idx;
}

/* --- interposed ---------------------------------------------------------- */

int drmModeAtomicAddProperty(void *req, u32 object_id, u32 property_id, u64 value)
{
    resolve();
    /* Record only; never inject here. At this point we have no fd, and the
     * request is still being assembled. */
    int slot = -1;
    for (int i = 0; i < n_pend; i++)
        if (pend[i] == object_id) { slot = i; break; }
    if (slot < 0 && n_pend < MAX_OBJ) {
        slot = n_pend++;
        pend[slot] = object_id;
        pend_fb[slot] = 0;
    }
    if (slot >= 0 && g_fbid_prop && property_id == g_fbid_prop)
        pend_fb[slot] = (u32)value;

    return real_add(req, object_id, property_id, value);
}

int drmModeAtomicCommit(int fd, void *req, u32 flags, void *user_data)
{
    resolve();
    refresh_tunables();

    static int announced;
    if (!announced) { announced = 1; LOGI("active; panel %dx%d", PANEL_W, PANEL_H); }

    /* A validation pass must not drive the panel. */
    if (flags & ATOMIC_TEST_ONLY) { n_pend = 0; return real_commit(fd, req, flags, user_data); }

    if (!t_enable) { n_pend = 0; return real_commit(fd, req, flags, user_data); }

    attach_damage();

    struct epdc_damage_rect dmg[EPDC_DAMAGE_MAX];
    int dmg_full = 0, dmg_changed = 1;
    int n_dmg = read_damage(dmg, &dmg_full, &dmg_changed);

    /* SurfaceFlinger's sequence number is a precise "did anything change"
     * signal -- better than guessing from buffer ids, so it wins when present. */
    if (g_dmg) {
        if (!dmg_changed) { n_pend = 0; return real_commit(fd, req, flags, user_data); }
    } else if (t_skipsame && g_fbid_prop) {
        u32 sig = 0;
        for (int i = 0; i < n_pend; i++)
            sig = sig * 31u + pend[i] * 131u + pend_fb[i];
        if (sig == last_fb_sig) {
            n_pend = 0;
            return real_commit(fd, req, flags, user_data);
        }
        last_fb_sig = sig;
    }

    long t  = now_ms();
    long dt = last_inject_ms ? t - last_inject_ms : -1;

    /* Page-turn mode.
     *
     * Measured against COMMIT arrival, not against the last injected update,
     * and evaluated before the interval throttle. That matters: the throttle
     * drops commits without advancing last_inject_ms, so dt there is always at
     * least t_interval. With interval >= fastms the motion test can never be
     * true, and an earlier version of this put the check inside init_parms
     * where it silently never fired -- identical frame counts with it on and
     * off, which is how it was caught.
     *
     * While commits keep arriving inside t_defer ms of each other the content
     * is animating, so submit nothing: the panel holds the previous page and
     * the slide happens entirely in the framebuffer. The first commit that
     * arrives after a gap draws once, as a full flash, and by then the frame
     * is the settled page. */
    long dt_commit = last_commit_ms ? t - last_commit_ms : -1;
    last_commit_ms = t;

    if (t_defer > 0) {
        if (dt_commit >= 0 && dt_commit < t_defer
            && (t_defermax <= 0 || ++deferred_frames < t_defermax)) {
            defer_pending = 1;
            /* Arm the settle thread. It is what actually draws in this mode:
             * it waits for quiet and then paints the settled frame through the
             * handwrite path, needing no further commit from the app. Without
             * this the suppressed frames would never be drawn at all -- which
             * is exactly the page turn that rendered nothing in the previous
             * attempt. */
            g_settle_pending = 1;
            start_settle_thread();
            n_pend = 0;
            return real_commit(fd, req, flags, user_data);
        }
        if (defer_pending) {
            defer_pending = 0;
            deferred_frames = 0;

            /* Let the SETTLE draw it, not this commit.
             *
             * Drawing here was the source of both remaining complaints. It went
             * through init_parms with force_full, which selects t_wf (GC16) and
             * t_cleanmode (1) -- a full drive, which takes every pixel through
             * black on its way to the new page. That is the black flash. It also
             * meant every page turn was painted twice, once here and once by the
             * settle, and during a finger drag the intermediate frames that got
             * through here are the animation that was still visible.
             *
             * The settle thread can paint the live screen on its own through the
             * handwrite path, needing no commit from the app, so there is nothing
             * this commit adds except the flash. Suppress it too and let the
             * settle be the only writer while deferring.
             *
             * Only when a settle is actually configured. With settlems 0 nothing
             * else would ever draw, and a page turn that renders nothing is worse
             * than one that flashes. */
            if (t_settlems > 0) {
                g_settle_pending = 1;
                start_settle_thread();
                n_pend = 0;
                return real_commit(fd, req, flags, user_data);
            }
            dmg_full = 1;              /* no settle configured: draw here */
        }
    }

    if (t_interval > 0 && dt >= 0 && dt < t_interval) {
        n_pend = 0;
        return real_commit(fd, req, flags, user_data);
    }
    last_inject_ms = t;

    int n_rect = init_parms(dt, dmg, n_dmg, dmg_full);

    /* Page-turn mode asked for this frame to be dropped. Let the composer's
     * own commit through untouched -- without our two properties the kernel
     * iterates zero rectangles and copies nothing, so the panel holds what it
     * already had. That is the whole trick: the animation runs in the
     * framebuffer, and none of it reaches the glass. */
    if (n_rect < 0) {
        n_pend = 0;
        return real_commit(fd, req, flags, user_data);
    }

    g_settle_pending = 1;
    start_settle_thread();

    for (int i = 0; i < n_pend; i++) {
        int idx = lookup(fd, pend[i]);
        if (idx < 0) continue;
        if (!c_parms_prop[idx] || !c_cnt_prop[idx]) continue;
        real_add(req, pend[i], c_parms_prop[idx], (u64)(usize)&g_parms[0]);
        real_add(req, pend[i], c_cnt_prop[idx], (u64)n_rect);
    }
    n_pend = 0;

    return real_commit(fd, req, flags, user_data);
}

/* Freestanding: the compiler may still emit calls to these. */
void *memset(void *d, int c, usize n)
{
    unsigned char *p = d;
    while (n--) *p++ = (unsigned char)c;
    return d;
}

void *memcpy(void *d, const void *s, usize n)
{
    unsigned char *a = d;
    const unsigned char *b = s;
    while (n--) *a++ = *b++;
    return d;
}
