import Foundation

/// `BRIRConvolver --selftest [file.wav]` — verifies the DSP against a direct double-precision
/// time-domain convolution (stereo and 7.1 routing), checks the file-layout loaders, the adaptive preamp,
/// bit-exact bypass and A/B, and benchmarks realtime headroom.
/// Without a file it uses synthetic BRIRs, so no impulse response needs to ship with the repo.
enum SelfTest {
    static var ok = true
    static func report(_ pass: Bool, _ msg: String) {
        ok = ok && pass
        print("[\(pass ? "PASS" : "FAIL")] \(msg)")
    }

    static func run(wavPath: String) -> Bool {
        let set: BRIRSet
        if wavPath.isEmpty {
            set = syntheticSet(speakers: [.FL, .FR], length: 36000)
            print("Using synthetic true-stereo BRIR: 48000 Hz, \(set.length) frames (pass a WAV path to test a real one)")
        } else {
            do {
                let wav = try WAVFile(url: URL(fileURLWithPath: wavPath))
                print("Loaded \(wavPath): \(wav.channelCount) ch, \(Int(wav.sampleRate)) Hz, \(wav.bitsPerSample)-bit, \(wav.frameCount) frames")
                set = try BRIRSet(wav: wav, order: .inputMajor, mapping: .standard)
                print("  layout: \(set.format), speakers \(set.speakerList)")
            } catch {
                print("FAIL: \(error.localizedDescription)"); return false
            }
        }
        for s in set.speakers {
            func e(_ h: [Double]) -> Double { 10 * log10(h.reduce(0) { $0 + $1 * $1 }) }
            print(String(format: "  %@ energy: left ear %.2f dB, right ear %.2f dB", s.speaker.rawValue, e(s.left), e(s.right)))
        }

        testLoaders()
        testRoutingRules()

        // ---------- Accuracy: stereo routing on the loaded/synthetic set, 7.1 routing on a synthetic set ----------
        let stereo = Routing.make(brir: set, roles: Routing.defaultRoles(count: 2), lfeGain: 1)
        for B in [64, 256, 1024] { accuracy(routing: stereo, rate: set.sampleRate, B: B, label: "stereo") }
        let surroundSet = syntheticSet(speakers: [.FL, .FR, .FC, .SL, .SR, .BL, .BR], length: 9000)
        let surround = Routing.make(brir: surroundSet, roles: Routing.defaultRoles(count: 8), lfeGain: pow(10, -3.0 / 20))
        print("  7.1 routing: \(surround.summary)")
        for B in [64, 256] { accuracy(routing: surround, rate: surroundSet.sampleRate, B: B, label: "7.1") }

        testAdaptivePreamp(routing: stereo, rate: set.sampleRate)
        testBypassAndAB(routing: stereo, rate: set.sampleRate)
        testMultichannelBypass(routing: surround, rate: surroundSet.sampleRate)

        // ---------- Performance ----------
        benchmark(routing: stereo, rate: set.sampleRate, label: "stereo")
        let full = syntheticSet(speakers: [.FL, .FR, .FC, .SL, .SR, .BL, .BR], length: set.length)
        benchmark(routing: Routing.make(brir: full, roles: Routing.defaultRoles(count: 8), lfeGain: 1),
                  rate: full.sampleRate, label: "7.1")

        // ---------- Analysis ----------
        if let ir = set.pair(.front) { testAnalysis(ir) }
        print(ok ? "ALL TESTS PASSED" : "SOME TESTS FAILED")
        return ok
    }

    // MARK: - Tests

