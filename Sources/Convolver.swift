import Accelerate
import Foundation

/// Uniformly-partitioned overlap-save convolver: any number of mono sources (each a weighted sum of input
/// channels) convolved with their left-/right-ear BRIRs and summed to two outputs. Double precision throughout.
///
/// Also handles the dry path (latency-matched; bit-exact for stereo input), the adaptive preamp, bypass
/// crossfade and metering. The render path performs no allocation, locking or Objective-C messaging.
///
/// **Adaptive preamp.** Each partition's wet output is computed one block before it is played, so the
/// convolver knows the block's peak in advance. If the current gain would push that peak above `ceiling`,
/// the gain is lowered to exactly `ceiling / peak`, ramping down over the samples that precede the first one
/// that would clip. The gain never rises again on its own (only `requestGainReset()` raises it). The result:
/// no sample ever exceeds the ceiling, and the gain is the highest value that has kept the audio played so far
/// below it.
final class Convolver {
    static let defaultCeiling = pow(10, -0.01 / 20)   // −0.01 dBFS

    let blockSize: Int
    let partitions: Int
    let sampleRate: Double
    let inputChannels: Int
    let sourceCount: Int
    let ceiling: Double

    private let N: Int
    private let half: Int
    private let log2n: vDSP_Length
    private let setup: FFTSetupD

    private let hRe: UnsafeMutablePointer<Double>   // [S][2][P][H]
    private let hIm: UnsafeMutablePointer<Double>
    private let xRe: UnsafeMutablePointer<Double>   // [S][P][H] frequency-domain delay lines
    private let xIm: UnsafeMutablePointer<Double>
    private let accRe: UnsafeMutablePointer<Double>
    private let accIm: UnsafeMutablePointer<Double>
    private let time: UnsafeMutablePointer<Double>  // N
    private let srcIn: UnsafeMutablePointer<Double> // [S][2B] sliding input windows (mixed per source)
    private let dryL: UnsafeMutablePointer<Double>  // 2B: dry delay line (read at pos, written at B + pos)
    private let dryR: UnsafeMutablePointer<Double>
    private let outL: UnsafeMutablePointer<Double>  // B wet output of the previous block (pre-gain)
    private let outR: UnsafeMutablePointer<Double>
    private let frameIn: UnsafeMutablePointer<Double> // one frame of input channels

    // Routing tables (flat): source s takes inputs routeChan[routeStart[s] ..< routeStart[s+1]].
    private let routeStart: UnsafeMutablePointer<Int>
    private let routeChan: UnsafeMutablePointer<Int>
    private let routeGain: UnsafeMutablePointer<Double>
    private let dryLChan: UnsafeMutablePointer<Int>, dryLGain: UnsafeMutablePointer<Double>, dryLCount: Int
    private let dryRChan: UnsafeMutablePointer<Int>, dryRGain: UnsafeMutablePointer<Double>, dryRCount: Int

    private var fdlPos = 0
    private var pos = 0

    // Gain ramp for the block currently being played: rampFrom → rampTo over the first rampLen samples.
    private var rampFrom: Double
    private var rampTo: Double
    private var rampLen = 0

    private var mix: Double
    private var dryGain: Double = 1

    // Surround test clip (binaural, already convolved). Written by the UI thread only while the audio thread
    // isn't using it (test state idle or finished).
    private var testL: UnsafeMutablePointer<Double>?
    private var testR: UnsafeMutablePointer<Double>?
    private var testLen = 0
    private var testPlayPos = 0   // 1 = untouched dry (bit-exact bypass); preamp gain while A/B is held

    // Shared parameters/meters (written by UI or audio thread; plain aligned words).
    let params = UnsafeMutablePointer<Double>.allocate(capacity: Param.count)
    enum Param {
        /// Current preamp (linear). Written by the audio thread; read by the UI.
        static let gain = 0
        static let mixTarget = 1
        /// UI → audio: non-zero asks the audio thread to raise the preamp back to 0 dB.
        static let resetGain = 2
        static let peakInL = 3, peakInR = 4, peakOutL = 5, peakOutR = 6, clips = 7
        /// A/B hold: crossfade to the dry signal *with the preamp applied*, for level-matched comparison.
        static let abHold = 8
        /// Number of times the preamp has been lowered.
        static let reductions = 9
        /// Surround test: 0 idle, 1 start requested (UI), 2 playing (audio), 3 finished (audio), 4 stop requested (UI).
        static let testState = 10
        /// Frames of the test clip played so far.
        static let testPos = 11
        /// Input samples that were NaN or infinite (replaced by silence).
        static let nonFiniteInput = 12
        static let count = 13
    }

