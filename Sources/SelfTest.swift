import Foundation

/// `BRIRConvolver --selftest [file.wav]` — verifies the DSP against a direct double-precision
/// time-domain convolution, checks bypass is bit-exact, and benchmarks realtime headroom.
/// Without a file it uses a synthetic true-stereo BRIR, so no impulse response needs to ship with the repo.
enum SelfTest {
    static func run(wavPath: String) -> Bool {
        var ok = true
        let ir: TrueStereoIR
        if wavPath.isEmpty {
            ir = syntheticIR()
            print("Using synthetic true-stereo BRIR: 4 paths, 48000 Hz, \(ir.length) frames (pass a WAV path to test a real one)")
        } else {
            do {
                let wav = try WAVFile(url: URL(fileURLWithPath: wavPath))
                print("Loaded \(wavPath): \(wav.channelCount) ch, \(Int(wav.sampleRate)) Hz, \(wav.bitsPerSample)-bit, \(wav.frameCount) frames")
                ir = try TrueStereoIR(wav: wav, order: .inputMajor)
            } catch {
                print("FAIL: \(error.localizedDescription)"); return false
            }
        }
        for (k, n) in ["LL", "LR", "RL", "RR"].enumerated() {
            let e = ir.paths[k].reduce(0) { $0 + $1 * $1 }
            print(String(format: "  %@ energy %.4f (%.2f dB)", n, e, 10 * log10(e)))
        }
        print(String(format: "Peak-safe preamp: %.2f dB", ir.peakSafeGainDB()))

        var rng = SystemRandomNumberGenerator()
        // ---------- 1. Accuracy ----------
        for B in [64, 256, 1024] {
            let excite = 4096
            let total = excite + ir.length + 2 * B
            var xl = [Float](repeating: 0, count: total), xr = xl
            for i in 0..<excite { xl[i] = Float.random(in: -0.5...0.5, using: &rng); xr[i] = Float.random(in: -0.5...0.5, using: &rng) }
            let conv = StereoConvolver(ir: ir, blockSize: B, gainDB: 0, bypass: false, limiter: false)
            var yl = [Float](repeating: 0, count: total), yr = yl
            var done = 0
            while done < total {   // irregular callback sizes
                let n = min(total - done, Int.random(in: 1...700, using: &rng))
                xl.withUnsafeBufferPointer { a in xr.withUnsafeBufferPointer { b in
                    yl.withUnsafeMutableBufferPointer { c in yr.withUnsafeMutableBufferPointer { d in
                        conv.process(inL: a.baseAddress! + done, inR: b.baseAddress! + done, inStride: 1,
                                     outL: c.baseAddress! + done, outR: d.baseAddress! + done, outStride: 1, frames: n)
                    }}
                }}
                done += n
            }
            // Reference: y_o[n] = sum_c sum_k x_c[k] h_{c,o}[n-k], delayed by B.
            var maxErr = 0.0, maxRef = 0.0
            let checkCount = min(total - B, excite + ir.length - 1)
            for n in stride(from: 0, to: checkCount, by: 7) {
                for o in 0..<2 {
                    var ref = 0.0
                    for c in 0..<2 {
                        let h = ir.paths[c * 2 + o]
                        let x = c == 0 ? xl : xr
                        let kLo = max(0, n - h.count + 1), kHi = min(n, excite - 1)
                        if kLo <= kHi { for k in kLo...kHi { ref += Double(x[k]) * h[n - k] } }
                    }
                    let got = Double((o == 0 ? yl : yr)[n + B])
                    maxErr = max(maxErr, abs(got - ref))
                    maxRef = max(maxRef, abs(ref))
                }
            }
            let errDB = 20 * log10(maxErr / maxRef)
            let pass = errDB < -130
            ok = ok && pass
            print(String(format: "[%@] accuracy B=%4d: max error %.3e (%.1f dB re peak; Float32 output floor ≈ -144 dB)",
                         pass ? "PASS" : "FAIL", B, maxErr, errDB))
        }

        // ---------- 2. Bypass is bit-exact ----------
        do {
            let B = 256, total = 50_000
            let conv = StereoConvolver(ir: ir, blockSize: B, gainDB: -7.3, bypass: true, limiter: true)
            var xl = [Float](repeating: 0, count: total), xr = xl
            for i in 0..<total { xl[i] = Float.random(in: -1...1, using: &rng); xr[i] = Float.random(in: -1...1, using: &rng) }
            var yl = [Float](repeating: 0, count: total), yr = yl
            conv.process(inL: xl, inR: xr, inStride: 1, outL: &yl, outR: &yr, outStride: 1, frames: total)
            var mismatches = 0
            for i in 0..<(total - B) where yl[i + B].bitPattern != xl[i].bitPattern || yr[i + B].bitPattern != xr[i].bitPattern {
                mismatches += 1
            }
            ok = ok && mismatches == 0
            print("[\(mismatches == 0 ? "PASS" : "FAIL")] bypass bit-exact: \(mismatches) mismatching frames of \(total - B)")
        }

        // ---------- 2b. A/B hold = dry × preamp, exactly ----------
        do {
            let B = 256, total = 60_000, gainDB = -7.3
            let conv = StereoConvolver(ir: ir, blockSize: B, gainDB: gainDB, bypass: false, limiter: false)
            conv.setABHold(true)
            let g = pow(10, gainDB / 20)
            var xl = [Float](repeating: 0, count: total), xr = xl
            for i in 0..<total { xl[i] = Float.random(in: -1...1, using: &rng); xr[i] = Float.random(in: -1...1, using: &rng) }
            var yl = [Float](repeating: 0, count: total), yr = yl
            conv.process(inL: xl, inR: xr, inStride: 1, outL: &yl, outR: &yr, outStride: 1, frames: total)
            var mismatches = 0
            let settle = 20_000   // crossfade + gain smoothing fully settled
            for i in settle..<(total - B) where yl[i + B] != Float(Double(xl[i]) * g) || yr[i + B] != Float(Double(xr[i]) * g) {
                mismatches += 1
            }
            ok = ok && mismatches == 0
            print("[\(mismatches == 0 ? "PASS" : "FAIL")] A/B hold = dry × preamp (\(gainDB) dB): \(mismatches) mismatching frames of \(total - B - settle)")
        }

        // ---------- 3. Performance ----------
        let rate = ir.sampleRate
        for B in [64, 128, 256, 512] {
            let conv = StereoConvolver(ir: ir, blockSize: B, gainDB: -6, bypass: false, limiter: false)
            let cb = 512
            let seconds = 20.0
            let iters = Int(seconds * rate) / cb
            var inBuf = [Float](repeating: 0, count: cb * 2)
            for i in 0..<inBuf.count { inBuf[i] = Float.random(in: -0.5...0.5, using: &rng) }
            var outBuf = [Float](repeating: 0, count: cb * 2)
            let t0 = DispatchTime.now().uptimeNanoseconds
            inBuf.withUnsafeBufferPointer { ip in outBuf.withUnsafeMutableBufferPointer { op in
                for _ in 0..<iters {
                    conv.process(inL: ip.baseAddress!, inR: ip.baseAddress! + 1, inStride: 2,
                                 outL: op.baseAddress!, outR: op.baseAddress! + 1, outStride: 2, frames: cb)
                }
            }}
            let dt = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e9
            let audio = Double(iters * cb) / rate
            print(String(format: "[INFO] B=%4d (%3d partitions, +%.1f ms): %.0fx realtime → %.2f%% of one core",
                         B, conv.partitions, Double(B) / rate * 1000, audio / dt, dt / audio * 100))
        }
        // ---------- 4. Analysis ----------
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
        do {
            let f = 1000.0, h = ir.paths[0]
            var re = 0.0, im = 0.0
            for (i, v) in h.enumerated() { let w = -2 * Double.pi * f * Double(i) / ir.sampleRate; re += v * cos(w); im += v * sin(w) }
            let direct = 10 * log10(re * re + im * im)
            let fromCurve = a.curve(series: 0, widthOct: 0, fMin: 999.999, fMax: 1000.001, points: 3)[1]
            let pass = abs(direct - fromCurve) < 0.5
            ok = ok && pass
            print(String(format: "[%@] response cross-check @1 kHz: DFT %.3f dB vs analysis %.3f dB", pass ? "PASS" : "FAIL", direct, fromCurve))
        }
        print("  spectrogram: \(a.specFrames)×\(a.specRows), images \(a.specImages.count)")
        print(ok ? "ALL TESTS PASSED" : "SOME TESTS FAILED")
        return ok
    }

    /// Deterministic stand-in BRIR: a direct impulse per path (opposite ear ~0.27 ms later and ~9 dB lower),
    /// followed by exponentially decaying noise (RT60 ≈ 300 ms), 0.75 s at 48 kHz.
    static func syntheticIR() -> TrueStereoIR {
        let sr = 48000.0, n = 36000
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        func noise() -> Double {   // xorshift64*, uniform in [-1, 1)
            state ^= state >> 12; state ^= state << 25; state ^= state >> 27
            return Double((state &* 0x2545_F491_4F6C_DD1D) >> 11) / Double(1 << 52) - 1
        }
        let decay = log(1000.0) / (0.3 * sr)   // −60 dB in 300 ms
        var paths: [[Double]] = []
        for k in 0..<4 {
            let ipsi = k == 0 || k == 3
            var h = [Double](repeating: 0, count: n)
            let onset = ipsi ? 48 : 61
            h[onset] = ipsi ? 0.5 : 0.18
            for i in (onset + 96)..<n { h[i] = 0.04 * noise() * exp(-decay * Double(i - onset)) }
            paths.append(h)
        }
        return TrueStereoIR(paths: paths, sampleRate: sr)
    }
}