    /// Each channel holds its own index as a marker, so we can check exactly which channel lands where.
    static func testLoaders() {
        func marked(_ n: Int) -> [[Double]] { (0..<n).map { [Double($0)] } }
        func check(_ set: BRIRSet, _ expect: [Speaker: (Int, Int)], _ name: String) {
            var bad: [String] = []
            for (s, (l, r)) in expect {
                guard let ir = set.ir(s) else { bad.append("\(s.rawValue) missing"); continue }
                if ir.left != [Double(l)] || ir.right != [Double(r)] {
                    bad.append("\(s.rawValue)=(\(Int(ir.left[0])),\(Int(ir.right[0]))) expected (\(l),\(r))")
                }
            }
            if set.speakers.count != expect.count { bad.append("\(set.speakers.count) speakers, expected \(expect.count)") }
            report(bad.isEmpty, "loader \(name)" + (bad.isEmpty ? "" : ": " + bad.joined(separator: ", ")))
        }
        do {
            check(try BRIRSet(channels: marked(4), sampleRate: 48000, order: .inputMajor, mapping: .standard),
                  [.FL: (0, 1), .FR: (2, 3)], "true stereo LL LR RL RR")
            check(try BRIRSet(channels: marked(4), sampleRate: 48000, order: .outputMajor, mapping: .standard),
                  [.FL: (0, 2), .FR: (1, 3)], "true stereo LL RL LR RR")
            check(try BRIRSet(channels: marked(2), sampleRate: 48000, order: .inputMajor, mapping: .standard),
                  [.FL: (0, 1), .FR: (1, 0)], "symmetric pair")
            // HeSuVi: FL-L FL-R SL-L SL-R BL-L BL-R FC-L FR-R FR-L SR-R SR-L BR-R BR-L FC-R
            check(try BRIRSet(channels: marked(14), sampleRate: 48000, order: .inputMajor, mapping: .standard),
                  [.FL: (0, 1), .SL: (2, 3), .BL: (4, 5), .FC: (6, 13), .FR: (8, 7), .SR: (10, 9), .BR: (12, 11)], "HeSuVi 14-ch")
            check(try BRIRSet(channels: marked(16), sampleRate: 48000, order: .inputMajor, mapping: .standard),
                  [.FL: (0, 1), .FR: (2, 3), .FC: (4, 5), .LFE: (6, 7), .SL: (8, 9), .SR: (10, 11), .BL: (12, 13), .BR: (14, 15)],
                  "16-ch standard")
            check(try BRIRSet(channels: marked(16), sampleRate: 48000, order: .inputMajor, mapping: .cinema),
                  [.FC: (0, 1), .LFE: (2, 3), .FL: (4, 5), .FR: (6, 7), .SL: (8, 9), .SR: (10, 11), .BL: (12, 13), .BR: (14, 15)],
                  "16-ch cinema order")
        } catch {
            report(false, "loader threw: \(error.localizedDescription)")
        }
        report((try? BRIRSet(channels: marked(6), sampleRate: 48000, order: .inputMajor, mapping: .standard)) == nil,
               "loader rejects a 6-channel file")
    }

    static func testRoutingRules() {
        // LFE identical to FC (ASH copies it) folds into the FC source; stereo dry downmix is exact.
        var s16 = syntheticSet(speakers: [.FL, .FR, .FC, .SL, .SR, .BL, .BR], length: 64)
        let fc = s16.ir(.FC)!
        s16.speakers.append(SpeakerIR(speaker: .LFE, left: fc.left, right: fc.right))
        let r = Routing.make(brir: s16, roles: Routing.defaultRoles(count: 8), lfeGain: 0.5)
        let fcSrc = r.sources.first { $0.speaker == .FC }
        let folded = r.sources.count == 7 && fcSrc?.inputs.count == 2 && fcSrc?.inputs.contains { $0.channel == 3 && $0.gain == 0.5 } == true
        report(folded, "LFE identical to FC is folded into the FC source: \(r.summary)")
        // Stereo BRIR with 7.1 input: everything lands on FL/FR.
        let st = syntheticSet(speakers: [.FL, .FR], length: 64)
        let r2 = Routing.make(brir: st, roles: Routing.defaultRoles(count: 8), lfeGain: 0)
        report(r2.sources.map(\.speaker) == [.FL, .FR] && r2.sources[0].inputs.count == 4,
               "7.1 input on a stereo BRIR folds onto FL/FR (LFE off): \(r2.summary)")
    }

    /// Run `x` (one array per input channel) through a convolver in irregular callback sizes.
    static func run(_ conv: Convolver, _ x: [[Float]]) -> ([Float], [Float]) {
        let total = x[0].count
        var yl = [Float](repeating: 0, count: total), yr = yl
        var rng = SystemRandomNumberGenerator()
        let base = x.map { a -> UnsafeMutablePointer<Float> in
            let p = UnsafeMutablePointer<Float>.allocate(capacity: total)
            p.initialize(from: a, count: total)
            return p
        }
        defer { base.forEach { $0.deallocate() } }
        let strides = [Int](repeating: 1, count: x.count)
        var done = 0
        while done < total {
            let n = min(total - done, Int.random(in: 1...700, using: &rng))
            let ptrs = base.map { UnsafePointer($0 + done) }
            yl.withUnsafeMutableBufferPointer { c in yr.withUnsafeMutableBufferPointer { d in
                conv.process(inputs: ptrs, inStrides: strides, outL: c.baseAddress! + done, outR: d.baseAddress! + done,
                             outStride: 1, frames: n)
            }}
            done += n
        }
        return (yl, yr)
    }

