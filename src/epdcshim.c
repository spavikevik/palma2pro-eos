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
    i32 flag;           /* +0x20  0x21000 is accepted by the driver         */
    i32 reserved;       /* +0x24                                            */
};
_Static_assert(sizeof(struct upd) == 40, "kernel copies 8 x 40 bytes");

static struct upd g_parms[8];

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
 */
#define RECHECK 30
static int t_enable   = 1;
static int t_wf       = 2;
static int t_upd      = 1;
static int t_flag     = 0x21000;
static int t_interval;
static int t_fastwf;      /* waveform to use while the screen is in motion   */
static int t_fastms  = 250;
static int t_fullevery;   /* force a full-flash clean every N updates        */
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
static int t_settlems;            /* 0 disables */
static int t_settlewf = 2;        /* GC16: the quality mode */

static void settle_now(void)
{
    if (!p_open || !p_ioctl) return;
    int fd = p_open(EBC_DEVICE, 2 /* O_RDWR */);
    if (fd < 0) return;

    struct ebc_upd u;
    for (usize i = 0; i < sizeof u; i++) ((unsigned char *)&u)[i] = 0;
    u.rect[0] = 0; u.rect[1] = 0; u.rect[2] = PANEL_W; u.rect[3] = PANEL_H;
    u.waveform_mode = t_settlewf;
    u.update_mode   = 1;          /* a settle is deliberately the full pass */
    /* Markers MUST be unique. The driver tracks them and blocks in
     * onyx_epdc_fb_wait_updates_complete() until the marker it is waiting on
     * completes; sending the same marker every time made each settle collide
     * with the previous one, which left the panel mid-waveform and BLANK. The
     * symptom was 'Waiting for update marker magic[1] complete' repeating
     * forever in dmesg. */
    static i32 marker;
    if (++marker <= 0) marker = 1;
    u.update_marker = marker;
    u.flag          = t_flag;
    p_ioctl(fd, EBC_SEND_UPDATE, &u);
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
    t_upd      = (int)prop_num("persist.epdcshim.upd", 1);
    t_flag     = (int)prop_num("persist.epdcshim.flag", 0x21000);
    t_interval = (int)prop_num("persist.epdcshim.interval", 0);
    t_fastwf   = (int)prop_num("persist.epdcshim.fastwf", 0);
    t_fastms   = (int)prop_num("persist.epdcshim.fastms", 250);
    t_fullevery= (int)prop_num("persist.epdcshim.fullevery", 0);
    t_skipsame = (int)prop_num("persist.epdcshim.skipsame", 1);
    /* Default is longer than a GC16 takes (~450 ms). A shorter window lets a
     * settle land inside an update that is still running. */
    t_settlems = (int)prop_num("persist.epdcshim.settlems", 0);
    t_settlewf = (int)prop_num("persist.epdcshim.settlewf", 2);
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

    if (t_fastwf > 0 && dt_ms >= 0 && dt_ms < t_fastms)
        wf = t_fastwf;                       /* screen is moving */

    if (t_fullevery > 0 && ++updates_since_full >= t_fullevery) {
        updates_since_full = 0;
        force_full = 1;
        wf  = t_wf;                          /* quality waveform ... */
        upd = 1;                             /* ... and a full flash */
    }

    int n = (force_full || n_dmg <= 0) ? 0 : n_dmg;
    if (n > (int)EPDC_DAMAGE_MAX) n = (int)EPDC_DAMAGE_MAX;

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
        g_parms[i].update_marker = g_parms[0].update_marker;
        g_parms[i].flag          = t_flag;
        g_parms[i].temp          = 0;
        g_parms[i].reserved      = 0;
    }
    return n ? n : 1;
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

    if (t_interval > 0 && dt >= 0 && dt < t_interval) {
        n_pend = 0;
        return real_commit(fd, req, flags, user_data);
    }
    last_inject_ms = t;

    g_parms[0].update_marker++;
    int n_rect = init_parms(dt, dmg, n_dmg, dmg_full);
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
