import AppKit
import SwiftUI

// MARK: - Theme (dark chart surface; series = speaker hue, ear = line style)

enum VizTheme {
    static let surface = Color(hex: 0x1a1a19)
    static let surface2 = Color(hex: 0x232322)
    static let tooltip = Color(hex: 0x2b2b29)
    static let text = Color(hex: 0xf0efec)
    static let text2 = Color(hex: 0xc3c2b7)
    static let muted = Color(hex: 0x8d8c85)
    static let grid = Color.white.opacity(0.06)
    static let gridStrong = Color.white.opacity(0.16)
    static let leftSpk = Color(hex: 0xd95926)    // orange
    static let rightSpk = Color(hex: 0x3987e5)   // blue

    /// Series 0..3 = LL, LR, RL, RR; 4/5 = left/right ear sums.
    static func color(_ s: Int) -> Color {
        switch s { case 0, 1, 4: return leftSpk; default: return rightSpk }
    }
    static func dashed(_ s: Int) -> Bool { s == 1 || s == 2 }
    static func name(_ s: Int) -> String { s < 4 ? IRAnalysis.pathNames[s] : IRAnalysis.earNames[s - 4] }
    static func stroke(_ s: Int, width: CGFloat = 2) -> StrokeStyle {
        StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round, dash: dashed(s) ? [6, 4] : [])
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xff) / 255, green: Double((hex >> 8) & 0xff) / 255,
                  blue: Double(hex & 0xff) / 255, opacity: 1)
    }
}

// MARK: - UI state (ObservableObject instead of @State so plain swiftc builds work)

final class VizUI: ObservableObject {
    static let shared = VizUI()
    enum Tab: String, CaseIterable, Identifiable { case response = "Frequency response", decay = "Reverb decay", spectrogram = "Spectrogram", impulse = "Impulse"; var id: String { rawValue } }
    enum FRMode: String, CaseIterable, Identifiable { case paths = "4 paths", ears = "Ear sum (mono in)"; var id: String { rawValue } }

    @Published var tab: Tab = .response
    @Published var frMode: FRMode = .paths
    @Published var smoothing: Double = 1.0 / 24
    @Published var includePreamp = false
    @Published var hidden: Set<Int> = []
    @Published var impulseMs: Double = 10
    @Published var hoverFR: CGPoint?
    @Published var hoverDecay: CGPoint?
    @Published var hoverBands: CGPoint?
    @Published var hoverImpulse: CGPoint?
    @Published var hoverSpec: (Int, CGPoint)?

    // Cached smoothed curves
    private var cacheKey: (Int, Double) = (-1, -1)
    private var cache: [[Double]] = []
    func curves(_ a: IRAnalysis, analysisID: Int) -> [[Double]] {
        if cacheKey != (analysisID, smoothing) {
            cache = (0..<6).map { a.curve(series: $0, widthOct: smoothing) }
            cacheKey = (analysisID, smoothing)
        }
        return cache
    }
}


// MARK: - Root

struct VisualizerView: View {
    @ObservedObject var state = AppState.shared
    @ObservedObject var ui = VizUI.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if let a = state.analysis {
                statTiles(a)
                Group {
                    switch ui.tab {
                    case .response: ResponseTab(a: a)
                    case .decay: DecayTab(a: a)
                    case .spectrogram: SpectrogramTab(a: a)
                    case .impulse: ImpulseTab(a: a)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Spacer()
                HStack {
                    Spacer()
                    if state.analyzing { ProgressView().controlSize(.small); Text("Analyzing impulse response…").foregroundColor(VizTheme.text2) }
                    else { Text("Load a BRIR in the main window to see its analysis.").foregroundColor(VizTheme.text2) }
                    Spacer()
                }
                Spacer()
            }
        }
        .padding(18)
        .frame(minWidth: 940, minHeight: 640)
        .background(VizTheme.surface)
        .environment(\.colorScheme, .dark)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("BRIR analysis").font(.system(size: 20, weight: .semibold)).foregroundColor(VizTheme.text)
                Text(state.irInfo).font(.caption).foregroundColor(VizTheme.text2).lineLimit(1)
            }
            Spacer()
            if state.availablePairs.count > 1 {
                Picker("", selection: $state.analysisPair) {
                    ForEach(state.availablePairs) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden()
                .frame(width: 130)
            }
            Picker("", selection: $ui.tab) {
                ForEach(VizUI.Tab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 520)
        }
    }

