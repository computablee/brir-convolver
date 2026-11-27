// BRIR Convolver Surround — a virtual 12-channel (7.1.4) loopback audio device (Core Audio AudioServerPlugIn).
//
// Apps play into the device's output; the same audio appears on its input, where BRIR Convolver
// captures it. The device reports a 7.1.4 channel layout, so apps send surround (and, where they
// support it, Dolby Atmos rendered to 7.1.4) without any Audio MIDI Setup configuration. Stereo and
// 7.1 sources land on the matching channels. Its volume and mute controls are applied to the audio, so the
// keyboard volume keys keep working while it is the default output.
//
// Written from scratch against Apple's public <CoreAudio/AudioServerPlugIn.h> API.

#include <CoreAudio/AudioServerPlugIn.h>
#include <CoreFoundation/CoreFoundation.h>
#include <mach/mach_time.h>
#include <dispatch/dispatch.h>
#include <os/log.h>
#include <math.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stddef.h>
#include <string.h>

// MARK: - Configuration

#define kManufacturer   "BRIR Convolver"
#define kDeviceName     "BRIR Convolver Surround"
#define kDeviceUID      "com.phil.brirconvolver.device.surround"
#define kDeviceModelUID "com.phil.brirconvolver.device.model"

/// Channel layout (7.1.4, in the order of kAudioChannelLayoutTag_Atmos_7_1_4). To change the channel
/// count, edit this table only.
static const AudioChannelLabel kLabels[] = {
    kAudioChannelLabel_Left, kAudioChannelLabel_Right, kAudioChannelLabel_Center, kAudioChannelLabel_LFEScreen,
    kAudioChannelLabel_LeftSurround, kAudioChannelLabel_RightSurround,
    kAudioChannelLabel_RearSurroundLeft, kAudioChannelLabel_RearSurroundRight,
    kAudioChannelLabel_LeftTopFront, kAudioChannelLabel_RightTopFront,
    kAudioChannelLabel_LeftTopRear, kAudioChannelLabel_RightTopRear,
};
#define kChannels ((UInt32)(sizeof(kLabels) / sizeof(kLabels[0])))
#define kBytesPerFrame (kChannels * (UInt32)sizeof(Float32))

/// Ring buffer length in frames; also the zero-timestamp period.
#define kRingFrames 16384

static const Float64 kSampleRates[] = { 44100, 48000, 88200, 96000, 176400, 192000 };
#define kNumSampleRates ((UInt32)(sizeof(kSampleRates) / sizeof(kSampleRates[0])))

#define kMinDB (-64.0f)

enum {
    kObjectID_PlugIn = kAudioObjectPlugInObject,
    kObjectID_Device = 2,
    kObjectID_StreamInput = 3,
    kObjectID_StreamOutput = 4,
    kObjectID_Volume = 5,
    kObjectID_Mute = 6,
};

// MARK: - Interface declarations

static HRESULT  Drv_QueryInterface(void* inDriver, REFIID inUUID, LPVOID* outInterface);
static ULONG    Drv_AddRef(void* inDriver);
static ULONG    Drv_Release(void* inDriver);
static OSStatus Drv_Initialize(AudioServerPlugInDriverRef inDriver, AudioServerPlugInHostRef inHost);
static OSStatus Drv_CreateDevice(AudioServerPlugInDriverRef inDriver, CFDictionaryRef inDescription,
                                 const AudioServerPlugInClientInfo* inClientInfo, AudioObjectID* outDeviceObjectID);
static OSStatus Drv_DestroyDevice(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID);
static OSStatus Drv_AddDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID,
                                    const AudioServerPlugInClientInfo* inClientInfo);
static OSStatus Drv_RemoveDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID,
                                       const AudioServerPlugInClientInfo* inClientInfo);
static OSStatus Drv_PerformConfigChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID,
                                        UInt64 inChangeAction, void* inChangeInfo);
static OSStatus Drv_AbortConfigChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID,
                                      UInt64 inChangeAction, void* inChangeInfo);
static Boolean  Drv_HasProperty(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientPID,
                                const AudioObjectPropertyAddress* inAddress);
static OSStatus Drv_IsPropertySettable(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientPID,
                                       const AudioObjectPropertyAddress* inAddress, Boolean* outIsSettable);
static OSStatus Drv_GetPropertyDataSize(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientPID,
                                        const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize,
                                        const void* inQualifierData, UInt32* outDataSize);
static OSStatus Drv_GetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientPID,
                                    const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize,
                                    const void* inQualifierData, UInt32 inDataSize, UInt32* outDataSize, void* outData);
static OSStatus Drv_SetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientPID,
                                    const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize,
                                    const void* inQualifierData, UInt32 inDataSize, const void* inData);
static OSStatus Drv_StartIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID);
static OSStatus Drv_StopIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID);
static OSStatus Drv_GetZeroTimeStamp(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID,
                                     Float64* outSampleTime, UInt64* outHostTime, UInt64* outSeed);
static OSStatus Drv_WillDoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID,
                                      UInt32 inOperationID, Boolean* outWillDo, Boolean* outWillDoInPlace);
static OSStatus Drv_BeginIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID,
                                     UInt32 inOperationID, UInt32 inIOBufferFrameSize,
                                     const AudioServerPlugInIOCycleInfo* inIOCycleInfo);
static OSStatus Drv_DoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID,
                                  AudioObjectID inStreamObjectID, UInt32 inClientID, UInt32 inOperationID,
                                  UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo* inIOCycleInfo,
                                  void* ioMainBuffer, void* ioSecondaryBuffer);
