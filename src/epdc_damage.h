/*
 * epdc_damage.h -- the contract between SurfaceFlinger and the composer shim.
 *
 * WHY THIS FILE EXISTS
 * --------------------
 * The kernel refreshes the EPD per update rectangle and takes up to 8 of them
 * (a 320-byte array of 40-byte structs, see docs/11). Nothing in our stack
 * supplies any, so `libepdcshim.so` currently submits one rectangle covering
 * the whole panel on every commit. That works, but it repaints 1.36M pixels for
 * a single changed character: slow, and partial waveforms ghost across the
 * entire display instead of one small region.
 *
 * The damage is known -- SurfaceFlinger computes it every frame -- but there is
 * no way to get it down to the kernel through the normal path:
 *
 *   - the DRM planes expose no FB_DAMAGE_CLIPS (property vocabulary dumped in
 *     docs/11), so the shim cannot read damage from the atomic request
 *   - client composition is mandatory on this panel, which collapses everything
 *     into one full-screen plane whose CRTC rect is always the whole display
 *   - Onyx's own route (app -> libgui hwc_epdc_llist -> their SF -> composer)
 *     is a private transport that appears in no vendor library, so reproducing
 *     it means reverse engineering an undocumented interface
 *
 * This sidesteps all of that: SurfaceFlinger publishes its dirty region into a
 * small shared mapping, and the shim reads it. Both processes run as `system`,
 * so a tmpfs file under /dev is sufficient.
 *
 * CONCURRENCY
 * -----------
 * Single writer (SurfaceFlinger), single reader (the composer), no locking:
 * a seqlock. The writer bumps `seq` to an odd value, writes, then bumps it to
 * even. The reader takes `seq` before and after and retries if it is odd or
 * changed. A torn read is therefore never acted on, and neither side can block
 * the other -- which matters because both sit on the frame path.
 *
 * `seq` doubles as a change detector: if it has not moved, SurfaceFlinger has
 * not composited anything new and the panel must not be driven at all.
 *
 * COORDINATES
 * -----------
 * Rectangles must be in **output/framebuffer space** -- the same space as the
 * plane the kernel blits, i.e. 1648x824 landscape -- not layer-stack space
 * (824x1648 portrait). The display is installed rotated, so the writer has to
 * apply the output transform before publishing. Publishing layer-stack
 * coordinates would refresh the wrong region.
 */

#ifndef EPDC_DAMAGE_H
#define EPDC_DAMAGE_H

/* The shim is built freestanding (-nostdlib, target aarch64-linux-none) and has
 * no stdint.h, so it defines the two types itself and sets this guard. Keeping
 * one header for both sides is deliberate: the layout must not drift. */
#ifndef EPDC_DAMAGE_NO_STDINT
#include <stdint.h>
#endif

/* /dev itself is root-owned, so init must create this directory for
 * SurfaceFlinger (uid system) to create the file in. See
 * system/etc/init/epdc-clientcomp.rc. */
#define EPDC_DAMAGE_DIR     "/dev/epdc"
#define EPDC_DAMAGE_PATH    "/dev/epdc/damage"
#define EPDC_DAMAGE_MAGIC   0x43504445u   /* 'EDPC' */
#define EPDC_DAMAGE_VERSION 1u

/* The kernel copies a fixed 320-byte array of 8 update structs; more than 8
 * rectangles cannot be expressed, so the writer must merge down to this many. */
#define EPDC_DAMAGE_MAX     8u

struct epdc_damage_rect {
    int32_t left, top, right, bottom;
};

struct epdc_damage_shm {
    uint32_t magic;      /* EPDC_DAMAGE_MAGIC once initialised            */
    uint32_t version;    /* EPDC_DAMAGE_VERSION                            */
    uint32_t seq;        /* seqlock; odd = write in progress               */
    uint32_t count;      /* valid rectangles, 0..EPDC_DAMAGE_MAX           */
    uint32_t full;       /* writer asks for a full-panel refresh this frame */
    uint32_t reserved[3];
    struct epdc_damage_rect rect[EPDC_DAMAGE_MAX];
};

/* 8*4 + 8*16 = 160 bytes; a page is mapped and the rest left unused. */

#endif /* EPDC_DAMAGE_H */
