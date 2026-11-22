import CoreAudio
import AudioToolbox
import Foundation

/// Captures the system mix with a Core Audio process tap (muting the originals), convolves it,
/// and plays it to the chosen output device. Tap + output live in one private aggregate device,
/// so a single IOProc reads the tap and writes the output on the same clock.
final class AudioPipeline {
    static let aggregateUIDPrefix = "com.phil.brirconvolver.aggregate"

    struct Config {
        var outputUID: String
        var excludedProcesses: [AudioObjectID]
        var driftCompensation: Bool
    }

    private(set) var tapID = AudioObjectID(kAudioObjectUnknown)
    private(set) var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var context: RenderContext?

    private(set) var tapFormat = AudioStreamBasicDescription()
    private(set) var sampleRate: Double = 0
    private(set) var ioBufferFrames: Int = 0
    private(set) var outputName = ""
    var convolver: StereoConvolver? { context?.convolver }
    var cpuLoad: Double { context?.cpuLoad ?? 0 }
    var callbacks: UInt64 { context?.callbacks ?? 0 }

    /// Phase 1: create tap + aggregate. Returns the aggregate's sample rate so the caller can prepare the IR.
    func prepare(_ config: Config) throws -> Double {
        // 1. Global stereo tap of everything except our own process and the excluded ones, muting the originals.
        let desc = CATapDescription(stereoGlobalTapButExcludeProcesses: config.excludedProcesses)
        desc.name = "BRIR Convolver Tap"
        desc.uuid = UUID()
        desc.isPrivate = true
        desc.muteBehavior = CATapMuteBehavior.mutedWhenTapped
        var tap = AudioObjectID(kAudioObjectUnknown)
        try check(AudioHardwareCreateProcessTap(desc, &tap), "Creating system audio tap")
        tapID = tap

        guard let fmt = CA.get(tap, kAudioTapPropertyFormat, initial: AudioStreamBasicDescription()) else {
            teardown(); throw CAError(what: "Reading tap format", status: -1)
        }
        tapFormat = fmt

        // 2. Private aggregate: output device as clock master + the tap.
        outputName = CA.device(forUID: config.outputUID).flatMap(CA.deviceName) ?? config.outputUID
        let aggUID = "\(Self.aggregateUIDPrefix).\(UUID().uuidString)"
        let dict: [String: Any] = [
            kAudioAggregateDeviceNameKey: "BRIR Convolver",
            kAudioAggregateDeviceUIDKey: aggUID,
            kAudioAggregateDeviceMainSubDeviceKey: config.outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: config.outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: desc.uuid.uuidString,
                kAudioSubTapDriftCompensationKey: config.driftCompensation,
            ]],
        ]
        var agg = AudioObjectID(kAudioObjectUnknown)
        do {
            try check(AudioHardwareCreateAggregateDevice(dict as CFDictionary, &agg), "Creating aggregate device")
        } catch { teardown(); throw error }
        aggregateID = agg
        sampleRate = CA.nominalSampleRate(agg) ?? fmt.mSampleRate
        ioBufferFrames = CA.bufferFrameSize(agg) ?? 0
        return sampleRate
    }

    /// Phase 2: install the IOProc and start.
    func start(convolver: StereoConvolver) throws {
        let ctx = RenderContext(convolver: convolver, tapFormat: tapFormat, sampleRate: sampleRate)
        context = ctx
        var proc: AudioDeviceIOProcID?
        do {
            try check(AudioDeviceCreateIOProcID(aggregateID, brirIOProc, Unmanaged.passUnretained(ctx).toOpaque(), &proc),
                      "Creating IOProc")
            procID = proc
            try check(AudioDeviceStart(aggregateID, proc), "Starting audio device")
        } catch { teardown(); throw error }
    }

    func stop() { teardown() }

    private func teardown() {
        if let p = procID {
            AudioDeviceStop(aggregateID, p)
            AudioDeviceDestroyIOProcID(aggregateID, p)
            procID = nil
        }
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
        context = nil   // IOProc is stopped & destroyed, so nothing references it anymore.
    }

    deinit { teardown() }
}

/// Everything the realtime thread touches. No Swift collections, no locks, no allocation.
final class RenderContext {
    let convolver: StereoConvolver
    let tapInterleaved: Bool
    let tapChannels: Int
    let sampleRate: Double
    private let ticksToSeconds: Double
    var cpuLoad: Double = 0
    var callbacks: UInt64 = 0
    private let silence: UnsafeMutablePointer<Float>
    private let silenceFrames = 16384

