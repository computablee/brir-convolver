import Foundation

/// A virtual loudspeaker in a 7.1.4 layout.
enum Speaker: String, CaseIterable, Identifiable {
    case FL, FR, FC, LFE, SL, SR, BL, BR, TFL, TFR, TBL, TBR
    var id: String { rawValue }
    var name: String {
        switch self {
        case .FL: return "Front left"
        case .FR: return "Front right"
        case .FC: return "Centre"
        case .LFE: return "LFE"
        case .SL: return "Side left"
        case .SR: return "Side right"
        case .BL: return "Back left"
        case .BR: return "Back right"
        case .TFL: return "Top front left"
        case .TFR: return "Top front right"
        case .TBL: return "Top back left"
        case .TBR: return "Top back right"
        }
    }
    var isHeight: Bool { [.TFL, .TFR, .TBL, .TBR].contains(self) }
    var isLeft: Bool { [.FL, .SL, .BL, .TFL, .TBL].contains(self) }
    var isRight: Bool { [.FR, .SR, .BR, .TFR, .TBR].contains(self) }

    /// Default position (ITU-R BS.775 / Dolby 7.1.4 style) in ASH Toolset's convention:
    /// elevation up-positive, azimuth negative to the left.
    var defaultDirection: Direction {
        switch self {
        case .FL: return Direction(elevation: 0, azimuth: -30)
        case .FR: return Direction(elevation: 0, azimuth: 30)
        case .FC, .LFE: return Direction(elevation: 0, azimuth: 0)
        case .SL: return Direction(elevation: 0, azimuth: -90)
        case .SR: return Direction(elevation: 0, azimuth: 90)
        case .BL: return Direction(elevation: 0, azimuth: -135)
        case .BR: return Direction(elevation: 0, azimuth: 135)
        case .TFL: return Direction(elevation: 45, azimuth: -45)
        case .TFR: return Direction(elevation: 45, azimuth: 45)
        case .TBL: return Direction(elevation: 45, azimuth: -135)
        case .TBR: return Direction(elevation: 45, azimuth: 135)
        }
    }

    /// Speakers a directional BRIR folder supplies (LFE uses the centre's).
    static let directional: [Speaker] = allCases.filter { $0 != .LFE }
}

/// A direction in ASH Toolset's convention: elevation in degrees (up positive), azimuth in degrees
/// (0 = front, negative = left, ±180 = behind).
struct Direction: Hashable, Codable {
    var elevation: Int
    var azimuth: Int

    /// Angle between two directions, in degrees.
    func angle(to o: Direction) -> Double {
        func v(_ d: Direction) -> (Double, Double, Double) {
            let e = Double(d.elevation) * .pi / 180, a = Double(d.azimuth) * .pi / 180
            return (cos(e) * cos(a), cos(e) * sin(a), sin(e))
        }
        let (x1, y1, z1) = v(self), (x2, y2, z2) = v(o)
        return acos(max(-1, min(1, x1 * x2 + y1 * y2 + z1 * z2))) * 180 / .pi
    }
    var label: String { "E\(elevation)° A\(azimuth)°" }
}

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

/// Speaker order of an ASH Toolset 16-channel WAV (8 speakers × left/right ear), matching
/// ASH's `PRESET_16CH_LABELS`. Also used as a manual channel order for multichannel input.
enum SpeakerOrder: String, CaseIterable, Identifiable {
    case standard = "FL|FR|FC|LFE|SL|SR|BL|BR"
    case backBeforeSide = "FL|FR|FC|LFE|BL|BR|SL|SR"
    case cinema = "FC|LFE|FL|FR|SL|SR|BL|BR"
    case sidePriority = "FL|FR|SL|SR|FC|LFE|BL|BR"
    case lateLFE = "FL|FR|FC|SL|SR|LFE|BL|BR"
    case backBeforeCenter = "FL|FR|BL|BR|FC|LFE|SL|SR"
    var id: String { rawValue }
    var speakers: [Speaker] { rawValue.split(separator: "|").map { Speaker(rawValue: String($0))! } }
    var label: String {
        switch self {
        case .standard: return "\(rawValue) — standard 7.1 (ASH default)"
        case .backBeforeSide: return "\(rawValue) — back before side"
        case .cinema: return "\(rawValue) — cinema / front priority"
        case .sidePriority: return "\(rawValue) — side priority"
        case .lateLFE: return "\(rawValue) — late LFE"
        case .backBeforeCenter: return "\(rawValue) — back before centre"
        }
    }
}

/// The two ear responses of one virtual speaker.
struct SpeakerIR {
    var speaker: Speaker
    var left: [Double]    // speaker → left ear
    var right: [Double]   // speaker → right ear
}

