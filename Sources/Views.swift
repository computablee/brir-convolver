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
                Picker("4-channel order", selection: $state.channelOrder) {
                    ForEach(ChannelOrder.allCases) { Text($0.label).tag($0) }
                }
                .disabled(state.irChannels != 4)
                Picker("16-channel speaker order", selection: $state.multichannelMapping) {
                    ForEach(SpeakerOrder.allCases) { Text($0.label).tag($0) }
                }
                .disabled(state.irChannels != 16)
            } header: { Text("Impulse response (drop a true-stereo, HeSuVi 14-channel or ASH 16-channel WAV here)") }

            Section("Input") {
                Picker("Capture", selection: $state.inputUID) {
                    Text("System audio (stereo tap of all apps)").tag("")
                    ForEach(state.inputDevices) { d in Text("\(d.name) (\(d.inputChannels) ch)").tag(d.uid) }
                }
                Picker("Channel layout", selection: $state.inputLayout) {
                    Text("Automatic (device's speaker configuration)").tag(SpeakerOrder?.none)
                    ForEach(SpeakerOrder.allCases) { Text($0.rawValue).tag(SpeakerOrder?.some($0)) }
                }
                .disabled(state.usingSystemTap)
                Picker("LFE level", selection: $state.lfeGainDB) {
                    ForEach(AppState.lfeChoices, id: \.self) { v in
                        Text(v.map { String(format: "%+.0f dB", $0) } ?? "Off").tag(v)
                    }
                }
                .disabled(state.usingSystemTap)
                Text(state.usingSystemTap
                     ? "Stereo only: the front speaker pair of a 7.1 BRIR is used. For surround, install a loopback driver "
                       + "(e.g. BlackHole 8ch), set it to 7.1 in Audio MIDI Setup → Configure Speakers, make it the macOS output, "
                       + "and pick it here."
                     : "Apps play into this device and BRIR Convolver plays the result to the Output below, which must be a "
                       + "different device (your DAC or GraphWorks EQ, not the system default).")
                    .font(.caption).foregroundStyle(.secondary)
                if !state.routingInfo.isEmpty {
                    Text(state.routingInfo).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }

            Section("Processing") {
                Toggle("Enable system-wide convolution", isOn: $state.enabled)
                Toggle("Bypass (passthrough, no preamp; multichannel input is downmixed to stereo)", isOn: $state.bypass)
                    .disabled(!state.enabled)
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("A/B")
                        Text("Hold to hear the original without the BRIR. The preamp stays on so the levels can be matched.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(action: {}) {
                        Text(state.abHeld ? "Original (dry)" : "Hold for A/B")
                            .frame(minWidth: 110)
                    }
                    .buttonStyle(HoldButtonStyle(held: state.abHeld) { state.abHeld = $0 })
                    .disabled(!state.running || state.bypass)
                }
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Preamp (adaptive)")
                        Text("Starts at 0 dB and drops only as far as needed to keep the output below 0 dBFS. "
                             + "It never rises on its own; reset it after something loud."
                             + (state.preampReductions > 0 ? " Lowered \(state.preampReductions)× since the last reset." : ""))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(String(format: "%.2f dB", state.preampDB)).monospacedDigit()
                    Button("Reset to 0 dB") { state.resetPreamp() }
                        .disabled(state.preampDB == 0)
                }
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
                    Circle().fill(state.running ? (state.bypass || state.abHeld ? Color.yellow : .green) : .gray).frame(width: 9, height: 9)
                    Text(state.running && state.abHeld ? "\(state.status) (A/B: dry)"
                         : state.running && state.bypass ? "\(state.status) (bypassed)" : state.status)
                    Spacer()
                    if state.running {
                        HStack(spacing: 14) {
                            Text("Added delay \(state.meters.addedDelayMs, specifier: "%.1f") ms")
                                .help("Latency this app adds between an app's audio and the output device: "
                                      + "Core Audio capture→output plus the convolver partition. See the breakdown below.")
                            Text("DSP \(state.meters.computeAvgMs, specifier: "%.3f") ms (peak \(state.meters.computeMaxMs, specifier: "%.3f"))")
                                .help(String(format: "Time spent computing each audio callback of %d frames: average %.3f ms, recent worst %.3f ms, deadline %.2f ms.",
                                             state.meters.callbackFrames, state.meters.computeAvgMs, state.meters.computeMaxMs, state.meters.budgetMs))
                            Text("Load \(state.meters.cpu * 100, specifier: "%.1f")%")
                                .help("Average compute time as a share of the time available per callback. Dropouts start near 100%.")
                        }
                        .monospacedDigit().foregroundStyle(.secondary)
                    }
                }
                if !state.detail.isEmpty { Text(state.detail).font(.caption).foregroundStyle(.secondary) }
                if state.running {
                    let m = state.meters
                    Text(String(format: "Delay: I/O %.1f ms + partition %.1f ms = %.1f ms added · output device reports %.1f ms",
                                m.ioMs, m.partitionMs, m.addedDelayMs, m.downstreamMs))
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    Text(String(format: "Compute: %.3f ms average, %.3f ms recent peak per %d-frame callback, against a %.2f ms deadline (%.0f× headroom at peak).",
                                m.computeAvgMs, m.computeMaxMs, m.callbackFrames, m.budgetMs, m.computeMaxMs > 0 ? m.budgetMs / m.computeMaxMs : 0))
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
                if let e = state.lastError { Text(e).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
                if state.running {
                    MeterRow(label: "In", l: state.meters.inL, r: state.meters.inR)
                    MeterRow(label: "Out", l: state.meters.outL, r: state.meters.outR)
                    if state.meters.clips > 0 {
                        HStack {
                            Text("⚠︎ \(state.meters.clips) samples over 0 dBFS (bypass / A/B passthrough)")
                                .font(.caption).foregroundStyle(.orange)
                            Spacer()
                            Button("Reset") { state.resetClips() }.controlSize(.small)
                        }
                    }
                }
                if state.usingSystemTap {
                    Text(state.excludedNames.isEmpty
                         ? "Not tapping: this app. (GraphWorks EQ not detected.)"
                         : "Not tapping: this app, \(state.excludedNames.joined(separator: ", "))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("Advanced") {
                Picker("Partition size (latency vs. CPU)", selection: $state.blockSize) {
                    ForEach([64, 128, 256, 512, 1024, 2048], id: \.self) { Text("\($0) samples").tag($0) }
                }
                Toggle("Drift compensation (tap or capture device)", isOn: $state.driftCompensation)
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

/// Momentary button: reports press and release so the app can act while it's held.
struct HoldButtonStyle: ButtonStyle {
    let held: Bool
    let onChange: (Bool) -> Void
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 12).padding(.vertical, 5)
            .foregroundStyle(held ? Color.black : Color.primary)
            .background(RoundedRectangle(cornerRadius: 6)
                .fill(held ? Color.yellow : Color.secondary.opacity(0.18)))
            .contentShape(RoundedRectangle(cornerRadius: 6))
            .onChange(of: configuration.isPressed) { _, pressed in onChange(pressed) }
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
