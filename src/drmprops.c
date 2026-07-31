/*
 * drmprops -- enumerate DRM objects and their properties on /dev/dri/card0.
 *
 * Looking for Onyx-added EPD properties. The kernel exports
 * drm_atomic_helper_{update_plane,commit_planes,cleanup_planes}_epdc and the
 * boot log shows SurfaceFlinger reaching epdc via msm_drm_open, so EPD refresh
 * behaviour is expected to ride on DRM plane/CRTC properties rather than
 * /dev/ebc ioctls.
 *
 * READ-ONLY: only GET ioctls plus the two client caps needed to see the full
 * object set. Never sets a property.
 *
 * usage: drmprops [/dev/dri/card0]
 */

#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>

/* Minimal DRM ABI -- avoids depending on kernel headers being present. */
struct drm_set_client_cap { uint64_t capability, value; };
#define DRM_CLIENT_CAP_UNIVERSAL_PLANES 2
#define DRM_CLIENT_CAP_ATOMIC           3

struct drm_mode_card_res {
    uint64_t fb_id_ptr, crtc_id_ptr, connector_id_ptr, encoder_id_ptr;
    uint32_t count_fbs, count_crtcs, count_connectors, count_encoders;
    uint32_t min_width, max_width, min_height, max_height;
};
struct drm_mode_get_plane_res { uint64_t plane_id_ptr; uint32_t count_planes; };
struct drm_mode_obj_get_properties {
    uint64_t props_ptr, prop_values_ptr;
    uint32_t count_props, obj_id, obj_type;
};
struct drm_mode_get_property {
    uint64_t values_ptr, enum_blob_ptr;
    uint32_t prop_id, flags;
    char name[32];
    uint32_t count_values, count_enum_blobs;
};

#define DRM_IOCTL_SET_CLIENT_CAP      _IOW('d', 0x0d, struct drm_set_client_cap)
#define DRM_IOCTL_MODE_GETRESOURCES   _IOWR('d', 0xA0, struct drm_mode_card_res)
#define DRM_IOCTL_MODE_GETPROPERTY    _IOWR('d', 0xAA, struct drm_mode_get_property)
#define DRM_IOCTL_MODE_OBJ_GETPROPERTIES _IOWR('d', 0xB9, struct drm_mode_obj_get_properties)
#define DRM_IOCTL_MODE_GETPLANERESOURCES _IOWR('d', 0xB5, struct drm_mode_get_plane_res)

#define OBJ_CRTC      0xcccccccc
#define OBJ_CONNECTOR 0xc0c0c0c0
#define OBJ_PLANE     0xeeeeeeee

static int fd;

static void dump_obj(uint32_t id, uint32_t type, const char *label)
{
    struct drm_mode_obj_get_properties op;
    memset(&op, 0, sizeof(op));
    op.obj_id = id;
    op.obj_type = type;
    if (ioctl(fd, DRM_IOCTL_MODE_OBJ_GETPROPERTIES, &op) < 0 || !op.count_props)
        return;

    uint32_t n = op.count_props;
    uint32_t *ids = calloc(n, sizeof(*ids));
    uint64_t *vals = calloc(n, sizeof(*vals));
    op.props_ptr = (uint64_t)(uintptr_t)ids;
    op.prop_values_ptr = (uint64_t)(uintptr_t)vals;
    op.count_props = n;
    if (ioctl(fd, DRM_IOCTL_MODE_OBJ_GETPROPERTIES, &op) < 0) {
        free(ids); free(vals);
        return;
    }

    printf("\n== %s id=%u (%u props) ==\n", label, id, op.count_props);
    for (uint32_t i = 0; i < op.count_props; i++) {
        struct drm_mode_get_property gp;
        memset(&gp, 0, sizeof(gp));
        gp.prop_id = ids[i];
        if (ioctl(fd, DRM_IOCTL_MODE_GETPROPERTY, &gp) < 0)
            continue;
        gp.name[sizeof(gp.name) - 1] = '\0';
        printf("  %-34s id=%-4u value=%llu\n", gp.name, ids[i],
               (unsigned long long)vals[i]);
    }
    free(ids); free(vals);
}

int main(int argc, char **argv)
{
    setvbuf(stdout, NULL, _IONBF, 0);
    const char *dev = argc > 1 ? argv[1] : "/dev/dri/card0";
    fd = open(dev, O_RDWR);
    if (fd < 0) {
        fprintf(stderr, "open(%s): %s\n", dev, strerror(errno));
        return 1;
    }

    /* Without these caps the kernel hides overlay/cursor planes and the
     * atomic-only properties, which is exactly where vendor additions live. */
    struct drm_set_client_cap cap;
    cap.capability = DRM_CLIENT_CAP_UNIVERSAL_PLANES; cap.value = 1;
    ioctl(fd, DRM_IOCTL_SET_CLIENT_CAP, &cap);
    cap.capability = DRM_CLIENT_CAP_ATOMIC; cap.value = 1;
    ioctl(fd, DRM_IOCTL_SET_CLIENT_CAP, &cap);

    struct drm_mode_card_res res;
    memset(&res, 0, sizeof(res));
    if (ioctl(fd, DRM_IOCTL_MODE_GETRESOURCES, &res) < 0) {
        fprintf(stderr, "GETRESOURCES: %s\n", strerror(errno));
        return 1;
    }
    uint32_t nc = res.count_crtcs, nn = res.count_connectors;
    uint32_t *crtcs = calloc(nc ? nc : 1, 4), *conns = calloc(nn ? nn : 1, 4);
    memset(&res, 0, sizeof(res));
    res.crtc_id_ptr = (uint64_t)(uintptr_t)crtcs;
    res.connector_id_ptr = (uint64_t)(uintptr_t)conns;
    res.count_crtcs = nc; res.count_connectors = nn;
    ioctl(fd, DRM_IOCTL_MODE_GETRESOURCES, &res);
    printf("crtcs=%u connectors=%u\n", res.count_crtcs, res.count_connectors);

    struct drm_mode_get_plane_res pr;
    memset(&pr, 0, sizeof(pr));
    ioctl(fd, DRM_IOCTL_MODE_GETPLANERESOURCES, &pr);
    uint32_t np = pr.count_planes;
    uint32_t *planes = calloc(np ? np : 1, 4);
    memset(&pr, 0, sizeof(pr));
    pr.plane_id_ptr = (uint64_t)(uintptr_t)planes;
    pr.count_planes = np;
    ioctl(fd, DRM_IOCTL_MODE_GETPLANERESOURCES, &pr);
    printf("planes=%u\n", pr.count_planes);

    for (uint32_t i = 0; i < res.count_crtcs; i++)
        dump_obj(crtcs[i], OBJ_CRTC, "CRTC");
    for (uint32_t i = 0; i < res.count_connectors; i++)
        dump_obj(conns[i], OBJ_CONNECTOR, "CONNECTOR");
    for (uint32_t i = 0; i < pr.count_planes; i++)
        dump_obj(planes[i], OBJ_PLANE, "PLANE");

    close(fd);
    return 0;
}
