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
static int commits_since_recheck = RECHECK;   /* force a read on first commit */
static long last_inject_ms;

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

#define LOGI(...) do { if (p_log) p_log(4, "epdcshim", __VA_ARGS__); } while (0)

/* --- per-object property-id cache --------------------------------------- */
#define MAX_OBJ 32
static u32 c_obj[MAX_OBJ];
static u32 c_parms_prop[MAX_OBJ];
static u32 c_cnt_prop[MAX_OBJ];
static int c_n;

/* object ids the composer itself placed in the current request */
static u32 pend[MAX_OBJ];
static int n_pend;

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
}

static void init_parms(void)
{
    g_parms[0].rect[0] = 0;
    g_parms[0].rect[1] = 0;
    g_parms[0].rect[2] = PANEL_W;
    g_parms[0].rect[3] = PANEL_H;
    g_parms[0].waveform_mode = t_wf;
    g_parms[0].update_mode   = t_upd;
    g_parms[0].flag          = t_flag;
    g_parms[0].temp          = 0;
    g_parms[0].reserved      = 0;
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
    for (u32 i = 0; i < op->count_props; i++) {
        propres_t *pr = p_get_prop(fd, op->props[i]);
        if (!pr) continue;
        if (str_eq(pr->name, "EPDC_UPDATE_PARMS_ADDR"))
            c_parms_prop[idx] = pr->prop_id;
        else if (str_eq(pr->name, "EPDC_UPDATE_CNT"))
            c_cnt_prop[idx] = pr->prop_id;
        if (p_free_prop) p_free_prop(pr);
    }
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
    int seen = 0;
    for (int i = 0; i < n_pend; i++)
        if (pend[i] == object_id) { seen = 1; break; }
    if (!seen && n_pend < MAX_OBJ) pend[n_pend++] = object_id;

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

    if (t_interval > 0) {
        long t = now_ms();
        if (t - last_inject_ms < t_interval) {
            n_pend = 0;
            return real_commit(fd, req, flags, user_data);
        }
        last_inject_ms = t;
    }

    init_parms();
    g_parms[0].update_marker++;

    for (int i = 0; i < n_pend; i++) {
        int idx = lookup(fd, pend[i]);
        if (idx < 0) continue;
        if (!c_parms_prop[idx] || !c_cnt_prop[idx]) continue;
        real_add(req, pend[i], c_parms_prop[idx], (u64)(usize)&g_parms[0]);
        real_add(req, pend[i], c_cnt_prop[idx], 1);
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
