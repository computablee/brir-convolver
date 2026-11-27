import CoreAudio
import AudioToolbox
import Foundation

/// Captures audio, convolves it, and plays it to the chosen output device. Capture is either the system mix
/// via a Core Audio process tap (stereo, originals muted) or a multichannel input device such as a loopback
/// driver set as the macOS output. Capture + output live in one private aggregate device, so a single IOProc
/// reads the input and writes the output on the same clock.
final class AudioPipeline {
    static let aggregateUIDPrefix = "com.phil.brirconvolver.aggregate"

    struct Config {
        var outputUID: String
        /// nil = system-wide stereo process tap; otherwise capture this device's input channels.
        var inputUID: String?
        var excludedProcesses: [AudioObjectID]
        var driftCompensation: Bool
    }

    private(set) var tapID = AudioObjectID(kAudioObjectUnknown)
    private(set) var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var context: RenderContext?

    /// Number of captured channels (2 for the system tap).
    private(set) var inputChannels = 0
    /// Short description of the capture side, e.g. "tap 48000 Hz/2 ch".
    private(set) var inputDescription = ""
    private(set) var sampleRate: Double = 0
    private(set) var ioBufferFrames: Int = 0
    private(set) var outputName = ""
    var convolver: Convolver? { context?.convolver }
    /// The realtime context, for timing-health logging.
    var renderContext: RenderContext? { context }
    private var listeners: [(AudioObjectID, AudioObjectPropertySelector, AudioObjectPropertyListenerBlock)] = []
    private(set) var overloads = 0
    var cpuLoad: Double { context?.cpuLoad ?? 0 }
    var callbacks: UInt64 { context?.callbacks ?? 0 }
    var starvedCallbacks: UInt64 { context?.starvedCallbacks ?? 0 }
    /// Frames between the input time and the output time inside our IOProc (measured from HAL timestamps).
    var measuredIOFrames: Double { context?.ioFrames ?? 0 }
    /// Compute time per IOProc callback (seconds): smoothed average, worst since last reset, and the deadline.
    var computeAvg: Double { context?.computeAvg ?? 0 }
    var computeBudget: Double { context?.computeBudget ?? 0 }
    var lastFrames: Int { context?.lastFrames ?? 0 }
    func takeComputeMax() -> Double {
        guard let c = context else { return 0 }
        let v = c.computeMax; c.computeMax = 0; return v
    }
    /// Output device's own presentation latency (device + stream latency), in frames.
    private(set) var outputLatencyFrames: Int = 0
    private(set) var safetyOffsetFrames: Int = 0
    /// Aggregate device's input + output safety offsets and latencies (frames) — what Core Audio adds between capture and output.
    private(set) var aggregateOverheadFrames: Int = 0

