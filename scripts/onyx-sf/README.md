# onyx-sf staging scripts

Run **on the builder**, against the AOSP tree at `/aosp`. They exist so the
branch is reproducible; the blobs themselves are never committed.

| script | what it does |
|---|---|
| `gen-prebuilt-mk.py` | writes `device/onyx/Palma2_Pro_C/onyx-sf.mk` -- `PRODUCT_COPY_FILES` for every lib in `onyx-sf/lib64/` plus the SF binary, and the two SIGSEGV-avoiding property sets. Also deletes macOS `._*` AppleDouble files, which a `tar` from a Mac will otherwise leave behind and which would double the lib count. |
| `patch-surfaceflinger-rc.py` | rewrites `frameworks/native/services/surfaceflinger/surfaceflinger.rc` to start `/system/bin/surfaceflinger_onyx` with `setenv LD_LIBRARY_PATH /system/lib64/onyxsf`. |

Staging the blobs (from the Mac, blobs live in the gitignored `firmware/`):

```sh
# exclude libbinder.so and libbinder_ndk.so -- see onyx-sf.mk for why
tar -C stage -cf - . | scripts/builder.sh ssh \
    'mkdir -p /aosp/device/onyx/Palma2_Pro_C/onyx-sf && \
     tar -C /aosp/device/onyx/Palma2_Pro_C/onyx-sf -xf -'
```

The one manual source edit not scripted here is moving
`getMaxLayerPictureProfiles` to the end of
`frameworks/native/libs/gui/aidl/android/gui/ISurfaceComposer.aidl`.
Verify it with:

```sh
scripts/aidl-txn-codes.py <built libgui.so> firmware/stock-extract/lib64/libgui.so
```

which should report `ALIGNED`.