    private func statTiles(_ a: IRAnalysis) -> some View {
        HStack(spacing: 10) {
            StatTile(title: "RT60 (mid)", value: a.rt60Mid.map { String(format: "%.0f", $0 * 1000) } ?? "—", unit: "ms",
                     note: "500 Hz–1 kHz, T20")
            StatTile(title: "Early decay", value: a.edt.map { String(format: "%.0f", $0 * 1000) } ?? "—", unit: "ms", note: "EDT, broadband")
            StatTile(title: "Direct / reverb", value: String(format: "%+.1f", a.drr), unit: "dB", note: "DRR, same-side ear")
            StatTile(title: "Clarity", value: String(format: "%+.1f", a.c50), unit: "dB", note: "C50")
            StatTile(title: "Interaural level", value: String(format: "%.1f", a.ildDirect), unit: "dB", note: "ILD, direct sound")
            StatTile(title: "Interaural time", value: String(format: "%.0f", a.itdMicros), unit: "µs", note: "ITD, < 1.5 kHz")
        }
    }
}

struct StatTile: View {
    let title: String, value: String, unit: String, note: String
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title.uppercased()).font(.system(size: 9.5, weight: .semibold)).tracking(0.8).foregroundColor(VizTheme.muted)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value).font(.system(size: 22, weight: .medium, design: .rounded)).monospacedDigit().foregroundColor(VizTheme.text)
                Text(unit).font(.system(size: 11)).foregroundColor(VizTheme.text2)
            }
            Text(note).font(.system(size: 10)).foregroundColor(VizTheme.muted)
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(VizTheme.surface2))
    }
}

// MARK: - Legend

struct Legend: View {
    let series: [Int]
    @ObservedObject var ui = VizUI.shared
    var body: some View {
        HStack(spacing: 14) {
            ForEach(series, id: \.self) { s in
                Button {
                    if ui.hidden.contains(s) { ui.hidden.remove(s) } else { ui.hidden.insert(s) }
                } label: {
                    HStack(spacing: 6) {
                        Canvas { ctx, size in
                            var p = Path(); p.move(to: CGPoint(x: 1, y: size.height / 2)); p.addLine(to: CGPoint(x: size.width - 1, y: size.height / 2))
                            ctx.stroke(p, with: .color(VizTheme.color(s)), style: VizTheme.stroke(s))
                        }
                        .frame(width: 24, height: 10)
                        Text(VizTheme.name(s)).font(.system(size: 11.5)).foregroundColor(VizTheme.text2)
                    }
                    .opacity(ui.hidden.contains(s) ? 0.35 : 1)
                }
                .buttonStyle(.plain)
                .help("Click to show/hide")
            }
        }
    }
}

// MARK: - Plot helpers

struct Plot {
    let rect: CGRect
    let xMin: Double, xMax: Double, yMin: Double, yMax: Double
    let logX: Bool
    func x(_ v: Double) -> CGFloat {
        let t = logX ? log(v / xMin) / log(xMax / xMin) : (v - xMin) / (xMax - xMin)
        return rect.minX + CGFloat(t) * rect.width
    }
    func y(_ v: Double) -> CGFloat { rect.maxY - CGFloat((v - yMin) / (yMax - yMin)) * rect.height }
    func xValue(_ px: CGFloat) -> Double {
        let t = Double((px - rect.minX) / rect.width)
        return logX ? xMin * pow(xMax / xMin, t) : xMin + t * (xMax - xMin)
    }
}

func fmtHz(_ f: Double) -> String {
    f >= 1000 ? (f >= 10000 ? String(format: "%.1f kHz", f / 1000) : String(format: "%.2f kHz", f / 1000)) : String(format: "%.0f Hz", f)
}

func drawYGrid(_ ctx: inout GraphicsContext, _ p: Plot, step: Double, unit: String, strongAt: Double? = nil) {
    var v = (p.yMin / step).rounded(.up) * step
    while v <= p.yMax + 1e-9 {
        var path = Path(); path.move(to: CGPoint(x: p.rect.minX, y: p.y(v))); path.addLine(to: CGPoint(x: p.rect.maxX, y: p.y(v)))
        ctx.stroke(path, with: .color(strongAt == v ? VizTheme.gridStrong : VizTheme.grid), lineWidth: 1)
        ctx.draw(Text(String(format: "%g", v) + unit).font(.system(size: 10)).foregroundColor(VizTheme.muted),
                 at: CGPoint(x: p.rect.minX - 6, y: p.y(v)), anchor: .trailing)
        v += step
    }
}

