import Accelerate
import Foundation

/// How the four channels of a true-stereo BRIR file are ordered.
enum ChannelOrder: String, CaseIterable, Identifiable {
    /// Equalizer APO / ASH-Toolset convention: L→L, L→R, R→L, R→R (input-major).
    case inputMajor = "LL LR RL RR"
    /// Output-major alternative: L→L, R→L, L→R, R→R.
    case outputMajor = "LL RL LR RR"
    var id: String { rawValue }
    var label: String {
        switch self {
        case .inputMajor: return "L→L, L→R, R→L, R→R (EAPO / ASH default)"
        case .outputMajor: return "L→L, R→L, L→R, R→R"
        }
    }
}

/// Four impulse responses indexed by `input * 2 + output` (0 = LL, 1 = LR, 2 = RL, 3 = RR).
struct TrueStereoIR {
    var paths: [[Double]]
    var sampleRate: Double
    var length: Int { paths.map(\.count).max() ?? 0 }

    init(paths: [[Double]], sampleRate: Double) {
        self.paths = paths
        self.sampleRate = sampleRate
    }

    init(wav: WAVFile, order: ChannelOrder) throws {
        let c = wav.channels
        switch c.count {
        case 4:
            switch order {
            case .inputMajor: paths = [c[0], c[1], c[2], c[3]]
            case .outputMajor: paths = [c[0], c[2], c[1], c[3]]
            }
        case 2:
            // Symmetric pair: ch1 = same-side ear, ch2 = opposite-side ear.
            paths = [c[0], c[1], c[1], c[0]]
        default:
            throw NSError(domain: "BRIR", code: 1, userInfo: [NSLocalizedDescriptionKey:
                "Expected a 4-channel true-stereo BRIR (or a 2-channel symmetric pair); file has \(c.count) channels."])
        }
        sampleRate = wav.sampleRate
    }

    func resampled(to rate: Double) -> TrueStereoIR {
        if rate == sampleRate { return self }
        return TrueStereoIR(paths: paths.map { Resampler.resample($0, from: sampleRate, to: rate) }, sampleRate: rate)
    }

    /// Gain (dB) that brings the worst-case magnitude response of either ear down to exactly 0 dB:
    /// max over f of max(|H_LL|+|H_RL|, |H_LR|+|H_RR|). Computed in double precision at high resolution.
    func peakSafeGainDB() -> Double {
        let L = max(length, 1)
        var n = 1
        while n < L * 8 { n <<= 1 }
        n = min(max(n, 1 << 14), 1 << 21)
        let log2n = vDSP_Length(n.trailingZeroBitCount)
        guard let setup = vDSP_create_fftsetupD(log2n, FFTRadix(kFFTRadix2)) else { return 0 }
        defer { vDSP_destroy_fftsetupD(setup) }
        let half = n / 2
        var mags = [[Double]](repeating: [Double](repeating: 0, count: half + 1), count: 4)
        var time = [Double](repeating: 0, count: n)
        var re = [Double](repeating: 0, count: half)
        var im = [Double](repeating: 0, count: half)
        for k in 0..<4 {
            for i in 0..<n { time[i] = i < paths[k].count ? paths[k][i] : 0 }
            re.withUnsafeMutableBufferPointer { rp in
                im.withUnsafeMutableBufferPointer { ip in
                    var split = DSPDoubleSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                    time.withUnsafeBufferPointer { tp in
                        tp.baseAddress!.withMemoryRebound(to: DSPDoubleComplex.self, capacity: half) {
                            vDSP_ctozD($0, 2, &split, 1, vDSP_Length(half))
                        }
                    }
                    vDSP_fft_zripD(setup, &split, 1, log2n, FFTDirection(kFFTDirection_Forward))
                }
            }
            mags[k][0] = abs(re[0]) / 2
            mags[k][half] = abs(im[0]) / 2
            for b in 1..<half { mags[k][b] = (re[b] * re[b] + im[b] * im[b]).squareRoot() / 2 }
        }
        var peak = 0.0
        for b in 0...half {
            peak = max(peak, mags[0][b] + mags[2][b], mags[1][b] + mags[3][b])
        }
        return peak > 0 ? -20 * log10(peak) : 0
    }
}

