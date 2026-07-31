#!/usr/bin/env python3
"""Make DisplayEventReceiver::getEvents accept BOTH 216- and 224-byte Events.

WHY ADAPTIVE INSTEAD OF FIXED
-----------------------------
Onyx's libgui sendEvents provably writes 216 (mov w3,#0xd8); ours writes 224
(mov w3,#0xe0). With the shim hard-coded to 216, every receiver then aborted the
OTHER way -- `size=216, res=224` -- so a 224-byte producer is also on the wire.
BitTube is SOCK_SEQPACKET, so a read returns one whole datagram: 224 bytes means
one event from a 224-byte sender, full stop. Both dialects genuinely coexist and
a fixed size cannot work.

HOW IT AVOIDS THE ASSERT
------------------------
BitTube::recvObjects aborts when datagram_size % objSize != 0. Both 216 and 224
are multiples of 8, so reading with an 8-byte granule can never trip it. We then
demux by datagram size ourselves.

It also logs, once per distinct size per process, what it actually saw -- that is
the measurement that tells us which producers speak which dialect.
"""
F = "/aosp/frameworks/native/libs/gui/DisplayEventReceiver.cpp"
s = open(F).read()

start = s.index("// onyx-sf branch: Onyx's SurfaceFlinger sends 216-byte Events")
end = s.index("ssize_t DisplayEventReceiver::sendEvents(Event const* events, size_t count)")
NEW = '''// onyx-sf branch: the wire carries BOTH 216-byte (Onyx libgui) and 224-byte
// (our libgui) Events -- verified from sendEvents in each: mov w3,#0xd8 vs
// #0xe0. BitTube is SOCK_SEQPACKET so one read == one datagram, and a 224-byte
// datagram cannot be a partial 216 event. So accept either.
//
// The only structural difference is our `numberQueuedBuffers` (4 bytes + 4
// padding) sitting between frameTimelinesLength and frameTimelines. Confirmed
// from their binary: VsyncEventData::preferredVsyncId() loads frameTimelines
// from [x8,#0x10] in theirs and [x8,#0x18] in ours.
static constexpr size_t kOnyxEventSize = 216;
static constexpr size_t kHeadBytes     = 48;   // Header + union head, identical
static constexpr size_t kGapBytes      = 8;    // numberQueuedBuffers + padding
static constexpr size_t kTailBytes     = 168;  // frameTimelines[7]

ssize_t DisplayEventReceiver::getEvents(gui::BitTube* dataChannel,
        Event* events, size_t count)
{
    static_assert(sizeof(Event) == kHeadBytes + kGapBytes + kTailBytes,
                  "Event layout changed; the onyx-sf shim needs updating");
    static_assert(kOnyxEventSize == kHeadBytes + kTailBytes, "shim arithmetic");
    static_assert(sizeof(Event) % 8 == 0 && kOnyxEventSize % 8 == 0,
                  "8-byte granule read relies on both sizes being multiples of 8");

    // Read with an 8-byte granule: BitTube::recvObjects aborts unless the
    // datagram is a multiple of objSize, and 8 divides both 216 and 224.
    struct Gran { uint8_t b[8]; };
    static thread_local std::vector<Gran> raw;
    const size_t granules = count * (sizeof(Event) / 8);
    if (raw.size() < granules) raw.resize(granules);

    ssize_t g = gui::BitTube::recvObjects(dataChannel, raw.data(), granules);
    if (g <= 0) return g;
    const size_t bytes = (size_t)g * 8;

    const uint8_t* src = raw[0].b;
    if (bytes % sizeof(Event) == 0) {
        // Our own dialect: straight copy.
        const size_t n = bytes / sizeof(Event);
        memcpy(events, src, bytes);
        static thread_local bool logged = false;
        if (!logged) { logged = true;
            ALOGI("onyx-sf: display events are %zu-byte (ours), %zu per read",
                  sizeof(Event), n); }
        return (ssize_t)n;
    }
    if (bytes % kOnyxEventSize == 0) {
        const size_t n = bytes / kOnyxEventSize;
        for (size_t i = 0; i < n; i++) {
            const uint8_t* s = src + i * kOnyxEventSize;
            uint8_t* d = reinterpret_cast<uint8_t*>(&events[i]);
            memcpy(d, s, kHeadBytes);
            memset(d + kHeadBytes, 0, kGapBytes);
            memcpy(d + kHeadBytes + kGapBytes, s + kHeadBytes, kTailBytes);
        }
        static thread_local bool logged = false;
        if (!logged) { logged = true;
            ALOGI("onyx-sf: display events are %zu-byte (Onyx), %zu per read, adapted",
                  kOnyxEventSize, n); }
        return (ssize_t)n;
    }
    ALOGE("onyx-sf: unrecognised display-event datagram of %zu bytes "
          "(not a multiple of %zu or %zu) -- dropping",
          bytes, sizeof(Event), kOnyxEventSize);
    return 0;
}

'''
s = s[:start] + NEW + s[end:]
if "#include <log/log.h>" not in s:
    s = s.replace("#include <cstring>", "#include <cstring>\n#include <log/log.h>", 1)
open(F, "w").write(s)
print("adaptive shim installed")
