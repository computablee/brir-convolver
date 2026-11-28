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
        testDirectionalFolder()
        testHeightRouting()
        testHeadTrackingMath()

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
        testSurroundTestPlayback(routing: stereo, rate: set.sampleRate)
        testChannelActivity(routing: surround, rate: surroundSet.sampleRate)
        testSolo(routing: surround, rate: surroundSet.sampleRate)
        testIRSwap()
        testSurroundTestRender()

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
        report(errDB < -130, String(format: "accuracy %@ B=%4ld (%ld sources): max error %.3e (%.1f dB re peak; Float32 output floor ≈ -144 dB)",
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
        report(over == 0 && peak <= 1, String(format: "adaptive preamp: output peak %.4f dBFS, %ld samples over the −0.01 dBFS ceiling (raw peak %+.2f dBFS)",
                                             20 * log10(peak), over, 20 * log10(rawPeak)))
        let relErr = abs(finalGain - expected) / expected
        report(relErr < 1e-4, String(format: "adaptive preamp settles at the minimum reduction: %.4f dB (expected %.4f dB), lowered %ld×",
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
            print(String(format: "[INFO] %@ (%ld sources) B=%4ld (%3ld partitions, +%.1f ms): %.0fx realtime → %.2f%% of one core",
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

    // MARK: - Directional folders, heights, surround test

    static func writeWAV(_ url: URL, channels: [[Double]], rate: Int) throws {
        let nch = channels.count, n = channels[0].count
        var d = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        let dataBytes = n * nch * 4
        d.append(contentsOf: Array("RIFF".utf8)); u32(UInt32(36 + dataBytes)); d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(3); u16(UInt16(nch)); u32(UInt32(rate))
        u32(UInt32(rate * nch * 4)); u16(UInt16(nch * 4)); u16(32)
        d.append(contentsOf: Array("data".utf8)); u32(UInt32(dataBytes))
        for i in 0..<n { for c in 0..<nch { u32(Float(channels[c][i]).bitPattern) } }
        try d.write(to: url)
    }

    static func testDirectionalFolder() {
        let parsed = [DirectionalFolder.parse("BRIR_E-15_A30.wav"), DirectionalFolder.parse("BRIR_E0_A-180.wav"),
                      DirectionalFolder.parse("BRIR_True_Stereo.wav"), DirectionalFolder.parse("notes.txt")]
        report(parsed[0] == Direction(elevation: -15, azimuth: 30) && parsed[1] == Direction(elevation: 0, azimuth: -180)
               && parsed[2] == nil && parsed[3] == nil, "directional file names parse (and others are ignored)")

        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("brir-selftest-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: dir) }
        let ear: [Direction] = [-135, -90, -30, 0, 30, 90, 135].map { Direction(elevation: 0, azimuth: $0) }
        let tops: [Direction] = [-45, 45, -135, 135].map { Direction(elevation: 45, azimuth: $0) }
        let decoy = Direction(elevation: 15, azimuth: -30)
        var code: [Direction: Double] = [:]
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            for (i, d) in (ear + tops + [decoy]).enumerated() {
                code[d] = Double(i + 1) / 100
                try writeWAV(dir.appendingPathComponent("BRIR_E\(d.elevation)_A\(d.azimuth).wav"),
                             channels: [[code[d]!, 0, 0], [code[d]! + 0.005, 0, 0]], rate: 48000)
            }
            try "x".write(to: dir.appendingPathComponent("readme.txt"), atomically: true, encoding: .utf8)
            let folder = try DirectionalFolder(url: dir)
            let set = try BRIRSet(folder: folder, positions: [:])
            func uses(_ s: Speaker, _ d: Direction) -> Bool {
                guard let ir = set.ir(s) else { return false }
                return abs(ir.left[0] - code[d]!) < 1e-6 && abs(ir.right[0] - code[d]! - 0.005) < 1e-6
            }
            let ok = set.speakers.count == 11 && uses(.FL, Direction(elevation: 0, azimuth: -30))
                && uses(.FR, Direction(elevation: 0, azimuth: 30)) && uses(.FC, Direction(elevation: 0, azimuth: 0))
                && uses(.SL, Direction(elevation: 0, azimuth: -90)) && uses(.BR, Direction(elevation: 0, azimuth: 135))
                && uses(.TFL, Direction(elevation: 45, azimuth: -45)) && uses(.TBR, Direction(elevation: 45, azimuth: 135))
            report(ok, "directional folder: 11 speakers at their default directions (\(set.chosen.joined(separator: ", ")))")
            let moved = try BRIRSet(folder: folder, positions: [.FL: Direction(elevation: 10, azimuth: -35),
                                                               .TFL: Direction(elevation: 30, azimuth: -60)])
            report(moved.ir(.FL).map { abs($0.left[0] - code[decoy]!) < 1e-6 } == true
                   && moved.ir(.TFL).map { abs($0.left[0] - code[tops[0]]!) < 1e-6 } == true,
                   "directional folder: moved speakers snap to the nearest exported direction")
            // Without anything ≥ 20° up, the heights are left out (they fold down at playback).
            for d in tops { try fm.removeItem(at: dir.appendingPathComponent("BRIR_E\(d.elevation)_A\(d.azimuth).wav")) }
            let flat = try BRIRSet(folder: try DirectionalFolder(url: dir), positions: [:])
            report(flat.speakers.count == 7 && !flat.speakers.contains { $0.speaker.isHeight },
                   "directional folder without elevated directions: 7 ear-level speakers")
        } catch {
            report(false, "directional folder test threw: \(error.localizedDescription)")
        }
    }

    static func testHeightRouting() {
        let roles = Routing.defaultRoles(count: 12)
        let s7 = syntheticSet(speakers: [.FL, .FR, .FC, .SL, .SR, .BL, .BR], length: 64)
        let r7 = Routing.make(brir: s7, roles: roles, lfeGain: 1)
        let h = Routing.minus3dB
        let fl = r7.sources.first { $0.speaker == .FL }?.inputs ?? []
        let bl = r7.sources.first { $0.speaker == .BL }?.inputs ?? []
        report(r7.sources.count == 7 && fl.contains { $0.channel == 8 && abs($0.gain - h) < 1e-12 }
               && bl.contains { $0.channel == 10 && abs($0.gain - h) < 1e-12 },
               "7.1.4 input on a 7.1 BRIR: heights fold onto the speakers below at −3 dB")
        let s11 = syntheticSet(speakers: Speaker.directional, length: 64)
        let r11 = Routing.make(brir: s11, roles: roles, lfeGain: 1)
        report(r11.sources.count == 11 && r11.sources.first { $0.speaker == .TBR }?.inputs.first?.channel == 11,
               "7.1.4 input on a 7.1.4 BRIR: 11 virtual speakers (\(r11.summary))")
    }

    /// The test clip must come out exactly (added to silence, since live input is muted), delayed one block.
    static func testSurroundTestPlayback(routing: Routing, rate: Double) {
        let B = 128, len = 1000
        let conv = Convolver(routing: routing, sampleRate: rate, blockSize: B, gainDB: 0, bypass: false, ceiling: .infinity)
        let cl = (0..<len).map { sin(Double($0) * 0.01) * 0.3 }, cr = (0..<len).map { cos(Double($0) * 0.013) * 0.2 }
        let started = conv.startTest(left: cl, right: cr)
        let x = noise(channels: 2, count: len + 4 * B, active: len + 4 * B, amp: 0.5)
        let (yl, yr) = run(conv, x)
        var mismatches = 0
        for k in 0..<len where yl[B + k] != Float(cl[k]) || yr[B + k] != Float(cr[k]) { mismatches += 1 }
        report(started && mismatches == 0 && conv.testFinished && conv.testPosition == len,
               "surround test clip plays exactly, with live input muted: \(mismatches) mismatches of \(len)")
    }

    /// Per-channel input peaks, and the format names shown in Status.
    static func testChannelActivity(routing: Routing, rate: Double) {
        let conv = Convolver(routing: routing, sampleRate: rate, blockSize: 128, gainDB: 0, bypass: false, ceiling: .infinity)
        var x = noise(channels: 8, count: 4000, active: 0, amp: 0)
        for i in 0..<4000 { x[2][i] = 0.25 * Float(sin(Double(i) * 0.05)); x[5][i] = -0.5 }   // FC and SR only
        _ = run(conv, x)
        let peaks = (0..<8).map { conv.inputPeaks[$0] }
        let ok = abs(peaks[2] - 0.25) < 1e-3 && peaks[5] == 0.5 && [0, 1, 3, 4, 6, 7].allSatisfy { peaks[$0] == 0 }
        report(ok, "per-channel input peaks: \(peaks.map { String(format: "%.2f", $0) }.joined(separator: " "))")
        let names = [
            AppState.formatName([.FL, .FR]),
            AppState.formatName([.FL, .FR, .FC, .LFE, .SL, .SR]),
            AppState.formatName([.FL, .FR, .FC, .LFE, .SL, .SR, .BL, .BR, .TFL, .TFR, .TBL, .TBR]),
            AppState.formatName([.FL, .FR, .FC, .SL, .SR]),
        ]
        report(names == ["stereo", "5.1", "7.1.4", "5.0"], "format names: \(names.joined(separator: ", "))")
    }

    /// Soloing a channel must sound exactly like feeding only that channel (once the ramp and the
    /// previous audio's reverb tail have passed), and the meters must still see every channel.
    static func testSolo(routing: Routing, rate: Double) {
        let total = 40_000, settle = 20_000, ch = 4
        let x = noise(channels: 8, count: total, active: total, amp: 0.3)
        let a = Convolver(routing: routing, sampleRate: rate, blockSize: 128, gainDB: 0, bypass: false, ceiling: .infinity)
        a.setSolo(ch)
        let (al, ar) = run(a, x)
        var only = [[Float]](repeating: [Float](repeating: 0, count: total), count: 8)
        only[ch] = x[ch]
        let b = Convolver(routing: routing, sampleRate: rate, blockSize: 128, gainDB: 0, bypass: false, ceiling: .infinity)
        let (bl, br) = run(b, only)
        var maxErr: Float = 0
        for i in settle..<total { maxErr = max(maxErr, abs(al[i] - bl[i]), abs(ar[i] - br[i])) }
        let metersSeeAll = (0..<8).allSatisfy { a.inputPeaks[$0] > 0.2 }
        report(maxErr < 1e-6 && metersSeeAll,
               String(format: "solo channel %ld = that channel alone (max difference %.1e); meters still see all 8", ch + 1, maxErr))
    }

    /// Calibration mapping, head rotation, and nearest-direction choice with hysteresis.
    static func testHeadTrackingMath() {
        func near(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 1e-9 }
        // Vision's conventions (yaw positive counterclockwise = turning left, pitch positive = nodding down),
        // relative to a forward reading that isn't zero.
        let cal = HeadCalibration(cameraID: "", forward: RawPose(yaw: 2, pitch: -3))
        let f = cal.pose(RawPose(yaw: 2, pitch: -3))
        let left = cal.pose(RawPose(yaw: 32, pitch: -3)), down = cal.pose(RawPose(yaw: 2, pitch: 17))
        let flipped = cal.pose(RawPose(yaw: 32, pitch: 17), reverseYaw: true, reversePitch: true)
        let calOK = near(f.yaw, 0) && near(f.pitch, 0) && near(left.yaw, -30) && near(left.pitch, 0)
            && near(down.pitch, -20) && near(flipped.yaw, 30) && near(flipped.pitch, 20)
        report(calOK, "head pose: offsets from straight ahead, in ASH's signs (and reversible per axis)")

        func rel(_ e: Int, _ a: Int, yaw: Double, pitch: Double) -> (Double, Double) {
            let r = HeadRotation.relative(Direction(elevation: e, azimuth: a), head: HeadPose(yaw: yaw, pitch: pitch))
            return (r.elevation, r.azimuth)
        }
        func close(_ r: (Double, Double), _ e: Double, _ a: Double) -> Bool { abs(r.0 - e) < 1e-6 && abs(r.1 - a) < 1e-6 }
        let rotOK = close(rel(0, -90, yaw: -90, pitch: 0), 0, 0)      // head 90° left: side left is straight ahead
            && close(rel(0, -30, yaw: -90, pitch: 0), 0, 60)          // … and front left is 60° to the right
            && close(rel(0, 30, yaw: 45, pitch: 0), 0, -15)
            && close(rel(45, 0, yaw: 0, pitch: 45), 0, 0)             // looking up 45°: a 45° high speaker is ahead
            && close(rel(0, 0, yaw: 0, pitch: 45), -45, 0)            // … and the centre is 45° below
        report(rotOK, "head rotation: speakers stay fixed in the room (yaw, then pitch)")

        let grid = stride(from: -180, to: 180, by: 15).map { Direction(elevation: 0, azimuth: $0) }
            + [Direction(elevation: 30, azimuth: 0)]
        let idx = DirectionIndex(grid)
        let a0 = Direction(elevation: 0, azimuth: 0), a15 = Direction(elevation: 0, azimuth: 15)
        // (elevation, azimuth, current, hysteresis, expected). Cases sit well clear of the 2° margin itself,
        // where rounding in acos decides either way.
        let cases: [(Double, Double, Direction?, Double, Direction, String)] = [
            (0, 7, nil, 2, a0, "7° → A0"),
            (0, 8, a0, 2, a0, "8° from A0: 7° vs 8°, stays"),
            (0, 9.5, a0, 2, a15, "9.5° from A0: 5.5° vs 9.5°, moves"),
            (0, 8, nil, 2, a15, "8° with no current → A15"),
            (0, 179, nil, 0, Direction(elevation: 0, azimuth: -180), "179° wraps to A-180"),
            (25, 2, a0, 2, Direction(elevation: 30, azimuth: 0), "E25 A2 → E30 A0"),
        ]
        let wrong = cases.compactMap { c -> String? in
            let got = idx.nearest(elevation: c.0, azimuth: c.1, current: c.2, hysteresis: c.3)
            return got == c.4 ? nil : "\(c.5) (got \(got.label))"
        }
        report(wrong.isEmpty, "nearest exported direction, with hysteresis at boundaries and wrap-around at ±180°"
               + (wrong.isEmpty ? "" : ": " + wrong.joined(separator: "; ")))

        // Rounding towards / away from front on a 5° grid at E0° and E30°.
        let fine = DirectionIndex(stride(from: -180, to: 180, by: 5).flatMap {
            [Direction(elevation: 0, azimuth: $0), Direction(elevation: 30, azimuth: $0)] })
        func D(_ e: Int, _ a: Int) -> Direction { Direction(elevation: e, azimuth: a) }
        let rounding: [(DirectionRounding, Double, Double, Direction?, Direction, String)] = [
            (.towardFront, 0, 4.99, nil, D(0, 0), "towards: 4.99° → A0"),
            (.towardFront, 0, 5, nil, D(0, 5), "towards: 5° → A5"),
            (.towardFront, 0, 9.99, nil, D(0, 5), "towards: 9.99° → A5"),
            (.towardFront, 0, -4.99, nil, D(0, 0), "towards: −4.99° → A0"),
            (.towardFront, 0, -7, nil, D(0, -5), "towards: −7° → A−5"),
            (.towardFront, 0, 179, nil, D(0, 175), "towards: 179° → A175 (not behind)"),
            (.towardFront, 20, 7, nil, D(0, 5), "towards: E20 A7 → E0 A5"),
            (.towardFront, 0, -29.9, D(0, -30), D(0, -30), "towards + hysteresis: −29.9° stays on A−30"),
            (.towardFront, 0, -27.5, D(0, -30), D(0, -25), "towards + hysteresis: −27.5° moves to A−25"),
            (.awayFromFront, 0, 0, nil, D(0, 0), "away: 0° → A0"),
            (.awayFromFront, 0, 0.1, nil, D(0, 5), "away: 0.1° → A5"),
            (.awayFromFront, 0, 5, nil, D(0, 5), "away: 5° → A5"),
            (.awayFromFront, 0, 5.01, nil, D(0, 10), "away: 5.01° → A10"),
            (.awayFromFront, 0, -0.1, nil, D(0, -5), "away: −0.1° → A−5"),
            (.awayFromFront, 0, 177, nil, D(0, -180), "away: 177° → behind (A−180)"),
            (.awayFromFront, 20, 7, nil, D(30, 10), "away: E20 A7 → E30 A10"),
            (.nearest, 0, 3, nil, D(0, 5), "nearest: 3° → A5"),
        ]
        let wrongRounding = rounding.compactMap { c -> String? in
            let got = fine.choose(elevation: c.1, azimuth: c.2, mode: c.0, current: c.3, hysteresis: c.3 == nil ? 0 : 2)
            return got == c.4 ? nil : "\(c.5) (got \(got.label))"
        }
        report(wrongRounding.isEmpty, "direction rounding towards and away from front (azimuth and elevation, with hysteresis)"
               + (wrongRounding.isEmpty ? "" : ": " + wrongRounding.joined(separator: "; ")))
    }

    /// Swapping BRIRs live (head tracking): during the crossfade every sample lies between the old and new
    /// outputs, and afterwards the output is exactly the input convolved with the new BRIRs.
    static func testIRSwap() {
        let B = 128, rate = 48000.0, half = 30_000, total = 2 * half
        let set = syntheticSet(speakers: [.FL, .FR, .BL, .BR], length: 3000)
        let routing = Routing.make(brir: set, roles: Routing.defaultRoles(count: 2), lfeGain: 1)   // sources FL, FR
        let conv = Convolver(routing: routing, sampleRate: rate, blockSize: B, gainDB: 0, bypass: false, ceiling: .infinity)
        let x = noise(channels: 2, count: total, active: total, amp: 0.3)
        let (l1, r1) = run(conv, x.map { Array($0[0..<half]) })
        let newIR = [set.ir(.BL)!, set.ir(.BR)!]
        let first = conv.swapIR(source: 0, left: newIR[0].left, right: newIR[0].right)
        let again = conv.swapIR(source: 0, left: newIR[0].left, right: newIR[0].right)   // still pending: refused
        let second = conv.swapIR(source: 1, left: newIR[1].left, right: newIR[1].right)
        let (l2, r2) = run(conv, x.map { Array($0[half...]) })
        let yl = l1 + l2, yr = r1 + r2

        // Direct references, delayed by B: y[n + B] = Σ_s Σ_k x_s[k] h_s[n − k].
        func ref(_ n: Int, ear o: Int, new: Bool) -> Double {
            var acc = 0.0
            for (s, src) in routing.sources.enumerated() {
                let ir = new ? newIR[s] : SpeakerIR(speaker: src.speaker, left: src.left, right: src.right)
                let h = o == 0 ? ir.left : ir.right
                let ch = src.inputs[0].channel
                for k in max(0, n - h.count + 1)...n { acc += Double(x[ch][k]) * h[n - k] }
            }
            return acc
        }
        // The swap is picked up at the first block boundary after `half`, then fades for `fadeBlocks` blocks.
        let pickup = ((half + B - 1) / B) * B
        let fadeEnd = pickup + conv.fadeBlocks * B
        var maxErr = 0.0, maxRef = 0.0, outside = 0.0
        for n in stride(from: pickup - 4 * B, to: total - B, by: 5) {
            for o in 0..<2 {
                let got = Double((o == 0 ? yl : yr)[n + B])
                let old = ref(n, ear: o, new: false), new = ref(n, ear: o, new: true)
                maxRef = max(maxRef, abs(old), abs(new))
                if n + B < pickup {
                    maxErr = max(maxErr, abs(got - old))
                } else if n + B >= fadeEnd {
                    maxErr = max(maxErr, abs(got - new))
                } else {
                    outside = max(outside, min(old, new) - got, got - max(old, new))
                }
            }
        }
        let errDB = 20 * log10(max(maxErr, 1e-300) / maxRef)
        report(first && !again && second && !conv.swapsPending && errDB < -130 && outside < 1e-6,
               String(format: "live BRIR swap: exact before and after the %ld-block crossfade (max error %.1f dB re peak); "
                      + "the fade stays between the old and new outputs (overshoot %.1e)", conv.fadeBlocks, errDB, max(0, outside)))
    }

    static func testSurroundTestRender() {
        var rng = SystemRandomNumberGenerator()
        let x = (0..<300).map { _ in Double.random(in: -1...1, using: &rng) }
        let h = (0..<200).map { _ in Double.random(in: -1...1, using: &rng) }
        let y = SurroundTest.convolve(x, h)
        var err = 0.0
        for n in 0..<(x.count + h.count - 1) {
            var ref = 0.0
            for k in max(0, n - h.count + 1)...min(n, x.count - 1) { ref += x[k] * h[n - k] }
            err = max(err, abs(ref - y[n]))
        }
        report(y.count == 499 && err < 1e-10, String(format: "offline FFT convolution matches direct: max error %.1e", err))
        let set = syntheticSet(speakers: Speaker.directional, length: 4800)
        let plan = SurroundTest.render(clip: Array(x.prefix(200)), brir: set)
        let pk = zip(plan.left, plan.right).reduce(0.0) { max($0, abs($1.0), abs($1.1)) }
        report(plan.segments.map(\.speaker) == SurroundTest.order && abs(pk - SurroundTest.peak) < 1e-12,
               "surround test plan: \(plan.segments.count) speakers in order, peak −6 dBFS")
        let url = SurroundTest.url(for: "Funk")
        if FileManager.default.fileExists(atPath: url.path) {
            let clip = try? SurroundTest.loadMono(url, rate: 48000)
            report((clip?.count ?? 0) > 1000, "stock sound Funk.aiff decodes (\(clip?.count ?? 0) frames at 48 kHz)")
        }
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
            let leftSide: Bool? = s.isLeft ? true : s.isRight ? false : nil
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
