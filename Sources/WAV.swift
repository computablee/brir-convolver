import Foundation

/// Minimal, exact WAV reader. Decodes integer PCM (8/16/24/32-bit) and IEEE float (32/64-bit),
/// including WAVE_FORMAT_EXTENSIBLE, straight to Double with no dithering, resampling or gain.
struct WAVFile {
    var channels: [[Double]]
    var sampleRate: Double
    var bitsPerSample: Int
    var isFloat: Bool

    var channelCount: Int { channels.count }
    var frameCount: Int { channels.first?.count ?? 0 }

    enum WAVError: LocalizedError {
        case notWAV, noFormat, noData, unsupported(String)
        var errorDescription: String? {
            switch self {
            case .notWAV: return "Not a RIFF/WAVE file."
            case .noFormat: return "WAV file has no 'fmt ' chunk."
            case .noData: return "WAV file has no 'data' chunk."
            case .unsupported(let s): return "Unsupported WAV format: \(s)"
            }
        }
    }

    init(url: URL) throws {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        try self.init(data: data)
    }

    init(data: Data) throws {
        func u16(_ o: Int) -> Int { Int(data[o]) | Int(data[o + 1]) << 8 }
        func u32(_ o: Int) -> Int { u16(o) | u16(o + 2) << 16 }
        func tag(_ o: Int) -> String { String(bytes: data[o..<o + 4], encoding: .ascii) ?? "" }

        guard data.count >= 12, tag(0) == "RIFF" || tag(0) == "RF64", tag(8) == "WAVE" else { throw WAVError.notWAV }

        var fmtTag = 0, nch = 0, rate = 0, bits = 0, blockAlign = 0
        var dataRange: Range<Int>?
        var ds64DataSize: Int?
        var off = 12
        while off + 8 <= data.count {
            let id = tag(off)
            var size = u32(off + 4)
            let body = off + 8
            switch id {
            case "ds64":
                // RF64: 64-bit data size lives here.
                let lo = u32(body + 8), hi = u32(body + 12)
                ds64DataSize = lo | (hi << 32)
            case "fmt ":
                fmtTag = u16(body); nch = u16(body + 2); rate = u32(body + 4)
                blockAlign = u16(body + 12); bits = u16(body + 14)
                if fmtTag == 0xFFFE, size >= 40 { fmtTag = u16(body + 24) } // SubFormat GUID's first two bytes
            case "data":
                if size == 0xFFFF_FFFF, let s = ds64DataSize { size = s }
                let end = min(body + size, data.count)
                dataRange = body..<end
            default: break
            }
            off = body + size + (size & 1)
            if dataRange != nil && nch > 0 { break }
        }
        guard nch > 0 else { throw WAVError.noFormat }
        guard let range = dataRange else { throw WAVError.noData }

        let isFloat: Bool
        switch (fmtTag, bits) {
        case (1, 8), (1, 16), (1, 24), (1, 32): isFloat = false
        case (3, 32), (3, 64): isFloat = true
        default: throw WAVError.unsupported("format tag \(fmtTag), \(bits)-bit")
        }
        let bytesPer = bits / 8
        let frameBytes = blockAlign > 0 ? blockAlign : bytesPer * nch
        let frames = range.count / frameBytes

        var out = [[Double]](repeating: [Double](repeating: 0, count: frames), count: nch)
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let base = raw.baseAddress!.advanced(by: range.lowerBound)
            for f in 0..<frames {
                for c in 0..<nch {
                    let p = base.advanced(by: f * frameBytes + c * bytesPer)
                    let v: Double
                    switch (isFloat, bits) {
                    case (true, 32): v = Double(p.loadUnaligned(as: Float32.self))
                    case (true, _): v = p.loadUnaligned(as: Float64.self)
                    case (false, 8): v = (Double(p.load(as: UInt8.self)) - 128.0) / 128.0
                    case (false, 16): v = Double(p.loadUnaligned(as: Int16.self)) / 32768.0
                    case (false, 24):
                        let b0 = Int32(p.load(fromByteOffset: 0, as: UInt8.self))
                        let b1 = Int32(p.load(fromByteOffset: 1, as: UInt8.self))
                        let b2 = Int32(p.load(fromByteOffset: 2, as: UInt8.self))
                        var s = b0 | (b1 << 8) | (b2 << 16)
                        if s & 0x80_0000 != 0 { s -= 0x100_0000 }
                        v = Double(s) / 8_388_608.0
                    default: v = Double(p.loadUnaligned(as: Int32.self)) / 2_147_483_648.0
                    }
                    out[c][f] = v
                }
            }
        }
        self.channels = out
        self.sampleRate = Double(rate)
        self.bitsPerSample = bits
        self.isFloat = isFloat
    }
}

/// High-quality offline band-limited resampler (Kaiser-windowed sinc, 64 zero crossings, double precision).
/// Only ever applied to the impulse response, never to the live audio stream.
enum Resampler {
    static func resample(_ x: [Double], from src: Double, to dst: Double) -> [Double] {
        if src == dst || x.isEmpty { return x }
        let ratio = dst / src
        let outCount = Int((Double(x.count) * ratio).rounded(.up))
        let fc = min(1.0, ratio) * 0.995         // cutoff relative to source Nyquist
        let zeroCrossings = 64.0
        let halfWidth = zeroCrossings / fc        // in source samples
        let beta = 12.0
        let i0b = besselI0(beta)
        var y = [Double](repeating: 0, count: outCount)
        x.withUnsafeBufferPointer { xp in
            for n in 0..<outCount {
                let t = Double(n) / ratio
                let k0 = max(0, Int((t - halfWidth).rounded(.up)))
                let k1 = min(x.count - 1, Int((t + halfWidth).rounded(.down)))
                if k0 > k1 { continue }
                var acc = 0.0
                for k in k0...k1 {
                    let d = t - Double(k)
                    let r = d / halfWidth
                    let w = besselI0(beta * (1 - r * r).squareRoot()) / i0b
                    let a = Double.pi * fc * d
                    let s = abs(a) < 1e-12 ? 1.0 : sin(a) / a
                    acc += xp[k] * fc * s * w
                }
                y[n] = acc
            }
        }
        return y
    }

    static func besselI0(_ x: Double) -> Double {
        var sum = 1.0, term = 1.0
        let q = x * x / 4
        for k in 1..<64 {
            term *= q / Double(k * k)
            sum += term
            if term < sum * 1e-17 { break }
        }
        return sum
    }
}