func drawLogFreqAxis(_ ctx: inout GraphicsContext, _ p: Plot) {
    let majors: [Double] = [20, 50, 100, 200, 500, 1000, 2000, 5000, 10000, 20000]
    var minors: [Double] = []
    for dec in [10.0, 100, 1000, 10000] { for m in 2...9 { minors.append(dec * Double(m)) } }
    for f in minors where f >= p.xMin && f <= p.xMax {
        var path = Path(); path.move(to: CGPoint(x: p.x(f), y: p.rect.minY)); path.addLine(to: CGPoint(x: p.x(f), y: p.rect.maxY))
        ctx.stroke(path, with: .color(VizTheme.grid.opacity(0.6)), lineWidth: 1)
    }
    for f in majors where f >= p.xMin && f <= p.xMax {
        var path = Path(); path.move(to: CGPoint(x: p.x(f), y: p.rect.minY)); path.addLine(to: CGPoint(x: p.x(f), y: p.rect.maxY))
        ctx.stroke(path, with: .color(VizTheme.grid), lineWidth: 1)
        let label = f >= 1000 ? String(format: "%gk", f / 1000) : String(format: "%g", f)
        ctx.draw(Text(label).font(.system(size: 10)).foregroundColor(VizTheme.muted),
                 at: CGPoint(x: p.x(f), y: p.rect.maxY + 12), anchor: .center)
    }
}

/// Rounded tooltip with a heading and colored-swatch rows; positioned to stay inside `bounds`.
func drawTooltip(_ ctx: inout GraphicsContext, at pt: CGPoint, bounds: CGRect, title: String, rows: [(Int?, String)]) {
    let titleT = ctx.resolve(Text(title).font(.system(size: 11, weight: .semibold)).foregroundColor(VizTheme.text))
    let rowTs = rows.map { ctx.resolve(Text($0.1).font(.system(size: 11).monospacedDigit()).foregroundColor(VizTheme.text2)) }
    let tS = titleT.measure(in: CGSize(width: 400, height: 40))
    let rS = rowTs.map { $0.measure(in: CGSize(width: 400, height: 40)) }
    let w = max(tS.width, (rS.map(\.width).max() ?? 0) + 22) + 20
    let lineH: CGFloat = 17
    let h = 12 + tS.height + 6 + CGFloat(rows.count) * lineH + 4
    var x = pt.x + 14, y = pt.y - h - 10
    if x + w > bounds.maxX { x = pt.x - w - 14 }
    if y < bounds.minY { y = pt.y + 14 }
    let box = CGRect(x: x, y: y, width: w, height: h)
    ctx.fill(Path(roundedRect: box, cornerRadius: 8), with: .color(VizTheme.tooltip.opacity(0.97)))
    ctx.stroke(Path(roundedRect: box, cornerRadius: 8), with: .color(Color.white.opacity(0.08)), lineWidth: 1)
    ctx.draw(titleT, at: CGPoint(x: box.minX + 10, y: box.minY + 8), anchor: .topLeading)
    var ry = box.minY + 8 + tS.height + 6
    for (i, r) in rows.enumerated() {
        if let s = r.0 {
            var sw = Path(); sw.move(to: CGPoint(x: box.minX + 10, y: ry + lineH / 2 - 1)); sw.addLine(to: CGPoint(x: box.minX + 24, y: ry + lineH / 2 - 1))
            ctx.stroke(sw, with: .color(VizTheme.color(s)), style: VizTheme.stroke(s, width: 2.5))
        }
        ctx.draw(rowTs[i], at: CGPoint(x: box.minX + (r.0 == nil ? 10 : 32), y: ry), anchor: .topLeading)
        ry += lineH
    }
}

/// Direct labels at the right edge of the plot with simple vertical collision avoidance.
func drawEndLabels(_ ctx: inout GraphicsContext, _ items: [(Int, CGFloat)], x: CGFloat, minY: CGFloat, maxY: CGFloat) {
    var placed: [(Int, CGFloat)] = []
    for it in items.sorted(by: { $0.1 < $1.1 }) {
        var y = min(max(it.1, minY + 6), maxY - 6)
        if let last = placed.last, y - last.1 < 14 { y = last.1 + 14 }
        placed.append((it.0, y))
    }
    for (s, y) in placed {
        var sw = Path(); sw.move(to: CGPoint(x: x + 6, y: y)); sw.addLine(to: CGPoint(x: x + 14, y: y))
        ctx.stroke(sw, with: .color(VizTheme.color(s)), style: VizTheme.stroke(s, width: 2))
        ctx.draw(Text(s < 4 ? IRAnalysis.shortNames[s] : (s == 4 ? "L ear" : "R ear")).font(.system(size: 10.5)).foregroundColor(VizTheme.text2),
                 at: CGPoint(x: x + 18, y: y), anchor: .leading)
    }
}

func chartCard<Content: View>(_ content: Content) -> some View {
    content
        .padding(.vertical, 10).padding(.horizontal, 8)
        .background(RoundedRectangle(cornerRadius: 12).fill(VizTheme.surface2.opacity(0.55)))
}

// MARK: - Frequency response

struct ResponseTab: View {
    let a: IRAnalysis
    @ObservedObject var ui = VizUI.shared
    @ObservedObject var state = AppState.shared

