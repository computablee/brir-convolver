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
    /// Speaker order of 16-channel BRIR files.
    @Published var multichannelMapping: SpeakerOrder { didSet { defaults.set(multichannelMapping.rawValue, forKey: "multichannelMapping"); reloadIR() } }
    @Published var outputUID: String { didSet { defaults.set(outputUID, forKey: "outputUID"); restartIfRunning() } }
    /// Capture device UID; "" = system audio via the stereo process tap.
    @Published var inputUID: String { didSet { defaults.set(inputUID, forKey: "inputUID"); restartIfRunning() } }
    /// Channel order of the capture device; nil = automatic (the device's speaker configuration).
    @Published var inputLayout: SpeakerOrder? { didSet { defaults.set(inputLayout?.rawValue ?? "", forKey: "inputLayout"); restartIfRunning() } }
    /// Level of LFE input channels in dB; nil = LFE discarded.
    @Published var lfeGainDB: Double? { didSet { defaults.set(lfeGainDB ?? AppState.lfeOff, forKey: "lfeGainDB"); restartIfRunning() } }
    /// Adaptive preamp (dB, ≤ 0): starts at 0 dB and only ever drops, by the least needed to avoid clipping.
    /// Written from the audio thread's value; persisted so a restart doesn't jump back up in level.
    @Published private(set) var preampDB: Double { didSet { defaults.set(preampDB, forKey: "adaptivePreampDB") } }
    @Published private(set) var preampReductions = 0
    @Published var enabled: Bool {
        didSet {
            defaults.set(enabled, forKey: "enabled")
            if enabled { start() } else { stop(); restoreDefaultOutput() }
        }
    }
    /// Use the bundled BRIR Convolver Surround device automatically while a multichannel BRIR is loaded.
    @Published var useVirtualDevice: Bool {
        didSet { defaults.set(useVirtualDevice, forKey: "useVirtualDevice"); surroundSuspended = false; restartIfRunning() }
    }
    /// Speaker positions used with directional BRIR folders.
    @Published private(set) var speakerPositions: [Speaker: Direction] = [:]
    /// Stock sound used by the surround test.
    @Published var testSound: String { didSet { defaults.set(testSound, forKey: "testSound") } }
    @Published var bypass: Bool { didSet { defaults.set(bypass, forKey: "bypass"); pipeline?.convolver?.setBypass(bypass) } }
    /// Momentary A/B (not persisted): while true, output is the dry signal with the preamp applied.
    @Published var abHeld = false { didSet { pipeline?.convolver?.setABHold(abHeld) } }
    @Published var blockSize: Int { didSet { defaults.set(blockSize, forKey: "blockSize"); restartIfRunning() } }
    @Published var driftCompensation: Bool { didSet { defaults.set(driftCompensation, forKey: "driftCompensation"); restartIfRunning() } }
    @Published var extraExclusions: String { didSet { defaults.set(extraExclusions, forKey: "extraExclusions") } }
    /// Which speaker pair the analysis window shows.
    @Published var analysisPair: SpeakerPair = .front { didSet { if let ir = sourceIR { analyzeIR(ir) } } }

    static let lfeOff = -1000.0
    static let lfeChoices: [Double?] = [nil, -10, -6, -3, 0, 3, 6, 10]

    // MARK: Live state
    @Published private(set) var irInfo: String = "No BRIR loaded"
    @Published private(set) var irError: String?
    @Published private(set) var irChannels = 0
    @Published private(set) var availablePairs: [SpeakerPair] = []
    @Published private(set) var devices: [AudioDeviceInfo] = []
    @Published private(set) var inputDevices: [AudioDeviceInfo] = []
    @Published private(set) var status: String = "Stopped"
    @Published private(set) var running = false
    @Published private(set) var lastError: String?
    @Published private(set) var excludedNames: [String] = []
    @Published private(set) var detail: String = ""
    @Published private(set) var routingInfo: String = ""
    @Published var meters = Meters()
    @Published private(set) var analysis: IRAnalysis?
    @Published private(set) var analyzing = false
    @Published private(set) var analysisID = 0
    /// Length of the longest FIR path currently loaded in the convolver, at the processing rate.
    @Published private(set) var firTaps = 0
    @Published private(set) var firRate = 0.0

    @Published private(set) var virtualDeviceInstalled = false
    /// True while the surround device is the macOS output and the convolver captures from it.
    @Published private(set) var surroundActive = false
    /// Set when switching to the surround device had to stop (a loop or an output tug-of-war).
    @Published private(set) var surroundSuspended = false
    @Published private(set) var testPlaying = false
    @Published private(set) var testSpeaker: Speaker?
    @Published private(set) var isDirectionalFolder = false
    /// Directions chosen for each speaker of a directional folder (for display).
    @Published private(set) var chosenDirections: [String] = []

    private var virtualDeviceID: AudioObjectID?
    private static let restoreKey = "restoreOutputUID"
    private var reclaimTimes: [Date] = []
    private var testSegments: [(speaker: Speaker, start: Int)] = []
    private var meterTicks = 0
    private var positionsReload: DispatchWorkItem?

    /// Whether the next start should use the surround device.
    var wantsSurround: Bool {
        enabled && useVirtualDevice && !surroundSuspended && virtualDeviceID != nil && (sourceIR?.speakers.count ?? 0) > 2
    }
    /// Capture device actually used: the surround device in surround mode, else the chosen one (nil = system tap).
    var effectiveInputUID: String? { wantsSurround ? VirtualDevice.uid : (inputUID.isEmpty ? nil : inputUID) }
    var usingSystemTap: Bool { effectiveInputUID == nil }
    var irIsMultichannel: Bool { (sourceIR?.speakers.count ?? 0) > 2 }

    struct Meters: Equatable {
        var inL = -120.0, inR = -120.0, outL = -120.0, outR = -120.0
        var clips = 0
        var nonFiniteInput = 0
        var callbacks: UInt64 = 0
        var starved: UInt64 = 0
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

    private var sourceIR: BRIRSet?
    private var irCache: [Double: BRIRSet] = [:]
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
        multichannelMapping = SpeakerOrder(rawValue: d.string(forKey: "multichannelMapping") ?? "") ?? .standard
        outputUID = d.string(forKey: "outputUID") ?? AppState.systemDefaultUID
        inputUID = d.string(forKey: "inputUID") ?? ""
        inputLayout = SpeakerOrder(rawValue: d.string(forKey: "inputLayout") ?? "")
        let lfe = d.object(forKey: "lfeGainDB") as? Double ?? 0
        lfeGainDB = lfe <= AppState.lfeOff ? nil : lfe
        preampDB = min(0, d.object(forKey: "adaptivePreampDB") as? Double ?? 0)
        enabled = d.object(forKey: "enabled") as? Bool ?? false
        bypass = d.bool(forKey: "bypass")
        blockSize = d.object(forKey: "blockSize") as? Int ?? 256
        driftCompensation = d.object(forKey: "driftCompensation") as? Bool ?? true
        extraExclusions = d.string(forKey: "extraExclusions") ?? ""
        useVirtualDevice = d.object(forKey: "useVirtualDevice") as? Bool ?? true
        testSound = d.string(forKey: "testSound") ?? "Funk"
        if let data = d.data(forKey: "speakerPositions"),
           let raw = try? JSONDecoder().decode([String: Direction].self, from: data) {
            for (k, v) in raw { if let sp = Speaker(rawValue: k) { speakerPositions[sp] = v } }
        }

        refreshDevices()
        installSystemListeners()
        if !irPath.isEmpty { loadIR(url: URL(fileURLWithPath: irPath), keepPreamp: true) }
        if enabled { start() }

        meterTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 15.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollMeters() }
        }
    }

    // MARK: IR

    /// Load a BRIR file. A different file starts the adaptive preamp again from 0 dB.
    func loadIR(url: URL, keepPreamp: Bool = false) {
        do {
            let isNewFile = url.path != irPath
            let ir: BRIRSet
            var wav: WAVFile?
            if DirectionalFolder.isDirectional(url) {
                ir = try BRIRSet(folder: try DirectionalFolder(url: url), positions: speakerPositions)
                isDirectionalFolder = true
                irChannels = 0
            } else {
                let w = try WAVFile(url: url)
                ir = try BRIRSet(wav: w, order: channelOrder, mapping: multichannelMapping)
                wav = w
                isDirectionalFolder = false
                irChannels = w.channelCount
            }
            chosenDirections = ir.chosen
            sourceIR = ir
            irCache = [ir.sampleRate: ir]
            availablePairs = ir.availablePairs
            if !availablePairs.contains(analysisPair) { analysisPair = .front }
            analyzeIR(ir)
            irError = nil
            irPath = url.path
            if !keepPreamp || isNewFile { resetPreamp() }
            let ms = Double(ir.length) / ir.sampleRate * 1000
            let bits = wav.map { "\($0.bitsPerSample)-bit \($0.isFloat ? "float" : "PCM"), " } ?? ""
            irInfo = "\(url.lastPathComponent) — \(ir.format) (\(ir.speakerList)), \(Int(ir.sampleRate)) Hz, "
                + "\(bits)\(ir.length) samples (\(String(format: "%.0f", ms)) ms)"
            restartIfRunning()
        } catch {
            irError = error.localizedDescription
            sourceIR = nil
            irChannels = 0
            availablePairs = []
            isDirectionalFolder = false
            chosenDirections = []
            irInfo = "No BRIR loaded"
            stop(keepEnabled: true)
        }
    }

    private func analyzeIR(_ set: BRIRSet) {
        guard let ir = set.pair(analysisPair) ?? set.pair(.front) else { return }
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

    private func ir(at rate: Double) -> BRIRSet? {
        guard let src = sourceIR else { return nil }
        if let c = irCache[rate] { return c }
        let r = src.resampled(to: rate)
        irCache[rate] = r
        return r
    }

    func position(_ s: Speaker) -> Direction { speakerPositions[s] ?? s.defaultDirection }

    /// Move a speaker of a directional folder; the folder is re-read shortly after the last change.
    func setPosition(_ s: Speaker, _ d: Direction) {
        speakerPositions[s] = d
        savePositions()
        schedulePositionsReload()
    }

    func resetPositions() {
        speakerPositions = [:]
        savePositions()
        schedulePositionsReload()
    }

    private func savePositions() {
        let raw = Dictionary(uniqueKeysWithValues: speakerPositions.map { ($0.key.rawValue, $0.value) })
        defaults.set(try? JSONEncoder().encode(raw), forKey: "speakerPositions")
    }

    private func schedulePositionsReload() {
        guard isDirectionalFolder else { return }
        positionsReload?.cancel()
        let w = DispatchWorkItem { [weak self] in Task { @MainActor in self?.reloadIR() } }
        positionsReload = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: w)
    }

    /// Raise the adaptive preamp back to 0 dB; it drops again only as far as the audio requires.
    func resetPreamp() {
        preampDB = 0
        preampReductions = 0
        if let c = pipeline?.convolver {
            c.requestGainReset()
            c.params[Convolver.Param.reductions] = 0
        }
    }

    /// Role of each captured channel.
    private func inputRoles(channels: Int) -> [InputRole] {
        if usingSystemTap { return Routing.defaultRoles(count: channels) }
        if let manual = inputLayout {
            let sp = manual.speakers
            return (0..<channels).map { $0 < sp.count ? .speaker(sp[$0]) : .unused }
        }
        if let uid = effectiveInputUID, let dev = CA.device(forUID: uid),
           let labels = CA.speakerLabels(dev), let roles = CA.roles(for: labels) {
            // The layout may describe fewer or more channels than the device has.
            return (0..<channels).map { $0 < roles.count ? roles[$0] : .unused }
        }
        return Routing.defaultRoles(count: channels)
    }

    // MARK: Devices & processes

    func refreshDevices() {
        devices = CA.outputDevices().filter { $0.uid != VirtualDevice.uid }
        inputDevices = CA.inputDevices()
        virtualDeviceID = VirtualDevice.deviceID
        virtualDeviceInstalled = virtualDeviceID != nil
    }

    // MARK: Surround device

    /// Make the surround device the macOS output, remembering what it replaces (e.g. GraphWorks EQ).
    private func claimDefaultOutput() {
        guard let v = virtualDeviceID else { return }
        if let cur = CA.defaultOutputDevice(), cur != v, let u = CA.deviceUID(cur) {
            defaults.set(u, forKey: AppState.restoreKey)
        }
        if CA.defaultOutputDevice() != v { CA.setDefaultOutputDevice(v) }
    }

    /// Put back the macOS output the surround device replaced.
    func restoreDefaultOutput() {
        defer { defaults.removeObject(forKey: AppState.restoreKey) }
        guard let v = virtualDeviceID ?? VirtualDevice.deviceID, CA.defaultOutputDevice() == v,
              let u = defaults.string(forKey: AppState.restoreKey), let d = CA.device(forUID: u) else { return }
        CA.setDefaultOutputDevice(d)
    }

    /// The macOS output changed away from the surround device while it was in use: treat the new device
    /// as where the convolved audio should go, and take the default back. If this keeps happening
    /// (another app insists on being the default), give up rather than fight.
    private func reclaimDefaultOutput(newDevice: AudioObjectID) {
        let now = Date()
        reclaimTimes = reclaimTimes.filter { now.timeIntervalSince($0) < 5 } + [now]
        if reclaimTimes.count > 4 {
            suspendSurround("Another app keeps changing the macOS output, so the surround device was turned off. "
                            + "Re-enable it under Input once that app leaves the output alone.")
            return
        }
        if let u = CA.deviceUID(newDevice) { defaults.set(u, forKey: AppState.restoreKey) }
        scheduleRestart()
    }

    /// Feedback guard: an EQ app (GraphWorks EQ or anything on the exclusion list) playing *into* the surround
    /// device means its output follows the system default, which would loop our output back to our input.
    private func checkForFeedbackLoop() {
        guard surroundActive, let v = virtualDeviceID else { return }
        let me = getpid()
        let pats = exclusionPatterns
        for p in CA.processObjects() where p.pid != me {
            let hay = (p.bundleID + " " + p.path).lowercased()
            guard pats.contains(where: { hay.contains($0) }) else { continue }
            if CA.processOutputDevices(p.objectID).contains(v) {
                suspendSurround("\(p.displayName) is sending its output to the system default, which is now the surround "
                                + "device; that would feed the convolved audio back into itself. Set its output to your "
                                + "DAC (not System Default), then re-enable the surround device under Input.")
                return
            }
        }
    }

    private func suspendSurround(_ message: String) {
        surroundSuspended = true
        surroundActive = false
        reclaimTimes = []
        lastError = message
        restoreDefaultOutput()
        scheduleRestart()
    }

    func resumeSurround() {
        surroundSuspended = false
        lastError = nil
        restartIfRunning()
    }

    func installVirtualDevice() {
        do {
            try VirtualDevice.install()
            lastError = nil
            status = "Surround device installed — Core Audio is restarting…"
        } catch {
            lastError = "Installing the surround device: \(error.localizedDescription)"
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            self?.refreshDevices()
            self?.restartIfRunning()
        }
    }

    func uninstallVirtualDevice() {
        stop(keepEnabled: true)
        restoreDefaultOutput()
        do {
            try VirtualDevice.uninstall()
            lastError = nil
        } catch {
            lastError = "Removing the surround device: \(error.localizedDescription)"
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            self?.refreshDevices()
            self?.restartIfRunning()
        }
    }

    /// Called when the app quits.
    func prepareForQuit() {
        stop(keepEnabled: true)
        restoreDefaultOutput()
    }

    // MARK: Surround test

    var availableTestSounds: [String] { SurroundTest.availableSounds() }

    /// Play the test sound from each virtual speaker in turn, through the convolver (live input is muted meanwhile).
    func runSurroundTest() {
        guard running, pipeline?.convolver != nil, let ir = ir(at: firRate) else { return }
        let sound = testSound
        testPlaying = true
        testSpeaker = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try SurroundTest.make(sound: sound, brir: ir) }
            DispatchQueue.main.async {
                switch result {
                case .success(let plan):
                    if let conv = self.pipeline?.convolver, conv.startTest(left: plan.left, right: plan.right) {
                        self.testSegments = plan.segments
                    } else {
                        self.testPlaying = false
                    }
                case .failure(let e):
                    self.testPlaying = false
                    self.lastError = "Surround test: \(e.localizedDescription)"
                }
            }
        }
    }

    func stopSurroundTest() { pipeline?.convolver?.stopTest() }

    private func updateTestState(_ c: Convolver) {
        let playing = c.testActive
        let pos = c.testPosition
        let spk = playing ? testSegments.last(where: { $0.start <= pos })?.speaker : nil
        if testSpeaker != spk { testSpeaker = spk }
        if !playing && testPlaying && c.testFinished { testPlaying = false; testSegments = [] }
    }

    /// Where convolved audio goes: the chosen device, else the macOS output — or, while the surround device
    /// is the macOS output, the device it replaced (e.g. GraphWorks EQ).
    var resolvedOutputUID: String? {
        if outputUID != AppState.systemDefaultUID, outputUID != VirtualDevice.uid, CA.device(forUID: outputUID) != nil { return outputUID }
        let def = CA.defaultOutputDevice().flatMap(CA.deviceUID)
        if def == VirtualDevice.uid {
            guard let u = defaults.string(forKey: AppState.restoreKey), CA.device(forUID: u) != nil else { return nil }
            return u
        }
        return def
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
                if self.surroundActive {
                    if let cur = CA.defaultOutputDevice(), cur != self.virtualDeviceID { self.reclaimDefaultOutput(newDevice: cur) }
                    return
                }
                if self.outputUID == AppState.systemDefaultUID { self.scheduleRestart() }
            }
        }
        CA.listen(CA.system, kAudioHardwarePropertyDevices) { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                let hadSurroundDevice = self.virtualDeviceID != nil
                self.refreshDevices()
                if hadSurroundDevice != (self.virtualDeviceID != nil) { self.scheduleRestart(); return }
                if self.running, let uid = self.resolvedOutputUID, CA.device(forUID: uid) != self.observedDevice {
                    self.scheduleRestart()
                }
            }
        }
        CA.listen(CA.system, kAudioHardwarePropertyProcessObjectList) { [weak self] in
            Task { @MainActor in
                guard let self, self.running else { return }
                self.checkForFeedbackLoop()
                guard self.usingSystemTap else { return }
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
        let surround = wantsSurround
        if surround { claimDefaultOutput() } else { restoreDefaultOutput() }
        surroundActive = surround
        guard let uid = resolvedOutputUID, let dev = CA.device(forUID: uid) else {
            status = surround ? "Choose an output under Output (the macOS output is now \(VirtualDevice.name))" : "No output device"
            return
        }
        // Never tap ourselves: that would feed our own output back into the convolver.
        guard CA.processObject(forPID: getpid()) != nil else {
            status = "Waiting for Core Audio…"
            scheduleRestart()
            return
        }
        let excl = usingSystemTap ? computeExclusions() : (ids: Set<AudioObjectID>(), names: [String]())
        let p = AudioPipeline()
        do {
            let rate = try p.prepare(.init(outputUID: uid, inputUID: effectiveInputUID,
                                           excludedProcesses: Array(excl.ids), driftCompensation: driftCompensation))
            guard let ir = ir(at: rate) else { p.stop(); return }
            let roles = inputRoles(channels: p.inputChannels)
            let routing = Routing.make(brir: ir, roles: roles, lfeGain: lfeGainDB.map { pow(10, $0 / 20) } ?? 0)
            let conv = Convolver(routing: routing, sampleRate: rate, blockSize: blockSize, gainDB: preampDB, bypass: bypass)
            conv.setABHold(abHeld)
            conv.params[Convolver.Param.reductions] = Double(preampReductions)
            routingInfo = routing.summary
            try p.start(convolver: conv)
            pipeline = p
            firTaps = ir.length
            firRate = rate
            currentExclusions = excl.ids
            excludedNames = excl.names
            observedDevice = dev
            observeRate(of: dev)
            running = true
            if !surroundSuspended { lastError = nil }
            let resampled = sourceIR.map { $0.sampleRate != rate } ?? false
            status = "Running → \(p.outputName)"
            let latencyMs = Double(blockSize) / rate * 1000
            detail = "\(Int(rate)) Hz · \(p.inputDescription) · \(conv.sourceCount) virtual speakers · "
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
        surroundActive = false
        testPlaying = false
        testSpeaker = nil
        if !keepEnabled || !enabled { status = "Stopped"; detail = ""; routingInfo = "" }
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
        typealias K = Convolver.Param
        var m = meters
        // Peak hold with ~20 dB/s fall
        let fall = 20.0 / 15.0
        m.inL = max(db(P[K.peakInL]), meters.inL - fall)
        m.inR = max(db(P[K.peakInR]), meters.inR - fall)
        m.outL = max(db(P[K.peakOutL]), meters.outL - fall)
        m.outR = max(db(P[K.peakOutR]), meters.outR - fall)
        P[K.peakInL] = 0; P[K.peakInR] = 0; P[K.peakOutL] = 0; P[K.peakOutR] = 0
        m.clips = Int(P[K.clips])
        m.nonFiniteInput = Int(P[K.nonFiniteInput])
        m.callbacks = p.callbacks
        m.starved = p.starvedCallbacks
        updateTestState(c)
        meterTicks += 1
        if meterTicks % 30 == 0 { checkForFeedbackLoop() }   // every 2 s
        let g = c.gainDB
        if abs(g - preampDB) > 0.001 { preampDB = min(0, g) }
        let red = Int(P[K.reductions])
        if red != preampReductions { preampReductions = red }
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

    func resetClips() { pipeline?.convolver?.params[Convolver.Param.clips] = 0 }

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