/// A set of BRIRs, one left/right-ear pair per virtual speaker.
struct BRIRSet {
    var speakers: [SpeakerIR]
    var sampleRate: Double
    /// Human-readable description of the file layout.
    var format: String
    /// For directional folders: the direction chosen for each speaker.
    var chosen: [String] = []
    /// For directional folders: the exported direction each speaker's BRIR came from.
    var directions: [Speaker: Direction] = [:]

    var length: Int { speakers.map { max($0.left.count, $0.right.count) }.max() ?? 0 }
    func ir(_ s: Speaker) -> SpeakerIR? { speakers.first { $0.speaker == s } }
    var speakerList: String { speakers.map(\.speaker.rawValue).joined(separator: " ") }

    init(speakers: [SpeakerIR], sampleRate: Double, format: String) {
        self.speakers = speakers
        self.sampleRate = sampleRate
        self.format = format
    }

    init(wav: WAVFile, order: ChannelOrder, mapping: SpeakerOrder) throws {
        try self.init(channels: wav.channels, sampleRate: wav.sampleRate, order: order, mapping: mapping)
    }

    /// Supported layouts:
    /// - 2 ch: symmetric pair (ch1 = same-side ear, ch2 = opposite ear)
    /// - 4 ch: true stereo, in `order`
    /// - 14 ch: HeSuVi (FL-L FL-R SL-L SL-R BL-L BL-R FC-L FR-R FR-L SR-R SR-L BR-R BR-L FC-R)
    /// - 16 ch: ASH Toolset, 8 speakers × (left ear, right ear) in `mapping` order
    init(channels c: [[Double]], sampleRate: Double, order: ChannelOrder, mapping: SpeakerOrder) throws {
        self.sampleRate = sampleRate
        func spk(_ s: Speaker, _ l: Int, _ r: Int) -> SpeakerIR { SpeakerIR(speaker: s, left: c[l], right: c[r]) }
        switch c.count {
        case 2:
            speakers = [spk(.FL, 0, 1), spk(.FR, 1, 0)]
            format = "symmetric stereo pair"
        case 4:
            switch order {
            case .inputMajor: speakers = [spk(.FL, 0, 1), spk(.FR, 2, 3)]
            case .outputMajor: speakers = [spk(.FL, 0, 2), spk(.FR, 1, 3)]
            }
            format = "true stereo"
        case 14:
            speakers = [spk(.FL, 0, 1), spk(.FR, 8, 7), spk(.FC, 6, 13),
                        spk(.SL, 2, 3), spk(.SR, 10, 9), spk(.BL, 4, 5), spk(.BR, 12, 11)]
            format = "HeSuVi 7.1"
        case 16:
            var list = mapping.speakers.enumerated().map { i, s in spk(s, 2 * i, 2 * i + 1) }
            list.sort { Speaker.allCases.firstIndex(of: $0.speaker)! < Speaker.allCases.firstIndex(of: $1.speaker)! }
            speakers = list
            format = "16-ch 7.1 (\(mapping.rawValue))"
        default:
            throw NSError(domain: "BRIR", code: 1, userInfo: [NSLocalizedDescriptionKey:
                "Unsupported channel count \(c.count). Expected 4 (true stereo), 14 (HeSuVi), 16 (ASH 16-channel) or 2 (symmetric pair)."])
        }
    }

    /// Build a 7.1(.4) set from a directional folder: each speaker uses the file nearest its position.
    /// Height speakers are included only if the folder has directions at least 20° up. LFE uses the centre.
    init(folder: DirectionalFolder, positions: [Speaker: Direction]) throws {
        var list: [SpeakerIR] = []
        var rate = 0.0
        var used: [String] = []
        var dirs: [Speaker: Direction] = [:]
        for s in Speaker.directional {
            if s.isHeight && !folder.hasHeights { continue }
            let want = positions[s] ?? s.defaultDirection
            let d = folder.nearest(to: want)
            if s.isHeight && d.elevation < 20 { continue }
            let wav = try WAVFile(url: folder.files[d]!)
            guard wav.channelCount == 2 else {
                throw NSError(domain: "BRIR", code: 3, userInfo: [NSLocalizedDescriptionKey:
                    "\(folder.files[d]!.lastPathComponent) has \(wav.channelCount) channels; directional BRIRs are stereo (left ear, right ear)."])
            }
            if rate == 0 { rate = wav.sampleRate } else if wav.sampleRate != rate {
                throw NSError(domain: "BRIR", code: 4, userInfo: [NSLocalizedDescriptionKey: "Directional BRIRs have mixed sample rates."])
            }
            list.append(SpeakerIR(speaker: s, left: wav.channels[0], right: wav.channels[1]))
            used.append("\(s.rawValue) \(d.label)")
            dirs[s] = d
        }
        speakers = list
        sampleRate = rate
        chosen = used
        directions = dirs
        format = "directional (\(folder.files.count) directions)"
    }