    static func noise(channels: Int, count: Int, active: Int, amp: Float) -> [[Float]] {
        var rng = SystemRandomNumberGenerator()
        return (0..<channels).map { _ in
            (0..<count).map { $0 < active ? Float.random(in: -amp...amp, using: &rng) : 0 }
        }
    }

    static func accuracy(routing: Routing, rate: Double, B: Int, label: String) {
        let L = routing.sources.map { max($0.left.count, $0.right.count) }.max() ?? 0
        let excite = 4096
        let total = excite + L + 2 * B
        let x = noise(channels: routing.inputChannels, count: total, active: excite, amp: 0.5)
        let conv = Convolver(routing: routing, sampleRate: rate, blockSize: B, gainDB: 0, bypass: false, ceiling: .infinity)
        let (yl, yr) = run(conv, x)
        // Reference: y_o[n] = Σ_s Σ_k m_s[k] h_{s,o}[n-k], with m_s the weighted input mix, delayed by B.
        let mixes: [[Double]] = routing.sources.map { s in
            (0..<excite).map { k in s.inputs.reduce(0.0) { $0 + Double(x[$1.channel][k]) * $1.gain } }
        }
        var maxErr = 0.0, maxRef = 0.0
        let checkCount = min(total - B, excite + L - 1)
        for n in stride(from: 0, to: checkCount, by: 7) {
            for o in 0..<2 {
                var ref = 0.0
                for (s, src) in routing.sources.enumerated() {
                    let h = o == 0 ? src.left : src.right
                    let m = mixes[s]
                    let kLo = max(0, n - h.count + 1), kHi = min(n, excite - 1)
                    if kLo <= kHi { for k in kLo...kHi { ref += m[k] * h[n - k] } }
                }
                let got = Double((o == 0 ? yl : yr)[n + B])
                maxErr = max(maxErr, abs(got - ref))
                maxRef = max(maxRef, abs(ref))
            }
        }
        let errDB = 20 * log10(maxErr / maxRef)
        report(errDB < -130, String(format: "accuracy %@ B=%4d (%d sources): max error %.3e (%.1f dB re peak; Float32 output floor ≈ -144 dB)",
                                    label, B, routing.sources.count, maxErr, errDB))
    }

    /// The preamp must never let a sample over the ceiling, and must settle on exactly the largest gain that
    /// keeps the loudest block under it (lowered only by what was needed).
    static func testAdaptivePreamp(routing: Routing, rate: Double) {
        let B = 256, total = 200_000
        // Quiet start, then a loud section, then quiet again.
        var x = noise(channels: routing.inputChannels, count: total, active: total, amp: 1)
        for c in 0..<x.count { for i in 0..<total where i < 40_000 || i > 120_000 { x[c][i] *= 0.02 } }
        // Pre-gain wet output (ceiling disabled, 0 dB): its peak sets the minimum necessary reduction.
        let ref = Convolver(routing: routing, sampleRate: rate, blockSize: B, gainDB: 0, bypass: false, ceiling: .infinity)
        let (rl, rr) = run(ref, x)
        let rawPeak = zip(rl, rr).reduce(0.0) { max($0, Double(abs($1.0)), Double(abs($1.1))) }
        let conv = Convolver(routing: routing, sampleRate: rate, blockSize: B, gainDB: 0, bypass: false)
        let (yl, yr) = run(conv, x)
        let peak = zip(yl, yr).reduce(0.0) { max($0, Double(abs($1.0)), Double(abs($1.1))) }
        let finalGain = conv.params[Convolver.Param.gain]
        let expected = min(1, Convolver.defaultCeiling / rawPeak)
        let over = zip(yl, yr).filter { Double(abs($0.0)) > Convolver.defaultCeiling * (1 + 1e-6) || Double(abs($0.1)) > Convolver.defaultCeiling * (1 + 1e-6) }.count
        report(over == 0 && peak <= 1, String(format: "adaptive preamp: output peak %.4f dBFS, %d samples over the −0.01 dBFS ceiling (raw peak %+.2f dBFS)",
                                             20 * log10(peak), over, 20 * log10(rawPeak)))
        let relErr = abs(finalGain - expected) / expected
        report(relErr < 1e-4, String(format: "adaptive preamp settles at the minimum reduction: %.4f dB (expected %.4f dB), lowered %d×",
                                     20 * log10(finalGain), 20 * log10(expected), Int(conv.params[Convolver.Param.reductions])))
        // Reset: back to 0 dB while the input is quiet.
        conv.requestGainReset()
        let quiet = noise(channels: routing.inputChannels, count: 20_000, active: 20_000, amp: 0.001)
        _ = run(conv, quiet)
        report(conv.params[Convolver.Param.gain] == 1, String(format: "reset raises the preamp to 0 dB on quiet input (now %.4f dB)", conv.gainDB))
    }