    var series: [Int] { ui.frMode == .paths ? [0, 3, 1, 2] : [4, 5] }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 16) {
                Picker("", selection: $ui.frMode) { ForEach(VizUI.FRMode.allCases) { Text($0.rawValue).tag($0) } }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 260)
                Picker("Smoothing", selection: $ui.smoothing) {
                    Text("1/48 oct").tag(1.0 / 48); Text("1/24 oct").tag(1.0 / 24); Text("1/12 oct").tag(1.0 / 12)
                    Text("1/6 oct").tag(1.0 / 6); Text("1/3 oct").tag(1.0 / 3)
                }
                .frame(width: 180)
                Toggle("Include preamp (\(String(format: "%.1f", state.preampDB)) dB)", isOn: $ui.includePreamp)
                Spacer()
                Legend(series: series)
            }
            .font(.system(size: 12))
            chartCard(chart)
            Text(ui.frMode == .paths
                 ? "Magnitude response of each speaker-to-ear path, i.e. the EQ the BRIR applies on that path. 0 dB = unity. Solid = same-side ear, dashed = opposite ear."
                 : "What each ear receives when both speakers play the same (mono) signal: |L→ear + R→ear|. This is the net tonal colouration of centred content.")
                .font(.system(size: 11)).foregroundColor(VizTheme.muted)
        }
    }

    private var chart: some View {
        let curves = ui.curves(a, analysisID: state.analysisID)
        let off = ui.includePreamp ? state.preampDB : 0
        let visible = series.filter { !ui.hidden.contains($0) }
        let fMin = 20.0, fMax = 20000.0
        let n = curves.first?.count ?? 1
        // y-range from visible data, padded and snapped to 5 dB
        var lo = Double.infinity, hi = -Double.infinity
        for s in visible { for v in curves[s] { lo = min(lo, v + off); hi = max(hi, v + off) } }
        if !lo.isFinite { lo = -20; hi = 10 }
        lo = max(lo, hi - 60)
        var yMin = ((lo - 3) / 5).rounded(.down) * 5, yMax = ((hi + 3) / 5).rounded(.up) * 5
        if yMax - yMin < 30 { let mid = (yMax + yMin) / 2; yMin = ((mid - 15) / 5).rounded(.down) * 5; yMax = yMin + 30 }

        return Canvas { ctx, size in
            let p = Plot(rect: CGRect(x: 52, y: 8, width: size.width - 52 - 64, height: size.height - 8 - 26),
                         xMin: fMin, xMax: fMax, yMin: yMin, yMax: yMax, logX: true)
            drawLogFreqAxis(&ctx, p)
            drawYGrid(&ctx, p, step: (yMax - yMin) > 45 ? 10 : 5, unit: " dB", strongAt: 0)
            var ends: [(Int, CGFloat)] = []
            var full = ctx
            ctx.clip(to: Path(p.rect.insetBy(dx: -2, dy: -2)))
            for s in visible.reversed() {
                var path = Path()
                for i in 0..<n {
                    let f = fMin * pow(fMax / fMin, Double(i) / Double(n - 1))
                    let pt = CGPoint(x: p.x(f), y: p.y(curves[s][i] + off))
                    i == 0 ? path.move(to: pt) : path.addLine(to: pt)
                }
                ctx.stroke(path, with: .color(VizTheme.color(s)), style: VizTheme.stroke(s, width: VizTheme.dashed(s) ? 1.6 : 2))
                ends.append((s, p.y(curves[s][n - 1] + off)))
            }
            drawEndLabels(&full, ends, x: p.rect.maxX, minY: p.rect.minY, maxY: p.rect.maxY)

            if let h = ui.hoverFR, p.rect.contains(h) {
                let f = p.xValue(h.x)
                let idx = Int((log(f / fMin) / log(fMax / fMin) * Double(n - 1)).rounded())
                var line = Path(); line.move(to: CGPoint(x: h.x, y: p.rect.minY)); line.addLine(to: CGPoint(x: h.x, y: p.rect.maxY))
                full.stroke(line, with: .color(Color.white.opacity(0.25)), lineWidth: 1)
                var rows: [(Int?, String)] = []
                for s in visible {
                    let v = curves[s][min(max(idx, 0), n - 1)] + off
                    let pt = CGPoint(x: h.x, y: p.y(v))
                    full.fill(Path(ellipseIn: CGRect(x: pt.x - 4.5, y: pt.y - 4.5, width: 9, height: 9)), with: .color(VizTheme.surface))
                    full.fill(Path(ellipseIn: CGRect(x: pt.x - 3.5, y: pt.y - 3.5, width: 7, height: 7)), with: .color(VizTheme.color(s)))
                    rows.append((s, String(format: "%@  %+6.2f dB", VizTheme.name(s), v)))
                }
                drawTooltip(&full, at: h, bounds: CGRect(origin: .zero, size: size), title: fmtHz(f), rows: rows)
            }
        }
        .onContinuousHover { phase in
            switch phase { case .active(let pt): ui.hoverFR = pt; case .ended: ui.hoverFR = nil }
        }
    }
}