    func resampled(to rate: Double) -> BRIRSet {
        if rate == sampleRate { return self }
        // Each path is independent, so resample them in parallel.
        let paths = speakers.flatMap { [$0.left, $0.right] }
        var out = [[Double]](repeating: [], count: paths.count)
        out.withUnsafeMutableBufferPointer { o in
            let base = o.baseAddress!
            DispatchQueue.concurrentPerform(iterations: paths.count) { i in
                (base + i).pointee = Resampler.resample(paths[i], from: sampleRate, to: rate)
            }
        }
        let s = speakers.enumerated().map { i, sp in SpeakerIR(speaker: sp.speaker, left: out[2 * i], right: out[2 * i + 1]) }
        var r = BRIRSet(speakers: s, sampleRate: rate, format: format)
        r.chosen = chosen
        r.directions = directions
        return r
    }

    /// A left/right speaker pair viewed as a true-stereo IR (for analysis).
    func pair(_ p: SpeakerPair) -> TrueStereoIR? {
        guard let l = ir(p.speakers.0), let r = ir(p.speakers.1) else { return nil }
        return TrueStereoIR(paths: [l.left, l.right, r.left, r.right], sampleRate: sampleRate)
    }

    var availablePairs: [SpeakerPair] { SpeakerPair.allCases.filter { pair($0) != nil } }
}

enum SpeakerPair: String, CaseIterable, Identifiable {
    case front = "Front L/R", side = "Side L/R", back = "Back L/R", topFront = "Top front L/R", topBack = "Top back L/R"
    var id: String { rawValue }
    var speakers: (Speaker, Speaker) {
        switch self {
        case .front: return (.FL, .FR)
        case .side: return (.SL, .SR)
        case .back: return (.BL, .BR)
        case .topFront: return (.TFL, .TFR)
        case .topBack: return (.TBL, .TBR)
        }
    }
}

// MARK: - Directional BRIR folders (ASH Toolset "directional BRIR" export)

/// A folder of stereo WAVs named `BRIR_E<elevation>_A<azimuth>.wav`, one per direction.
struct DirectionalFolder {
    let url: URL
    let files: [Direction: URL]

    static func isDirectional(_ url: URL) -> Bool {
        var dir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &dir) && dir.boolValue
    }

    init(url: URL) throws {
        self.url = url
        let names = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
        var f: [Direction: URL] = [:]
        for n in names {
            guard let d = DirectionalFolder.parse(n) else { continue }
            f[d] = url.appendingPathComponent(n)
        }
        guard !f.isEmpty else {
            throw NSError(domain: "BRIR", code: 2, userInfo: [NSLocalizedDescriptionKey:
                "No BRIR_E<elevation>_A<azimuth>.wav files in \(url.lastPathComponent). Export ASH Toolset's directional BRIRs to a folder and choose that folder."])
        }
        files = f
    }

    /// `BRIR_E-15_A30.wav` → elevation −15, azimuth 30.
    static func parse(_ name: String) -> Direction? {
        guard name.hasPrefix("BRIR_E"), name.lowercased().hasSuffix(".wav") else { return nil }
        let core = String(name.dropFirst("BRIR_E".count).dropLast(4))
        guard let r = core.range(of: "_A"),
              let e = Int(core[core.startIndex..<r.lowerBound]), let a = Int(core[r.upperBound...]) else { return nil }
        return Direction(elevation: e, azimuth: a)
    }

    func nearest(to d: Direction) -> Direction {
        files.keys.min { a, b in
            let da = a.angle(to: d), db = b.angle(to: d)
            return da != db ? da < db : (a.elevation, a.azimuth) < (b.elevation, b.azimuth)
        }!
    }

    var hasHeights: Bool { files.keys.contains { $0.elevation >= 20 } }
}

/// Four impulse responses indexed by `input * 2 + output` (0 = LL, 1 = LR, 2 = RL, 3 = RR). Used for analysis.
struct TrueStereoIR {
    var paths: [[Double]]
    var sampleRate: Double
    var length: Int { paths.map(\.count).max() ?? 0 }
}

// MARK: - Input channel roles and routing

/// What one captured input channel carries.
enum InputRole: Equatable {
    case speaker(Speaker)
    case centerSurround
    case unused

    var short: String {
        switch self {
        case .speaker(let s): return s.rawValue
        case .centerSurround: return "Cs"
        case .unused: return "–"
        }
    }
}

/// One convolution source: a mono signal (a weighted sum of input channels) and its two ear responses.
struct ConvolverSource {
    var speaker: Speaker
    var left: [Double]
    var right: [Double]
    var inputs: [(channel: Int, gain: Double)]
}

/// How input channels reach the convolver (wet) and the stereo passthrough (dry).
struct Routing {
    var inputChannels: Int
    var sources: [ConvolverSource]
    var dryL: [(channel: Int, gain: Double)]
    var dryR: [(channel: Int, gain: Double)]
    var summary: String

