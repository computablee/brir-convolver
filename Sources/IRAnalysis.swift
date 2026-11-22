import Accelerate
import CoreGraphics
import Foundation

/// Double-precision real FFT returning/accepting the true (unscaled) DFT, bins 0...n/2.
final class FFTD {
    let n: Int
    private let half: Int
    private let log2n: vDSP_Length
    private let setup: FFTSetupD

    init(n: Int) {
        precondition(n >= 4 && n & (n - 1) == 0)
        self.n = n
        half = n / 2
        log2n = vDSP_Length(n.trailingZeroBitCount)
        setup = vDSP_create_fftsetupD(log2n, FFTRadix(kFFTRadix2))!
    }
    deinit { vDSP_destroy_fftsetupD(setup) }

    func forward(_ x: UnsafePointer<Double>, count: Int) -> (re: [Double], im: [Double]) {
        var buf = [Double](repeating: 0, count: n)
        for i in 0..<min(count, n) { buf[i] = x[i] }
        var r = [Double](repeating: 0, count: half), im = [Double](repeating: 0, count: half)
        r.withUnsafeMutableBufferPointer { rp in
            im.withUnsafeMutableBufferPointer { ip in
                var s = DSPDoubleSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                buf.withUnsafeBufferPointer { bp in
                    bp.baseAddress!.withMemoryRebound(to: DSPDoubleComplex.self, capacity: half) {
                        vDSP_ctozD($0, 2, &s, 1, vDSP_Length(half))
                    }
                }
                vDSP_fft_zripD(setup, &s, 1, log2n, FFTDirection(kFFTDirection_Forward))
            }
        }
        var re = [Double](repeating: 0, count: half + 1), ii = [Double](repeating: 0, count: half + 1)
        re[0] = r[0] / 2; re[half] = im[0] / 2
        for k in 1..<half { re[k] = r[k] / 2; ii[k] = im[k] / 2 }
        return (re, ii)
    }

    func forward(_ x: [Double]) -> (re: [Double], im: [Double]) {
        x.withUnsafeBufferPointer { forward($0.baseAddress!, count: x.count) }
    }

    func inverse(re: [Double], im: [Double]) -> [Double] {
        var r = [Double](repeating: 0, count: half), i = [Double](repeating: 0, count: half)
        r[0] = re[0]; i[0] = re[half]
        for k in 1..<half { r[k] = re[k]; i[k] = im[k] }
        var out = [Double](repeating: 0, count: n)
        r.withUnsafeMutableBufferPointer { rp in
            i.withUnsafeMutableBufferPointer { ip in
                var s = DSPDoubleSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                vDSP_fft_zripD(setup, &s, 1, log2n, FFTDirection(kFFTDirection_Inverse))
                out.withUnsafeMutableBufferPointer { op in
                    op.baseAddress!.withMemoryRebound(to: DSPDoubleComplex.self, capacity: half) {
                        vDSP_ztocD(&s, 1, $0, 2, vDSP_Length(half))
                    }
                }
            }
        }
        let scale = 1.0 / Double(n)
        for k in 0..<n { out[k] *= scale }
        return out
    }
}

/// Everything the visualizer shows, computed once (off the main thread) from the source IR.
struct IRAnalysis {
    static let pathNames = ["L spk → L ear", "L spk → R ear", "R spk → L ear", "R spk → R ear"]
    static let shortNames = ["L→L", "L→R", "R→L", "R→R"]
    static let earNames = ["Left ear", "Right ear"]

    let sampleRate: Double
    let length: Int

    // Frequency response: 6 series (4 paths + left-ear sum + right-ear sum), cumulative power per bin.
    let binHz: Double
    private let cumPower: [[Double]]
    private let power: [[Double]]