// MARK: - Decay

struct DecayTab: View {
    let a: IRAnalysis
    @ObservedObject var ui = VizUI.shared
    let series = [0, 3, 1, 2]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Energy decay (Schroeder integral) over the 1 ms peak envelope")
                    .font(.system(size: 12, weight: .medium)).foregroundColor(VizTheme.text2)
                Spacer()
                Legend(series: series)
            }
            chartCard(decayChart).frame(maxHeight: .infinity)
            HStack {
                Text("Reverberation time by octave band (all four paths, summed energy)")
                    .font(.system(size: 12, weight: .medium)).foregroundColor(VizTheme.text2)
                Spacer()
            }
            chartCard(bandChart).frame(height: 190)
        }
    }

    private var decayChart: some View {
        let visible = series.filter { !ui.hidden.contains($0) }
        let tMax = Double(a.length) / a.sampleRate * 1000
        return Canvas { ctx, size in
            let p = Plot(rect: CGRect(x: 52, y: 8, width: size.width - 52 - 64, height: size.height - 8 - 26),
                         xMin: 0, xMax: tMax, yMin: -90, yMax: 0, logX: false)
            drawYGrid(&ctx, p, step: 10, unit: " dB", strongAt: -60)
            let tStep = tMax > 400 ? 100.0 : 50
            var t = 0.0
            while t <= tMax + 1e-6 {
                var g = Path(); g.move(to: CGPoint(x: p.x(t), y: p.rect.minY)); g.addLine(to: CGPoint(x: p.x(t), y: p.rect.maxY))
                ctx.stroke(g, with: .color(VizTheme.grid), lineWidth: 1)
                ctx.draw(Text(String(format: "%.0f ms", t)).font(.system(size: 10)).foregroundColor(VizTheme.muted),
                         at: CGPoint(x: p.x(t), y: p.rect.maxY + 12))
                t += tStep
            }
            var inner = ctx
            inner.clip(to: Path(p.rect))
            // Envelopes (recessive)
            for s in visible {
                var path = Path()
                for (i, v) in a.envDB[s].enumerated() {
                    let pt = CGPoint(x: p.x(a.envTimes[i] * 1000), y: p.y(max(v, -95)))
                    i == 0 ? path.move(to: pt) : path.addLine(to: pt)
                }
                inner.stroke(path, with: .color(VizTheme.color(s).opacity(0.22)), lineWidth: 1)
            }
            var ends: [(Int, CGFloat)] = []
            for s in visible.reversed() {
                var path = Path()
                for (i, v) in a.edcDB[s].enumerated() {
                    let pt = CGPoint(x: p.x(a.edcTimes[i] * 1000), y: p.y(max(v, -95)))
                    i == 0 ? path.move(to: pt) : path.addLine(to: pt)
                }
                inner.stroke(path, with: .color(VizTheme.color(s)), style: VizTheme.stroke(s))
                let mid = a.edcDB[s][a.edcDB[s].count * 3 / 5]
                ends.append((s, p.y(max(mid, -90))))
            }
            ctx.draw(Text("−60 dB").font(.system(size: 10)).foregroundColor(VizTheme.text2),
                     at: CGPoint(x: p.rect.maxX - 4, y: p.y(-60) - 8), anchor: .trailing)
            drawEndLabels(&ctx, ends, x: p.rect.maxX, minY: p.rect.minY, maxY: p.rect.maxY)

            if let h = ui.hoverDecay, p.rect.contains(h) {
                let tms = p.xValue(h.x)
                var line = Path(); line.move(to: CGPoint(x: h.x, y: p.rect.minY)); line.addLine(to: CGPoint(x: h.x, y: p.rect.maxY))
                ctx.stroke(line, with: .color(Color.white.opacity(0.25)), lineWidth: 1)
                let idx = min(a.edcTimes.count - 1, max(0, Int((tms / 1000 / (a.edcTimes.last ?? 1)) * Double(a.edcTimes.count - 1))))
                var rows: [(Int?, String)] = []
                for s in visible {
                    let v = a.edcDB[s][idx]
                    let pt = CGPoint(x: h.x, y: p.y(max(v, -95)))
                    ctx.fill(Path(ellipseIn: CGRect(x: pt.x - 3.5, y: pt.y - 3.5, width: 7, height: 7)), with: .color(VizTheme.color(s)))
                    rows.append((s, String(format: "%@  %6.1f dB", VizTheme.name(s), v)))
                }
                drawTooltip(&ctx, at: h, bounds: CGRect(origin: .zero, size: size), title: String(format: "%.1f ms", tms), rows: rows)
            }
        }
        .onContinuousHover { phase in
            switch phase { case .active(let pt): ui.hoverDecay = pt; case .ended: ui.hoverDecay = nil }
        }
    }

    private var bandChart: some View {
        let vals = a.bandRT60
        let maxV = max(0.1, (vals.compactMap { $0 }.max() ?? 0.5) * 1.2)
        return Canvas { ctx, size in
            let p = Plot(rect: CGRect(x: 52, y: 8, width: size.width - 52 - 20, height: size.height - 8 - 40),
                         xMin: 0, xMax: Double(vals.count), yMin: 0, yMax: maxV * 1000, logX: false)
            let step = maxV * 1000 > 800 ? 200.0 : maxV * 1000 > 300 ? 100 : 50
            drawYGrid(&ctx, p, step: step, unit: " ms")
            let slot = p.rect.width / CGFloat(vals.count)
            let barW = min(46, slot * 0.6)
            var hovered: Int?
            if let h = ui.hoverBands, p.rect.insetBy(dx: 0, dy: -30).contains(h) { hovered = min(vals.count - 1, max(0, Int((h.x - p.rect.minX) / slot))) }
            for (i, v) in vals.enumerated() {
                let cx = p.rect.minX + slot * (CGFloat(i) + 0.5)
                let fc = a.bandCenters[i]
                ctx.draw(Text(fc >= 1000 ? String(format: "%gk", fc / 1000) : String(format: "%g", fc)).font(.system(size: 10)).foregroundColor(VizTheme.muted),
                         at: CGPoint(x: cx, y: p.rect.maxY + 11))
                ctx.draw(Text(v.map { String(format: "%.0f", $0 * 1000) } ?? "—").font(.system(size: 10).monospacedDigit()).foregroundColor(VizTheme.text2),
                         at: CGPoint(x: cx, y: p.rect.maxY + 25))
                guard let v else { continue }
                let top = p.y(v * 1000)
                let r = CGRect(x: cx - barW / 2, y: top, width: barW, height: p.rect.maxY - top)
                let shape = UnevenRoundedRectangle(topLeadingRadius: 4, bottomLeadingRadius: 0, bottomTrailingRadius: 0, topTrailingRadius: 4).path(in: r)
                ctx.fill(shape, with: .color(VizTheme.rightSpk.opacity(hovered == nil || hovered == i ? 1 : 0.45)))
            }
            if let i = hovered, let h = ui.hoverBands {
                let fc = a.bandCenters[i]
                drawTooltip(&ctx, at: h, bounds: CGRect(origin: .zero, size: size),
                            title: "\(fmtHz(fc)) octave",
                            rows: [(nil, a.bandRT60[i].map { String(format: "RT60  %.0f ms  (%@)", $0 * 1000, a.bandMethod[i]) } ?? "Decay too short to measure")])
            }
        }
        .onContinuousHover { phase in
            switch phase { case .active(let pt): ui.hoverBands = pt; case .ended: ui.hoverBands = nil }
        }
    }
}