static OSStatus Drv_EndIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID,
                                   UInt32 inOperationID, UInt32 inIOBufferFrameSize,
                                   const AudioServerPlugInIOCycleInfo* inIOCycleInfo);

static AudioServerPlugInDriverInterface gInterface = {
    NULL,
    Drv_QueryInterface, Drv_AddRef, Drv_Release,
    Drv_Initialize, Drv_CreateDevice, Drv_DestroyDevice,
    Drv_AddDeviceClient, Drv_RemoveDeviceClient,
    Drv_PerformConfigChange, Drv_AbortConfigChange,
    Drv_HasProperty, Drv_IsPropertySettable, Drv_GetPropertyDataSize, Drv_GetPropertyData, Drv_SetPropertyData,
    Drv_StartIO, Drv_StopIO, Drv_GetZeroTimeStamp,
    Drv_WillDoIOOperation, Drv_BeginIOOperation, Drv_DoIOOperation, Drv_EndIOOperation,
};
static AudioServerPlugInDriverInterface* gInterfacePtr = &gInterface;
static AudioServerPlugInDriverRef gDriverRef = &gInterfacePtr;

// MARK: - State

static pthread_mutex_t gStateMutex = PTHREAD_MUTEX_INITIALIZER;   // properties
static pthread_mutex_t gClockMutex = PTHREAD_MUTEX_INITIALIZER;   // zero timestamps
static UInt32 gRefCount = 0;
static AudioServerPlugInHostRef gHost = NULL;

static Float64 gSampleRate = 48000;
static UInt32 gIORunning = 0;
static Boolean gInputActive = true, gOutputActive = true;
static _Atomic(Float32) gVolume = 1.0f;     // scalar 0…1
static _Atomic(UInt32) gMute = 0;

static Float64 gHostTicksPerSecond = 0;
static Float64 gHostTicksPerFrame = 0;
static UInt64 gAnchorHostTime = 0;
static UInt64 gPeriodCount = 0;
/// Changes whenever the timeline restarts, so the HAL never mixes timestamps from two timelines.
static UInt64 gSeed = 1;

// Diagnostics (logged about every 2 s while IO runs): frames read that had data vs read as silence.
static _Atomic(UInt64) gReadValid = 0, gReadSilent = 0, gWriteCalls = 0;
static UInt64 gLastLogHost = 0;
static os_log_t gLog;

static Float32 gRing[kRingFrames * kChannels];
/// Sample time just past the last frame written. Frames in [gWriteEnd - kRingFrames, gWriteEnd) are valid.
static _Atomic(SInt64) gWriteEnd = 0;

// MARK: - Helpers

static inline UInt32 RingIndex(SInt64 t) {
    SInt64 m = t % kRingFrames;
    return (UInt32)(m < 0 ? m + kRingFrames : m);
}

static Float32 ScalarToDB(Float32 s) {
    if (!(s > 0)) return kMinDB;
    Float32 db = 40.0f * log10f(s);   // the gain applied is s², so this is its level in dB
    return db < kMinDB ? kMinDB : (db > 0 ? 0 : db);
}

static Float32 DBToScalar(Float32 db) {
    if (!(db > kMinDB)) return 0;
    if (db > 0) db = 0;
    return powf(10.0f, db / 40.0f);
}

static bool IsSupportedRate(Float64 r) {
    for (UInt32 i = 0; i < kNumSampleRates; ++i) if (kSampleRates[i] == r) return true;
    return false;
}

static void FillFormat(AudioStreamBasicDescription* f, Float64 rate) {
    memset(f, 0, sizeof(*f));
    f->mSampleRate = rate;
    f->mFormatID = kAudioFormatLinearPCM;
    f->mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsPacked;
    f->mBytesPerPacket = kBytesPerFrame;
    f->mFramesPerPacket = 1;
    f->mBytesPerFrame = kBytesPerFrame;
    f->mChannelsPerFrame = kChannels;
    f->mBitsPerChannel = 32;
}

static void Notify(AudioObjectID obj, AudioObjectPropertySelector sel) {
    if (!gHost) return;
    AudioObjectPropertyAddress a = { sel, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    gHost->PropertiesChanged(gHost, obj, 1, &a);
}

static void NotifyRunningAsync(void* ctx) { (void)ctx; Notify(kObjectID_Device, kAudioDevicePropertyDeviceIsRunning); }

/// Announce a running-state change outside StartIO/StopIO, which the host calls with its own locks held.
static void PostRunningChanged(void) {
    dispatch_async_f(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), NULL, NotifyRunningAsync);
}

/// Write a scalar property value; with outData == NULL only report the size.
#define RETURN_VALUE(type, expr)                                                       \
    do {                                                                               \
        *outSize = (UInt32)sizeof(type);                                               \
        if (outData) {                                                                 \
            if (inSize < sizeof(type)) return kAudioHardwareBadPropertySizeError;      \
            *(type*)outData = (expr);                                                  \
        }                                                                              \
        return kAudioHardwareNoError;                                                  \
    } while (0)

#define RETURN_STRING(literal) RETURN_VALUE(CFStringRef, (CFStringRef)CFRetain(CFSTR(literal)))

/// Write an array property: as many elements as fit.
static OSStatus ReturnArray(const void* items, UInt32 count, UInt32 itemSize, UInt32 inSize, UInt32* outSize, void* outData) {
    if (!outData) { *outSize = count * itemSize; return kAudioHardwareNoError; }
    UInt32 fit = inSize / itemSize;
    if (fit > count) fit = count;
    if (fit) memcpy(outData, items, fit * itemSize);
    *outSize = fit * itemSize;
    return kAudioHardwareNoError;
}

