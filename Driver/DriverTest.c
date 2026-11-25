// Loads the built driver bundle in-process with a stand-in host and exercises its properties,
// sample-rate change, clock, loopback IO, volume and mute — so the driver can be checked before
// it is installed into coreaudiod.   Usage: DriverTest path/to/BRIRConvolverSurround.driver

#include <CoreAudio/AudioServerPlugIn.h>
#include <CoreFoundation/CoreFoundation.h>
#include <math.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

static int failures = 0;
#define CHECK(cond, ...) do { int ok_ = (cond); printf(ok_ ? "[PASS] " : "[FAIL] "); printf(__VA_ARGS__); printf("\n"); if (!ok_) failures++; } while (0)

enum { PLUGIN = kAudioObjectPlugInObject, DEVICE = 2, IN_STREAM = 3, OUT_STREAM = 4, VOLUME = 5, MUTE = 6 };
#define CH 12

static int gRequests = 0, gChanges = 0;
static UInt64 gAction = 0;
static OSStatus HostPropertiesChanged(AudioServerPlugInHostRef h, AudioObjectID o, UInt32 n, const AudioObjectPropertyAddress a[]) {
    (void)h; (void)o; (void)a; gChanges += (int)n; return 0;
}
static OSStatus HostCopy(AudioServerPlugInHostRef h, CFStringRef k, CFPropertyListRef* out) { (void)h; (void)k; *out = NULL; return 0; }
static OSStatus HostWrite(AudioServerPlugInHostRef h, CFStringRef k, CFPropertyListRef d) { (void)h; (void)k; (void)d; return 0; }
static OSStatus HostDelete(AudioServerPlugInHostRef h, CFStringRef k) { (void)h; (void)k; return 0; }
static OSStatus HostRequest(AudioServerPlugInHostRef h, AudioObjectID dev, UInt64 action, void* info) {
    (void)h; (void)dev; (void)info; gRequests++; gAction = action; return 0;
}
static AudioServerPlugInHostInterface gHost = { HostPropertiesChanged, HostCopy, HostWrite, HostDelete, HostRequest };

static AudioServerPlugInDriverRef D;

static AudioObjectPropertyAddress Addr(AudioObjectPropertySelector s, AudioObjectPropertyScope sc) {
    AudioObjectPropertyAddress a = { s, sc, kAudioObjectPropertyElementMain };
    return a;
}
static OSStatus Get(AudioObjectID o, AudioObjectPropertySelector s, AudioObjectPropertyScope sc,
                    UInt32 qs, const void* q, UInt32 size, void* out, UInt32* outSize) {
    AudioObjectPropertyAddress a = Addr(s, sc);
    UInt32 os = 0;
    OSStatus st = (*D)->GetPropertyData(D, o, 0, &a, qs, q, size, &os, out);
    if (outSize) *outSize = os;
    return st;
}
static OSStatus Set(AudioObjectID o, AudioObjectPropertySelector s, UInt32 size, const void* data) {
    AudioObjectPropertyAddress a = Addr(s, kAudioObjectPropertyScopeGlobal);
    return (*D)->SetPropertyData(D, o, 0, &a, 0, NULL, size, data);
}
static bool StrEq(CFStringRef s, const char* c) {
    if (!s) return false;
    CFStringRef t = CFStringCreateWithCString(NULL, c, kCFStringEncodingUTF8);
    bool eq = CFStringCompare(s, t, 0) == kCFCompareEqualTo;
    CFRelease(t);
    CFRelease(s);
    return eq;
}
static UInt32 CountIDs(AudioObjectID o, AudioObjectPropertySelector s, AudioObjectPropertyScope sc) {
    AudioObjectID ids[16]; UInt32 n = 0;
    if (Get(o, s, sc, 0, NULL, sizeof(ids), ids, &n) != 0) return 999;
    return n / (UInt32)sizeof(AudioObjectID);
}