// MARK: - Spectrogram

struct SpectrogramTab: View {
    let a: IRAnalysis
    @ObservedObject var ui = VizUI.shared
    let order = [0, 2, 1, 3]   // row 1: left ear (L→L, R→L); row 2: right ear (L→R, R→R)

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 14) {
                VStack(spacing: 10) {
                    HStack(spacing: 10) { cell(0); cell(2) }
                    HStack(spacing: 10) { cell(1); cell(3) }
                }
                colorBar.frame(width: 54)
            }
            Text("Time–frequency energy of each path (1024-sample Hann window, 1.3 ms hop). Brightness is relative to the loudest point across all four paths.")
                .font(.system(size: 11)).foregroundColor(VizTheme.muted)
        }
    }

    private func cell(_ s: Int) -> some View {
        let tMax = Double(a.length) / a.sampleRate * 1000
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Canvas { ctx, size in
                    var p = Path(); p.move(to: CGPoint(x: 1, y: size.height / 2)); p.addLine(to: CGPoint(x: size.width - 1, y: size.height / 2))
                    ctx.stroke(p, with: .color(VizTheme.color(s)), style: VizTheme.stroke(s))
                }.frame(width: 20, height: 8)
                Text(VizTheme.name(s)).font(.system(size: 11.5, weight: .medium)).foregroundColor(VizTheme.text2)
            }
            Canvas { ctx, size in
                let rect = CGRect(x: 44, y: 2, width: size.width - 48, height: size.height - 20)
                if s < a.specImages.count {
                    ctx.draw(Image(decorative: a.specImages[s], scale: 1).interpolation(.high).resizable(), in: rect)
                }
                let fp = Plot(rect: rect, xMin: 0, xMax: tMax, yMin: log(a.specFMin), yMax: log(a.specFMax), logX: false)
                for f in [50.0, 100, 200, 500, 1000, 2000, 5000, 10000] where f < a.specFMax {
                    let y = fp.y(log(f))
                    var g = Path(); g.move(to: CGPoint(x: rect.minX, y: y)); g.addLine(to: CGPoint(x: rect.maxX, y: y))
                    ctx.stroke(g, with: .color(Color.white.opacity(0.07)), lineWidth: 1)
                    ctx.draw(Text(f >= 1000 ? String(format: "%gk", f / 1000) : String(format: "%g", f)).font(.system(size: 9.5)).foregroundColor(VizTheme.muted),
                             at: CGPoint(x: rect.minX - 5, y: y), anchor: .trailing)
                }
                let tStep = tMax > 400 ? 200.0 : 100
                var t = 0.0
                while t <= tMax + 1e-6 {
                    ctx.draw(Text(String(format: "%.0f ms", t)).font(.system(size: 9.5)).foregroundColor(VizTheme.muted),
                             at: CGPoint(x: fp.x(t), y: rect.maxY + 9), anchor: t == 0 ? .leading : .center)
                    t += tStep
                }
                if case let (hs, h)? = ui.hoverSpec, hs == s, rect.contains(h) {
                    let tms = fp.xValue(h.x)
                    let f = exp(log(a.specFMin) + Double((rect.maxY - h.y) / rect.height) * (log(a.specFMax) - log(a.specFMin)))
                    let col = min(a.specFrames - 1, max(0, Int(Double((h.x - rect.minX) / rect.width) * Double(a.specFrames))))
                    let row = min(a.specRows - 1, max(0, Int(Double((h.y - rect.minY) / rect.height) * Double(a.specRows))))
                    let db = a.specDB[s][row * a.specFrames + col]
                    var vline = Path(); vline.move(to: CGPoint(x: h.x, y: rect.minY)); vline.addLine(to: CGPoint(x: h.x, y: rect.maxY))
                    var hline = Path(); hline.move(to: CGPoint(x: rect.minX, y: h.y)); hline.addLine(to: CGPoint(x: rect.maxX, y: h.y))
                    ctx.stroke(vline, with: .color(Color.white.opacity(0.3)), lineWidth: 1)
                    ctx.stroke(hline, with: .color(Color.white.opacity(0.3)), lineWidth: 1)
                    drawTooltip(&ctx, at: h, bounds: CGRect(origin: .zero, size: size),
                                title: "\(fmtHz(f)) · \(String(format: "%.1f ms", tms))",
                                rows: [(nil, String(format: "%.1f dB re max", max(db, -IRAnalysis.specRange)))])
                }
            }
            .onContinuousHover { phase in
                switch phase { case .active(let pt): ui.hoverSpec = (s, pt); case .ended: ui.hoverSpec = nil }
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 12).fill(VizTheme.surface2.opacity(0.55)))
    }

    private var colorBar: some View {
        Canvas { ctx, size in
            let r = CGRect(x: 4, y: 26, width: 12, height: size.height - 60)
            let steps = 64
            for i in 0..<steps {
                let t = 1 - Double(i) / Double(steps - 1)
                let (cr, cg, cb) = IRAnalysis.ramp(t)
                let seg = CGRect(x: r.minX, y: r.minY + r.height * CGFloat(i) / CGFloat(steps), width: r.width, height: r.height / CGFloat(steps) + 0.5)
                ctx.fill(Path(seg), with: .color(Color(.sRGB, red: Double(cr) / 255, green: Double(cg) / 255, blue: Double(cb) / 255)))
            }
            for db in stride(from: 0, through: -Int(IRAnalysis.specRange), by: -24) {
                let y = r.minY + r.height * CGFloat(Double(-db) / Double(IRAnalysis.specRange))
                ctx.draw(Text("\(db)").font(.system(size: 9.5)).foregroundColor(VizTheme.muted), at: CGPoint(x: r.maxX + 5, y: y), anchor: .leading)
            }
            ctx.draw(Text("dB").font(.system(size: 10)).foregroundColor(VizTheme.text2), at: CGPoint(x: r.minX, y: 12), anchor: .leading)
        }
    }
}