static OSStatus ReturnIDs(const AudioObjectID* ids, UInt32 n, UInt32 inSize, UInt32* outSize, void* outData) {
    return ReturnArray(ids, n, sizeof(AudioObjectID), inSize, outSize, outData);
}

// MARK: - Properties

static OSStatus PlugInProperty(const AudioObjectPropertyAddress* a, UInt32 qSize, const void* q,
                               UInt32 inSize, UInt32* outSize, void* outData) {
    static const AudioObjectID devices[] = { kObjectID_Device };
    switch (a->mSelector) {
    case kAudioObjectPropertyBaseClass: RETURN_VALUE(AudioClassID, kAudioObjectClassID);
    case kAudioObjectPropertyClass: RETURN_VALUE(AudioClassID, kAudioPlugInClassID);
    case kAudioObjectPropertyOwner: RETURN_VALUE(AudioObjectID, kAudioObjectUnknown);
    case kAudioObjectPropertyManufacturer: RETURN_STRING(kManufacturer);
    case kAudioObjectPropertyOwnedObjects:
    case kAudioPlugInPropertyDeviceList:
        return ReturnIDs(devices, 1, inSize, outSize, outData);
    case kAudioPlugInPropertyTranslateUIDToDevice: {
        AudioObjectID found = kAudioObjectUnknown;
        if (outData && qSize == sizeof(CFStringRef) && q && *(const CFStringRef*)q &&
            CFStringCompare(*(const CFStringRef*)q, CFSTR(kDeviceUID), 0) == kCFCompareEqualTo) found = kObjectID_Device;
        RETURN_VALUE(AudioObjectID, found);
    }
    case kAudioPlugInPropertyResourceBundle: RETURN_STRING("");
    default: return kAudioHardwareUnknownPropertyError;
    }
}

static OSStatus DeviceProperty(const AudioObjectPropertyAddress* a, UInt32 inSize, UInt32* outSize, void* outData) {
    const AudioObjectPropertyScope scope = a->mScope;
    switch (a->mSelector) {
    case kAudioObjectPropertyBaseClass: RETURN_VALUE(AudioClassID, kAudioObjectClassID);
    case kAudioObjectPropertyClass: RETURN_VALUE(AudioClassID, kAudioDeviceClassID);
    case kAudioObjectPropertyOwner: RETURN_VALUE(AudioObjectID, kObjectID_PlugIn);
    case kAudioObjectPropertyName: RETURN_STRING(kDeviceName);
    case kAudioObjectPropertyManufacturer: RETURN_STRING(kManufacturer);
    case kAudioObjectPropertyOwnedObjects: {
        static const AudioObjectID all[] = { kObjectID_StreamInput, kObjectID_StreamOutput, kObjectID_Volume, kObjectID_Mute };
        static const AudioObjectID in[] = { kObjectID_StreamInput };
        static const AudioObjectID out[] = { kObjectID_StreamOutput, kObjectID_Volume, kObjectID_Mute };
        if (scope == kAudioObjectPropertyScopeInput) return ReturnIDs(in, 1, inSize, outSize, outData);
        if (scope == kAudioObjectPropertyScopeOutput) return ReturnIDs(out, 3, inSize, outSize, outData);
        return ReturnIDs(all, 4, inSize, outSize, outData);
    }
    case kAudioDevicePropertyStreams: {
        static const AudioObjectID all[] = { kObjectID_StreamInput, kObjectID_StreamOutput };
        static const AudioObjectID in[] = { kObjectID_StreamInput };
        static const AudioObjectID out[] = { kObjectID_StreamOutput };
        if (scope == kAudioObjectPropertyScopeInput) return ReturnIDs(in, 1, inSize, outSize, outData);
        if (scope == kAudioObjectPropertyScopeOutput) return ReturnIDs(out, 1, inSize, outSize, outData);
        return ReturnIDs(all, 2, inSize, outSize, outData);
    }
    case kAudioObjectPropertyControlList: {
        static const AudioObjectID controls[] = { kObjectID_Volume, kObjectID_Mute };
        return ReturnIDs(controls, 2, inSize, outSize, outData);
    }
    case kAudioDevicePropertyDeviceUID: RETURN_STRING(kDeviceUID);
    case kAudioDevicePropertyModelUID: RETURN_STRING(kDeviceModelUID);
    case kAudioDevicePropertyTransportType: RETURN_VALUE(UInt32, kAudioDeviceTransportTypeVirtual);
    case kAudioDevicePropertyRelatedDevices: {
        static const AudioObjectID related[] = { kObjectID_Device };
        return ReturnIDs(related, 1, inSize, outSize, outData);
    }
    case kAudioDevicePropertyClockDomain: RETURN_VALUE(UInt32, 0);
    case kAudioDevicePropertyDeviceIsAlive: RETURN_VALUE(UInt32, 1);
    case kAudioDevicePropertyDeviceIsRunning: RETURN_VALUE(UInt32, gIORunning > 0 ? 1 : 0);
    // It can be the default output, but not the default input (it isn't a microphone) or the alert device.
    case kAudioDevicePropertyDeviceCanBeDefaultDevice: RETURN_VALUE(UInt32, scope == kAudioObjectPropertyScopeInput ? 0 : 1);
    case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice: RETURN_VALUE(UInt32, 0);
    case kAudioDevicePropertyLatency: RETURN_VALUE(UInt32, 0);
    case kAudioDevicePropertySafetyOffset: RETURN_VALUE(UInt32, 0);
    case kAudioDevicePropertyNominalSampleRate: RETURN_VALUE(Float64, gSampleRate);
    case kAudioDevicePropertyAvailableNominalSampleRates: {
        AudioValueRange r[kNumSampleRates];
        for (UInt32 i = 0; i < kNumSampleRates; ++i) { r[i].mMinimum = kSampleRates[i]; r[i].mMaximum = kSampleRates[i]; }
        return ReturnArray(r, kNumSampleRates, sizeof(AudioValueRange), inSize, outSize, outData);
    }
    case kAudioDevicePropertyIsHidden: RETURN_VALUE(UInt32, 0);
    case kAudioDevicePropertyZeroTimeStampPeriod: RETURN_VALUE(UInt32, kRingFrames);
    case kAudioDevicePropertyPreferredChannelsForStereo: {
        static const UInt32 lr[2] = { 1, 2 };
        *outSize = sizeof(lr);
        if (outData) {
            if (inSize < sizeof(lr)) return kAudioHardwareBadPropertySizeError;
            memcpy(outData, lr, sizeof(lr));
        }
        return kAudioHardwareNoError;
    }
    case kAudioDevicePropertyPreferredChannelLayout: {
        UInt32 size = (UInt32)(offsetof(AudioChannelLayout, mChannelDescriptions) + kChannels * sizeof(AudioChannelDescription));
        *outSize = size;
        if (outData) {
            if (inSize < size) return kAudioHardwareBadPropertySizeError;
            AudioChannelLayout* l = (AudioChannelLayout*)outData;
            memset(l, 0, size);
            l->mChannelLayoutTag = kAudioChannelLayoutTag_UseChannelDescriptions;
            l->mNumberChannelDescriptions = kChannels;
            for (UInt32 i = 0; i < kChannels; ++i) l->mChannelDescriptions[i].mChannelLabel = kLabels[i];
        }
        return kAudioHardwareNoError;
    }
    case kAudioDevicePropertyConfigurationApplication: RETURN_STRING("com.apple.audio.AudioMIDISetup");
    default: return kAudioHardwareUnknownPropertyError;
    }
}

