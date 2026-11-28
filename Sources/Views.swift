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
                    Button("Choose WAV or folder…") { ui.importing = true }
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
                if state.isDirectionalFolder {
                    DisclosureGroup("Speaker positions (nearest exported direction is used)") {
                        ForEach(Speaker.directional) { sp in
                            SpeakerPositionRow(speaker: sp)
                        }
                        HStack {
                            Text(state.chosenDirections.joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                            Spacer()
                            Button("Defaults") { state.resetPositions() }.controlSize(.small)
                        }
                    }
                }
            } header: {
                Text("Impulse response (drop a true-stereo, HeSuVi 14-channel or ASH 16-channel WAV, or a folder of ASH directional BRIRs)")
            }

            HeadTrackingSection()

            Section("Input") {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Toggle("Use the BRIR Convolver Surround device for surround BRIRs", isOn: $state.useVirtualDevice)
                        Text(state.virtualDeviceInstalled
                             ? "Installed. While a surround BRIR is loaded it becomes the macOS output; picking another output "
                               + "in macOS sends the convolved audio there instead (e.g. GraphWorks EQ)."
                             : "Not installed. Installing asks for your password once and restarts Core Audio.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if state.virtualDeviceInstalled {
                        Button("Uninstall…") { state.uninstallVirtualDevice() }
                    }
                    Button(state.virtualDeviceInstalled ? "Reinstall…" : "Install…") { state.installVirtualDevice() }
                        .disabled(!VirtualDevice.isBundled)
                }
                if state.surroundSuspended {
                    HStack {
                        Text("Surround device paused (see the message under Status).").font(.caption).foregroundStyle(.orange)
                        Spacer()
                        Button("Re-enable") { state.resumeSurround() }.controlSize(.small)
                    }
                }
                Picker("Capture", selection: $state.inputUID) {
                    Text("System audio (stereo tap of all apps)").tag("")
                    ForEach(state.inputDevices) { d in Text("\(d.name) (\(d.inputChannels) ch)").tag(d.uid) }
                }
                Picker("Channel layout", selection: $state.inputLayout) {
                    Text("Automatic (device's speaker configuration)").tag(SpeakerOrder?.none)
                    ForEach(SpeakerOrder.allCases) { Text($0.rawValue).tag(SpeakerOrder?.some($0)) }
                }
                .disabled(state.usingSystemTap || state.wantsSurround)
                Picker("LFE level", selection: $state.lfeGainDB) {
                    ForEach(AppState.lfeChoices, id: \.self) { v in
                        Text(v.map { String(format: "%+.0f dB", $0) } ?? "Off").tag(v)
                    }
                }
                .disabled(state.usingSystemTap)
                Text(state.wantsSurround
                     ? "Capturing 7.1.4 from \(VirtualDevice.name) (automatic while a surround BRIR is loaded)."
                     : state.usingSystemTap
                     ? "Stereo only: the front speaker pair of a surround BRIR is used. Load a surround BRIR with the "
                       + "surround device installed, or capture from another multichannel loopback device."
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

            Section("Surround test") {
                HStack {
                    Picker("Sound", selection: $state.testSound) {
                        ForEach(state.availableTestSounds, id: \.self) { Text($0).tag($0) }
                    }
                    .frame(maxWidth: 220)
                    Spacer()
                    if state.testPlaying {
                        Text(state.testSpeaker?.name ?? "Preparing…").monospacedDigit().foregroundStyle(.secondary)
                        Button("Stop") { state.stopSurroundTest() }
                    } else {
                        Button("Play from each speaker") { state.runSurroundTest() }
                            .disabled(!state.running || state.bypass)
                    }
                }
                Text("Plays the sound from each virtual speaker in turn (front left, centre, front right, around the back, "
                     + "then the heights), through the BRIR and preamp. Other audio is muted while it plays.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Output") {
                Picker("Send convolved audio to", selection: $state.outputUID) {
                    Text("System default output").tag(AppState.systemDefaultUID)
                    ForEach(state.devices) { d in Text(d.name).tag(d.uid) }
                }
                Text("For GraphWorks EQ: leave GraphWorks EQ as the macOS output (or pick it here). "
                     + "This app feeds GraphWorks EQ, which applies your headphone EQ last. While the surround device is "
                     + "the macOS output, “System default” means the device it replaced. Set GraphWorks EQ's own output "
                     + "to your DAC rather than System Default.")
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
                                .help(String(format: "Time spent computing each audio callback of %ld frames: average %.3f ms, recent worst %.3f ms, deadline %.2f ms.",
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
                    Text(String(format: "Compute: %.3f ms average, %.3f ms recent peak per %ld-frame callback, against a %.2f ms deadline (%.0f× headroom at peak). %llu callbacks, %llu with missing input.",
                                m.computeAvgMs, m.computeMaxMs, m.callbackFrames, m.budgetMs, m.computeMaxMs > 0 ? m.budgetMs / m.computeMaxMs : 0.0,
                                m.callbacks, m.starved))
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
                if let e = state.lastError { Text(e).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
                if state.running {
                    ChannelMeters(title: "In — click and hold a channel to hear only that channel",
                                  labels: state.inputLabels, levels: state.meters.inputs,
                                  solo: state.soloChannel, onSolo: { state.soloChannel = $0 })
                    if !state.receivingSummary.isEmpty {
                        Text(state.receivingSummary + "  (channels above −70 dBFS in the last 20 s)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    ChannelMeters(title: "Out", labels: ["L", "R"], levels: [state.meters.outL, state.meters.outR])
                    if let hint = state.captureHint {
                        Text("⚠︎ " + hint).font(.caption).foregroundStyle(.orange)
                    }
                    if state.meters.nonFiniteInput > 0 {
                        Text("⚠︎ \(state.meters.nonFiniteInput) input samples were NaN/infinite and were replaced with silence.")
                            .font(.caption).foregroundStyle(.orange)
                    }
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
        .onAppear { state.refreshLaunchAtLogin() }
        .frame(minWidth: 560, idealWidth: 620, minHeight: 640)
        .fileImporter(isPresented: $ui.importing, allowedContentTypes: [.wav, .audio, .folder]) { result in
            if case .success(let url) = result { state.loadIR(url: url) }
        }
    }
}

/// Elevation/azimuth steppers for one speaker of a directional BRIR folder.
struct SpeakerPositionRow: View {
    @ObservedObject var state = AppState.shared
    let speaker: Speaker
    var body: some View {
        let d = state.position(speaker)
        HStack {
            Text(speaker.name).frame(width: 120, alignment: .leading)
            Spacer()
            Stepper("Elevation \(d.elevation)°", value: Binding(
                get: { d.elevation },
                set: { state.setPosition(speaker, Direction(elevation: $0, azimuth: d.azimuth)) }), in: -90...90, step: 5)
                .monospacedDigit()
            Stepper("Azimuth \(d.azimuth)°", value: Binding(
                get: { d.azimuth },
                set: { state.setPosition(speaker, Direction(elevation: d.elevation, azimuth: $0)) }), in: -180...180, step: 5)
                .monospacedDigit()
        }
        .font(.callout)
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

/// One labelled bar per channel, under a title. With `onSolo`, pressing and holding a row solos that channel.
struct ChannelMeters: View {
    let title: String
    let labels: [String]
    let levels: [Double]
    var solo: Int? = nil
    var onSolo: ((Int?) -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption.weight(.semibold))
            ForEach(Array(levels.enumerated()), id: \.offset) { i, db in
                if let onSolo {
                    Button(action: {}) { row(i, db) }
                        .buttonStyle(PressReportingStyle(highlighted: solo == i) { onSolo($0 ? i : nil) })
                        .help("Hold to hear only \(label(i))")
                } else {
                    row(i, db)
                }
            }
        }
    }

    private func label(_ i: Int) -> String { i < labels.count ? labels[i] : "\(i + 1)" }

    private func row(_ i: Int, _ db: Double) -> some View {
        HStack(spacing: 8) {
            Text(label(i))
                .font(.caption2.monospaced())
                .foregroundStyle(db > -70 ? Color.primary : Color.secondary)
                .frame(width: 30, alignment: .leading)
            MeterBar(db: db)
            Text(db <= -119.9 ? "—" : String(format: "%5.1f", db))
                .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                .frame(width: 40, alignment: .trailing)
        }
        .padding(.horizontal, 4).padding(.vertical, 1)
        .contentShape(Rectangle())
    }
}

/// Reports press and release of a plain-looking button (for hold-to-solo rows).
struct PressReportingStyle: ButtonStyle {
    let highlighted: Bool
    let onChange: (Bool) -> Void
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(RoundedRectangle(cornerRadius: 4).fill(highlighted ? Color.accentColor.opacity(0.25) : .clear))
            .onChange(of: configuration.isPressed) { _, pressed in onChange(pressed) }
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

/// Webcam head tracking (directional BRIR folders only). Observes the controller itself so its 20 Hz updates
/// redraw only this section.
struct HeadTrackingSection: View {
    @ObservedObject var ht = HeadTrackingController.shared

    var body: some View {
        Section("Head tracking") {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Toggle("Head tracking (webcam)", isOn: Binding(get: { ht.enabled }, set: { ht.setEnabled($0) }))
                        .disabled(!ht.available && !ht.enabled)
                    Text(caption).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if ht.enabled {
                    if ht.calibrated {
                        Button("Recenter") { ht.recenter() }
                            .disabled(!ht.faceVisible)
                            .help("Make the direction you're looking right now straight ahead.")
                    } else {
                        Button("Set straight ahead…") { ht.beginCalibration() }
                    }
                }
            }
            if ht.enabled {
                HStack {
                    Picker("Camera", selection: $ht.cameraID) {
                        Text("Default camera").tag("")
                        ForEach(ht.cameras) { Text($0.name).tag($0.id) }
                    }
                    Button("Refresh") { ht.refreshCameras() }.controlSize(.small)
                }
                HStack(spacing: 8) {
                    Circle().fill(!ht.cameraRunning ? Color.gray : ht.faceVisible ? .green : .orange).frame(width: 9, height: 9)
                    Text(status)
                    Spacer()
                    if ht.cameraRunning {
                        Text(String(format: "Head: %@, %@", Self.yawText(ht.pose.yaw), Self.pitchText(ht.pose.pitch)))
                            .monospacedDigit().foregroundStyle(.secondary)
                    }
                }
                Picker("Direction rounding", selection: $ht.rounding) {
                    ForEach(DirectionRounding.allCases) { Text($0.label).tag($0) }
                }
                .help("How the measured direction of each speaker picks an exported BRIR. Towards front: with files at "
                      + "0° and 5°, 0–4.99° uses 0° and 5–9.99° uses 5°. Applies to azimuth and elevation.")
                HStack(spacing: 16) {
                    Toggle("Reverse left/right", isOn: $ht.reverseYaw)
                    Toggle("Reverse up/down", isOn: $ht.reversePitch)
                }
                Text("Turn your head and check the readout above. If it reports the opposite direction, reverse that axis.")
                    .font(.caption).foregroundStyle(.secondary)
                if !ht.trackedSummary.isEmpty {
                    Text(ht.trackedSummary).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
            if let m = ht.message {
                Text(m).font(.caption).foregroundStyle(.orange).textSelection(.enabled)
            }
        }
        .sheet(isPresented: Binding(get: { ht.calibrationVisible }, set: { if !$0 { ht.cancelCalibration() } })) {
            CalibrationSheet()
        }
    }

    private var caption: String {
        if !ht.available {
            return "Available with a folder of ASH Toolset directional BRIRs. Uses Apple's Vision face tracking with a "
                + "webcam; camera access is asked for only when you turn this on."
        }
        if ht.enabled && !ht.attached { return "On. Tracking starts while convolution is running." }
        return "Each speaker stays put in the room as you turn: it uses the exported direction nearest to where it is "
            + "relative to your head."
    }

    private var status: String {
        if !ht.calibrated { return "Paused: straight ahead isn't set for this camera" }
        if !ht.cameraRunning { return "Camera off" }
        if ht.faceVisible { return "Tracking" }
        return "No face in view (holding the last position, then easing back to front)"
    }

    static func yawText(_ y: Double) -> String {
        abs(y) < 0.5 ? "facing forward" : String(format: "turned %.0f° %@", abs(y), y < 0 ? "left" : "right")
    }
    static func pitchText(_ p: Double) -> String {
        abs(p) < 0.5 ? "level" : String(format: "%.0f° %@", abs(p), p > 0 ? "up" : "down")
    }
}

/// Sets straight ahead: look forward, count down, capture.
struct CalibrationSheet: View {
    @ObservedObject var ht = HeadTrackingController.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Set straight ahead").font(.title2.weight(.semibold))
            Picker("Camera", selection: $ht.cameraID) {
                Text("Default camera").tag("")
                ForEach(ht.cameras) { Text($0.name).tag($0.id) }
            }
            .disabled(ht.calibrationPhase == .countdown || ht.calibrationPhase == .capturing)
            switch ht.calibrationPhase {
            case .ready:
                Text("Sit where you normally listen and look straight ahead, wherever the centre speaker should be. "
                     + "Press Start, keep looking there through the 3-second countdown, and hold still until the chime.")
                    .fixedSize(horizontal: false, vertical: true)
            case .countdown, .capturing:
                Text("Look straight ahead.").font(.title3)
                Text(ht.calibrationPhase == .countdown ? "\(ht.countdown)" : "Hold still…")
                    .font(.system(size: 40, weight: .light)).monospacedDigit()
            case .failed:
                Text((ht.calibrationProblem ?? "That didn't work.") + " If this camera can't see you, pick another above.")
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            case .done:
                Text("Done. Turn your head and the speakers should stay where they are in the room. If they move the "
                     + "wrong way, use the Reverse switches. Press Recenter whenever you want to make where you're "
                     + "looking straight ahead again.")
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                Circle().fill(ht.faceVisible ? Color.green : .orange).frame(width: 9, height: 9)
                if let r = ht.raw {
                    Text(String(format: "Face seen — Vision reports yaw %+.1f°, pitch %+.1f°", r.yaw, r.pitch)).monospacedDigit()
                } else {
                    Text(ht.cameraRunning ? "No face in view" : "Starting the camera…")
                }
            }
            .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Cancel") { ht.cancelCalibration() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                switch ht.calibrationPhase {
                case .ready:
                    Button("Start") { ht.startCalibration() }.keyboardShortcut(.defaultAction)
                case .failed:
                    Button("Try again") { ht.startCalibration() }.keyboardShortcut(.defaultAction)
                case .done:
                    Button("Done") { ht.finishCalibration() }.keyboardShortcut(.defaultAction)
                case .countdown, .capturing:
                    EmptyView()
                }
            }
        }
        .padding(24)
        .frame(width: 460)
    }
}