    init(routing: Routing, sampleRate: Double, blockSize: Int, gainDB: Double, bypass: Bool,
         ceiling: Double = Convolver.defaultCeiling) {
        precondition(blockSize > 0 && blockSize & (blockSize - 1) == 0)
        self.blockSize = blockSize
        self.sampleRate = sampleRate
        self.ceiling = ceiling
        let I = max(1, routing.inputChannels)
        inputChannels = I
        let S = routing.sources.count
        sourceCount = S
        let B = blockSize
        let fftN = 2 * B
        let H = B
        let lg = vDSP_Length(fftN.trailingZeroBitCount)
        N = fftN
        half = H
        log2n = lg
        let fftSetup = vDSP_create_fftsetupD(lg, FFTRadix(kFFTRadix2))!
        setup = fftSetup
        let L = routing.sources.map { max($0.left.count, $0.right.count) }.max() ?? 0
        let P = max(1, (L + B - 1) / B)
        partitions = P
        let g = min(1, pow(10, gainDB / 20))
        rampFrom = g
        rampTo = g
        mix = bypass ? 0 : 1

        func alloc(_ n: Int) -> UnsafeMutablePointer<Double> {
            let p = UnsafeMutablePointer<Double>.allocate(capacity: max(n, 1))
            p.initialize(repeating: 0, count: max(n, 1))
            return p
        }
        func allocInt(_ n: Int) -> UnsafeMutablePointer<Int> {
            let p = UnsafeMutablePointer<Int>.allocate(capacity: max(n, 1))
            p.initialize(repeating: 0, count: max(n, 1))
            return p
        }
        let hr = alloc(S * 2 * P * H), hi = alloc(S * 2 * P * H)
        hRe = hr; hIm = hi
        xRe = alloc(S * P * H); xIm = alloc(S * P * H)
        accRe = alloc(H); accIm = alloc(H)
        let tm = alloc(fftN)
        time = tm
        srcIn = alloc(S * fftN)
        dryL = alloc(fftN); dryR = alloc(fftN)
        outL = alloc(B); outR = alloc(B)
        frameIn = alloc(I)

        // Routing tables
        let totalRoutes = routing.sources.reduce(0) { $0 + $1.inputs.count }
        let rs = allocInt(S + 1), rc = allocInt(totalRoutes), rgn = alloc(totalRoutes)
        var r = 0
        for (s, src) in routing.sources.enumerated() {
            rs[s] = r
            for t in src.inputs { rc[r] = t.channel; rgn[r] = t.gain; r += 1 }
        }
        rs[S] = r
        routeStart = rs; routeChan = rc; routeGain = rgn
        let nL = routing.dryL.count, nR = routing.dryR.count
        let dlc = allocInt(nL), dlg = alloc(nL), drc = allocInt(nR), drg = alloc(nR)
        for (i, t) in routing.dryL.enumerated() { dlc[i] = t.channel; dlg[i] = t.gain }
        for (i, t) in routing.dryR.enumerated() { drc[i] = t.channel; drg[i] = t.gain }
        dryLCount = nL; dryLChan = dlc; dryLGain = dlg
        dryRCount = nR; dryRChan = drc; dryRGain = drg

        // vDSP's packed real FFT: forward scales by 2, inverse by N → product needs 1/(4N).
        let scale = 1.0 / (4.0 * Double(fftN))
        for (s, src) in routing.sources.enumerated() {
            for (o, h) in [src.left, src.right].enumerated() {
                for p in 0..<P {
                    for i in 0..<fftN { time[i] = 0 }
                    let start = p * B
                    let end = min(start + B, h.count)
                    if start < end { for i in start..<end { time[i - start] = h[i] * scale } }
                    let k = (s * 2 + o) * P + p
                    forward(time, re: hRe + k * H, im: hIm + k * H)
                }
            }
        }

        params.initialize(repeating: 0, count: Param.count)
        params[Param.gain] = g
        params[Param.mixTarget] = mix
    }

    deinit {
        vDSP_destroy_fftsetupD(setup)
        for p in [hRe, hIm, xRe, xIm, accRe, accIm, time, srcIn, dryL, dryR, outL, outR, frameIn,
                  routeGain, dryLGain, dryRGain, params] { p.deallocate() }
        for p in [routeStart, routeChan, dryLChan, dryRChan] { p.deallocate() }
        testL?.deallocate(); testR?.deallocate()
    }

    var latencyFrames: Int { blockSize }
    var gainDB: Double { 20 * log10(max(params[Param.gain], 1e-12)) }

    func setBypass(_ b: Bool) { params[Param.mixTarget] = b ? 0 : 1 }
    func setABHold(_ held: Bool) { params[Param.abHold] = held ? 1 : 0 }
    /// Raise the preamp back to 0 dB (it will drop again as needed). Takes effect at the next block.
    func requestGainReset() { params[Param.resetGain] = 1 }