static OSStatus StreamProperty(AudioObjectID obj, const AudioObjectPropertyAddress* a,
                               UInt32 inSize, UInt32* outSize, void* outData) {
    const bool isInput = obj == kObjectID_StreamInput;
    switch (a->mSelector) {
    case kAudioObjectPropertyBaseClass: RETURN_VALUE(AudioClassID, kAudioObjectClassID);
    case kAudioObjectPropertyClass: RETURN_VALUE(AudioClassID, kAudioStreamClassID);
    case kAudioObjectPropertyOwner: RETURN_VALUE(AudioObjectID, kObjectID_Device);
    case kAudioObjectPropertyOwnedObjects: return ReturnIDs(NULL, 0, inSize, outSize, outData);
    case kAudioStreamPropertyIsActive: RETURN_VALUE(UInt32, (isInput ? gInputActive : gOutputActive) ? 1 : 0);
    case kAudioStreamPropertyDirection: RETURN_VALUE(UInt32, isInput ? 1 : 0);
    case kAudioStreamPropertyTerminalType:
        RETURN_VALUE(UInt32, isInput ? kAudioStreamTerminalTypeLine : kAudioStreamTerminalTypeSpeaker);
    case kAudioStreamPropertyStartingChannel: RETURN_VALUE(UInt32, 1);
    case kAudioStreamPropertyLatency: RETURN_VALUE(UInt32, 0);
    case kAudioStreamPropertyVirtualFormat:
    case kAudioStreamPropertyPhysicalFormat: {
        *outSize = sizeof(AudioStreamBasicDescription);
        if (outData) {
            if (inSize < sizeof(AudioStreamBasicDescription)) return kAudioHardwareBadPropertySizeError;
            FillFormat((AudioStreamBasicDescription*)outData, gSampleRate);
        }
        return kAudioHardwareNoError;
    }
    case kAudioStreamPropertyAvailableVirtualFormats:
    case kAudioStreamPropertyAvailablePhysicalFormats: {
        AudioStreamRangedDescription d[kNumSampleRates];
        for (UInt32 i = 0; i < kNumSampleRates; ++i) {
            FillFormat(&d[i].mFormat, kSampleRates[i]);
            d[i].mSampleRateRange.mMinimum = kSampleRates[i];
            d[i].mSampleRateRange.mMaximum = kSampleRates[i];
        }
        return ReturnArray(d, kNumSampleRates, sizeof(AudioStreamRangedDescription), inSize, outSize, outData);
    }
    default: return kAudioHardwareUnknownPropertyError;
    }
}

static OSStatus VolumeProperty(const AudioObjectPropertyAddress* a, UInt32 inSize, UInt32* outSize, void* outData) {
    switch (a->mSelector) {
    case kAudioObjectPropertyBaseClass: RETURN_VALUE(AudioClassID, kAudioLevelControlClassID);
    case kAudioObjectPropertyClass: RETURN_VALUE(AudioClassID, kAudioVolumeControlClassID);
    case kAudioObjectPropertyOwner: RETURN_VALUE(AudioObjectID, kObjectID_Device);
    case kAudioObjectPropertyOwnedObjects: return ReturnIDs(NULL, 0, inSize, outSize, outData);
    case kAudioControlPropertyScope: RETURN_VALUE(AudioObjectPropertyScope, kAudioObjectPropertyScopeOutput);
    case kAudioControlPropertyElement: RETURN_VALUE(AudioObjectPropertyElement, kAudioObjectPropertyElementMain);
    case kAudioLevelControlPropertyScalarValue: RETURN_VALUE(Float32, atomic_load(&gVolume));
    case kAudioLevelControlPropertyDecibelValue: RETURN_VALUE(Float32, ScalarToDB(atomic_load(&gVolume)));
    case kAudioLevelControlPropertyDecibelRange: {
        AudioValueRange r = { kMinDB, 0 };
        RETURN_VALUE(AudioValueRange, r);
    }
    // In/out: the caller passes the value to convert in outData.
    case kAudioLevelControlPropertyConvertScalarToDecibels:
        RETURN_VALUE(Float32, ScalarToDB(*(Float32*)outData));
    case kAudioLevelControlPropertyConvertDecibelsToScalar:
        RETURN_VALUE(Float32, DBToScalar(*(Float32*)outData));
    default: return kAudioHardwareUnknownPropertyError;
    }
}

