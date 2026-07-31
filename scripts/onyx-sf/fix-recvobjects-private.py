F = "/aosp/frameworks/native/libs/gui/DisplayEventReceiver.cpp"
s = open(F).read()

OLD = """    // Reused across calls: this is the vsync path and runs constantly.
    static thread_local std::vector<uint8_t> raw;
    if (raw.size() < count * kOnyxEventSize) raw.resize(count * kOnyxEventSize);

    ssize_t n = gui::BitTube::recvObjects(dataChannel, raw.data(), count,
                                          kOnyxEventSize);"""

NEW = """    // BitTube's raw recvObjects(void*, count, objSize) is private; the public
    // entry is a template that takes sizeof(T) from the argument type. So hand
    // it a POD of exactly Onyx's Event size and the right objSize follows.
    struct OnyxEvent { uint8_t bytes[kOnyxEventSize]; };
    static_assert(sizeof(OnyxEvent) == kOnyxEventSize, "padding crept in");

    // Reused across calls: this is the vsync path and runs constantly.
    static thread_local std::vector<OnyxEvent> raw;
    if (raw.size() < count) raw.resize(count);

    ssize_t n = gui::BitTube::recvObjects(dataChannel, raw.data(), count);"""

assert OLD in s
s = s.replace(OLD, NEW, 1)
s = s.replace("const uint8_t* src = raw.data() + (size_t)i * kOnyxEventSize;",
              "const uint8_t* src = raw[i].bytes;", 1)
open(F, "w").write(s)
print("patched to use the public templated recvObjects")