/// Uniformly-partitioned overlap-save true-stereo convolver, double precision throughout.
/// Also handles the dry path (bit-exact, latency-matched), preamp, bypass crossfade, optional
/// safety limiter, metering. The render path performs no allocation, locking or Objective-C messaging.
final class StereoConvolver {
    let blockSize: Int
    let partitions: Int
    let sampleRate: Double

    private let N: Int
    private let half: Int
    private let log2n: vDSP_Length
    private let setup: FFTSetupD

    private let hRe: UnsafeMutablePointer<Double>   // [4][P][half]
    private let hIm: UnsafeMutablePointer<Double>
    private let xRe: UnsafeMutablePointer<Double>   // [2][P][half] frequency-domain delay line
    private let xIm: UnsafeMutablePointer<Double>
    private let accRe: UnsafeMutablePointer<Double>
    private let accIm: UnsafeMutablePointer<Double>
    private let time: UnsafeMutablePointer<Double>  // N
    private let inL: UnsafeMutablePointer<Double>   // 2B sliding window; first half doubles as the dry delay line
    private let inR: UnsafeMutablePointer<Double>
    private let outL: UnsafeMutablePointer<Double>  // B wet output of the previous block
    private let outR: UnsafeMutablePointer<Double>
    private var fdlPos = 0
    private var pos = 0

    // Smoothed state
    private var gain: Double
    private var mix: Double
    private var dryGain: Double = 1   // 1 = untouched dry (bit-exact bypass); preamp gain while A/B is held

    // Shared parameters/meters (written by UI or audio thread; plain aligned words).
    let params = UnsafeMutablePointer<Double>.allocate(capacity: Param.count)
    enum Param {
        static let gain = 0, mixTarget = 1, limiter = 2, peakInL = 3, peakInR = 4, peakOutL = 5, peakOutR = 6, clips = 7
        /// A/B hold: crossfade to the dry signal *with the preamp applied*, for level-matched comparison.
        static let abHold = 8
        static let count = 9
    }

    init(ir: TrueStereoIR, blockSize: Int, gainDB: Double, bypass: Bool, limiter: Bool) {
        precondition(blockSize > 0 && blockSize & (blockSize - 1) == 0)
        self.blockSize = blockSize
        self.sampleRate = ir.sampleRate
        let B = blockSize
        let fftN = 2 * B
        let H = B
        let lg = vDSP_Length(fftN.trailingZeroBitCount)
        N = fftN
        half = H
        log2n = lg
        setup = vDSP_create_fftsetupD(lg, FFTRadix(kFFTRadix2))!
        let P = max(1, (ir.length + B - 1) / B)
        partitions = P
        let g = pow(10, gainDB / 20)
        gain = g
        mix = bypass ? 0 : 1

        func alloc(_ n: Int) -> UnsafeMutablePointer<Double> {
            let p = UnsafeMutablePointer<Double>.allocate(capacity: n)
            p.initialize(repeating: 0, count: n)
            return p
        }
        hRe = alloc(4 * P * H); hIm = alloc(4 * P * H)
        xRe = alloc(2 * P * H); xIm = alloc(2 * P * H)
        accRe = alloc(H); accIm = alloc(H)
        time = alloc(fftN)
        inL = alloc(fftN); inR = alloc(fftN)
        outL = alloc(B); outR = alloc(B)

        // vDSP's packed real FFT: forward scales by 2, inverse by N → product needs 1/(4N).
        let scale = 1.0 / (4.0 * Double(fftN))
        for k in 0..<4 {
            let h = ir.paths[k]
            for p in 0..<P {
                for i in 0..<fftN { time[i] = 0 }
                let start = p * B
                let end = min(start + B, h.count)
                if start < end { for i in start..<end { time[i - start] = h[i] * scale } }
                forward(time, re: hRe + (k * P + p) * H, im: hIm + (k * P + p) * H)
            }
        }

        params.initialize(repeating: 0, count: Param.count)
        params[Param.gain] = g
        params[Param.mixTarget] = mix
        params[Param.limiter] = limiter ? 1 : 0
    }