static void Write(Float64 t, Float32* buf, UInt32 frames) {
    AudioServerPlugInIOCycleInfo ci; memset(&ci, 0, sizeof(ci));
    ci.mOutputTime.mSampleTime = t;
    (*D)->DoIOOperation(D, DEVICE, OUT_STREAM, 0, kAudioServerPlugInIOOperationWriteMix, frames, &ci, buf, NULL);
}
static void Read(Float64 t, Float32* buf, UInt32 frames) {
    AudioServerPlugInIOCycleInfo ci; memset(&ci, 0, sizeof(ci));
    ci.mInputTime.mSampleTime = t;
    (*D)->DoIOOperation(D, DEVICE, IN_STREAM, 0, kAudioServerPlugInIOOperationReadInput, frames, &ci, buf, NULL);
}
static void Pattern(Float32* buf, UInt32 frames, Float64 t0) {
    for (UInt32 f = 0; f < frames; ++f)
        for (UInt32 c = 0; c < CH; ++c) buf[f * CH + c] = (Float32)(0.001 * fmod(t0 + f, 997.0) + 0.01 * c);
}
static double MaxDiff(const Float32* a, const Float32* b, UInt32 n, Float32 scaleB) {
    double m = 0;
    for (UInt32 i = 0; i < n; ++i) { double d = fabs((double)a[i] - (double)b[i] * scaleB); if (d > m) m = d; }
    return m;
}
static double MaxAbs(const Float32* a, UInt32 n) {
    double m = 0;
    for (UInt32 i = 0; i < n; ++i) if (fabs(a[i]) > m) m = fabs(a[i]);
    return m;
}