    static let minus3dB = 0.5.squareRoot()

    /// - Parameters:
    ///   - roles: one entry per input channel
    ///   - lfeGain: linear gain for LFE input channels (0 = discard)
    static func make(brir: BRIRSet, roles: [InputRole], lfeGain: Double) -> Routing {
        let has = Set(brir.speakers.map(\.speaker))
        // An LFE BRIR identical to the centre one (ASH copies FC into LFE) is folded into the centre source.
        var lfeTarget: Speaker = .FC
        if let lfe = brir.ir(.LFE) {
            if let fc = brir.ir(.FC), fc.left == lfe.left, fc.right == lfe.right { lfeTarget = .FC } else { lfeTarget = .LFE }
        }
        let h = minus3dB
        /// Virtual speakers (and gains) that a channel meant for `s` is played on, given what the BRIR has.
        func targets(_ s: Speaker) -> [(Speaker, Double)] {
            if s == .LFE {
                if has.contains(lfeTarget) { return [(lfeTarget, 1)] }
                return [(.FL, h), (.FR, h)]
            }
            if has.contains(s) { return [(s, 1)] }
            switch s {
            case .FC: return [(.FL, h), (.FR, h)]
            case .SL: return has.contains(.BL) ? [(.BL, 1)] : [(.FL, h)]
            case .SR: return has.contains(.BR) ? [(.BR, 1)] : [(.FR, h)]
            case .BL: return has.contains(.SL) ? [(.SL, 1)] : [(.FL, h)]
            case .BR: return has.contains(.SR) ? [(.SR, 1)] : [(.FR, h)]
            // Heights without height BRIRs fold down onto the ear-level speaker below them, −3 dB.
            case .TFL: return targets(.FL).map { ($0.0, $0.1 * h) }
            case .TFR: return targets(.FR).map { ($0.0, $0.1 * h) }
            case .TBL: return has.contains(.TFL) ? [(.TFL, h)] : targets(.BL).map { ($0.0, $0.1 * h) }
            case .TBR: return has.contains(.TFR) ? [(.TFR, h)] : targets(.BR).map { ($0.0, $0.1 * h) }
            default: return []
            }
        }
        var feeds: [Speaker: [(channel: Int, gain: Double)]] = [:]
        var dryL: [(channel: Int, gain: Double)] = [], dryR: [(channel: Int, gain: Double)] = []
        for (i, role) in roles.enumerated() {
            var t: [(Speaker, Double)] = []
            switch role {
            case .speaker(let s):
                t = targets(s)
                if s == .LFE { t = lfeGain > 0 ? t.map { ($0.0, $0.1 * lfeGain) } : [] }
                // Stereo passthrough downmix (ITU-style, LFE omitted).
                switch s {
                case .FL: dryL.append((i, 1))
                case .FR: dryR.append((i, 1))
                case .FC: dryL.append((i, h)); dryR.append((i, h))
                case .SL, .BL, .TFL, .TBL: dryL.append((i, h))
                case .SR, .BR, .TFR, .TBR: dryR.append((i, h))
                case .LFE: break
                }
            case .centerSurround:
                t = (targets(.BL) + targets(.BR)).map { ($0.0, $0.1 * h) }
                dryL.append((i, 0.5)); dryR.append((i, 0.5))
            case .unused: break
            }
            for (spk, g) in t where g != 0 { feeds[spk, default: []].append((i, g)) }
        }
        var sources: [ConvolverSource] = []
        for s in Speaker.allCases {
            guard let f = feeds[s], let ir = brir.ir(s) else { continue }
            sources.append(ConvolverSource(speaker: s, left: ir.left, right: ir.right, inputs: f))
        }
        let used = roles.enumerated().filter { $0.element != .unused }
        let inDesc = used.isEmpty ? "none" : used.map { "\($0.offset + 1)=\($0.element.short)" }.joined(separator: " ")
        let summary = "Inputs \(inDesc) → virtual speakers \(sources.map(\.speaker.rawValue).joined(separator: " "))"
        return Routing(inputChannels: roles.count, sources: sources, dryL: dryL, dryR: dryR, summary: summary)
    }

    /// Role of each channel when the device's speaker layout isn't known: standard 7.1.4 order prefix
    /// (L R C LFE Ls Rs Lrs Rrs Ltf Rtf Ltr Rtr), stereo for 2 channels.
    static func defaultRoles(count: Int) -> [InputRole] {
        if count == 1 { return [.speaker(.FC)] }
        let std = SpeakerOrder.standard.speakers + [.TFL, .TFR, .TBL, .TBR]
        return (0..<count).map { $0 < std.count ? .speaker(std[$0]) : .unused }
    }
}