    /// Phase 1: create the capture side + aggregate. Returns the aggregate's sample rate so the caller can prepare the IR.
    func prepare(_ config: Config) throws -> Double {
        outputName = CA.device(forUID: config.outputUID).flatMap(CA.deviceName) ?? config.outputUID
        let aggUID = "\(Self.aggregateUIDPrefix).\(UUID().uuidString)"
        var dict: [String: Any] = [
            kAudioAggregateDeviceNameKey: "BRIR Convolver",
            kAudioAggregateDeviceUIDKey: aggUID,
            kAudioAggregateDeviceMainSubDeviceKey: config.outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
        ]
        var fallbackRate = 0.0

        if let inUID = config.inputUID {
            // Multichannel input device: output device first (clock master), then the input device, whose
            // input channels are therefore the last ones in the aggregate's input buffer list.
            guard inUID != config.outputUID else {
                throw PipelineError("The output is the capture device itself. Under Output, choose your DAC or GraphWorks EQ instead of the system default.")
            }
            guard let inDev = CA.device(forUID: inUID) else { throw PipelineError("The capture device isn't connected.") }
            let ch = CA.channelCount(inDev, scope: kAudioObjectPropertyScopeInput)
            guard ch > 0 else { throw PipelineError("The capture device has no input channels.") }
            // Sub-devices of an aggregate must share a nominal rate: follow the output device.
            if let outDev = CA.device(forUID: config.outputUID), let r = CA.nominalSampleRate(outDev) {
                CA.setNominalSampleRate(inDev, r)
            }
            inputChannels = ch
            fallbackRate = CA.nominalSampleRate(inDev) ?? 0
            inputDescription = "\(CA.deviceName(inDev) ?? inUID) \(Int(fallbackRate)) Hz/\(ch) ch"
            dict[kAudioAggregateDeviceSubDeviceListKey] = [
                [kAudioSubDeviceUIDKey: config.outputUID],
                [kAudioSubDeviceUIDKey: inUID, kAudioSubDeviceDriftCompensationKey: config.driftCompensation],
            ] as [[String: Any]]
        } else {
            // Global stereo tap of everything except our own process and the excluded ones, muting the originals.
            let desc = CATapDescription(stereoGlobalTapButExcludeProcesses: config.excludedProcesses)
            desc.name = "BRIR Convolver Tap"
            desc.uuid = UUID()
            desc.isPrivate = true
            desc.muteBehavior = CATapMuteBehavior.mutedWhenTapped
            // Right after the previous tap is destroyed, Core Audio often hands back a tap that isn't ready yet
            // (object 0 / no format). Retry briefly in place rather than failing the whole start.
            var tap = AudioObjectID(kAudioObjectUnknown)
            var format: AudioStreamBasicDescription?
            var lastStatus: OSStatus = noErr
            for attempt in 1...6 {
                desc.uuid = UUID()
                var t = AudioObjectID(kAudioObjectUnknown)
                lastStatus = AudioHardwareCreateProcessTap(desc, &t)
                if lastStatus == noErr, t != kAudioObjectUnknown,
                   let f = CA.get(t, kAudioTapPropertyFormat, initial: AudioStreamBasicDescription()) {
                    tap = t; format = f
                    if attempt > 1 { Log.pipeline.notice("tap ready on attempt \(attempt)") }
                    break
                }
                if t != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(t) }
                Log.pipeline.notice("tap not ready (attempt \(attempt), status \(lastStatus)); retrying in 0.2 s")
                Thread.sleep(forTimeInterval: 0.2)
            }
            try check(lastStatus, "Creating system audio tap")
            guard let fmt = format else { throw CAError(what: "Reading tap format", status: -1) }
            tapID = tap
            inputChannels = max(1, Int(fmt.mChannelsPerFrame))
            fallbackRate = fmt.mSampleRate
            inputDescription = "tap \(Int(fmt.mSampleRate)) Hz/\(fmt.mChannelsPerFrame) ch"
            dict[kAudioAggregateDeviceSubDeviceListKey] = [[kAudioSubDeviceUIDKey: config.outputUID]] as [[String: Any]]
            dict[kAudioAggregateDeviceTapAutoStartKey] = true
            dict[kAudioAggregateDeviceTapListKey] = [[
                kAudioSubTapUIDKey: desc.uuid.uuidString,
                kAudioSubTapDriftCompensationKey: config.driftCompensation,
            ]] as [[String: Any]]
        }