    static func testBypassAndAB(routing: Routing, rate: Double) {
        // Bypass is bit-exact for stereo input.
        do {
            let B = 256, total = 50_000
            let conv = Convolver(routing: routing, sampleRate: rate, blockSize: B, gainDB: -7.3, bypass: true)
            let x = noise(channels: 2, count: total, active: total, amp: 1)
            let (yl, yr) = run(conv, x)
            var mismatches = 0
            for i in 0..<(total - B) where yl[i + B].bitPattern != x[0][i].bitPattern || yr[i + B].bitPattern != x[1][i].bitPattern {
                mismatches += 1
            }
            report(mismatches == 0, "bypass bit-exact: \(mismatches) mismatching frames of \(total - B)")
        }
        // A/B hold = dry × preamp, exactly (preamp adaptation disabled so the gain stays put).
        do {
            let B = 256, total = 60_000, gainDB = -7.3
            let conv = Convolver(routing: routing, sampleRate: rate, blockSize: B, gainDB: gainDB, bypass: false, ceiling: .infinity)
            conv.setABHold(true)
            let g = pow(10, gainDB / 20)
            let x = noise(channels: 2, count: total, active: total, amp: 1)
            let (yl, yr) = run(conv, x)
            var mismatches = 0
            let settle = 20_000   // crossfade + gain smoothing fully settled
            for i in settle..<(total - B) where yl[i + B] != Float(Double(x[0][i]) * g) || yr[i + B] != Float(Double(x[1][i]) * g) {
                mismatches += 1
            }
            report(mismatches == 0, "A/B hold = dry × preamp (\(gainDB) dB): \(mismatches) mismatching frames of \(total - B - settle)")
        }
    }

    /// Bypass with 7.1 input is the ITU-style stereo downmix (LFE omitted).
    static func testMultichannelBypass(routing: Routing, rate: Double) {
        let B = 128, total = 20_000
        let conv = Convolver(routing: routing, sampleRate: rate, blockSize: B, gainDB: 0, bypass: true)
        let x = noise(channels: 8, count: total, active: total, amp: 0.3)
        let (yl, _) = run(conv, x)
        let h = 0.5.squareRoot()
        var maxErr = 0.0
        for i in 0..<(total - B) {
            let ref = Double(x[0][i]) + Double(x[2][i]) * h + Double(x[4][i]) * h + Double(x[6][i]) * h
            maxErr = max(maxErr, abs(Double(yl[i + B]) - ref))
        }
        report(maxErr < 1e-6, String(format: "7.1 bypass = stereo downmix: max error %.2e", maxErr))
    }

    static func benchmark(routing: Routing, rate: Double, label: String) {
        let I = routing.inputChannels
        var rng = SystemRandomNumberGenerator()
        for B in [64, 128, 256, 512] {
            let conv = Convolver(routing: routing, sampleRate: rate, blockSize: B, gainDB: -6, bypass: false)
            let cb = 512
            let iters = Int(10.0 * rate) / cb
            var inBuf = [Float](repeating: 0, count: cb * I)
            for i in 0..<inBuf.count { inBuf[i] = Float.random(in: -0.5...0.5, using: &rng) }
            var outBuf = [Float](repeating: 0, count: cb * 2)
            let strides = [Int](repeating: I, count: I)
            let t0 = DispatchTime.now().uptimeNanoseconds
            inBuf.withUnsafeBufferPointer { ip in outBuf.withUnsafeMutableBufferPointer { op in
                let ptrs = (0..<I).map { ip.baseAddress! + $0 }
                for _ in 0..<iters {
                    conv.process(inputs: ptrs, inStrides: strides, outL: op.baseAddress!, outR: op.baseAddress! + 1, outStride: 2, frames: cb)
                }
            }}
            let dt = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e9
            let audio = Double(iters * cb) / rate
            print(String(format: "[INFO] %@ (%d sources) B=%4d (%3d partitions, +%.1f ms): %.0fx realtime → %.2f%% of one core",
                         label, conv.sourceCount, B, conv.partitions, Double(B) / rate * 1000, audio / dt, dt / audio * 100))
        }
    }