    // Decay
    let edcTimes: [Double]          // seconds
    let edcDB: [[Double]]           // 4 paths, Schroeder backward-integrated, dB re total
    let envTimes: [Double]
    let envDB: [[Double]]           // 4 paths, 1 ms peak envelope, dB re global peak
    let bandCenters: [Double]
    let bandRT60: [Double?]         // seconds, summed energy of all paths
    let bandMethod: [String]

    // Headline numbers
    let rt60Mid: Double?            // mean of 500 Hz & 1 kHz bands
    let edt: Double?
    let drr: Double
    let c50: Double
    let ildDirect: Double
    let itdMicros: Double

    // Spectrograms
    let specFrames: Int
    let specRows: Int
    let specHop: Int
    let specFMin: Double
    let specFMax: Double
    let specDB: [[Float]]           // 4 × (rows*frames), row 0 = highest frequency; dB re global max
    let specImages: [CGImage]
    static let specRange: Float = 96

    // Impulse (first 100 ms)
    let impulse: [[Double]]
    let impulsePeak: Double

    // MARK: Frequency response query

    /// Magnitude (dB) of `series` at `points` log-spaced frequencies with fractional-octave smoothing
    /// (power average over ±width/2 octaves). width 0 → interpolated raw bins.
    func curve(series: Int, widthOct: Double, fMin: Double = 20, fMax: Double = 20000, points: Int = 720) -> [Double] {
        let c = cumPower[series], p = power[series]
        let nb = p.count
        func cum(_ x: Double) -> Double {
            let xc = min(max(x, 0), Double(nb - 1))
            let k = Int(xc)
            return c[k] + (xc - Double(k)) * p[k]
        }
        func interp(_ x: Double) -> Double {
            let xc = min(max(x, 0), Double(nb - 1))
            let k = min(Int(xc), nb - 2)
            let t = xc - Double(k)
            return p[k] * (1 - t) + p[k + 1] * t
        }
        var out = [Double](repeating: 0, count: points)
        let ratio = log(fMax / fMin)
        for i in 0..<points {
            let f = fMin * exp(ratio * Double(i) / Double(points - 1))
            var pw: Double
            if widthOct > 0 {
                let k1 = f * pow(2, -widthOct / 2) / binHz, k2 = f * pow(2, widthOct / 2) / binHz
                pw = (k2 - k1) >= 1 ? (cum(k2 + 0.5) - cum(k1 + 0.5)) / (k2 - k1) : interp(f / binHz)
            } else {
                pw = interp(f / binHz)
            }
            out[i] = 10 * log10(max(pw, 1e-30))
        }
        return out
    }

    // MARK: Compute

