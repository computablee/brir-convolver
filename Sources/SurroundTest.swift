import Accelerate
import AVFoundation
import Foundation

/// Builds the surround test: a stock macOS sound played from each virtual speaker in turn, rendered
/// binaurally (convolved with that speaker's BRIRs) offline, so the live convolver only has to mix it in.
enum SurroundTest {
    static let soundsDirectory = "/System/Library/Sounds"
    /// Around the room clockwise from front left, then the heights.
    static let order: [Speaker] = [.FL, .FC, .FR, .SR, .BR, .BL, .SL, .TFL, .TFR, .TBR, .TBL]
    static let gapSeconds = 0.45
    /// Peak level of the rendered test (−6 dBFS), so it never makes the adaptive preamp drop.
    static let peak = 0.5
    /// Longer sounds are cut to this length, with a short fade-out, so a full sweep stays brief.
    static let maxClipSeconds = 1.2
    static let fadeSeconds = 0.08

    struct Plan {
        var left: [Double]
        var right: [Double]
        var segments: [(speaker: Speaker, start: Int)]
    }

    static func availableSounds() -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: soundsDirectory)) ?? []
        return names.filter { $0.hasSuffix(".aiff") }.map { String($0.dropLast(5)) }.sorted()
    }

    static func url(for sound: String) -> URL { URL(fileURLWithPath: "\(soundsDirectory)/\(sound).aiff") }

    static func make(sound: String, brir: BRIRSet) throws -> Plan {
        var clip = try loadMono(url(for: sound), rate: brir.sampleRate)
        let maxLen = Int(maxClipSeconds * brir.sampleRate)
        if clip.count > maxLen {
            clip = Array(clip.prefix(maxLen))
            let fade = Int(fadeSeconds * brir.sampleRate)
            for i in 0..<fade { clip[maxLen - fade + i] *= 0.5 * (1 + cos(Double.pi * Double(i) / Double(fade))) }
        }
        return render(clip: clip, brir: brir)
    }

    static func render(clip: [Double], brir: BRIRSet) -> Plan {
        let speakers = order.filter { brir.ir($0) != nil }
        let step = clip.count + Int(gapSeconds * brir.sampleRate)
        let total = (speakers.count - 1) * step + clip.count + brir.length
        var left = [Double](repeating: 0, count: max(total, 1)), right = left
        var segments: [(speaker: Speaker, start: Int)] = []
        for (i, s) in speakers.enumerated() {
            let ir = brir.ir(s)!
            let start = i * step
            for (dst, h) in [(0, ir.left), (1, ir.right)] {
                let y = convolve(clip, h)
                for k in 0..<min(y.count, total - start) {
                    if dst == 0 { left[start + k] += y[k] } else { right[start + k] += y[k] }
                }
            }
            segments.append((s, start))
        }
        var pk = 0.0
        for i in 0..<left.count { pk = max(pk, abs(left[i]), abs(right[i])) }
        if pk > 0 {
            let g = peak / pk
            for i in 0..<left.count { left[i] *= g; right[i] *= g }
        }
        return Plan(left: left, right: right, segments: segments)
    }

    /// Decode a sound file to mono Double at `rate`.
    static func loadMono(_ url: URL, rate: Double) throws -> [Double] {
        let file = try AVAudioFile(forReading: url)
        let fmt = file.processingFormat
        guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw PipelineError("Couldn't allocate a buffer for \(url.lastPathComponent).")
        }
        try file.read(into: buf)
        let n = Int(buf.frameLength), ch = Int(fmt.channelCount)
        guard n > 0, let data = buf.floatChannelData else { throw PipelineError("\(url.lastPathComponent) is empty.") }
        var mono = [Double](repeating: 0, count: n)
        for c in 0..<ch { for i in 0..<n { mono[i] += Double(data[c][i]) / Double(ch) } }
        return Resampler.resample(mono, from: fmt.sampleRate, to: rate)
    }

    /// Linear convolution by FFT, double precision.
    static func convolve(_ x: [Double], _ h: [Double]) -> [Double] {
        guard !x.isEmpty, !h.isEmpty else { return [] }
        let outN = x.count + h.count - 1
        var n = 2
        while n < outN { n <<= 1 }
        let log2n = vDSP_Length(n.trailingZeroBitCount)
        guard let setup = vDSP_create_fftsetupD(log2n, FFTRadix(kFFTRadix2)) else { return [] }
        defer { vDSP_destroy_fftsetupD(setup) }
        let half = n / 2

        func forward(_ v: [Double]) -> (re: [Double], im: [Double]) {
            var padded = v + [Double](repeating: 0, count: n - v.count)
            var re = [Double](repeating: 0, count: half), im = re
            re.withUnsafeMutableBufferPointer { rp in
                im.withUnsafeMutableBufferPointer { ip in
                    var sp = DSPDoubleSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                    padded.withUnsafeMutableBufferPointer { pp in
                        pp.baseAddress!.withMemoryRebound(to: DSPDoubleComplex.self, capacity: half) {
                            vDSP_ctozD($0, 2, &sp, 1, vDSP_Length(half))
                        }
                    }
                    vDSP_fft_zripD(setup, &sp, 1, log2n, FFTDirection(kFFTDirection_Forward))
                }
            }
            return (re, im)
        }
        let X = forward(x), H = forward(h)
        var yr = [Double](repeating: 0, count: half), yi = yr
        // Packed bin 0: DC in the real part, Nyquist in the imaginary part.
        yr[0] = X.re[0] * H.re[0]
        yi[0] = X.im[0] * H.im[0]
        for k in 1..<half {
            yr[k] = X.re[k] * H.re[k] - X.im[k] * H.im[k]
            yi[k] = X.re[k] * H.im[k] + X.im[k] * H.re[k]
        }
        var out = [Double](repeating: 0, count: n)
        yr.withUnsafeMutableBufferPointer { rp in
            yi.withUnsafeMutableBufferPointer { ip in
                var sp = DSPDoubleSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                vDSP_fft_zripD(setup, &sp, 1, log2n, FFTDirection(kFFTDirection_Inverse))
                out.withUnsafeMutableBufferPointer { op in
                    op.baseAddress!.withMemoryRebound(to: DSPDoubleComplex.self, capacity: half) {
                        vDSP_ztocD(&sp, 1, $0, 2, vDSP_Length(half))
                    }
                }
            }
        }
        // Forward scales by 2 (each), inverse by n.
        let scale = 1.0 / (4.0 * Double(n))
        return (0..<outN).map { out[$0] * scale }
    }
}