static OSStatus MuteProperty(const AudioObjectPropertyAddress* a, UInt32 inSize, UInt32* outSize, void* outData) {
    switch (a->mSelector) {
    case kAudioObjectPropertyBaseClass: RETURN_VALUE(AudioClassID, kAudioBooleanControlClassID);
    case kAudioObjectPropertyClass: RETURN_VALUE(AudioClassID, kAudioMuteControlClassID);
    case kAudioObjectPropertyOwner: RETURN_VALUE(AudioObjectID, kObjectID_Device);
    case kAudioObjectPropertyOwnedObjects: return ReturnIDs(NULL, 0, inSize, outSize, outData);
    case kAudioControlPropertyScope: RETURN_VALUE(AudioObjectPropertyScope, kAudioObjectPropertyScopeOutput);
    case kAudioControlPropertyElement: RETURN_VALUE(AudioObjectPropertyElement, kAudioObjectPropertyElementMain);
    case kAudioBooleanControlPropertyValue: RETURN_VALUE(UInt32, atomic_load(&gMute));
    default: return kAudioHardwareUnknownPropertyError;
    }
}

/// One entry point for size queries (outData == NULL) and reads.
static OSStatus Property(AudioObjectID obj, const AudioObjectPropertyAddress* a, UInt32 qSize, const void* q,
                         UInt32 inSize, UInt32* outSize, void* outData) {
    if (!a || !outSize) return kAudioHardwareIllegalOperationError;
    switch (obj) {
    case kObjectID_PlugIn: return PlugInProperty(a, qSize, q, inSize, outSize, outData);
    case kObjectID_Device: return DeviceProperty(a, inSize, outSize, outData);
    case kObjectID_StreamInput:
    case kObjectID_StreamOutput: return StreamProperty(obj, a, inSize, outSize, outData);
    case kObjectID_Volume: return VolumeProperty(a, inSize, outSize, outData);
    case kObjectID_Mute: return MuteProperty(a, inSize, outSize, outData);
    default: return kAudioHardwareBadObjectError;
    }
}

static bool Settable(AudioObjectID obj, AudioObjectPropertySelector sel) {
    switch (obj) {
    case kObjectID_Device: return sel == kAudioDevicePropertyNominalSampleRate;
    case kObjectID_StreamInput:
    case kObjectID_StreamOutput:
        return sel == kAudioStreamPropertyIsActive || sel == kAudioStreamPropertyVirtualFormat ||
               sel == kAudioStreamPropertyPhysicalFormat;
    case kObjectID_Volume:
        return sel == kAudioLevelControlPropertyScalarValue || sel == kAudioLevelControlPropertyDecibelValue;
    case kObjectID_Mute: return sel == kAudioBooleanControlPropertyValue;
    default: return false;
    }
}

static OSStatus RequestRate(Float64 rate) {
    if (!IsSupportedRate(rate)) return kAudioHardwareIllegalOperationError;
    if (rate == gSampleRate) return kAudioHardwareNoError;
    if (!gHost) return kAudioHardwareUnspecifiedError;
    // The rate changes in PerformDeviceConfigurationChange, when the host says it's safe.
    return gHost->RequestDeviceConfigurationChange(gHost, kObjectID_Device, (UInt64)rate, NULL);
}

// MARK: - Driver interface

static HRESULT Drv_QueryInterface(void* inDriver, REFIID inUUID, LPVOID* outInterface) {
    if (inDriver != gDriverRef || !outInterface) return kAudioHardwareBadObjectError;
    CFUUIDRef requested = CFUUIDCreateFromUUIDBytes(NULL, inUUID);
    HRESULT result = E_NOINTERFACE;
    if (requested && (CFEqual(requested, IUnknownUUID) || CFEqual(requested, kAudioServerPlugInDriverInterfaceUUID))) {
        Drv_AddRef(inDriver);
        *outInterface = gDriverRef;
        result = S_OK;
    }
    if (requested) CFRelease(requested);
    return result;
}

static ULONG Drv_AddRef(void* inDriver) {
    if (inDriver != gDriverRef) return 0;
    pthread_mutex_lock(&gStateMutex);
    if (gRefCount < UINT32_MAX) ++gRefCount;
    ULONG r = gRefCount;
    pthread_mutex_unlock(&gStateMutex);
    return r;
}

static ULONG Drv_Release(void* inDriver) {
    if (inDriver != gDriverRef) return 0;
    pthread_mutex_lock(&gStateMutex);
    if (gRefCount > 0) --gRefCount;
    ULONG r = gRefCount;
    pthread_mutex_unlock(&gStateMutex);
    return r;
}

