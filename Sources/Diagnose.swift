import CoreAudio
import Foundation

/// `BRIRConvolver --diagnose [output device name]` — checks the installed surround device directly:
/// its properties, which apps play into it, a loopback round trip (a quiet tone written to its output must
/// come back on its input), and optionally the full capture → convolver → output path.
enum Diagnose {
    final class Stats {
        var callbacks = 0
        var inFrames = 0
        var inPeak = [Float](repeating: 0, count: 64)
        var inNaN = 0
        var inChannels = 0
        var outChannels = 0
        var phase = 0.0
        var firstIn = -1.0, firstOut = -1.0
    }

    static func run(args: [String]) -> Bool {
        print("=== BRIR Convolver diagnostics ===")
        let def = CA.defaultOutputDevice()
        print("Default output: \(def.flatMap(CA.deviceName) ?? "none") [\(def.flatMap(CA.deviceUID) ?? "-")]")
        guard let dev = VirtualDevice.deviceID else {
            print("Surround device: NOT LOADED by Core Audio (not installed, or coreaudiod rejected it)."); return false
        }
        func u32(_ sel: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> String {
            CA.get(dev, sel, scope: scope, initial: UInt32(0)).map(String.init) ?? "n/a"
        }
        print("Surround device id \(dev): rate \(CA.nominalSampleRate(dev).map { String(Int($0)) } ?? "n/a") Hz, "
              + "in \(CA.channelCount(dev, scope: kAudioObjectPropertyScopeInput)) ch, "
              + "out \(CA.channelCount(dev, scope: kAudioObjectPropertyScopeOutput)) ch, "
              + "running \(u32(kAudioDevicePropertyDeviceIsRunning)), runningSomewhere \(u32(kAudioDevicePropertyDeviceIsRunningSomewhere)), "
              + "buffer \(CA.bufferFrameSize(dev).map(String.init) ?? "n/a")")
        let labels = CA.speakerLabels(dev) ?? []
        print("Layout labels: \(labels.map(String.init).joined(separator: " "))")
        for scope in [kAudioObjectPropertyScopeOutput, kAudioObjectPropertyScopeInput] {
            let streams = CA.getArray(dev, kAudioDevicePropertyStreams, scope: scope, zero: AudioObjectID(0))
            for s in streams {
                if let f = CA.get(s, kAudioStreamPropertyVirtualFormat, initial: AudioStreamBasicDescription()) {
                    print("  \(scope == kAudioObjectPropertyScopeInput ? "input" : "output") stream \(s): \(Int(f.mSampleRate)) Hz, "
                          + "\(f.mChannelsPerFrame) ch, \(f.mBitsPerChannel)-bit, flags 0x\(String(f.mFormatFlags, radix: 16)), "
                          + "active \(CA.get(s, kAudioStreamPropertyIsActive, initial: UInt32(0)).map(String.init) ?? "n/a")")
                }
            }
        }
        let volAddr = CA.getArray(dev, kAudioObjectPropertyControlList, zero: AudioObjectID(0))
        for c in volAddr {
            if let v = CA.get(c, kAudioLevelControlPropertyScalarValue, initial: Float32(-1)) { print("  volume control \(c): scalar \(v)") }
            if let m = CA.get(c, kAudioBooleanControlPropertyValue, initial: UInt32(9)) { print("  mute control \(c): \(m)") }
        }

        print("Apps playing (output devices):")
        for p in CA.processObjects() {
            let outs = CA.processOutputDevices(p.objectID)
            let running = CA.get(p.objectID, kAudioProcessPropertyIsRunningOutput, initial: UInt32(0)) ?? 0
            guard !outs.isEmpty || running != 0 else { continue }
            print("  \(p.displayName): running output \(running), devices \(outs.map { CA.deviceName($0) ?? "\($0)" })")
        }

        // Loopback round trip on the surround device alone (no aggregate).
        print("Loopback test: writing a −20 dBFS 1 kHz tone to the surround device's L/R and reading its input for 2 s…")
        let st = Stats()
        let rate = CA.nominalSampleRate(dev) ?? 48000
        var procID: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcIDWithBlock(&procID, dev, nil) { _, inData, inTime, outData, outTime in
            st.callbacks += 1
            if st.firstIn < 0 { st.firstIn = inTime.pointee.mSampleTime; st.firstOut = outTime.pointee.mSampleTime }
            let ins = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inData))
            var ch = 0
            for b in ins {
                let n = Int(b.mNumberChannels)
                guard n > 0, let d = b.mData?.assumingMemoryBound(to: Float.self) else { ch += n; continue }
                let frames = Int(b.mDataByteSize) / (4 * n)
                st.inFrames += frames
                for f in 0..<frames {
                    for c in 0..<n where ch + c < 64 {
                        let v = d[f * n + c]
                        if !v.isFinite { st.inNaN += 1 } else { st.inPeak[ch + c] = max(st.inPeak[ch + c], abs(v)) }
                    }
                }
                ch += n
            }
            st.inChannels = ch
            let outs = UnsafeMutableAudioBufferListPointer(outData)
            var oc = 0
            for b in outs {
                let n = Int(b.mNumberChannels)
                guard n > 0, let d = b.mData?.assumingMemoryBound(to: Float.self) else { oc += n; continue }
                let frames = Int(b.mDataByteSize) / (4 * n)
                var ph = st.phase
                for f in 0..<frames {
                    let s = Float(0.1 * sin(ph))
                    ph += 2 * Double.pi * 1000 / rate
                    for c in 0..<n { d[f * n + c] = (oc + c) < 2 ? s : 0 }
                }
                if oc == 0 { st.phase = ph.truncatingRemainder(dividingBy: 2 * Double.pi) }
                oc += n
            }
            st.outChannels = oc
        }
        guard status == noErr, let pid = procID else { print("  FAIL creating IOProc: \(status)"); return false }
        let startSt = AudioDeviceStart(dev, pid)
        Thread.sleep(forTimeInterval: 2)
        AudioDeviceStop(dev, pid)
        AudioDeviceDestroyIOProcID(dev, pid)
        print("  start status \(startSt), callbacks \(st.callbacks), input frames \(st.inFrames), in/out channels \(st.inChannels)/\(st.outChannels), "
              + "first input/output sample time \(st.firstIn)/\(st.firstOut)")
        let peaks = (0..<min(st.inChannels, 12)).map { String(format: "%.3f", st.inPeak[$0]) }
        print("  input peaks per channel: \(peaks.joined(separator: " ")), non-finite samples \(st.inNaN)")
        let ok = st.callbacks > 10 && st.inNaN == 0 && st.inPeak[0] > 0.05 && st.inPeak[0] < 0.2
        print(ok ? "[PASS] loopback round trip works" : "[FAIL] loopback round trip (expected ≈0.100 on channels 1–2, no non-finite samples)")
        return ok
    }
}