    deinit {
        vDSP_destroy_fftsetupD(setup)
        for p in [hRe, hIm, xRe, xIm, accRe, accIm, time, inL, inR, outL, outR, params] { p.deallocate() }
    }

    var latencyFrames: Int { blockSize }

    func setGainDB(_ db: Double) { params[Param.gain] = pow(10, db / 20) }
    func setBypass(_ b: Bool) { params[Param.mixTarget] = b ? 0 : 1 }
    func setLimiter(_ on: Bool) { params[Param.limiter] = on ? 1 : 0 }
    func setABHold(_ held: Bool) { params[Param.abHold] = held ? 1 : 0 }

    @inline(__always)
    private func forward(_ src: UnsafePointer<Double>, re: UnsafeMutablePointer<Double>, im: UnsafeMutablePointer<Double>) {
        var split = DSPDoubleSplitComplex(realp: re, imagp: im)
        src.withMemoryRebound(to: DSPDoubleComplex.self, capacity: half) {
            vDSP_ctozD($0, 2, &split, 1, vDSP_Length(half))
        }
        vDSP_fft_zripD(setup, &split, 1, log2n, FFTDirection(kFFTDirection_Forward))
    }

    private func processBlock() {
        let P = partitions, H = half, B = blockSize
        forward(inL, re: xRe + fdlPos * H, im: xIm + fdlPos * H)
        forward(inR, re: xRe + (P + fdlPos) * H, im: xIm + (P + fdlPos) * H)

        for o in 0..<2 {
            vDSP_vclrD(accRe, 1, vDSP_Length(H))
            vDSP_vclrD(accIm, 1, vDSP_Length(H))
            var acc = DSPDoubleSplitComplex(realp: accRe, imagp: accIm)
            var accOut = acc
            var dc = 0.0, ny = 0.0
            var slot = fdlPos
            for p in 0..<P {
                for c in 0..<2 {
                    let xr = xRe + (c * P + slot) * H, xi = xIm + (c * P + slot) * H
                    let k = c * 2 + o
                    let hr = hRe + (k * P + p) * H, hi = hIm + (k * P + p) * H
                    // Packed bin 0 holds DC (real) and Nyquist (imag) — both purely real products.
                    dc += xr[0] * hr[0]
                    ny += xi[0] * hi[0]
                    var xs = DSPDoubleSplitComplex(realp: xr, imagp: xi)
                    var hs = DSPDoubleSplitComplex(realp: hr, imagp: hi)
                    vDSP_zvmaD(&xs, 1, &hs, 1, &acc, 1, &accOut, 1, vDSP_Length(H))
                }
                slot = slot == 0 ? P - 1 : slot - 1
            }
            accRe[0] = dc
            accIm[0] = ny
            vDSP_fft_zripD(setup, &acc, 1, log2n, FFTDirection(kFFTDirection_Inverse))
            time.withMemoryRebound(to: DSPDoubleComplex.self, capacity: H) {
                vDSP_ztocD(&acc, 1, $0, 2, vDSP_Length(H))
            }
            // Overlap-save: the last B samples are the valid linear-convolution output.
            (o == 0 ? outL : outR).update(from: time + B, count: B)
        }
        inL.update(from: inL + B, count: B)
        inR.update(from: inR + B, count: B)
        fdlPos = fdlPos + 1 == P ? 0 : fdlPos + 1
    }