    /// Play a binaural clip through the wet path, ahead of the preamp; live input is muted while it plays.
    /// Returns false if a clip is still playing.
    func startTest(left: [Double], right: [Double]) -> Bool {
        let st = params[Param.testState]
        guard st == 0 || st == 3 else { return false }
        testL?.deallocate(); testR?.deallocate()
        let n = min(left.count, right.count)
        let l = UnsafeMutablePointer<Double>.allocate(capacity: max(n, 1))
        let r = UnsafeMutablePointer<Double>.allocate(capacity: max(n, 1))
        l.initialize(repeating: 0, count: max(n, 1)); r.initialize(repeating: 0, count: max(n, 1))
        for i in 0..<n { l[i] = left[i]; r[i] = right[i] }
        testL = l; testR = r; testLen = n
        params[Param.testPos] = 0
        params[Param.testState] = 1
        return true
    }

    func stopTest() {
        let st = params[Param.testState]
        if st == 1 || st == 2 { params[Param.testState] = 4 }
    }

    var testActive: Bool { let st = params[Param.testState]; return st == 1 || st == 2 || st == 4 }
    var testFinished: Bool { params[Param.testState] == 3 }
    var testPosition: Int { Int(params[Param.testPos]) }

    @inline(__always)
    private func forward(_ src: UnsafePointer<Double>, re: UnsafeMutablePointer<Double>, im: UnsafeMutablePointer<Double>) {
        var split = DSPDoubleSplitComplex(realp: re, imagp: im)
        src.withMemoryRebound(to: DSPDoubleComplex.self, capacity: half) {
            vDSP_ctozD($0, 2, &split, 1, vDSP_Length(half))
        }
        vDSP_fft_zripD(setup, &split, 1, log2n, FFTDirection(kFFTDirection_Forward))
    }