    static func testAnalysis(_ ir: TrueStereoIR) {
        let t0 = DispatchTime.now().uptimeNanoseconds
        let a = IRAnalysis.compute(ir: ir)
        let dt = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
        print(String(format: "[INFO] analysis computed in %.0f ms", dt))
        print(String(format: "  RT60 mid %@ ms, EDT %@ ms, DRR %+.1f dB, C50 %+.1f dB, ILD %.1f dB, ITD %.0f µs",
                     a.rt60Mid.map { String(format: "%.0f", $0 * 1000) } ?? "—", a.edt.map { String(format: "%.0f", $0 * 1000) } ?? "—",
                     a.drr, a.c50, a.ildDirect, a.itdMicros))
        print("  bands: " + zip(a.bandCenters, zip(a.bandRT60, a.bandMethod)).map { c, r in
            "\(Int(c))Hz=\(r.0.map { String(format: "%.0f", $0 * 1000) } ?? "—")(\(r.1))" }.joined(separator: " "))
        for (k, name) in IRAnalysis.shortNames.enumerated() {
            let c = a.curve(series: k, widthOct: 1.0 / 3, points: 11)
            print("  \(name) 1/3-oct dB @20Hz..20kHz: " + c.map { String(format: "%+.1f", $0) }.joined(separator: " "))
        }
        // Cross-check: unsmoothed response at 1 kHz vs a direct DFT of the path
        let f = 1000.0, h = ir.paths[0]
        var re = 0.0, im = 0.0
        for (i, v) in h.enumerated() { let w = -2 * Double.pi * f * Double(i) / ir.sampleRate; re += v * cos(w); im += v * sin(w) }
        let direct = 10 * log10(re * re + im * im)
        let fromCurve = a.curve(series: 0, widthOct: 0, fMin: 999.999, fMax: 1000.001, points: 3)[1]
        report(abs(direct - fromCurve) < 0.5, String(format: "response cross-check @1 kHz: DFT %.3f dB vs analysis %.3f dB", direct, fromCurve))
        print("  spectrogram: \(a.specFrames)×\(a.specRows), images \(a.specImages.count)")
    }

    // MARK: - Synthetic BRIRs

    /// Deterministic stand-in BRIRs: per speaker, a direct impulse at each ear (opposite ear ~0.27 ms later and
    /// ~9 dB lower; centre/back speakers get their own delays), followed by exponentially decaying noise
    /// (RT60 ≈ 300 ms) at 48 kHz.
    static func syntheticSet(speakers: [Speaker], length n: Int) -> BRIRSet {
        let sr = 48000.0
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        func noise() -> Double {   // xorshift64*, uniform in [-1, 1)
            state ^= state >> 12; state ^= state << 25; state ^= state >> 27
            return Double((state &* 0x2545_F491_4F6C_DD1D) >> 11) / Double(1 << 52) - 1
        }
        let decay = log(1000.0) / (0.3 * sr)   // −60 dB in 300 ms
        func path(onset: Int, amp: Double) -> [Double] {
            var h = [Double](repeating: 0, count: n)
            guard onset < n else { return h }
            h[onset] = amp
            if onset + 96 < n { for i in (onset + 96)..<n { h[i] = 0.04 * noise() * exp(-decay * Double(i - onset)) } }
            return h
        }
        let irs: [SpeakerIR] = speakers.enumerated().map { idx, s in
            let leftSide: Bool? = [.FL, .SL, .BL].contains(s) ? true : [.FR, .SR, .BR].contains(s) ? false : nil
            let base = 48 + 3 * idx
            switch leftSide {
            case true?: return SpeakerIR(speaker: s, left: path(onset: base, amp: 0.5), right: path(onset: base + 13, amp: 0.18))
            case false?: return SpeakerIR(speaker: s, left: path(onset: base + 13, amp: 0.18), right: path(onset: base, amp: 0.5))
            case nil: return SpeakerIR(speaker: s, left: path(onset: base, amp: 0.4), right: path(onset: base + 1, amp: 0.39))
            }
        }
        return BRIRSet(speakers: irs, sampleRate: sr, format: "synthetic")
    }
}