static OSStatus Drv_Initialize(AudioServerPlugInDriverRef inDriver, AudioServerPlugInHostRef inHost) {
    if (inDriver != gDriverRef) return kAudioHardwareBadObjectError;
    gHost = inHost;
    mach_timebase_info_data_t tb;
    mach_timebase_info(&tb);
    gHostTicksPerSecond = 1e9 * (Float64)tb.denom / (Float64)tb.numer;
    gHostTicksPerFrame = gHostTicksPerSecond / gSampleRate;
    gLog = os_log_create("com.phil.brirconvolver.device", "io");
    os_log(gLog, "initialized");
    return kAudioHardwareNoError;
}

static OSStatus Drv_CreateDevice(AudioServerPlugInDriverRef d, CFDictionaryRef desc, const AudioServerPlugInClientInfo* ci,
                                 AudioObjectID* out) {
    (void)d; (void)desc; (void)ci; (void)out;
    return kAudioHardwareUnsupportedOperationError;
}

static OSStatus Drv_DestroyDevice(AudioServerPlugInDriverRef d, AudioObjectID dev) {
    (void)d; (void)dev;
    return kAudioHardwareUnsupportedOperationError;
}

static OSStatus Drv_AddDeviceClient(AudioServerPlugInDriverRef d, AudioObjectID dev, const AudioServerPlugInClientInfo* ci) {
    (void)ci;
    if (d != gDriverRef) return kAudioHardwareBadObjectError;
    return dev == kObjectID_Device ? kAudioHardwareNoError : kAudioHardwareBadObjectError;
}

static OSStatus Drv_RemoveDeviceClient(AudioServerPlugInDriverRef d, AudioObjectID dev, const AudioServerPlugInClientInfo* ci) {
    return Drv_AddDeviceClient(d, dev, ci);
}

static OSStatus Drv_PerformConfigChange(AudioServerPlugInDriverRef d, AudioObjectID dev, UInt64 action, void* info) {
    (void)info;
    if (d != gDriverRef) return kAudioHardwareBadObjectError;
    if (dev != kObjectID_Device) return kAudioHardwareBadObjectError;
    Float64 rate = (Float64)action;
    if (!IsSupportedRate(rate)) return kAudioHardwareIllegalOperationError;
    pthread_mutex_lock(&gStateMutex);
    pthread_mutex_lock(&gClockMutex);
    gSampleRate = rate;
    gHostTicksPerFrame = gHostTicksPerSecond / gSampleRate;
    pthread_mutex_unlock(&gClockMutex);
    pthread_mutex_unlock(&gStateMutex);
    return kAudioHardwareNoError;
}

static OSStatus Drv_AbortConfigChange(AudioServerPlugInDriverRef d, AudioObjectID dev, UInt64 action, void* info) {
    (void)action; (void)info;
    if (d != gDriverRef) return kAudioHardwareBadObjectError;
    return dev == kObjectID_Device ? kAudioHardwareNoError : kAudioHardwareBadObjectError;
}

static Boolean Drv_HasProperty(AudioServerPlugInDriverRef d, AudioObjectID obj, pid_t pid, const AudioObjectPropertyAddress* a) {
    (void)pid;
    if (d != gDriverRef || !a) return false;
    UInt32 size = 0;
    return Property(obj, a, 0, NULL, 0, &size, NULL) == kAudioHardwareNoError;
}

static OSStatus Drv_IsPropertySettable(AudioServerPlugInDriverRef d, AudioObjectID obj, pid_t pid,
                                       const AudioObjectPropertyAddress* a, Boolean* outIsSettable) {
    (void)pid;
    if (d != gDriverRef) return kAudioHardwareBadObjectError;
    if (!a || !outIsSettable) return kAudioHardwareIllegalOperationError;
    UInt32 size = 0;
    OSStatus st = Property(obj, a, 0, NULL, 0, &size, NULL);
    if (st != kAudioHardwareNoError) return st;
    *outIsSettable = Settable(obj, a->mSelector);
    return kAudioHardwareNoError;
}

static OSStatus Drv_GetPropertyDataSize(AudioServerPlugInDriverRef d, AudioObjectID obj, pid_t pid,
                                        const AudioObjectPropertyAddress* a, UInt32 qSize, const void* q, UInt32* outSize) {
    (void)pid;
    if (d != gDriverRef) return kAudioHardwareBadObjectError;
    return Property(obj, a, qSize, q, 0, outSize, NULL);
}

static OSStatus Drv_GetPropertyData(AudioServerPlugInDriverRef d, AudioObjectID obj, pid_t pid,
                                    const AudioObjectPropertyAddress* a, UInt32 qSize, const void* q,
                                    UInt32 inSize, UInt32* outSize, void* outData) {
    (void)pid;
    if (d != gDriverRef) return kAudioHardwareBadObjectError;
    if (!outData) return kAudioHardwareIllegalOperationError;
    // The conversion properties read their input from outData, so check its size before Property() does.
    if (obj == kObjectID_Volume && a && (a->mSelector == kAudioLevelControlPropertyConvertScalarToDecibels ||
                                         a->mSelector == kAudioLevelControlPropertyConvertDecibelsToScalar) &&
        inSize < sizeof(Float32)) return kAudioHardwareBadPropertySizeError;
    pthread_mutex_lock(&gStateMutex);
    OSStatus st = Property(obj, a, qSize, q, inSize, outSize, outData);
    pthread_mutex_unlock(&gStateMutex);
    return st;
}