    private func processBlock() {
        let P = partitions, H = half, B = blockSize, S = sourceCount, W = 2 * B
        for s in 0..<S {
            forward(srcIn + s * W, re: xRe + (s * P + fdlPos) * H, im: xIm + (s * P + fdlPos) * H)
        }
        for o in 0..<2 {
            vDSP_vclrD(accRe, 1, vDSP_Length(H))
            vDSP_vclrD(accIm, 1, vDSP_Length(H))
            var acc = DSPDoubleSplitComplex(realp: accRe, imagp: accIm)
            var accOut = acc
            var dc = 0.0, ny = 0.0
            var slot = fdlPos
            for p in 0..<P {
                for s in 0..<S {
                    let xr = xRe + (s * P + slot) * H, xi = xIm + (s * P + slot) * H
                    let k = (s * 2 + o) * P + p
                    let hr = hRe + k * H, hi = hIm + k * H
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
        for s in 0..<S { (srcIn + s * W).update(from: srcIn + s * W + B, count: B) }
        dryL.update(from: dryL + B, count: B)
        dryR.update(from: dryR + B, count: B)
        fdlPos = fdlPos + 1 == P ? 0 : fdlPos + 1
        mixTest()
        planGain()
    }

    /// Add the next block of the surround-test clip to the block that plays next.
    @inline(__always)
    private func mixTest() {
        let st = params[Param.testState]
        if st == 4 { params[Param.testState] = 3; return }
        if st == 1 { testPlayPos = 0; params[Param.testState] = 2 }
        guard params[Param.testState] == 2, let tl = testL, let tr = testR else { return }
        let n = min(blockSize, testLen - testPlayPos)
        if n > 0 {
            vDSP_vaddD(outL, 1, tl + testPlayPos, 1, outL, 1, vDSP_Length(n))
            vDSP_vaddD(outR, 1, tr + testPlayPos, 1, outR, 1, vDSP_Length(n))
            testPlayPos += n
        }
        params[Param.testPos] = Double(testPlayPos)
        if testPlayPos >= testLen { params[Param.testState] = 3 }
    }

    /// Choose the gain trajectory for the block that was just computed (it plays next), so that no
    /// sample of it exceeds the ceiling, lowering the gain as little as possible.
    @inline(__always)
    private func planGain() {
        let B = blockSize
        var pkL = 0.0, pkR = 0.0
        vDSP_maxmgvD(outL, 1, &pkL, vDSP_Length(B))
        vDSP_maxmgvD(outR, 1, &pkR, vDSP_Length(B))
        let pk = max(pkL, pkR)
        let now = rampTo
        var target = now
        if params[Param.resetGain] != 0 {
            params[Param.resetGain] = 0
            target = 1
        }
        if target * pk > ceiling {
            target = ceiling / pk
            params[Param.reductions] += 1
        }
        rampFrom = now
        rampTo = target
        if target < now {
            // Ramp down, arriving at `target` by the first sample the current gain would push over the ceiling.
            // Every earlier sample is safe at `now`, and the ramp never exceeds `now`.
            var first = 0
            while first < B && max(abs(outL[first]), abs(outR[first])) * now <= ceiling { first += 1 }
            rampLen = first
        } else if target > now {
            rampLen = B   // only after a reset: `target` is safe for the whole block, so ramp up across it
        } else {
            rampLen = 0
        }
        params[Param.gain] = target
    }

    /// Process `frames` frames. `inputs[c]` points at input channel c, advancing by `inStrides[c]` floats per
    /// frame (a stride of 0 reads a constant, e.g. silence). Outputs are strided Float32.
    /// Latency is exactly `blockSize` frames for both wet and dry paths.
    func process(inputs: UnsafePointer<UnsafePointer<Float>>, inStrides: UnsafePointer<Int>,
                 outL dstL: UnsafeMutablePointer<Float>, outR dstR: UnsafeMutablePointer<Float>, outStride: Int,
                 frames: Int) {
        let B = blockSize, S = sourceCount, W = 2 * B, I = inputChannels
        let abHeld = params[Param.abHold] != 0
        let ts = params[Param.testState]
        let muteInput = ts == 1 || ts == 2 || ts == 4
        let mTarget = abHeld ? 0 : params[Param.mixTarget]
        let gCoef = 1.0 - exp(-1.0 / (0.010 * sampleRate))  // 10 ms one-pole smoothing (A/B dry gain)
        let mStep = 1.0 / (0.030 * sampleRate)              // 30 ms linear crossfade
        var pInL = params[Param.peakInL], pInR = params[Param.peakInR]
        var pOutL = params[Param.peakOutL], pOutR = params[Param.peakOutR]
        var clips = params[Param.clips]
        var nonFinite = params[Param.nonFiniteInput]
        var m = mix, dg = dryGain

        var i = 0
        while i < frames {
            let n = min(frames - i, B - pos)
            for j in 0..<n {
                let f = i + j
                for c in 0..<I {
                    let v = Double(inputs[c][f * inStrides[c]])
                    if v.isFinite { frameIn[c] = v } else { frameIn[c] = 0; nonFinite += 1 }
                }
                // Wet inputs: one mixed sample per source.
                for s in 0..<S {
                    var v = 0.0
                    for r in routeStart[s]..<routeStart[s + 1] { v += frameIn[routeChan[r]] * routeGain[r] }
                    srcIn[s * W + B + pos + j] = muteInput ? 0 : v
                }
                // Dry passthrough. A single unity term is copied as-is, so stereo bypass is bit-exact.
                var xl = 0.0, xr = 0.0
                if dryLCount > 0 {
                    xl = dryLGain[0] == 1 ? frameIn[dryLChan[0]] : frameIn[dryLChan[0]] * dryLGain[0]
                    for k in 1..<max(dryLCount, 1) { xl += frameIn[dryLChan[k]] * dryLGain[k] }
                }
                if dryRCount > 0 {
                    xr = dryRGain[0] == 1 ? frameIn[dryRChan[0]] : frameIn[dryRChan[0]] * dryRGain[0]
                    for k in 1..<max(dryRCount, 1) { xr += frameIn[dryRChan[k]] * dryRGain[k] }
                }
                let dl = dryL[pos + j], dr = dryR[pos + j]          // dry, delayed exactly B frames
                dryL[B + pos + j] = xl
                dryR[B + pos + j] = xr
                pInL = max(pInL, abs(xl)); pInR = max(pInR, abs(xr))

                let p = pos + j
                let g = p >= rampLen ? rampTo : rampFrom + (rampTo - rampFrom) * (Double(p) / Double(rampLen))
                if m != mTarget {
                    m = m < mTarget ? min(mTarget, m + mStep) : max(mTarget, m - mStep)
                }
                let dgTarget = abHeld ? g : 1.0
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
                    let wl = outL[p] * g, wr = outR[p] * g
                    if m == 1 { yl = wl; yr = wr } else {
                        yl = gl + (wl - gl) * m
                        yr = gr + (wr - gr) * m
                    }
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
        mix = m; dryGain = dg
        params[Param.peakInL] = pInL; params[Param.peakInR] = pInR
        params[Param.peakOutL] = pOutL; params[Param.peakOutR] = pOutR
        params[Param.clips] = clips
        params[Param.nonFiniteInput] = nonFinite
    }

    /// Convenience for strided stereo input (tests).
    func processStereo(inL: UnsafePointer<Float>, inR: UnsafePointer<Float>, inStride: Int,
                       outL: UnsafeMutablePointer<Float>, outR: UnsafeMutablePointer<Float>, outStride: Int, frames: Int) {
        let ptrs = [inL, inR], strides = [inStride, inStride]
        process(inputs: ptrs, inStrides: strides, outL: outL, outR: outR, outStride: outStride, frames: frames)
    }
}
