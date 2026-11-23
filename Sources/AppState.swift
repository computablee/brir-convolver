import AppKit
import CoreAudio
import Foundation
import ServiceManagement
import SwiftUI

@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()
    static let systemDefaultUID = ""

    private let defaults = UserDefaults.standard

    // MARK: Persisted settings
    @Published var irPath: String { didSet { defaults.set(irPath, forKey: "irPath") } }
    @Published var channelOrder: ChannelOrder { didSet { defaults.set(channelOrder.rawValue, forKey: "channelOrder"); reloadIR() } }
    @Published var outputUID: String { didSet { defaults.set(outputUID, forKey: "outputUID"); restartIfRunning() } }
    @Published var preampDB: Double { didSet { defaults.set(preampDB, forKey: "preampDB"); pipeline?.convolver?.setGainDB(preampDB) } }
    @Published var autoPreamp: Bool { didSet { defaults.set(autoPreamp, forKey: "autoPreamp"); if autoPreamp, let s = peakSafeDB { preampDB = s } } }
    @Published var enabled: Bool { didSet { defaults.set(enabled, forKey: "enabled"); enabled ? start() : stop() } }
    @Published var bypass: Bool { didSet { defaults.set(bypass, forKey: "bypass"); pipeline?.convolver?.setBypass(bypass) } }
    @Published var limiter: Bool { didSet { defaults.set(limiter, forKey: "limiter"); pipeline?.convolver?.setLimiter(limiter) } }
    @Published var blockSize: Int { didSet { defaults.set(blockSize, forKey: "blockSize"); restartIfRunning() } }
    @Published var driftCompensation: Bool { didSet { defaults.set(driftCompensation, forKey: "driftCompensation"); restartIfRunning() } }
    @Published var extraExclusions: String { didSet { defaults.set(extraExclusions, forKey: "extraExclusions") } }

    // MARK: Live state
    @Published private(set) var irInfo: String = "No BRIR loaded"
    @Published private(set) var irError: String?
    @Published private(set) var peakSafeDB: Double?
    @Published private(set) var devices: [AudioDeviceInfo] = []
    @Published private(set) var status: String = "Stopped"
    @Published private(set) var running = false
    @Published private(set) var lastError: String?
    @Published private(set) var excludedNames: [String] = []
    @Published private(set) var detail: String = ""
    @Published var meters = Meters()
    @Published private(set) var analysis: IRAnalysis?
    @Published private(set) var analyzing = false
    @Published private(set) var analysisID = 0
    /// Length of the longest FIR path currently loaded in the convolver, at the processing rate.
    @Published private(set) var firTaps = 0
    @Published private(set) var firRate = 0.0

    struct Meters: Equatable {
        var inL = -120.0, inR = -120.0, outL = -120.0, outR = -120.0
        var clips = 0
        var cpu = 0.0
        var addedDelayMs = 0.0      // what this app adds: Core Audio capture→output + convolver partition
        var ioMs = 0.0
        var ioMeasured = false
        var expectedIOMs = 0.0
        var partitionMs = 0.0
        var downstreamMs = 0.0
        var computeAvgMs = 0.0      // DSP time per audio callback (average)
        var computeMaxMs = 0.0      // worst callback, decaying peak hold
        var budgetMs = 0.0          // time available per callback (callback frames / sample rate)
        var callbackFrames = 0      // output device's self-reported latency (not added by this app)
    }

    private var sourceIR: TrueStereoIR?
    private var irCache: [Double: TrueStereoIR] = [:]
    private var pipeline: AudioPipeline?
    private var currentExclusions: Set<AudioObjectID> = []
    private var observedDevice: AudioObjectID = 0
    private var rateListener: AudioObjectPropertyListenerBlock?
    private var restartWork: DispatchWorkItem?
    private var meterTimer: Timer?
    private var restarting = false

    private init() {
        let d = UserDefaults.standard
        irPath = d.string(forKey: "irPath") ?? ""
        channelOrder = ChannelOrder(rawValue: d.string(forKey: "channelOrder") ?? "") ?? .inputMajor
        outputUID = d.string(forKey: "outputUID") ?? AppState.systemDefaultUID
        preampDB = d.object(forKey: "preampDB") as? Double ?? -6
        autoPreamp = d.object(forKey: "autoPreamp") as? Bool ?? true
        enabled = d.object(forKey: "enabled") as? Bool ?? false
        bypass = d.bool(forKey: "bypass")
        limiter = d.bool(forKey: "limiter")
        blockSize = d.object(forKey: "blockSize") as? Int ?? 256
        driftCompensation = d.object(forKey: "driftCompensation") as? Bool ?? true
        extraExclusions = d.string(forKey: "extraExclusions") ?? ""

        refreshDevices()
        installSystemListeners()
        if !irPath.isEmpty { loadIR(url: URL(fileURLWithPath: irPath), keepPreamp: !autoPreamp) }
        if enabled { start() }

        meterTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 15.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollMeters() }
        }
    }

    // MARK: IR

    func loadIR(url: URL, keepPreamp: Bool = false) {
        do {
            let wav = try WAVFile(url: url)
            let ir = try TrueStereoIR(wav: wav, order: channelOrder)
            sourceIR = ir
            irCache = [ir.sampleRate: ir]
            analyzeIR(ir)
            irError = nil
            irPath = url.path
            let safe = ir.peakSafeGainDB()
            peakSafeDB = safe
            if autoPreamp || !keepPreamp { preampDB = (safe * 10).rounded(.down) / 10 }
            let ms = Double(wav.frameCount) / wav.sampleRate * 1000
            irInfo = "\(url.lastPathComponent) — \(wav.channelCount) ch, \(Int(wav.sampleRate)) Hz, "
                + "\(wav.bitsPerSample)-bit \(wav.isFloat ? "float" : "PCM"), \(wav.frameCount) samples (\(String(format: "%.0f", ms)) ms)"
            restartIfRunning()
        } catch {
            irError = error.localizedDescription
            sourceIR = nil
            irInfo = "No BRIR loaded"
            stop(keepEnabled: true)
        }
    }

    private func analyzeIR(_ ir: TrueStereoIR) {
        analysisID += 1
        let id = analysisID
        analyzing = true
        DispatchQueue.global(qos: .userInitiated).async {
            let a = IRAnalysis.compute(ir: ir)
            DispatchQueue.main.async {
                guard id == self.analysisID else { return }
                self.analysis = a
                self.analyzing = false
            }
        }
    }

    private func reloadIR() {
        guard !irPath.isEmpty else { return }
        loadIR(url: URL(fileURLWithPath: irPath), keepPreamp: true)
    }

    private func ir(at rate: Double) -> TrueStereoIR? {
        guard let src = sourceIR else { return nil }
        if let c = irCache[rate] { return c }
        let r = src.resampled(to: rate)
        irCache[rate] = r
        return r
    }

    // MARK: Devices & processes

    func refreshDevices() { devices = CA.outputDevices() }

    var resolvedOutputUID: String? {
        if outputUID != AppState.systemDefaultUID, CA.device(forUID: outputUID) != nil { return outputUID }
        return CA.defaultOutputDevice().flatMap(CA.deviceUID)
    }

    private var exclusionPatterns: [String] {
        ["graphworks", "gweq"] + extraExclusions
            .split(whereSeparator: { $0 == "," || $0 == "\n" })
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }
    }

    private func computeExclusions() -> (ids: Set<AudioObjectID>, names: [String]) {
        var ids = Set<AudioObjectID>()
        var names: [String] = []
        let me = getpid()
        if let own = CA.processObject(forPID: me) { ids.insert(own) }
        let pats = exclusionPatterns
        for p in CA.processObjects() {
            if p.pid == me { ids.insert(p.objectID); continue }
            let hay = (p.bundleID + " " + p.path).lowercased()
            if pats.contains(where: { hay.contains($0) }) {
                ids.insert(p.objectID)
                names.append(p.displayName)
            }
        }
        return (ids, names)
    }

    private func installSystemListeners() {
        CA.listen(CA.system, kAudioHardwarePropertyDefaultOutputDevice) { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                if self.outputUID == AppState.systemDefaultUID { self.scheduleRestart() }
            }
        }
        CA.listen(CA.system, kAudioHardwarePropertyDevices) { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.refreshDevices()
                if self.running, let uid = self.resolvedOutputUID, CA.device(forUID: uid) != self.observedDevice {
                    self.scheduleRestart()
                }
            }
        }
        CA.listen(CA.system, kAudioHardwarePropertyProcessObjectList) { [weak self] in
            Task { @MainActor in
                guard let self, self.running else { return }
                if self.computeExclusions().ids != self.currentExclusions { self.scheduleRestart() }
            }
        }
    }

    func applyExclusionChanges() { restartIfRunning() }

    // MARK: Lifecycle

    private func restartIfRunning() { if enabled { scheduleRestart() } }

    private func scheduleRestart() {
        guard enabled else { return }
        restartWork?.cancel()
        let w = DispatchWorkItem { [weak self] in
            Task { @MainActor in self?.start() }
        }
        restartWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: w)
    }

    func start() {
        guard !restarting else { return }
        restarting = true
        defer { restarting = false }
        stop(keepEnabled: true)
        guard enabled else { return }
        guard sourceIR != nil else { status = "Load a BRIR file to start"; return }
        guard let uid = resolvedOutputUID, let dev = CA.device(forUID: uid) else {
            status = "No output device"; return
        }
        // Never tap ourselves: that would feed our own output back into the convolver.
        guard CA.processObject(forPID: getpid()) != nil else {
            status = "Waiting for Core Audio…"
            scheduleRestart()
            return
        }
        let excl = computeExclusions()
        let p = AudioPipeline()
        do {
            let rate = try p.prepare(.init(outputUID: uid, excludedProcesses: Array(excl.ids),
                                           driftCompensation: driftCompensation))
            guard let ir = ir(at: rate) else { p.stop(); return }
            let conv = StereoConvolver(ir: ir, blockSize: blockSize, gainDB: preampDB, bypass: bypass, limiter: limiter)
            try p.start(convolver: conv)
            pipeline = p
            firTaps = ir.length
            firRate = rate
            currentExclusions = excl.ids
            excludedNames = excl.names
            observedDevice = dev
            observeRate(of: dev)
            running = true
            lastError = nil
            let resampled = sourceIR.map { $0.sampleRate != rate } ?? false
            let tf = p.tapFormat
            status = "Running → \(p.outputName)"
            let latencyMs = Double(blockSize) / rate * 1000
            detail = "\(Int(rate)) Hz · tap \(Int(tf.mSampleRate)) Hz/\(tf.mChannelsPerFrame) ch · "
                + "\(conv.partitions) partitions × \(blockSize) · +\(String(format: "%.1f", latencyMs)) ms · IO \(p.ioBufferFrames) frames"
                + (resampled ? " · IR resampled from \(Int(sourceIR!.sampleRate)) Hz" : " · IR native rate")
        } catch {
            p.stop()
            running = false
            lastError = error.localizedDescription
            status = "Error"
        }
    }

    func stop(keepEnabled: Bool = false) {
        pipeline?.stop()
        pipeline = nil
        if let l = rateListener, observedDevice != 0 {
            CA.unlisten(observedDevice, kAudioDevicePropertyNominalSampleRate, l)
        }
        rateListener = nil
        running = false
        if !keepEnabled || !enabled { status = "Stopped"; detail = "" }
        meters = Meters()
    }

    private func observeRate(of dev: AudioObjectID) {
        rateListener = CA.listen(dev, kAudioDevicePropertyNominalSampleRate) { [weak self] in
            Task { @MainActor in self?.scheduleRestart() }
        }
    }

    private func pollMeters() {
        guard let p = pipeline, let c = p.convolver else { return }
        func db(_ v: Double) -> Double { v > 0 ? max(-120, 20 * log10(v)) : -120 }
        let P = c.params
        typealias K = StereoConvolver.Param
        var m = meters
        // Peak hold with ~20 dB/s fall
        let fall = 20.0 / 15.0
        m.inL = max(db(P[K.peakInL]), meters.inL - fall)
        m.inR = max(db(P[K.peakInR]), meters.inR - fall)
        m.outL = max(db(P[K.peakOutL]), meters.outL - fall)
        m.outR = max(db(P[K.peakOutR]), meters.outR - fall)
        P[K.peakInL] = 0; P[K.peakInR] = 0; P[K.peakOutL] = 0; P[K.peakOutR] = 0
        m.clips = Int(P[K.clips])
        m.cpu = p.cpuLoad
        // Delay this app adds, from Core Audio timestamps (output sample time − tap input sample time
        // inside one IOProc cycle) plus the convolver's partition. The output device's own reported latency
        // is downstream of us and exists with or without this app, so it is reported separately.
        let sr = c.sampleRate
        let expected = Double(p.ioBufferFrames + p.aggregateOverheadFrames)
        m.ioMeasured = p.measuredIOFrames > 0
        let io = m.ioMeasured ? p.measuredIOFrames : expected
        m.ioMs = io / sr * 1000
        m.expectedIOMs = expected / sr * 1000
        m.partitionMs = Double(c.latencyFrames) / sr * 1000
        m.addedDelayMs = m.ioMs + m.partitionMs
        m.downstreamMs = Double(p.outputLatencyFrames) / sr * 1000
        m.computeAvgMs = p.computeAvg * 1000
        // Peak hold for ~2 s so short spikes stay readable
        let newMax = p.takeComputeMax() * 1000
        m.computeMaxMs = max(newMax, meters.computeMaxMs * 0.97)
        m.budgetMs = p.computeBudget * 1000
        m.callbackFrames = p.lastFrames
        if m != meters { meters = m }
    }

    func resetClips() { pipeline?.convolver?.params[StereoConvolver.Param.clips] = 0 }

    // MARK: Launch at login

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do { newValue ? try SMAppService.mainApp.register() : try SMAppService.mainApp.unregister() }
            catch { lastError = "Launch at login: \(error.localizedDescription)" }
            objectWillChange.send()
        }
    }
}