// MARK: - Impulse

struct ImpulseTab: View {
    let a: IRAnalysis
    @ObservedObject var ui = VizUI.shared
    let series = [0, 3, 1, 2]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                Picker("Window", selection: $ui.impulseMs) {
                    Text("3 ms").tag(3.0); Text("10 ms").tag(10.0); Text("30 ms").tag(30.0); Text("100 ms").tag(100.0)
                }
                .pickerStyle(.segmented).frame(width: 300)
                Spacer()
                Legend(series: series)
            }
            .font(.system(size: 12))
            chartCard(chart)
            Text("Raw waveform of each path from t = 0: direct sound, the interaural delay and level difference, then the first reflections.")
                .font(.system(size: 11)).foregroundColor(VizTheme.muted)
        }
    }

    private var chart: some View {
        let visible = series.filter { !ui.hidden.contains($0) }
        let count = min(a.impulse.first?.count ?? 0, Int(ui.impulseMs / 1000 * a.sampleRate))
        let tMax = Double(count) / a.sampleRate * 1000
        var pk = 1e-9
        for s in visible { for i in 0..<count { pk = max(pk, abs(a.impulse[s][i])) } }
        let yr = pk * 1.08
        return Canvas { ctx, size in
            let p = Plot(rect: CGRect(x: 52, y: 8, width: size.width - 52 - 64, height: size.height - 8 - 26),
                         xMin: 0, xMax: max(tMax, 1e-3), yMin: -yr, yMax: yr, logX: false)
            for frac in [-1.0, -0.5, 0, 0.5, 1] {
                let v = frac * pk
                var g = Path(); g.move(to: CGPoint(x: p.rect.minX, y: p.y(v))); g.addLine(to: CGPoint(x: p.rect.maxX, y: p.y(v)))
                ctx.stroke(g, with: .color(frac == 0 ? VizTheme.gridStrong : VizTheme.grid), lineWidth: 1)
                ctx.draw(Text(String(format: "%.2f", v)).font(.system(size: 10)).foregroundColor(VizTheme.muted),
                         at: CGPoint(x: p.rect.minX - 6, y: p.y(v)), anchor: .trailing)
            }
            let tStep = [0.5, 1, 2, 5, 10, 20].first { tMax / $0 <= 10 } ?? 20
            var t = 0.0
            while t <= tMax + 1e-9 {
                ctx.draw(Text(String(format: tStep < 1 ? "%.1f ms" : "%.0f ms", t)).font(.system(size: 10)).foregroundColor(VizTheme.muted),
                         at: CGPoint(x: p.x(t), y: p.rect.maxY + 12))
                t += tStep
            }
            var inner = ctx
            inner.clip(to: Path(p.rect))
            let px = max(1, Int(p.rect.width))
            var ends: [(Int, CGFloat)] = []
            for s in visible.reversed() {
                let h = a.impulse[s]
                var path = Path()
                if count <= px * 2 {
                    for i in 0..<count {
                        let pt = CGPoint(x: p.x(Double(i) / a.sampleRate * 1000), y: p.y(h[i]))
                        i == 0 ? path.move(to: pt) : path.addLine(to: pt)
                    }
                } else {   // min/max decimation per pixel column
                    for c in 0..<px {
                        let i0 = c * count / px, i1 = max(i0 + 1, (c + 1) * count / px)
                        var lo = h[i0], hi = h[i0]
                        for i in i0..<min(i1, count) { lo = min(lo, h[i]); hi = max(hi, h[i]) }
                        let x = p.rect.minX + CGFloat(c)
                        c == 0 ? path.move(to: CGPoint(x: x, y: p.y(lo))) : path.addLine(to: CGPoint(x: x, y: p.y(lo)))
                        path.addLine(to: CGPoint(x: x, y: p.y(hi)))
                    }
                }
                inner.stroke(path, with: .color(VizTheme.color(s)), style: VizTheme.stroke(s, width: VizTheme.dashed(s) ? 1.4 : 1.8))
                ends.append((s, p.y(0) + CGFloat(s) * 0.01))
            }
            drawEndLabels(&ctx, ends, x: p.rect.maxX, minY: p.rect.minY, maxY: p.rect.maxY)

            if let hv = ui.hoverImpulse, p.rect.contains(hv), count > 0 {
                let tms = p.xValue(hv.x)
                let i = min(count - 1, max(0, Int((tms / 1000 * a.sampleRate).rounded())))
                var line = Path(); line.move(to: CGPoint(x: hv.x, y: p.rect.minY)); line.addLine(to: CGPoint(x: hv.x, y: p.rect.maxY))
                ctx.stroke(line, with: .color(Color.white.opacity(0.25)), lineWidth: 1)
                let rows: [(Int?, String)] = visible.map { s in
                    let v = a.impulse[s][i]
                    return (s, String(format: "%@  %+.4f (%.1f dBFS)", VizTheme.name(s), v, 20 * log10(max(abs(v), 1e-9))))
                }
                drawTooltip(&ctx, at: hv, bounds: CGRect(origin: .zero, size: size),
                            title: String(format: "%.3f ms · sample %d", Double(i) / a.sampleRate * 1000, i), rows: rows)
            }
        }
        .onContinuousHover { phase in
            switch phase { case .active(let pt): ui.hoverImpulse = pt; case .ended: ui.hoverImpulse = nil }
        }
    }
}
