import Accelerate
import Foundation
import os

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
///
/// **BRIR swaps (head tracking).** Each source has two filter slots. `swapIR` writes a new BRIR into the slot
/// that isn't playing, off the audio thread; the audio thread then crossfades from the old filter to the new
/// one over about `fadeSeconds`, applied to the same input history, so the change is click-free. Once the
/// fade completes the output is exactly the input convolved with the new BRIR. The audio thread only ever
/// `trylock`s the handshake lock and skips a block's bookkeeping if it's busy.
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

    private let hRe: UnsafeMutablePointer<Double>   // [S][slot 2][ear 2][P][H]
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
    /// Peak |sample| per input channel since the UI last read it (the UI resets entries to 0).
    let inputPeaks: UnsafeMutablePointer<Double>
    /// Per-input-channel gain, ramped toward 1 (playing) or 0 (muted by a solo).
    private let channelGain: UnsafeMutablePointer<Double>

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

    // BRIR swaps. `activeSlot` is changed only by the audio thread, and only while that source's
    // `swapState` is 2, so the loader may read it whenever the state is 0.
    /// Speaker of each source, in source order (read by the UI / head tracking).
    let sourceSpeakers: [Speaker]
    static let fadeSeconds = 0.02
    /// Blocks a crossfade lasts (≥ 1).
    let fadeBlocks: Int
    private let activeSlot: UnsafeMutablePointer<Int>   // S: filter slot each source plays from
    /// Per source, guarded by `swapLock`: 0 idle (the inactive slot belongs to the loader), 1 new BRIR written
    /// to the inactive slot (loader → audio), 2 crossfading (the audio thread uses both slots).
    private let swapState: UnsafeMutablePointer<Int>
    private let swapLock: UnsafeMutablePointer<os_unfair_lock>
    /// Sources in the current crossfade batch (audio thread). All fades in a batch start and end together.
    private let fadeList: UnsafeMutablePointer<Int>
    private var fadeCount = 0
    private var fadeStep = 0
    /// The batch has finished (slots switched) but its swap states haven't been released yet.
    private var fadeDone = false
    private let allSources: UnsafeMutablePointer<Int>   // 0 ..< S
    private let fadeOld: UnsafeMutablePointer<Double>   // B: fading sources through their old filters
    private let fadeNew: UnsafeMutablePointer<Double>   // B: … and through their new ones
    /// Scratch for `swapIR` (loader thread only).
    private let prepTime: UnsafeMutablePointer<Double>
    private let filterScale: Double

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
        /// Solo: index of the only input channel to play, or −1 for all.
        static let solo = 13
        static let count = 14
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
        let hr = alloc(S * 2 * 2 * P * H), hi = alloc(S * 2 * 2 * P * H)
        hRe = hr; hIm = hi
        xRe = alloc(S * P * H); xIm = alloc(S * P * H)
        accRe = alloc(H); accIm = alloc(H)
        let tm = alloc(fftN)
        time = tm
        srcIn = alloc(S * fftN)
        dryL = alloc(fftN); dryR = alloc(fftN)
        outL = alloc(B); outR = alloc(B)
        frameIn = alloc(I)
        inputPeaks = alloc(I)
        let cg = alloc(I)
        for c in 0..<I { cg[c] = 1 }
        channelGain = cg

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

        sourceSpeakers = routing.sources.map(\.speaker)
        fadeBlocks = max(1, Int((Convolver.fadeSeconds * sampleRate / Double(B)).rounded(.up)))
        activeSlot = allocInt(S)
        swapState = allocInt(S)
        let lock = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1)
        lock.initialize(to: os_unfair_lock())
        swapLock = lock
        fadeList = allocInt(S)
        let all = allocInt(S)
        for s in 0..<S { all[s] = s }
        allSources = all
        fadeOld = alloc(B); fadeNew = alloc(B)
        prepTime = alloc(fftN)

        // vDSP's packed real FFT: forward scales by 2, inverse by N → product needs 1/(4N).
        filterScale = 1.0 / (4.0 * Double(fftN))
        for (s, src) in routing.sources.enumerated() {
            for (o, h) in [src.left, src.right].enumerated() { loadFilter(h, source: s, slot: 0, ear: o, scratch: time) }
        }

        params.initialize(repeating: 0, count: Param.count)
        params[Param.gain] = g
        params[Param.mixTarget] = mix
        params[Param.solo] = -1
    }

    deinit {
        vDSP_destroy_fftsetupD(setup)
        for p in [hRe, hIm, xRe, xIm, accRe, accIm, time, srcIn, dryL, dryR, outL, outR, frameIn, inputPeaks, channelGain,
                  routeGain, dryLGain, dryRGain, params, fadeOld, fadeNew, prepTime] { p.deallocate() }
        for p in [routeStart, routeChan, dryLChan, dryRChan, activeSlot, swapState, fadeList, allSources] { p.deallocate() }
        swapLock.deinitialize(count: 1)
        swapLock.deallocate()
        testL?.deallocate(); testR?.deallocate()
    }

    var latencyFrames: Int { blockSize }
    var gainDB: Double { 20 * log10(max(params[Param.gain], 1e-12)) }

    func setBypass(_ b: Bool) { params[Param.mixTarget] = b ? 0 : 1 }
    func setABHold(_ held: Bool) { params[Param.abHold] = held ? 1 : 0 }
    /// Play only input channel `ch` (nil = all). Switches with a 5 ms ramp.
    func setSolo(_ ch: Int?) { params[Param.solo] = Double(ch ?? -1) }
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

    /// Partition one ear's impulse response into the frequency domain, into `slot` of `source`.
    private func loadFilter(_ h: [Double], source s: Int, slot: Int, ear o: Int, scratch: UnsafeMutablePointer<Double>) {
        let P = partitions, H = half, B = blockSize
        for p in 0..<P {
            for i in 0..<N { scratch[i] = 0 }
            let start = p * B
            let end = min(start + B, h.count)
            if start < end { for i in start..<end { scratch[i - start] = h[i] * filterScale } }
            let k = ((s * 2 + slot) * 2 + o) * P + p
            forward(scratch, re: hRe + k * H, im: hIm + k * H)
        }
    }

    /// Replace source `s`'s BRIR (at this convolver's sample rate; anything past `partitions × blockSize`
    /// samples is dropped), crossfading over about `fadeSeconds`. Call from one background thread at a time —
    /// never the audio thread. Returns false, changing nothing, while that source's previous swap is still
    /// being applied; try again shortly.
    func swapIR(source s: Int, left: [Double], right: [Double]) -> Bool {
        guard s >= 0 && s < sourceCount else { return false }
        os_unfair_lock_lock(swapLock)
        let busy = swapState[s] != 0
        let slot = 1 - activeSlot[s]
        os_unfair_lock_unlock(swapLock)
        if busy { return false }
        // The inactive slot isn't read by the audio thread while the state is 0.
        loadFilter(left, source: s, slot: slot, ear: 0, scratch: prepTime)
        loadFilter(right, source: s, slot: slot, ear: 1, scratch: prepTime)
        os_unfair_lock_lock(swapLock)   // the unlock publishes the filter before the state change
        swapState[s] = 1
        os_unfair_lock_unlock(swapLock)
        return true
    }

    /// True while any source has a swap requested or crossfading.
    var swapsPending: Bool {
        os_unfair_lock_lock(swapLock)
        defer { os_unfair_lock_unlock(swapLock) }
        return (0..<sourceCount).contains { swapState[$0] != 0 }
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

    /// Sum `list[0..<count]` through ear `o`'s filters (each source's active slot, or the other slot with
    /// `otherSlot`) and write the block's valid output samples to `dst`.
    @inline(__always)
    private func convolve(ear o: Int, list: UnsafePointer<Int>, count: Int, otherSlot: Bool, into dst: UnsafeMutablePointer<Double>) {
        let P = partitions, H = half, B = blockSize
        vDSP_vclrD(accRe, 1, vDSP_Length(H))
        vDSP_vclrD(accIm, 1, vDSP_Length(H))
        var acc = DSPDoubleSplitComplex(realp: accRe, imagp: accIm)
        var accOut = acc
        var dc = 0.0, ny = 0.0
        var slot = fdlPos
        for p in 0..<P {
            for i in 0..<count {
                let s = list[i]
                let f = otherSlot ? 1 - activeSlot[s] : activeSlot[s]
                let xr = xRe + (s * P + slot) * H, xi = xIm + (s * P + slot) * H
                let k = ((s * 2 + f) * 2 + o) * P + p
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
        dst.update(from: time + B, count: B)
    }

    /// Release a finished crossfade batch and pick up newly requested swaps (never blocks).
    @inline(__always)
    private func updateSwaps() {
        guard fadeDone || fadeCount == 0, os_unfair_lock_trylock(swapLock) else { return }
        if fadeDone {
            for i in 0..<fadeCount { swapState[fadeList[i]] = 0 }
            fadeCount = 0
            fadeDone = false
        }
        for s in 0..<sourceCount where swapState[s] == 1 {
            swapState[s] = 2
            fadeList[fadeCount] = s
            fadeCount += 1
        }
        fadeStep = 0
        os_unfair_lock_unlock(swapLock)
    }

    private func processBlock() {
        let B = blockSize, S = sourceCount, W = 2 * B, P = partitions, H = half
        for s in 0..<S {
            forward(srcIn + s * W, re: xRe + (s * P + fdlPos) * H, im: xIm + (s * P + fdlPos) * H)
        }
        updateSwaps()
        let fading = fadeCount > 0 && !fadeDone
        for o in 0..<2 {
            let dst = o == 0 ? outL : outR
            convolve(ear: o, list: allSources, count: S, otherSlot: false, into: dst)
            if fading {
                // out = all sources (old filters) + w · (fading sources' new − old), w rising linearly to 1.
                convolve(ear: o, list: fadeList, count: fadeCount, otherSlot: false, into: fadeOld)
                convolve(ear: o, list: fadeList, count: fadeCount, otherSlot: true, into: fadeNew)
                let total = Double(fadeBlocks * B), base = Double(fadeStep * B)
                for j in 0..<B { dst[j] += (fadeNew[j] - fadeOld[j]) * ((base + Double(j + 1)) / total) }
            }
        }
        if fading {
            fadeStep += 1
            if fadeStep == fadeBlocks {
                for i in 0..<fadeCount { activeSlot[fadeList[i]] ^= 1 }
                fadeDone = true
            }
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
        let solo = Int(params[Param.solo])
        let chCoef = 1.0 - exp(-1.0 / (0.005 * sampleRate))   // 5 ms solo ramp
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
                    var x = 0.0
                    if v.isFinite {
                        x = v
                        let a = abs(v)
                        if a > inputPeaks[c] { inputPeaks[c] = a }   // meters show what arrives, solo or not
                    } else { nonFinite += 1 }
                    let target: Double = solo < 0 || solo == c ? 1 : 0
                    var g = channelGain[c]
                    if g != target {
                        g += (target - g) * chCoef
                        if abs(g - target) < 1e-9 { g = target }
                        channelGain[c] = g
                    }
                    frameIn[c] = g == 1 ? x : x * g   // untouched at unity, so stereo bypass stays bit-exact
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