    init(convolver: StereoConvolver, tapFormat: AudioStreamBasicDescription, sampleRate: Double) {
        self.convolver = convolver
        tapInterleaved = tapFormat.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
        tapChannels = max(1, Int(tapFormat.mChannelsPerFrame))
        self.sampleRate = sampleRate
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        ticksToSeconds = Double(tb.numer) / Double(tb.denom) * 1e-9
        silence = .allocate(capacity: silenceFrames * 2)
        silence.initialize(repeating: 0, count: silenceFrames * 2)
    }
    deinit { silence.deallocate() }

    @inline(__always)
    func render(_ input: UnsafePointer<AudioBufferList>, _ output: UnsafeMutablePointer<AudioBufferList>) {
        let t0 = mach_absolute_time()
        let outs = UnsafeMutableAudioBufferListPointer(output)
        let ins = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        guard outs.count > 0 else { return }

        // Zero every output channel first; we then fill channels 1 & 2.
        for b in outs where b.mData != nil { memset(b.mData!, 0, Int(b.mDataByteSize)) }

        // Destination: first two channels of the output device.
        let out0 = outs[0]
        guard let o0 = out0.mData?.assumingMemoryBound(to: Float.self) else { return }
        let outCh = max(1, Int(out0.mNumberChannels))
        let frames = Int(out0.mDataByteSize) / (MemoryLayout<Float>.size * outCh)
        let dstL = o0
        let dstR: UnsafeMutablePointer<Float>
        let outStride: Int
        if outCh >= 2 {
            dstR = o0 + 1; outStride = outCh
        } else if outs.count >= 2, let o1 = outs[1].mData?.assumingMemoryBound(to: Float.self) {
            dstR = o1; outStride = 1
        } else {
            dstR = o0; outStride = 1   // mono device: R overwrites L; acceptable edge case
        }

        // Source: the tap's stream(s) come after any input streams of the output device.
        var srcL = UnsafePointer(silence), srcR = UnsafePointer(silence) + 1
        var inStride = 2
        var inFrames = silenceFrames
        if tapInterleaved, ins.count >= 1, let d = ins[ins.count - 1].mData {
            let b = ins[ins.count - 1]
            let ch = max(1, Int(b.mNumberChannels))
            let p = UnsafePointer(d.assumingMemoryBound(to: Float.self))
            srcL = p; srcR = ch > 1 ? p + 1 : p; inStride = ch
            inFrames = Int(b.mDataByteSize) / (MemoryLayout<Float>.size * ch)
        } else if !tapInterleaved, ins.count >= tapChannels {
            let first = ins.count - tapChannels
            if let dl = ins[first].mData {
                let pl = UnsafePointer(dl.assumingMemoryBound(to: Float.self))
                srcL = pl
                srcR = tapChannels > 1 ? UnsafePointer(ins[first + 1].mData!.assumingMemoryBound(to: Float.self)) : pl
                inStride = 1
                inFrames = Int(ins[first].mDataByteSize) / MemoryLayout<Float>.size
            }
        }

        let n = min(frames, inFrames)
        if n > 0 {
            convolver.process(inL: srcL, inR: srcR, inStride: inStride,
                              outL: dstL, outR: dstR, outStride: outStride, frames: n)
        }

        callbacks &+= 1
        if frames > 0 {
            let elapsed = Double(mach_absolute_time() - t0) * ticksToSeconds
            let budget = Double(frames) / sampleRate
            cpuLoad += (elapsed / budget - cpuLoad) * 0.05
        }
    }
}

private func brirIOProc(_ device: AudioObjectID,
                        _ now: UnsafePointer<AudioTimeStamp>,
                        _ inputData: UnsafePointer<AudioBufferList>,
                        _ inputTime: UnsafePointer<AudioTimeStamp>,
                        _ outputData: UnsafeMutablePointer<AudioBufferList>,
                        _ outputTime: UnsafePointer<AudioTimeStamp>,
                        _ clientData: UnsafeMutableRawPointer?) -> OSStatus {
    guard let clientData else { return noErr }
    Unmanaged<RenderContext>.fromOpaque(clientData).takeUnretainedValue().render(inputData, outputData)
    return noErr
}