int main(int argc, const char* argv[]) {
    if (argc < 2) { fprintf(stderr, "usage: %s path/to/driver.bundle\n", argv[0]); return 2; }
    CFURLRef url = CFURLCreateFromFileSystemRepresentation(NULL, (const UInt8*)argv[1], (CFIndex)strlen(argv[1]), true);
    CFBundleRef bundle = CFBundleCreate(NULL, url);
    CHECK(bundle != NULL, "driver bundle opens");
    if (!bundle) return 1;
    typedef void* (*Factory)(CFAllocatorRef, CFUUIDRef);
    Factory factory = (Factory)CFBundleGetFunctionPointerForName(bundle, CFSTR("BRIRConvolverDevice_Create"));
    CHECK(factory != NULL, "factory function is exported");
    if (!factory) return 1;
    CFDictionaryRef factories = CFBundleGetValueForInfoDictionaryKey(bundle, CFSTR("CFPlugInFactories"));
    CHECK(factories && CFDictionaryGetCount(factories) == 1, "Info.plist declares one plug-in factory");

    D = (AudioServerPlugInDriverRef)factory(NULL, kAudioServerPlugInTypeUUID);
    CHECK(D != NULL, "factory returns a driver for the AudioServerPlugIn type");
    if (!D) return 1;
    void* iface = NULL;
    HRESULT hr = (*D)->QueryInterface(D, CFUUIDGetUUIDBytes(kAudioServerPlugInDriverInterfaceUUID), &iface);
    CHECK(hr == S_OK && iface == D, "QueryInterface(driver interface)");
    (*D)->Release(D);
    CHECK((*D)->Initialize(D, &gHost) == 0, "Initialize");

    // --- Object graph ---
    CHECK(CountIDs(PLUGIN, kAudioPlugInPropertyDeviceList, kAudioObjectPropertyScopeGlobal) == 1, "plug-in lists one device");
    CFStringRef uid = CFSTR("com.phil.brirconvolver.device.surround");
    AudioObjectID found = 0; UInt32 sz = 0;
    Get(PLUGIN, kAudioPlugInPropertyTranslateUIDToDevice, kAudioObjectPropertyScopeGlobal, sizeof(uid), &uid, sizeof(found), &found, &sz);
    CHECK(found == DEVICE, "TranslateUIDToDevice finds the device");
    CFStringRef s = NULL;
    Get(DEVICE, kAudioObjectPropertyName, kAudioObjectPropertyScopeGlobal, 0, NULL, sizeof(s), &s, NULL);
    CHECK(StrEq(s, "BRIR Convolver Surround"), "device name");
    s = NULL;
    Get(DEVICE, kAudioDevicePropertyDeviceUID, kAudioObjectPropertyScopeGlobal, 0, NULL, sizeof(s), &s, NULL);
    CHECK(StrEq(s, "com.phil.brirconvolver.device.surround"), "device UID");
    CHECK(CountIDs(DEVICE, kAudioDevicePropertyStreams, kAudioObjectPropertyScopeGlobal) == 2 &&
          CountIDs(DEVICE, kAudioDevicePropertyStreams, kAudioObjectPropertyScopeInput) == 1 &&
          CountIDs(DEVICE, kAudioDevicePropertyStreams, kAudioObjectPropertyScopeOutput) == 1, "one input and one output stream");
    CHECK(CountIDs(DEVICE, kAudioObjectPropertyControlList, kAudioObjectPropertyScopeGlobal) == 2, "volume and mute controls");

    AudioStreamBasicDescription f; memset(&f, 0, sizeof(f));
    Get(OUT_STREAM, kAudioStreamPropertyVirtualFormat, kAudioObjectPropertyScopeGlobal, 0, NULL, sizeof(f), &f, NULL);
    CHECK(f.mChannelsPerFrame == CH && f.mBitsPerChannel == 32 && (f.mFormatFlags & kAudioFormatFlagIsFloat) && f.mSampleRate == 48000,
          "stream format: %u ch, %u-bit float, %.0f Hz", f.mChannelsPerFrame, f.mBitsPerChannel, f.mSampleRate);
    UInt32 dir = 9;
    Get(IN_STREAM, kAudioStreamPropertyDirection, kAudioObjectPropertyScopeGlobal, 0, NULL, sizeof(dir), &dir, NULL);
    CHECK(dir == 1, "input stream direction");

    UInt8 layoutBuf[1024];
    UInt32 layoutSize = 0;
    OSStatus st = Get(DEVICE, kAudioDevicePropertyPreferredChannelLayout, kAudioObjectPropertyScopeOutput, 0, NULL,
                      sizeof(layoutBuf), layoutBuf, &layoutSize);
    const AudioChannelLayout* l = (const AudioChannelLayout*)layoutBuf;
    const AudioChannelLabel want[CH] = { 1, 2, 3, 4, 5, 6, 33, 34, 13, 15, 52, 54 };
    bool labelsOK = st == 0 && l->mNumberChannelDescriptions == CH;
    for (UInt32 i = 0; labelsOK && i < CH; ++i) labelsOK = l->mChannelDescriptions[i].mChannelLabel == want[i];
    CHECK(labelsOK, "7.1.4 channel layout (L R C LFE Ls Rs Lrs Rrs Ltf Rtf Ltr Rtr)");

    // Every advertised selector answers both HasProperty and a size query.
    struct { AudioObjectID o; AudioObjectPropertySelector s; } props[] = {
        { PLUGIN, kAudioObjectPropertyManufacturer }, { PLUGIN, kAudioPlugInPropertyResourceBundle },
        { DEVICE, kAudioDevicePropertyTransportType }, { DEVICE, kAudioDevicePropertyAvailableNominalSampleRates },
        { DEVICE, kAudioDevicePropertyZeroTimeStampPeriod }, { DEVICE, kAudioDevicePropertyPreferredChannelsForStereo },
        { DEVICE, kAudioDevicePropertyDeviceCanBeDefaultDevice }, { IN_STREAM, kAudioStreamPropertyAvailablePhysicalFormats },
        { VOLUME, kAudioLevelControlPropertyDecibelRange }, { MUTE, kAudioBooleanControlPropertyValue },
    };
    bool allHave = true;
    for (size_t i = 0; i < sizeof(props) / sizeof(props[0]); ++i) {
        AudioObjectPropertyAddress a = Addr(props[i].s, kAudioObjectPropertyScopeGlobal);
        UInt32 n = 0;
        if (!(*D)->HasProperty(D, props[i].o, 0, &a) || (*D)->GetPropertyDataSize(D, props[i].o, 0, &a, 0, NULL, &n) != 0 || n == 0)
            allHave = false;
    }
    AudioObjectPropertyAddress bogus = Addr('zzzz', kAudioObjectPropertyScopeGlobal);
    CHECK(allHave && !(*D)->HasProperty(D, DEVICE, 0, &bogus), "HasProperty / GetPropertyDataSize agree; unknown selectors rejected");
    Boolean settable = false;
    AudioObjectPropertyAddress rateAddr = Addr(kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal);
    (*D)->IsPropertySettable(D, DEVICE, 0, &rateAddr, &settable);
    CHECK(settable, "nominal sample rate is settable");

    // --- Sample-rate change goes through the host's configuration-change request ---
    Float64 rate = 44100;
    CHECK(Set(DEVICE, kAudioDevicePropertyNominalSampleRate, sizeof(rate), &rate) == 0 && gRequests == 1 && gAction == 44100,
          "setting 44.1 kHz requests a configuration change");
    (*D)->PerformDeviceConfigurationChange(D, DEVICE, gAction, NULL);
    rate = 0;
    Get(DEVICE, kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal, 0, NULL, sizeof(rate), &rate, NULL);
    CHECK(rate == 44100, "rate after the change: %.0f Hz", rate);
    Float64 bad = 12345;
    CHECK(Set(DEVICE, kAudioDevicePropertyNominalSampleRate, sizeof(bad), &bad) != 0, "unsupported rate rejected");
    rate = 48000;
    Set(DEVICE, kAudioDevicePropertyNominalSampleRate, sizeof(rate), &rate);
    (*D)->PerformDeviceConfigurationChange(D, DEVICE, gAction, NULL);

    // --- IO ---
    CHECK((*D)->StartIO(D, DEVICE, 1) == 0, "StartIO");
    Boolean will = false, inPlace = false;
    (*D)->WillDoIOOperation(D, DEVICE, 1, kAudioServerPlugInIOOperationWriteMix, &will, &inPlace);
    Boolean willRead = false;
    (*D)->WillDoIOOperation(D, DEVICE, 1, kAudioServerPlugInIOOperationReadInput, &willRead, &inPlace);
    CHECK(will && willRead && inPlace, "does WriteMix and ReadInput in place");

    enum { N = 512 };
    static Float32 src[N * CH], dst[N * CH];
    Pattern(src, N, 1000);
    Write(1000, src, N);
    Read(1000, dst, N);
    CHECK(MaxDiff(dst, src, N * CH, 1) == 0, "loopback: input returns exactly what was played");
    Read(1000 + N, dst, N);
    CHECK(MaxAbs(dst, N * CH) == 0, "frames not yet played read as silence");
    Pattern(src, N, 16000);
    Write(16000, src, N);    // crosses the ring's wrap point (16384)
    Read(16000, dst, N);
    CHECK(MaxDiff(dst, src, N * CH, 1) == 0, "loopback across the ring wrap");

    // Volume (gain = scalar²) and mute
    Float32 v = 0.5f;
    Set(VOLUME, kAudioLevelControlPropertyScalarValue, sizeof(v), &v);
    Float32 db = 0;
    Get(VOLUME, kAudioLevelControlPropertyDecibelValue, kAudioObjectPropertyScopeGlobal, 0, NULL, sizeof(db), &db, NULL);
    Pattern(src, N, 17000);
    Write(16000 + N, src, N);
    Read(16000 + N, dst, N);
    CHECK(MaxDiff(dst, src, N * CH, 0.25f) < 1e-7 && fabs(db - 40 * log10(0.5)) < 1e-3 && gChanges > 0,
          "volume 0.5 → gain 0.25 (%.2f dB), listeners notified", db);
    Float32 conv = 1.0f;
    Get(VOLUME, kAudioLevelControlPropertyConvertScalarToDecibels, kAudioObjectPropertyScopeGlobal, 0, NULL, sizeof(conv), &conv, NULL);
    CHECK(conv == 0, "scalar 1 converts to 0 dB");
    v = 1;
    Set(VOLUME, kAudioLevelControlPropertyScalarValue, sizeof(v), &v);
    UInt32 mute = 1;
    Set(MUTE, kAudioBooleanControlPropertyValue, sizeof(mute), &mute);
    Write(16000 + 2 * N, src, N);
    Read(16000 + 2 * N, dst, N);
    CHECK(MaxAbs(dst, N * CH) == 0, "mute silences the output");
    mute = 0;
    Set(MUTE, kAudioBooleanControlPropertyValue, sizeof(mute), &mute);

    // After a gap longer than the ring, stale audio from the previous lap must not reappear.
    const Float64 t1 = 200000, t2 = t1 + 16384 + 100;
    Pattern(src, N, t1);
    Write(t1, src, N);
    Pattern(src, N, t2);
    Write(t2, src, N);
    Read(t2 - 50, dst, 50);   // same ring slots as t1 + 16384 − 50 … written one lap earlier
    CHECK(MaxAbs(dst, 50 * CH) == 0, "a gap in playback reads as silence, not stale audio");
    Read(t1, dst, N);
    CHECK(MaxAbs(dst, N * CH) == 0, "audio older than one ring length reads as silence");

    // Clock: one zero timestamp per 16384 frames.
    Float64 st0 = -1; UInt64 h0 = 0, seed = 0;
    (*D)->GetZeroTimeStamp(D, DEVICE, 1, &st0, &h0, &seed);
    usleep(400000);   // > 16384 / 48000 s
    Float64 st1 = -1; UInt64 h1 = 0;
    (*D)->GetZeroTimeStamp(D, DEVICE, 1, &st1, &h1, &seed);
    CHECK(st0 == 0 && st1 == 16384 && h1 > h0 && seed == 1, "zero timestamps advance by one period (%.0f → %.0f)", st0, st1);
    UInt32 running = 0;
    Get(DEVICE, kAudioDevicePropertyDeviceIsRunning, kAudioObjectPropertyScopeGlobal, 0, NULL, sizeof(running), &running, NULL);
    CHECK(running == 1, "device reports running");
    CHECK((*D)->StopIO(D, DEVICE, 1) == 0, "StopIO");

    printf(failures ? "DRIVER TESTS FAILED (%d)\n" : "ALL DRIVER TESTS PASSED\n", failures);
    return failures ? 1 : 0;
}