        var agg = AudioObjectID(kAudioObjectUnknown)
        do {
            try check(AudioHardwareCreateAggregateDevice(dict as CFDictionary, &agg), "Creating aggregate device")
        } catch { teardown(); throw error }
        aggregateID = agg
        sampleRate = CA.nominalSampleRate(agg) ?? fallbackRate
        let outDevForLog = CA.device(forUID: config.outputUID)
        Log.pipeline.notice("""
            prepared: capture \(self.inputDescription, privacy: .public) → output \(self.outputName, privacy: .public)             (\(outDevForLog.flatMap(CA.nominalSampleRate).map { String(Int($0)) } ?? "?", privacy: .public) Hz),             aggregate \(Int(self.sampleRate)) Hz, buffer \(CA.bufferFrameSize(agg) ?? 0) frames,             drift compensation \(config.driftCompensation, privacy: .public)
            """)
        watch(agg, kAudioDeviceProcessorOverload) { [weak self] in
            self?.overloads += 1
            Log.health.error("aggregate reported an IO overload (CPU or scheduling could not keep up)")
        }
        watch(agg, kAudioDevicePropertyDeviceIsAlive) {
            Log.pipeline.error("aggregate device died (IsAlive changed)")
        }
        watch(agg, kAudioDevicePropertyNominalSampleRate) {
            Log.pipeline.notice("aggregate sample rate changed → \(CA.nominalSampleRate(agg).map { String(Int($0)) } ?? "?", privacy: .public) Hz")
        }
        if let od = outDevForLog {
            watch(od, kAudioDevicePropertyDeviceIsAlive) {
                Log.pipeline.error("output device IsAlive changed (unplugged or its driver restarted)")
            }
        }
        if tapID != kAudioObjectUnknown {
            let tap = tapID
            watch(tap, kAudioTapPropertyFormat) {
                let f = CA.get(tap, kAudioTapPropertyFormat, initial: AudioStreamBasicDescription())
                Log.pipeline.notice("tap format changed → \(Int(f?.mSampleRate ?? 0)) Hz / \(f?.mChannelsPerFrame ?? 0) ch")
            }
        }
        ioBufferFrames = CA.bufferFrameSize(agg) ?? 0
        let inS = kAudioObjectPropertyScopeInput, outS = kAudioObjectPropertyScopeOutput
        aggregateOverheadFrames = [
            CA.get(agg, kAudioDevicePropertySafetyOffset, scope: inS, initial: UInt32(0)),
            CA.get(agg, kAudioDevicePropertySafetyOffset, scope: outS, initial: UInt32(0)),
            CA.get(agg, kAudioDevicePropertyLatency, scope: inS, initial: UInt32(0)),
        ].reduce(0) { $0 + Int($1 ?? 0) }
        if let dev = CA.device(forUID: config.outputUID) {
            let out = kAudioObjectPropertyScopeOutput
            let devLat = Int(CA.get(dev, kAudioDevicePropertyLatency, scope: out, initial: UInt32(0)) ?? 0)
            let streams = CA.getArray(dev, kAudioDevicePropertyStreams, scope: out, zero: AudioObjectID(0))
            let streamLat = streams.first.flatMap { CA.get($0, kAudioStreamPropertyLatency, initial: UInt32(0)) }.map(Int.init) ?? 0
            outputLatencyFrames = devLat + streamLat
            safetyOffsetFrames = Int(CA.get(dev, kAudioDevicePropertySafetyOffset, scope: out, initial: UInt32(0)) ?? 0)
        }
        return sampleRate
    }

    /// Phase 2: install the IOProc and start.
    func start(convolver: Convolver) throws {
        let ctx = RenderContext(convolver: convolver, sampleRate: sampleRate)
        context = ctx
        var proc: AudioDeviceIOProcID?
        do {
            try check(AudioDeviceCreateIOProcID(aggregateID, brirIOProc, Unmanaged.passUnretained(ctx).toOpaque(), &proc),
                      "Creating IOProc")
            procID = proc
            try check(AudioDeviceStart(aggregateID, proc), "Starting audio device")
        } catch {
            Log.pipeline.error("start failed: \(error.localizedDescription, privacy: .public)")
            teardown(); throw error
        }
        Log.pipeline.notice("IO started")
    }

    func stop() { teardown() }

    /// False once Core Audio has torn down our process tap (it then no longer answers its format).
    var tapIsAlive: Bool {
        tapID == kAudioObjectUnknown || CA.get(tapID, kAudioTapPropertyFormat, initial: AudioStreamBasicDescription()) != nil
    }

    private func watch(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector, _ handler: @escaping () -> Void) {
        let block = CA.listen(obj, sel, handler)
        listeners.append((obj, sel, block))
    }

    private func teardown() {
        for (obj, sel, block) in listeners { CA.unlisten(obj, sel, block) }
        listeners = []
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

struct PipelineError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// Everything the realtime thread touches. No Swift collections, no locks, no allocation.
final class RenderContext {
    let convolver: Convolver
    /// Channels the convolver expects; they are the last `channels` channels of the aggregate's input.
    let channels: Int
    let sampleRate: Double
    private let ticksToSeconds: Double
    var cpuLoad: Double = 0
    var callbacks: UInt64 = 0
    var ioFrames: Double = 0
    var computeAvg: Double = 0
    var computeMax: Double = 0
    var computeBudget: Double = 0
    var lastFrames = 0
    /// Callbacks where the capture side delivered fewer frames than the output needed.
    var starvedCallbacks: UInt64 = 0

    // Timing health, read (and the min/max reset) by the UI thread every couple of seconds.
    /// Callbacks whose input / output sample time didn't continue from the previous callback.
    var inJumps: UInt64 = 0, outJumps: UInt64 = 0
    /// Rate scalars reported by Core Audio (actual ÷ nominal sample rate) since the last reset.
    var inRateMin = 10.0, inRateMax = 0.0, outRateMin = 10.0, outRateMax = 0.0
    /// Latest sample/host times, to measure the real rate of each side between two UI reads.
    var inSampleNow = 0.0, outSampleNow = 0.0
    var inHostNow: UInt64 = 0, outHostNow: UInt64 = 0
    /// Callbacks whose processing took longer than the time available.
    var overruns: UInt64 = 0
    /// Worst callback compute time (s) since the health log last read it.
    var computeWorst: Double = 0
    private var lastInSample = -1.0, lastOutSample = -1.0
    private let silence: UnsafeMutablePointer<Float>
    private let inPtrs: UnsafeMutablePointer<UnsafePointer<Float>>
    private let inStrides: UnsafeMutablePointer<Int>

    init(convolver: Convolver, sampleRate: Double) {
        self.convolver = convolver
        channels = convolver.inputChannels
        self.sampleRate = sampleRate
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        ticksToSeconds = Double(tb.numer) / Double(tb.denom) * 1e-9
        silence = .allocate(capacity: 1)
        silence.initialize(to: 0)
        inPtrs = .allocate(capacity: max(channels, 1))
        inPtrs.initialize(repeating: UnsafePointer(silence), count: max(channels, 1))
        inStrides = .allocate(capacity: max(channels, 1))
        inStrides.initialize(repeating: 0, count: max(channels, 1))
    }
    deinit { silence.deallocate(); inPtrs.deallocate(); inStrides.deallocate() }

    @inline(__always)
    func render(_ input: UnsafePointer<AudioBufferList>, _ output: UnsafeMutablePointer<AudioBufferList>,
                inTime: UnsafePointer<AudioTimeStamp>, outTime: UnsafePointer<AudioTimeStamp>) {
        let t0 = mach_absolute_time()
        let valid = AudioTimeStampFlags.sampleTimeValid
        if inTime.pointee.mFlags.contains(valid) && outTime.pointee.mFlags.contains(valid) {
            let d = outTime.pointee.mSampleTime - inTime.pointee.mSampleTime
            if d > 0 && d < sampleRate { ioFrames = ioFrames == 0 ? d : ioFrames + (d - ioFrames) * 0.05 }
        }
        let it = inTime.pointee, ot = outTime.pointee
        if it.mFlags.contains(valid) {
            if lastInSample >= 0, abs(it.mSampleTime - (lastInSample + Double(lastFrames))) > 0.5 { inJumps &+= 1 }
            lastInSample = it.mSampleTime
            inSampleNow = it.mSampleTime
            if it.mFlags.contains(.hostTimeValid) { inHostNow = it.mHostTime }
            if it.mFlags.contains(.rateScalarValid) {
                inRateMin = min(inRateMin, it.mRateScalar); inRateMax = max(inRateMax, it.mRateScalar)
            }
        }
        if ot.mFlags.contains(valid) {
            if lastOutSample >= 0, abs(ot.mSampleTime - (lastOutSample + Double(lastFrames))) > 0.5 { outJumps &+= 1 }
            lastOutSample = ot.mSampleTime
            outSampleNow = ot.mSampleTime
            if ot.mFlags.contains(.hostTimeValid) { outHostNow = ot.mHostTime }
            if ot.mFlags.contains(.rateScalarValid) {
                outRateMin = min(outRateMin, ot.mRateScalar); outRateMax = max(outRateMax, ot.mRateScalar)
            }
        }
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

        // Source: the captured channels (tap streams or the input device's streams) come after any input
        // streams of the output device, so take the last `channels` channels of the input buffer list.
        var total = 0
        for b in ins { total += Int(b.mNumberChannels) }
        let first = total - channels
        var inFrames = Int.max
        var g = 0
        for b in ins {
            let nch = Int(b.mNumberChannels)
            defer { g += nch }
            guard nch > 0, g + nch > first, let d = b.mData else { continue }
            let p = UnsafePointer(d.assumingMemoryBound(to: Float.self))
            inFrames = min(inFrames, Int(b.mDataByteSize) / (MemoryLayout<Float>.size * nch))
            for c in 0..<nch where g + c >= first {
                inPtrs[g + c - first] = p + c
                inStrides[g + c - first] = nch
            }
        }
        if first < 0 {   // fewer channels than expected: the missing ones read silence
            for k in 0..<min(-first, channels) { inPtrs[k] = UnsafePointer(silence); inStrides[k] = 0 }
        }
        if inFrames == Int.max { inFrames = frames }
        // If the capture side delivered less than a full buffer, play this cycle on silent input rather than
        // skipping it, so the output (and the surround test) keeps running.
        if inFrames < frames {
            for k in 0..<channels { inPtrs[k] = UnsafePointer(silence); inStrides[k] = 0 }
            starvedCallbacks &+= 1
        }

        let n = frames
        if n > 0 {
            convolver.process(inputs: inPtrs, inStrides: inStrides, outL: dstL, outR: dstR, outStride: outStride, frames: n)
        }

        callbacks &+= 1
        if frames > 0 {
            let elapsed = Double(mach_absolute_time() - t0) * ticksToSeconds
            let budget = Double(frames) / sampleRate
            cpuLoad += (elapsed / budget - cpuLoad) * 0.05
            computeAvg = computeAvg == 0 ? elapsed : computeAvg + (elapsed - computeAvg) * 0.05
            if elapsed > computeMax { computeMax = elapsed }
            if elapsed > budget { overruns &+= 1 }
            if elapsed > computeWorst { computeWorst = elapsed }
            computeBudget = budget
            lastFrames = frames
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
    Unmanaged<RenderContext>.fromOpaque(clientData).takeUnretainedValue()
        .render(inputData, outputData, inTime: inputTime, outTime: outputTime)
    return noErr
}