    static func compute(ir: TrueStereoIR) -> IRAnalysis {
        let sr = ir.sampleRate
        let L = max(ir.length, 1)
        let paths = ir.paths.map { $0 + [Double](repeating: 0, count: L - $0.count) }

        // --- Frequency response ---
        var n = 1 << 16
        while n < 2 * L { n <<= 1 }
        let fft = FFTD(n: n)
        let half = n / 2
        let specs = paths.map { fft.forward($0) }
        func sum(_ a: (re: [Double], im: [Double]), _ b: (re: [Double], im: [Double])) -> (re: [Double], im: [Double]) {
            (zip(a.re, b.re).map(+), zip(a.im, b.im).map(+))
        }
        let all = specs + [sum(specs[0], specs[2]), sum(specs[1], specs[3])]
        var power: [[Double]] = []
        var cumPower: [[Double]] = []
        for s in all {
            var p = [Double](repeating: 0, count: half + 1)
            for k in 0...half { p[k] = s.re[k] * s.re[k] + s.im[k] * s.im[k] }
            var c = [Double](repeating: 0, count: half + 2)
            for k in 0...half { c[k + 1] = c[k] + p[k] }
            power.append(p); cumPower.append(c)
        }

        // --- Decay (broadband) ---
        func schroederDB(_ e: [Double]) -> [Double] {
            var acc = 0.0
            var back = [Double](repeating: 0, count: e.count)
            for i in stride(from: e.count - 1, through: 0, by: -1) { acc += e[i]; back[i] = acc }
            let total = max(back.first ?? 0, 1e-30)
            return back.map { 10 * log10(max($0 / total, 1e-30)) }
        }
        let fullEDC = paths.map { schroederDB($0.map { $0 * $0 }) }
        let edcStep = max(1, L / 1200)
        let edcIdx = Array(stride(from: 0, to: L, by: edcStep))
        let edcTimes = edcIdx.map { Double($0) / sr }
        let edcDB = fullEDC.map { e in edcIdx.map { e[$0] } }

        let globalPeak = max(paths.flatMap { $0 }.map(abs).max() ?? 1, 1e-12)
        let envWin = max(1, Int(sr / 1000))
        var envDB: [[Double]] = []
        var envTimes: [Double] = []
        for (pi, p) in paths.enumerated() {
            var e: [Double] = []
            var i = 0
            while i < L {
                let m = p[i..<min(L, i + envWin)].map(abs).max() ?? 0
                e.append(20 * log10(max(m / globalPeak, 1e-12)))
                if pi == 0 { envTimes.append(Double(i) / sr) }
                i += envWin
            }
            envDB.append(e)
        }

        func fit(_ edc: [Double], from a: Double, to b: Double) -> Double? {
            guard let i0 = edc.firstIndex(where: { $0 <= a }), let i1 = edc.firstIndex(where: { $0 <= b }), i1 > i0 + 8 else { return nil }
            var sx = 0.0, sy = 0.0, sxx = 0.0, sxy = 0.0
            let cnt = Double(i1 - i0 + 1)
            for i in i0...i1 {
                let x = Double(i) / sr, y = edc[i]
                sx += x; sy += y; sxx += x * x; sxy += x * y
            }
            let slope = (cnt * sxy - sx * sy) / (cnt * sxx - sx * sx)
            return slope < 0 ? -60 / slope : nil
        }
        // Broadband EDT from summed energy of all paths
        var sumE = [Double](repeating: 0, count: L)
        for p in paths { for i in 0..<L { sumE[i] += p[i] * p[i] } }
        let edcSum = schroederDB(sumE)
        let edt = fit(edcSum, from: -0.0001, to: -10)

        // --- Octave-band RT60 (T20, falling back to T10) on summed band energy ---
        let centers: [Double] = [63, 125, 250, 500, 1000, 2000, 4000, 8000, 16000].filter { $0 * 1.5 < sr / 2 }
        var bandRT: [Double?] = []
        var bandMethod: [String] = []
        for fc in centers {
            let lo = fc / 2.0.squareRoot(), hi = fc * 2.0.squareRoot()
            let taper = pow(2, 1.0 / 6)
            var w = [Double](repeating: 0, count: half + 1)
            for k in 0...half {
                let f = Double(k) * sr / Double(n)
                if f >= lo && f <= hi { w[k] = 1 }
                else if f > lo / taper && f < lo { w[k] = 0.5 - 0.5 * cos(Double.pi * log(f * taper / lo) / log(taper)) }
                else if f > hi && f < hi * taper { w[k] = 0.5 + 0.5 * cos(Double.pi * log(f / hi) / log(taper)) }
            }
            var e = [Double](repeating: 0, count: L)
            for s in specs {
                let y = fft.inverse(re: zip(s.re, w).map(*), im: zip(s.im, w).map(*))
                for i in 0..<L { e[i] += y[i] * y[i] }
            }
            let edc = schroederDB(e)
            if let t = fit(edc, from: -5, to: -25) { bandRT.append(t); bandMethod.append("T20") }
            else if let t = fit(edc, from: -5, to: -15) { bandRT.append(t); bandMethod.append("T10") }
            else { bandRT.append(nil); bandMethod.append("—") }
        }
        let mids = zip(centers, bandRT).filter { $0.0 == 500 || $0.0 == 1000 }.compactMap { $0.1 }
        let rt60Mid = mids.isEmpty ? nil : mids.reduce(0, +) / Double(mids.count)

        // --- Direct sound metrics (ipsilateral paths) ---
        func onset(_ p: [Double]) -> Int {
            let pk = p.map(abs).max() ?? 0
            return p.firstIndex { abs($0) >= 0.1 * pk } ?? 0
        }
        let ms = sr / 1000
        var drrs: [Double] = [], c50s: [Double] = [], ilds: [Double] = []
        for (ipsi, contra) in [(0, 1), (3, 2)] {
            let p = paths[ipsi], q = paths[contra]
            let o = onset(p)
            let d0 = max(0, o - Int(0.5 * ms)), d1 = min(L, o + Int(2.5 * ms))
            let eDir = p[d0..<d1].reduce(0) { $0 + $1 * $1 }
            let eTot = p.reduce(0) { $0 + $1 * $1 }
            drrs.append(10 * log10(eDir / max(eTot - eDir, 1e-30)))
            let c = min(L, o + Int(50 * ms))
            let eEarly = p[d0..<c].reduce(0) { $0 + $1 * $1 }
            c50s.append(10 * log10(eEarly / max(eTot - eEarly, 1e-30)))
            let eqDir = q[d0..<d1].reduce(0) { $0 + $1 * $1 }
            ilds.append(10 * log10(eDir / max(eqDir, 1e-30)))
        }
        // ITD: cross-correlation of <1.5 kHz content within the first 5 ms, lag search ±1 ms.
        func lowpass(_ s: (re: [Double], im: [Double])) -> [Double] {
            var re = s.re, im = s.im
            for k in 0...half {
                let f = Double(k) * sr / Double(n)
                let g = f <= 1200 ? 1 : f >= 1800 ? 0 : 0.5 + 0.5 * cos(Double.pi * (f - 1200) / 600)
                re[k] *= g; im[k] *= g
            }
            return Array(fft.inverse(re: re, im: im).prefix(L))
        }
        let lp = specs.map(lowpass)
        var itds: [Double] = []
        for (ipsi, contra) in [(0, 1), (3, 2)] {
            let o = onset(paths[ipsi])
            let a0 = max(0, o - Int(1 * ms)), a1 = min(L, o + Int(5 * ms))
            let maxLag = Int(1.2 * ms)
            var best = 0, bestV = -Double.infinity
            for lag in -maxLag...maxLag {
                var acc = 0.0
                for i in a0..<a1 {
                    let j = i + lag
                    if j >= 0 && j < L { acc += lp[ipsi][i] * lp[contra][j] }
                }
                if acc > bestV { bestV = acc; best = lag }
            }
            itds.append(Double(best) / sr * 1e6)
        }

        // --- Spectrograms ---
        let W = 1024, hop = 64, nfft = 4096
        let sfft = FFTD(n: nfft)
        let window = (0..<W).map { 0.5 - 0.5 * cos(2 * Double.pi * Double($0) / Double(W)) }
        let frames = (L + hop - 1) / hop
        let rows = 256
        let fMin = 20.0, fMax = min(20000.0, sr / 2)
        let sBin = sr / Double(nfft)
        let rowEdges = (0...rows).map { fMin * pow(fMax / fMin, Double($0) / Double(rows)) }
        var specDB = [[Float]](repeating: [Float](repeating: -300, count: rows * frames), count: 4)
        var gmax: Float = -300
        var frame = [Double](repeating: 0, count: nfft)
        for pi in 0..<4 {
            let p = paths[pi]
            for f in 0..<frames {
                let c = f * hop
                for i in 0..<nfft { frame[i] = 0 }
                for i in 0..<W {
                    let t = c - W / 2 + i
                    if t >= 0 && t < L { frame[i] = p[t] * window[i] }
                }
                let s = sfft.forward(frame)
                let nb = nfft / 2 + 1
                var pw = [Double](repeating: 0, count: nb)
                for k in 0..<nb { pw[k] = s.re[k] * s.re[k] + s.im[k] * s.im[k] }
                for r in 0..<rows {
                    let k1 = rowEdges[r] / sBin, k2 = rowEdges[r + 1] / sBin
                    var v: Double
                    if k2 - k1 < 1 {
                        let x = (k1 + k2) / 2
                        let k = min(Int(x), nb - 2), t = x - Double(k)
                        v = pw[k] * (1 - t) + pw[k + 1] * t
                    } else {
                        var acc = 0.0, cnt = 0.0
                        for k in Int(k1.rounded(.up))...min(nb - 1, Int(k2)) { acc += pw[k]; cnt += 1 }
                        v = cnt > 0 ? acc / cnt : 0
                    }
                    let db = Float(10 * log10(max(v, 1e-30)))
                    specDB[pi][(rows - 1 - r) * frames + f] = db
                    gmax = max(gmax, db)
                }
            }
        }
        for pi in 0..<4 { for i in 0..<specDB[pi].count { specDB[pi][i] -= gmax } }
        let images = specDB.compactMap { makeImage($0, width: frames, height: rows) }

        let impLen = min(L, Int(0.1 * sr))
        return IRAnalysis(
            sampleRate: sr, length: L, binHz: sr / Double(n), cumPower: cumPower, power: power,
            edcTimes: edcTimes, edcDB: edcDB, envTimes: envTimes, envDB: envDB,
            bandCenters: centers, bandRT60: bandRT, bandMethod: bandMethod,
            rt60Mid: rt60Mid, edt: edt,
            drr: drrs.reduce(0, +) / 2, c50: c50s.reduce(0, +) / 2, ildDirect: ilds.reduce(0, +) / 2,
            itdMicros: itds.map(abs).reduce(0, +) / 2,
            specFrames: frames, specRows: rows, specHop: hop, specFMin: fMin, specFMax: fMax,
            specDB: specDB, specImages: images,
            impulse: paths.map { Array($0.prefix(impLen)) }, impulsePeak: globalPeak)
    }