static OSStatus Drv_SetPropertyData(AudioServerPlugInDriverRef d, AudioObjectID obj, pid_t pid,
                                    const AudioObjectPropertyAddress* a, UInt32 qSize, const void* q,
                                    UInt32 inSize, const void* inData) {
    (void)pid; (void)qSize; (void)q;
    if (d != gDriverRef) return kAudioHardwareBadObjectError;
    if (!a || !inData) return kAudioHardwareIllegalOperationError;
    UInt32 size = 0;
    OSStatus st = Property(obj, a, 0, NULL, 0, &size, NULL);
    if (st != kAudioHardwareNoError) return st;
    if (!Settable(obj, a->mSelector)) return kAudioHardwareUnsupportedOperationError;
    if (inSize < size) return kAudioHardwareBadPropertySizeError;

    switch (obj) {
    case kObjectID_Device:   // nominal sample rate
        return RequestRate(*(const Float64*)inData);
    case kObjectID_StreamInput:
    case kObjectID_StreamOutput:
        if (a->mSelector == kAudioStreamPropertyIsActive) {
            Boolean on = *(const UInt32*)inData != 0;
            pthread_mutex_lock(&gStateMutex);
            if (obj == kObjectID_StreamInput) gInputActive = on; else gOutputActive = on;
            pthread_mutex_unlock(&gStateMutex);
            Notify(obj, kAudioStreamPropertyIsActive);
            return kAudioHardwareNoError;
        } else {
            const AudioStreamBasicDescription* f = (const AudioStreamBasicDescription*)inData;
            if (f->mFormatID != kAudioFormatLinearPCM || f->mChannelsPerFrame != kChannels ||
                f->mBitsPerChannel != 32 || !(f->mFormatFlags & kAudioFormatFlagIsFloat) ||
                (f->mFormatFlags & kAudioFormatFlagIsNonInterleaved))
                return kAudioDeviceUnsupportedFormatError;
            return RequestRate(f->mSampleRate);
        }
    case kObjectID_Volume: {
        Float32 v = *(const Float32*)inData;
        Float32 s = a->mSelector == kAudioLevelControlPropertyScalarValue ? (v < 0 ? 0 : v > 1 ? 1 : v) : DBToScalar(v);
        atomic_store(&gVolume, s);
        if (gHost) {
            AudioObjectPropertyAddress changed[2] = {
                { kAudioLevelControlPropertyScalarValue, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain },
                { kAudioLevelControlPropertyDecibelValue, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain },
            };
            gHost->PropertiesChanged(gHost, kObjectID_Volume, 2, changed);
        }
        return kAudioHardwareNoError;
    }
    case kObjectID_Mute:
        atomic_store(&gMute, *(const UInt32*)inData ? 1u : 0u);
        Notify(kObjectID_Mute, kAudioBooleanControlPropertyValue);
        return kAudioHardwareNoError;
    default:
        return kAudioHardwareBadObjectError;
    }
}

// MARK: - IO

static OSStatus Drv_StartIO(AudioServerPlugInDriverRef d, AudioObjectID dev, UInt32 client) {
    if (d != gDriverRef) return kAudioHardwareBadObjectError;
    if (dev != kObjectID_Device) return kAudioHardwareBadObjectError;
    pthread_mutex_lock(&gStateMutex);
    const bool first = gIORunning == 0;
    if (first) {
        pthread_mutex_lock(&gClockMutex);
        gAnchorHostTime = mach_absolute_time();
        gPeriodCount = 0;
        ++gSeed;
        gHostTicksPerFrame = gHostTicksPerSecond / gSampleRate;
        pthread_mutex_unlock(&gClockMutex);
        memset(gRing, 0, sizeof(gRing));
        atomic_store(&gWriteEnd, 0);
    }
    if (gIORunning < UINT32_MAX) ++gIORunning;
    const UInt32 n = gIORunning;
    pthread_mutex_unlock(&gStateMutex);
    if (gLog) os_log(gLog, "StartIO client %u → %u running%s", client, n, first ? " (new timeline)" : "");
    if (first) PostRunningChanged();
    return kAudioHardwareNoError;
}

static OSStatus Drv_StopIO(AudioServerPlugInDriverRef d, AudioObjectID dev, UInt32 client) {
    if (d != gDriverRef) return kAudioHardwareBadObjectError;
    if (dev != kObjectID_Device) return kAudioHardwareBadObjectError;
    pthread_mutex_lock(&gStateMutex);
    if (gIORunning > 0) --gIORunning;
    const UInt32 n = gIORunning;
    pthread_mutex_unlock(&gStateMutex);
    if (gLog) os_log(gLog, "StopIO client %u → %u running", client, n);
    if (n == 0) PostRunningChanged();
    return kAudioHardwareNoError;
}

/// The device's clock: one zero timestamp per ring-buffer period, derived from the host clock.
static OSStatus Drv_GetZeroTimeStamp(AudioServerPlugInDriverRef d, AudioObjectID dev, UInt32 client,
                                     Float64* outSampleTime, UInt64* outHostTime, UInt64* outSeed) {
    (void)client;
    if (d != gDriverRef) return kAudioHardwareBadObjectError;
    if (dev != kObjectID_Device) return kAudioHardwareBadObjectError;
    pthread_mutex_lock(&gClockMutex);
    const Float64 ticksPerPeriod = gHostTicksPerFrame * kRingFrames;
    const UInt64 now = mach_absolute_time();
    while (gAnchorHostTime + (UInt64)((Float64)(gPeriodCount + 1) * ticksPerPeriod) <= now) ++gPeriodCount;
    *outSampleTime = (Float64)gPeriodCount * kRingFrames;
    *outHostTime = gAnchorHostTime + (UInt64)((Float64)gPeriodCount * ticksPerPeriod);
    *outSeed = gSeed;
    pthread_mutex_unlock(&gClockMutex);
    return kAudioHardwareNoError;
}

