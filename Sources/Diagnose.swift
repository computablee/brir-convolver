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

        // Another process plays into the device; does its audio reach the input? Once with this client only
        // reading, once with it also writing silence to the output (as BRIR Convolver's capture aggregate does).
        let a = otherClientTest(dev, writeSilence: false)
        print(a > 0.01 ? String(format: "[PASS] audio from another app reaches the input (peak %.3f)", a)
                       : String(format: "[FAIL] audio from another app did NOT reach the input (peak %.4f)", a))
        let b = otherClientTest(dev, writeSilence: true)
        print(b > 0.01 ? String(format: "[PASS] …also while this client writes silence to the output (peak %.3f)", b)
                       : String(format: "[FAIL] …a client writing silence to the output wipes other apps' audio (peak %.4f)", b))
        // Recreate the app's capture aggregate in a few configurations and see which carry another app's audio.
        let outName = args.drop(while: { $0 != "--diagnose" }).dropFirst().first
        let outDev = CA.outputDevices().first { d in
            d.uid != VirtualDevice.uid && (outName.map { d.name.localizedCaseInsensitiveContains($0) }
                                           ?? !d.name.localizedCaseInsensitiveContains("graphworks"))
        }
        var aggOK = true
        if let o = outDev {
            print("Aggregate tests with output \(o.name) [\(o.uid)] (pass a name after --diagnose to pick another):")
            for (label, mainIsOutput, drift) in [("E70-style main + surround, drift on (current app)", true, true),
                                                 ("main + surround, drift off", true, false),
                                                 ("surround as main + output, drift on", false, true)] {
                let r = aggregateTest(output: o.uid, surround: dev, mainIsOutput: mainIsOutput, drift: drift)
                print(String(format: "  %@ %@: input peak %.3f, callbacks %d, surround driver running during test: %@",
                             r.peak > 0.01 ? "[PASS]" : "[FAIL]", label, r.peak, r.callbacks, r.driverRunning))
                if label.hasSuffix("(current app)") { aggOK = r.peak > 0.01 }
            }
        } else {
            print("Aggregate tests skipped: no other output device found.")
        }
        return ok && a > 0.01 && b > 0.01 && aggOK
    }

    static func aggregateTest(output: String, surround dev: AudioObjectID, mainIsOutput: Bool, drift: Bool)
        -> (peak: Float, callbacks: Int, driverRunning: String) {
        let sub: [[String: Any]] = mainIsOutput
            ? [[kAudioSubDeviceUIDKey: output], [kAudioSubDeviceUIDKey: VirtualDevice.uid, kAudioSubDeviceDriftCompensationKey: drift]]
            : [[kAudioSubDeviceUIDKey: VirtualDevice.uid], [kAudioSubDeviceUIDKey: output, kAudioSubDeviceDriftCompensationKey: drift]]
        let dict: [String: Any] = [
            kAudioAggregateDeviceNameKey: "BRIR Convolver Diagnose",
            kAudioAggregateDeviceUIDKey: "\(AudioPipeline.aggregateUIDPrefix).diag.\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: mainIsOutput ? output : VirtualDevice.uid,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceSubDeviceListKey: sub,
        ]
        var agg = AudioObjectID(0)
        let st = AudioHardwareCreateAggregateDevice(dict as CFDictionary, &agg)
        guard st == noErr else { return (-1, 0, "aggregate failed \(st)") }
        defer { AudioHardwareDestroyAggregateDevice(agg) }
        Thread.sleep(forTimeInterval: 0.3)
        final class S { var peak: Float = 0; var callbacks = 0; var inCh = 0 }
        let s = S()
        let want = CA.channelCount(dev, scope: kAudioObjectPropertyScopeInput)
        var procID: AudioDeviceIOProcID?
        AudioDeviceCreateIOProcIDWithBlock(&procID, agg, nil) { _, inData, _, outData, _ in
            s.callbacks += 1
            let ins = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inData))
            var total = 0
            for b in ins { total += Int(b.mNumberChannels) }
            s.inCh = total
            // The surround device's channels: last `want` when the output is main, first `want` otherwise.
            let lo = mainIsOutput ? total - want : 0, hi = lo + want
            var g = 0
            for b in ins {
                let n = Int(b.mNumberChannels)
                defer { g += n }
                guard n > 0, let d = b.mData?.assumingMemoryBound(to: Float.self) else { continue }
                let frames = Int(b.mDataByteSize) / (4 * n)
                for f in 0..<frames { for c in 0..<n where g + c >= lo && g + c < hi {
                    let v = abs(d[f * n + c]); if v.isFinite && v > s.peak { s.peak = v }
                } }
            }
            for b in UnsafeMutableAudioBufferListPointer(outData) where b.mData != nil { memset(b.mData!, 0, Int(b.mDataByteSize)) }
        }
        guard let pid = procID else { return (-1, 0, "no IOProc") }
        AudioDeviceStart(agg, pid)
        Thread.sleep(forTimeInterval: 0.4)
        // Before anything else plays into it: has the aggregate started the surround device's driver?
        let running = CA.get(dev, kAudioDevicePropertyDeviceIsRunning, initial: UInt32(9)).map(String.init) ?? "n/a"
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-a", "\(dev)", "testing one two three"]
        try? say.run()
        say.waitUntilExit()
        Thread.sleep(forTimeInterval: 0.3)
        AudioDeviceStop(agg, pid)
        AudioDeviceDestroyIOProcID(agg, pid)
        return (s.peak, s.callbacks, running + " (aggregate in channels \(s.inCh))")
    }

    /// Speak a phrase into the device from a separate process (`say -a`) while reading the device's input.
    static func otherClientTest(_ dev: AudioObjectID, writeSilence: Bool) -> Float {
        final class Peak { var v: Float = 0 }
        let pk = Peak()
        var procID: AudioDeviceIOProcID?
        let st = AudioDeviceCreateIOProcIDWithBlock(&procID, dev, nil) { _, inData, _, outData, _ in
            for b in UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inData)) {
                guard let d = b.mData?.assumingMemoryBound(to: Float.self) else { continue }
                let n = Int(b.mDataByteSize) / 4
                for i in 0..<n { let v = abs(d[i]); if v.isFinite && v > pk.v { pk.v = v } }   // all channels: `say` is mono → centre
            }
            if writeSilence {
                for b in UnsafeMutableAudioBufferListPointer(outData) where b.mData != nil { memset(b.mData!, 0, Int(b.mDataByteSize)) }
            }
        }
        guard st == noErr, let pid = procID else { print("  IOProc failed: \(st)"); return -1 }
        AudioDeviceStart(dev, pid)
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-a", "\(dev)", "testing one two three"]
        print("  \(writeSilence ? "reading + writing silence" : "reading only"): `say -a \(dev)` into the surround device…")
        do { try say.run(); say.waitUntilExit() } catch { print("  couldn't run say: \(error)") }
        Thread.sleep(forTimeInterval: 0.3)
        AudioDeviceStop(dev, pid)
        AudioDeviceDestroyIOProcID(dev, pid)
        return pk.v
    }
}
