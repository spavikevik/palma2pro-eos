#!/usr/bin/env python3
"""Adapt Onyx's 216-byte DisplayEventReceiver::Event to our 224-byte one.

Run on the builder.

WHY
---
Onyx's SurfaceFlinger writes display events (vsync, hotplug, mode change) into a
BitTube as raw structs. Their Event is 216 bytes; ours is 224. Our reader asks
for multiples of 224, gets 216, and aborts:

    BitTube::recvObjects(count=100, size=224), res=216 (partial events were received!)

The whole difference is one field. Verified from THEIR binary, not inferred:
VsyncEventData::preferredVsyncId() indexes frameTimelines[] with stride 24 in
both builds, but loads from [x8, #0x10] in theirs and [x8, #0x18] in ours -- so
their frameTimelines starts 8 bytes earlier. That gap is our
`numberQueuedBuffers` (4 bytes + 4 alignment), an AOSP addition for
buffer-stuffing detection that their build predates.

WHY ADAPT RATHER THAN DELETE THE FIELD
--------------------------------------
Deleting it would touch 8 files including Choreographer.java, the JNI and the
public Java DisplayEventReceiver, changing our ABI for every app. Adapting at
the single receive funnel keeps our struct, our ABI and buffer-stuffing
detection intact, and confines the compatibility hack to one function.

LAYOUT
------
Event = Header(24) + union. Within the VSync union member:

    theirs  [0,24) count,pad,frameInterval,preferredIdx,length
            [24,192) frameTimelines[7]
    ours    [0,24) same
            [24,32) numberQueuedBuffers + padding
            [32,200) frameTimelines[7]

so in whole-Event terms:

    dst[0,48)    <- src[0,48)     header + union head
    dst[48,56)   <- zero          numberQueuedBuffers + padding
    dst[56,224)  <- src[48,216)   frameTimelines

Safe for non-VSync events too: every other union member (Hotplug, ModeChange,
FrameRateOverride, HdcpLevelsChange, ModeRejection) fits inside the first 24
union bytes, which are copied verbatim.
"""
F = "/aosp/frameworks/native/libs/gui/DisplayEventReceiver.cpp"

OLD = """ssize_t DisplayEventReceiver::getEvents(gui::BitTube* dataChannel,
        Event* events, size_t count)
{
    return gui::BitTube::recvObjects(dataChannel, events, count);
}"""

NEW = """// onyx-sf branch: Onyx's SurfaceFlinger sends 216-byte Events, we expect 224.
// See scripts/onyx-sf/patch-displayeventreceiver.py for the derivation; the
// difference is our `numberQueuedBuffers` field, which their build predates.
// Read their layout and expand into ours rather than changing our struct.
static constexpr size_t kOnyxEventSize = 216;   // sizeof(Event) in Onyx's libgui
static constexpr size_t kHeadBytes     = 48;    // Header + union head, identical
static constexpr size_t kGapBytes      = 8;     // numberQueuedBuffers + padding
static constexpr size_t kTailBytes     = 168;   // frameTimelines[7]

ssize_t DisplayEventReceiver::getEvents(gui::BitTube* dataChannel,
        Event* events, size_t count)
{
    static_assert(sizeof(Event) == kHeadBytes + kGapBytes + kTailBytes,
                  "Event layout changed; the onyx-sf compat shim needs updating");
    static_assert(kOnyxEventSize == kHeadBytes + kTailBytes, "shim arithmetic");

    // Reused across calls: this is the vsync path and runs constantly.
    static thread_local std::vector<uint8_t> raw;
    if (raw.size() < count * kOnyxEventSize) raw.resize(count * kOnyxEventSize);

    ssize_t n = gui::BitTube::recvObjects(dataChannel, raw.data(), count,
                                          kOnyxEventSize);
    if (n <= 0) return n;

    for (ssize_t i = 0; i < n; i++) {
        const uint8_t* src = raw.data() + (size_t)i * kOnyxEventSize;
        uint8_t* dst = reinterpret_cast<uint8_t*>(&events[i]);
        memcpy(dst, src, kHeadBytes);
        memset(dst + kHeadBytes, 0, kGapBytes);
        memcpy(dst + kHeadBytes + kGapBytes, src + kHeadBytes, kTailBytes);
    }
    return n;
}"""

s = open(F).read()
assert OLD in s, "getEvents body not found -- source changed?"
s = s.replace(OLD, NEW, 1)
if "#include <vector>" not in s:
    s = s.replace("#include <gui/DisplayEventReceiver.h>",
                  "#include <cstring>\n#include <vector>\n\n#include <gui/DisplayEventReceiver.h>", 1)
open(F, "w").write(s)
print("patched DisplayEventReceiver::getEvents")