    // MARK: Spectrogram image (single-hue sequential ramp: dark → blue → pale)

    static let rampStops: [(Double, (Double, Double, Double))] = [
        (0.00, (0x1a, 0x1a, 0x19)),
        (0.18, (0x0d, 0x36, 0x6b)),
        (0.36, (0x18, 0x4f, 0x95)),
        (0.52, (0x25, 0x6a, 0xbf)),
        (0.66, (0x39, 0x87, 0xe5)),
        (0.78, (0x6d, 0xa7, 0xec)),
        (0.88, (0x9e, 0xc5, 0xf4)),
        (0.95, (0xcd, 0xe2, 0xfb)),
        (1.00, (0xf4, 0xf8, 0xfe)),
    ]

    static func ramp(_ t: Double) -> (UInt8, UInt8, UInt8) {
        let x = min(max(t, 0), 1)
        var i = 0
        while i < rampStops.count - 2 && x > rampStops[i + 1].0 { i += 1 }
        let (t0, c0) = rampStops[i], (t1, c1) = rampStops[i + 1]
        let u = (x - t0) / (t1 - t0)
        func mix(_ a: Double, _ b: Double) -> UInt8 { UInt8(max(0, min(255, (a + (b - a) * u).rounded()))) }
        return (mix(c0.0, c1.0), mix(c0.1, c1.1), mix(c0.2, c1.2))
    }

    static func makeImage(_ db: [Float], width: Int, height: Int) -> CGImage? {
        var px = [UInt8](repeating: 255, count: width * height * 4)
        for i in 0..<(width * height) {
            let t = Double((db[i] + specRange) / specRange)
            let (r, g, b) = ramp(t)
            px[i * 4] = r; px[i * 4 + 1] = g; px[i * 4 + 2] = b; px[i * 4 + 3] = 255
        }
        guard let provider = CGDataProvider(data: Data(px) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}