static OSStatus Drv_WillDoIOOperation(AudioServerPlugInDriverRef d, AudioObjectID dev, UInt32 client, UInt32 op,
                                      Boolean* outWillDo, Boolean* outWillDoInPlace) {
    (void)client;
    if (d != gDriverRef) return kAudioHardwareBadObjectError;
    if (dev != kObjectID_Device) return kAudioHardwareBadObjectError;
    Boolean will = op == kAudioServerPlugInIOOperationReadInput || op == kAudioServerPlugInIOOperationWriteMix;
    if (outWillDo) *outWillDo = will;
    if (outWillDoInPlace) *outWillDoInPlace = true;
    return kAudioHardwareNoError;
}

static OSStatus Drv_BeginIOOperation(AudioServerPlugInDriverRef d, AudioObjectID dev, UInt32 client, UInt32 op,
                                     UInt32 frames, const AudioServerPlugInIOCycleInfo* info) {
    (void)client; (void)op; (void)frames; (void)info;
    if (d != gDriverRef) return kAudioHardwareBadObjectError;
    return dev == kObjectID_Device ? kAudioHardwareNoError : kAudioHardwareBadObjectError;
}

static OSStatus Drv_EndIOOperation(AudioServerPlugInDriverRef d, AudioObjectID dev, UInt32 client, UInt32 op,
                                   UInt32 frames, const AudioServerPlugInIOCycleInfo* info) {
    return Drv_BeginIOOperation(d, dev, client, op, frames, info);
}

/// Store the mixed output at its sample time. Frames skipped since the last write (output stopped and
/// restarted) are cleared, so stale audio from an earlier lap of the ring can never be read back.
static void RingWrite(SInt64 start, const Float32* src, UInt32 frames, Float32 gain) {
    const SInt64 prevEnd = atomic_load(&gWriteEnd);
    if (start > prevEnd) {
        SInt64 gap = start - prevEnd;
        if (gap > kRingFrames) gap = kRingFrames;
        for (SInt64 t = start - gap; t < start; ++t) memset(&gRing[RingIndex(t) * kChannels], 0, kBytesPerFrame);
    }
    for (UInt32 f = 0; f < frames; ++f) {
        Float32* dst = &gRing[RingIndex(start + f) * kChannels];
        const Float32* s = src + (size_t)f * kChannels;
        for (UInt32 c = 0; c < kChannels; ++c) dst[c] = s[c] * gain;
    }
    const SInt64 end = start + frames;
    atomic_store(&gWriteEnd, end > prevEnd ? end : prevEnd);
}

/// Read frames back at their sample time; anything never written (or already overwritten) reads as silence.
static void RingRead(SInt64 start, Float32* dst, UInt32 frames) {
    const SInt64 end = atomic_load(&gWriteEnd);
    UInt64 valid = 0;
    for (UInt32 f = 0; f < frames; ++f) {
        const SInt64 t = start + f;
        Float32* o = dst + (size_t)f * kChannels;
        if (t < end && t >= end - kRingFrames) { memcpy(o, &gRing[RingIndex(t) * kChannels], kBytesPerFrame); ++valid; }
        else memset(o, 0, kBytesPerFrame);
    }
    atomic_fetch_add(&gReadValid, valid);
    atomic_fetch_add(&gReadSilent, frames - valid);
    // Low-rate diagnostics: where reads land relative to what has been written.
    const UInt64 now = mach_absolute_time();
    if (gLog && (Float64)(now - gLastLogHost) > 2.0 * gHostTicksPerSecond) {
        gLastLogHost = now;
        os_log(gLog, "read t=%lld writeEnd=%lld (read − written %lld) · last 2 s: %llu frames with data, %llu silent, %llu writes",
               (long long)start, (long long)end, (long long)(start - end),
               (unsigned long long)atomic_exchange(&gReadValid, 0), (unsigned long long)atomic_exchange(&gReadSilent, 0),
               (unsigned long long)atomic_exchange(&gWriteCalls, 0));
    }
}

static OSStatus Drv_DoIOOperation(AudioServerPlugInDriverRef d, AudioObjectID dev, AudioObjectID stream, UInt32 client,
                                  UInt32 op, UInt32 frames, const AudioServerPlugInIOCycleInfo* info,
                                  void* ioMainBuffer, void* ioSecondaryBuffer) {
    (void)client; (void)ioSecondaryBuffer;
    if (d != gDriverRef) return kAudioHardwareBadObjectError;
    if (dev != kObjectID_Device) return kAudioHardwareBadObjectError;
    if (!info || !ioMainBuffer) return kAudioHardwareIllegalOperationError;
    if (op == kAudioServerPlugInIOOperationWriteMix && stream == kObjectID_StreamOutput) {
        const Float32 v = atomic_load(&gVolume);
        const Float32 gain = atomic_load(&gMute) ? 0.0f : v * v;
        RingWrite((SInt64)info->mOutputTime.mSampleTime, (const Float32*)ioMainBuffer, frames, gain);
        atomic_fetch_add(&gWriteCalls, 1);
    } else if (op == kAudioServerPlugInIOOperationReadInput && stream == kObjectID_StreamInput) {
        RingRead((SInt64)info->mInputTime.mSampleTime, (Float32*)ioMainBuffer, frames);
    }
    return kAudioHardwareNoError;
}

// MARK: - Factory

__attribute__((visibility("default")))
void* BRIRConvolverDevice_Create(CFAllocatorRef inAllocator, CFUUIDRef inRequestedTypeUUID) {
    (void)inAllocator;
    if (CFEqual(inRequestedTypeUUID, kAudioServerPlugInTypeUUID)) return gDriverRef;
    return NULL;
}
