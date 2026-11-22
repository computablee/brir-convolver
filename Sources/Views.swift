import SwiftUI
import UniformTypeIdentifiers

/// Transient UI state (kept out of @State so the app builds with a plain swiftc toolchain).
final class UIState: ObservableObject {
    static let shared = UIState()
    @Published var importing = false
    @Published var dropTargeted = false
}

struct MainView: View {
    @ObservedObject var state = AppState.shared
    @ObservedObject private var ui = UIState.shared
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Form {
            Section {
                HStack(alignment: .center, spacing: 12) {
                    Image(systemName: "waveform.path.ecg")
                        .font(.system(size: 28, weight: .light))
                        .foregroundStyle(state.irError == nil ? Color.accentColor : .red)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(state.irInfo).font(.callout).lineLimit(2)
                        if let e = state.irError { Text(e).font(.caption).foregroundStyle(.red) }
                        else if let s = state.peakSafeDB {
                            Text("Peak-safe preamp: \(s, specifier: "%.2f") dB").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button("Analysis…") { openWindow(id: "viz") }
                    Button("Choose WAV…") { ui.importing = true }
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(ui.dropTargeted ? Color.accentColor : .clear, style: StrokeStyle(lineWidth: 2, dash: [6])))
                .onDrop(of: [.fileURL], isTargeted: $ui.dropTargeted) { providers in
                    guard let p = providers.first else { return false }
                    _ = p.loadObject(ofClass: URL.self) { url, _ in
                        if let url { Task { @MainActor in state.loadIR(url: url) } }
                    }
                    return true
                }
                Picker("Channel order", selection: $state.channelOrder) {
                    ForEach(ChannelOrder.allCases) { Text($0.label).tag($0) }
                }
            } header: { Text("Impulse response (drop a 4-channel true-stereo WAV here)") }

            Section("Processing") {
                Toggle("Enable system-wide convolution", isOn: $state.enabled)
                Toggle("Bypass (bit-exact passthrough, for A/B)", isOn: $state.bypass)
                    .disabled(!state.enabled)
                HStack {
                    Text("Preamp")
                    Slider(value: $state.preampDB, in: -30...12, step: 0.1).disabled(state.autoPreamp)
                    TextField("", value: $state.preampDB, format: .number.precision(.fractionLength(1)))
                        .frame(width: 56).multilineTextAlignment(.trailing).disabled(state.autoPreamp)
                    Text("dB").foregroundStyle(.secondary)
                }
                Toggle("Auto preamp (peak-safe: no frequency boosted above 0 dB)", isOn: $state.autoPreamp)
                Toggle("Safety limiter above −1 dBFS (off = purely linear)", isOn: $state.limiter)
            }

            Section("Output") {
                Picker("Send convolved audio to", selection: $state.outputUID) {
                    Text("System default output").tag(AppState.systemDefaultUID)
                    ForEach(state.devices) { d in Text(d.name).tag(d.uid) }
                }
                Text("For GraphWorks EQ: leave GraphWorks EQ as the macOS output (or pick it here). "
                     + "This app feeds GraphWorks EQ, which applies your headphone EQ last.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Status") {
                HStack {
                    Circle().fill(state.running ? (state.bypass ? Color.yellow : .green) : .gray).frame(width: 9, height: 9)
                    Text(state.running && state.bypass ? "\(state.status) (bypassed)" : state.status)
                    Spacer()
                    if state.running {
                        Text("DSP load \(state.meters.cpu * 100, specifier: "%.1f")%")
                            .monospacedDigit().foregroundStyle(.secondary)
                    }
                }
                if !state.detail.isEmpty { Text(state.detail).font(.caption).foregroundStyle(.secondary) }
                if let e = state.lastError { Text(e).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
                if state.running {
                    MeterRow(label: "In", l: state.meters.inL, r: state.meters.inR)
                    MeterRow(label: "Out", l: state.meters.outL, r: state.meters.outR)
                    if state.meters.clips > 0 {
                        HStack {
                            Text("⚠︎ \(state.meters.clips) samples over 0 dBFS — lower the preamp")
                                .font(.caption).foregroundStyle(.orange)
                            Spacer()
                            Button("Reset") { state.resetClips() }.controlSize(.small)
                        }
                    }
                }
                Text(state.excludedNames.isEmpty
                     ? "Not tapping: this app. (GraphWorks EQ not detected.)"
                     : "Not tapping: this app, \(state.excludedNames.joined(separator: ", "))")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Advanced") {
                Picker("Partition size (latency vs. CPU)", selection: $state.blockSize) {
                    ForEach([64, 128, 256, 512, 1024, 2048], id: \.self) { Text("\($0) samples").tag($0) }
                }
                Toggle("Tap drift compensation", isOn: $state.driftCompensation)
                HStack {
                    TextField("Also never tap (comma-separated bundle IDs / names)", text: $state.extraExclusions)
                    Button("Apply") { state.applyExclusionChanges() }
                }
                Toggle("Launch at login", isOn: Binding(get: { state.launchAtLogin }, set: { state.launchAtLogin = $0 }))
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 560, idealWidth: 620, minHeight: 640)
        .fileImporter(isPresented: $ui.importing, allowedContentTypes: [.wav, .audio]) { result in
            if case .success(let url) = result { state.loadIR(url: url) }
        }
    }
}

struct MeterRow: View {
    let label: String
    let l: Double
    let r: Double
    var body: some View {
        HStack(spacing: 8) {
            Text(label).font(.caption).frame(width: 28, alignment: .leading)
            VStack(spacing: 3) { MeterBar(db: l); MeterBar(db: r) }
            Text(String(format: "%5.1f", max(l, r))).font(.caption.monospacedDigit()).frame(width: 44, alignment: .trailing)
        }
    }
}

struct MeterBar: View {
    let db: Double
    var body: some View {
        GeometryReader { g in
            let frac = max(0, min(1, (db + 60) / 60))
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.15))
                Capsule().fill(db > -0.1 ? Color.red : db > -6 ? Color.orange : Color.green)
                    .frame(width: g.size.width * frac)
            }
        }
        .frame(height: 5)
    }
}

struct MenuContent: View {
    @ObservedObject var state = AppState.shared
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Toggle("Convolution enabled", isOn: $state.enabled)
        Toggle("Bypass", isOn: $state.bypass).disabled(!state.enabled)
        Divider()
        Text(state.status)
        Divider()
        Button("Open BRIR Convolver…") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        Button("BRIR Analysis…") {
            openWindow(id: "viz")
            NSApp.activate(ignoringOtherApps: true)
        }
        Button("Quit") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}