    /// Process `frames` stereo frames. Input/output are strided Float32 (interleaved or not).
    /// Safe to call with any frame count; latency is exactly `blockSize` frames for both wet and dry paths.
    func process(inL srcL: UnsafePointer<Float>, inR srcR: UnsafePointer<Float>, inStride: Int,
                 outL dstL: UnsafeMutablePointer<Float>, outR dstR: UnsafeMutablePointer<Float>, outStride: Int,
                 frames: Int) {
        let B = blockSize
        let gTarget = params[Param.gain]
        let abHeld = params[Param.abHold] != 0
        let mTarget = abHeld ? 0 : params[Param.mixTarget]
        let dgTarget = abHeld ? gTarget : 1.0
        let limit = params[Param.limiter] != 0
        let gCoef = 1.0 - exp(-1.0 / (0.010 * sampleRate))  // 10 ms one-pole gain smoothing
        let mStep = 1.0 / (0.030 * sampleRate)              // 30 ms linear crossfade
        var pInL = params[Param.peakInL], pInR = params[Param.peakInR]
        var pOutL = params[Param.peakOutL], pOutR = params[Param.peakOutR]
        var clips = params[Param.clips]
        var g = gain, m = mix, dg = dryGain

        var i = 0
        while i < frames {
            let n = min(frames - i, B - pos)
            for j in 0..<n {
                let f = i + j
                let xl = Double(srcL[f * inStride]), xr = Double(srcR[f * inStride])
                let dl = inL[pos + j], dr = inR[pos + j]          // dry, delayed exactly B frames
                inL[B + pos + j] = xl
                inR[B + pos + j] = xr
                pInL = max(pInL, abs(xl)); pInR = max(pInR, abs(xr))

                if g != gTarget {
                    g += (gTarget - g) * gCoef
                    if abs(g - gTarget) < 1e-12 { g = gTarget }
                }
                if m != mTarget {
                    m = m < mTarget ? min(mTarget, m + mStep) : max(mTarget, m - mStep)
                }
                if dg != dgTarget {
                    dg += (dgTarget - dg) * gCoef
                    if abs(dg - dgTarget) < 1e-12 { dg = dgTarget }
                }
                // dg == 1 exactly outside A/B, so dl * dg == dl and bypass stays bit-exact.
                let gl = dl * dg, gr = dr * dg
                var yl: Double, yr: Double
                if m == 0 {
                    yl = gl; yr = gr                          // bypass (bit-exact) or A/B dry with preamp
                } else {
                    let wl = outL[pos + j] * g, wr = outR[pos + j] * g
                    if m == 1 { yl = wl; yr = wr } else {
                        yl = gl + (wl - gl) * m
                        yr = gr + (wr - gr) * m
                    }
                    if limit { yl = StereoConvolver.softLimit(yl); yr = StereoConvolver.softLimit(yr) }
                }
                let al = abs(yl), ar = abs(yr)
                if al > 1 || ar > 1 { clips += 1 }
                pOutL = max(pOutL, al); pOutR = max(pOutR, ar)
                dstL[f * outStride] = Float(yl)
                dstR[f * outStride] = Float(yr)
            }
            pos += n
            i += n
            if pos == B {
                processBlock()
                pos = 0
            }
        }
        gain = g; mix = m; dryGain = dg
        params[Param.peakInL] = pInL; params[Param.peakInR] = pInR
        params[Param.peakOutL] = pOutL; params[Param.peakOutR] = pOutR
        params[Param.clips] = clips
    }

    /// Transparent below -1 dBFS; smooth tanh knee above, never exceeding 0 dBFS.
    @inline(__always)
    static func softLimit(_ x: Double) -> Double {
        let t = 0.891250938  // -1 dBFS
        let a = abs(x)
        if a <= t { return x }
        let y = t + (1 - t) * tanh((a - t) / (1 - t))
        return x < 0 ? -y : y
    }
}
