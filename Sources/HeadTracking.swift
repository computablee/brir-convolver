import AppKit
import AVFoundation
import CoreMedia
import Foundation
import Vision

// MARK: - Angles

/// Head orientation in ASH Toolset's convention, in degrees: `yaw` is the azimuth the face points to
/// (negative = turned left), `pitch` the elevation (positive = looking up).
struct HeadPose: Equatable {
    var yaw: Double
    var pitch: Double
    static let forward = HeadPose(yaw: 0, pitch: 0)
}

/// Angles exactly as Apple's Vision reports them for a face, converted to degrees (Vision's own signs and offsets).
struct RawPose: Codable, Equatable {
    var yaw: Double
    var pitch: Double
}

/// Where "straight ahead" is: Vision's reading while the listener faced forward. Head angles are Vision's change
/// from it, with the signs turned into ASH's convention (Apple's headers: yaw is positive counterclockwise, which
/// is taken to mean turning left; pitch is positive nodding down). Either sign can be reversed in the UI in case
/// a camera reports the other way.
struct HeadCalibration: Codable, Equatable {
    /// Camera the calibration was made with ("" = the default camera).
    var cameraID: String
    var forward: RawPose

    func pose(_ r: RawPose, reverseYaw: Bool = false, reversePitch: Bool = false) -> HeadPose {
        let yaw = (reverseYaw ? 1.0 : -1.0) * (r.yaw - forward.yaw)
        let pitch = (reversePitch ? 1.0 : -1.0) * (r.pitch - forward.pitch)
        return HeadPose(yaw: max(-180, min(180, yaw)), pitch: max(-90, min(90, pitch)))
    }
}

enum HeadRotation {
    /// Where a speaker fixed in the room (`d`) is relative to the listener's head: undo the head's yaw, then its
    /// pitch. Returns (elevation, azimuth) in degrees, ASH convention.
    static func relative(_ d: Direction, head: HeadPose) -> (elevation: Double, azimuth: Double) {
        let r = Double.pi / 180
        let e = Double(d.elevation) * r, a = (Double(d.azimuth) - head.yaw) * r
        // x forward, y right, z up
        let x = cos(e) * cos(a), y = cos(e) * sin(a), z = sin(e)
        let p = head.pitch * r
        let x2 = x * cos(p) + z * sin(p)
        let z2 = -x * sin(p) + z * cos(p)
        return (asin(max(-1, min(1, z2))) / r, atan2(y, x2) / r)
    }
}

/// The directions of a directional BRIR folder, for fast nearest-direction lookups.
struct DirectionIndex {
    private let dirs: [Direction]
    private let vecs: [(Double, Double, Double)]

    init<S: Sequence>(_ directions: S) where S.Element == Direction {
        // Same tie-break as DirectionalFolder.nearest: lowest (elevation, azimuth) wins.
        dirs = Array(directions).sorted { ($0.elevation, $0.azimuth) < ($1.elevation, $1.azimuth) }
        vecs = dirs.map { Self.unit(Double($0.elevation), Double($0.azimuth)) }
    }

    static func unit(_ e: Double, _ a: Double) -> (Double, Double, Double) {
        let er = e * .pi / 180, ar = a * .pi / 180
        return (cos(er) * cos(ar), cos(er) * sin(ar), sin(er))
    }

    private static func degrees(_ dot: Double) -> Double { acos(max(-1, min(1, dot))) * 180 / .pi }

    /// The exported direction nearest to (elevation, azimuth). Keeps `current` unless the nearest one is closer by
    /// more than `hysteresis` degrees, so a head held near a boundary doesn't flip between two files.
    func nearest(elevation e: Double, azimuth a: Double, current: Direction?, hysteresis: Double) -> Direction {
        let v = Self.unit(e, a)
        var best = 0, bestDot = -2.0
        for (i, u) in vecs.enumerated() {
            let d = u.0 * v.0 + u.1 * v.1 + u.2 * v.2
            if d > bestDot + 1e-12 { best = i; bestDot = d }
        }
        let b = dirs[best]
        guard let cur = current, cur != b, hysteresis > 0 else { return b }
        let u = Self.unit(Double(cur.elevation), Double(cur.azimuth))
        let curAngle = Self.degrees(u.0 * v.0 + u.1 * v.1 + u.2 * v.2)
        return curAngle - Self.degrees(bestDot) > hysteresis ? b : cur
    }
}

// MARK: - Camera + Vision

/// Webcam head tracking with Apple's frameworks: AVFoundation captures frames, and Apple's Vision
/// (`VNDetectFaceRectanglesRequest`, revision 3) reports each face's yaw and pitch. This class does no image
/// processing of its own; it passes Vision's angles on.
final class HeadTracker: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    struct Camera: Identifiable, Hashable {
        let id: String
        let name: String
    }

    /// Frames per second handed to Vision (the rest are dropped).
    static let rate = 20.0

    /// Called on the main thread with Vision's angles for the largest face, or nil when no face is seen.
    var onPose: (@MainActor (RawPose?) -> Void)?

    private let queue = DispatchQueue(label: "com.phil.brirconvolver.headtracker", qos: .userInitiated)
    private var session: AVCaptureSession?
    private var lastFrame = 0.0   // capture queue only
    private let request: VNDetectFaceRectanglesRequest = {
        let r = VNDetectFaceRectanglesRequest()
        r.revision = VNDetectFaceRectanglesRequestRevision3   // the first revision with pitch
        return r
    }()

    private static func discovery() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
                                         mediaType: .video, position: .unspecified).devices
    }

    /// Listing cameras doesn't ask for camera access.
    static func cameras() -> [Camera] { discovery().map { Camera(id: $0.uniqueID, name: $0.localizedName) } }

    static var authorization: AVAuthorizationStatus { AVCaptureDevice.authorizationStatus(for: .video) }

    /// Shows the macOS camera prompt (only if the user hasn't answered it yet).
    static func requestAccess(_ done: @escaping @MainActor (Bool) -> Void) {
        AVCaptureDevice.requestAccess(for: .video) { granted in
            DispatchQueue.main.async { MainActor.assumeIsolated { done(granted) } }
        }
    }

    var isRunning: Bool { session != nil }

    /// Start capturing from `cameraID` (nil, or a camera that's gone: the default camera). Main thread only;
    /// camera access must already be granted.
    func start(cameraID: String?) throws {
        stop()
        let all = Self.discovery()
        guard let dev = all.first(where: { $0.uniqueID == cameraID }) ?? AVCaptureDevice.default(for: .video) ?? all.first else {
            throw NSError(domain: "HeadTracking", code: 1, userInfo: [NSLocalizedDescriptionKey: "No camera found."])
        }
        let s = AVCaptureSession()
        s.beginConfiguration()
        if s.canSetSessionPreset(.vga640x480) { s.sessionPreset = .vga640x480 } else if s.canSetSessionPreset(.low) { s.sessionPreset = .low }
        let input = try AVCaptureDeviceInput(device: dev)
        guard s.canAddInput(input) else {
            throw NSError(domain: "HeadTracking", code: 2, userInfo: [NSLocalizedDescriptionKey: "\(dev.localizedName) can't be used for capture."])
        }
        s.addInput(input)
        let out = AVCaptureVideoDataOutput()
        out.alwaysDiscardsLateVideoFrames = true
        out.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
        out.setSampleBufferDelegate(self, queue: queue)
        guard s.canAddOutput(out) else {
            throw NSError(domain: "HeadTracking", code: 3, userInfo: [NSLocalizedDescriptionKey: "\(dev.localizedName) can't deliver video frames."])
        }
        s.addOutput(out)
        s.commitConfiguration()
        session = s
        queue.async { s.startRunning() }   // blocks until the camera is running, so not on the main thread
        Log.system.notice("head tracking camera started: \(dev.localizedName, privacy: .public)")
    }

    /// Main thread only.
    func stop() {
        guard let s = session else { return }
        session = nil
        queue.async { s.stopRunning() }
        Log.system.notice("head tracking camera stopped")
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let t = ProcessInfo.processInfo.systemUptime
        guard t - lastFrame >= 0.9 / Self.rate, let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lastFrame = t
        var pose: RawPose?
        do {
            try VNImageRequestHandler(cvPixelBuffer: pixels, orientation: .up, options: [:]).perform([request])
            // The largest face is taken to be the listener's.
            let face = request.results?.max { $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height }
            if let face, let y = face.yaw?.doubleValue, let p = face.pitch?.doubleValue {
                pose = RawPose(yaw: y * 180 / .pi, pitch: p * 180 / .pi)
            }
        } catch {
            pose = nil
        }
        let result = pose
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.session != nil else { return }
                self.onPose?(result)
            }
        }
    }
}

// MARK: - Calibration steps

enum CalibrationPhase {
    /// "Face forward" and a Start button.
    case ready
    case countdown
    case capturing
    case failed
    case done
}

// MARK: - Controller

/// Owns the toggle, camera, the forward reference and the mapping from head pose to directional BRIRs, and asks the running
/// convolver to swap each speaker's BRIR as the head turns.
@MainActor
final class HeadTrackingController: ObservableObject {
    static let shared = HeadTrackingController()
    private let defaults = UserDefaults.standard
    private static let enabledKey = "headTracking", cameraKey = "headTrackingCamera", calibrationKey = "headCalibration"
    private static let reverseYawKey = "headTrackingReverseYaw", reversePitchKey = "headTrackingReversePitch"

    /// The user's toggle (persisted). Only ever on with camera access granted.
    @Published private(set) var enabled: Bool
    /// Chosen camera's unique ID; "" = the default camera.
    @Published var cameraID: String {
        didSet {
            guard cameraID != oldValue else { return }
            defaults.set(cameraID, forKey: Self.cameraKey)
            cameraChanged()
        }
    }
    @Published private(set) var calibration: HeadCalibration?
    @Published private(set) var cameras: [HeadTracker.Camera] = []
    /// A directional BRIR folder is loaded.
    @Published private(set) var available = false
    /// A running convolver with a directional folder is attached.
    @Published private(set) var attached = false
    @Published private(set) var cameraRunning = false
    @Published private(set) var faceVisible = false
    /// Latest raw reading from Vision.
    @Published private(set) var raw: RawPose?
    /// Smoothed, calibrated head pose used for the BRIRs.
    @Published private(set) var pose = HeadPose.forward
    /// Exported direction currently playing for each speaker.
    @Published private(set) var trackedSummary = ""
    @Published private(set) var message: String?

    /// Vision reports the opposite signs from the default assumption (persisted).
    @Published var reverseYaw: Bool { didSet { defaults.set(reverseYaw, forKey: Self.reverseYawKey) } }
    @Published var reversePitch: Bool { didSet { defaults.set(reversePitch, forKey: Self.reversePitchKey) } }

    @Published private(set) var calibrationVisible = false
    @Published private(set) var calibrationPhase = CalibrationPhase.ready
    @Published private(set) var countdown = 0
    @Published private(set) var calibrationProblem: String?

    private let tracker = HeadTracker()

    // Tracking state
    private var lastPoseTime = 0.0
    private var lastFaceTime = 0.0
    /// Seconds without a face before the pose eases back to forward.
    static let holdWhenLost = 2.0
    /// Smoothing time constants (s): following a face, and easing back after losing it.
    static let followTau = 0.08, returnTau = 0.5
    /// A speaker only moves to a new file when that file is this many degrees closer than the current one.
    static let hysteresis = 2.0

    // Attached convolver
    private struct Tracked {
        let source: Int
        let speaker: Speaker
        /// Where the speaker sits in the room (the user's speaker position).
        let world: Direction
        /// Direction the convolver was built with (head facing forward).
        let base: Direction
        var applied: Direction
        var inFlight = false
    }
    private var conv: Convolver?
    private var files: [Direction: URL] = [:]
    private var index: DirectionIndex?
    private var tracked: [Tracked] = []
    private var failed: Set<Direction> = []
    private let loader = DispatchQueue(label: "com.phil.brirconvolver.headtracking.loader", qos: .userInitiated)
    private let cache = DirectionalIRCache()   // loader queue only

    // Calibration state
    private var calibrationTimer: Timer?
    private var phaseDeadline = 0.0
    private var samples: [RawPose] = []
    static let countdownSeconds = 3.0, captureSeconds = 1.2
    /// Face readings needed for the forward capture (about a third of the capture window).
    static let minimumSamples = 6
    /// Recent face readings (time, pose), for Recenter.
    private var recent: [(Double, RawPose)] = []
    static let recenterWindow = 0.5

    private init() {
        enabled = defaults.bool(forKey: Self.enabledKey)
        cameraID = defaults.string(forKey: Self.cameraKey) ?? ""
        reverseYaw = defaults.bool(forKey: Self.reverseYawKey)
        reversePitch = defaults.bool(forKey: Self.reversePitchKey)
        if let d = defaults.data(forKey: Self.calibrationKey) {
            calibration = try? JSONDecoder().decode(HeadCalibration.self, from: d)
        }
        tracker.onPose = { [weak self] r in self?.ingest(r) }
        // Never prompt at launch: if access was lost (e.g. after an ad-hoc rebuild), turn off and say so.
        if enabled && HeadTracker.authorization != .authorized {
            enabled = false
            defaults.set(false, forKey: Self.enabledKey)
            message = "Head tracking was turned off because BRIR Convolver doesn't have camera access any more "
                + "(this can happen after rebuilding the app). Turn it on to allow access again."
        }
        if enabled { cameras = HeadTracker.cameras() }
    }

    // MARK: Toggle

    func setEnabled(_ on: Bool) {
        message = nil
        guard on else { turnOff(); return }
        guard available else { return }
        switch HeadTracker.authorization {
        case .authorized:
            turnOn()
        case .notDetermined:
            message = "Waiting for camera permission…"
            HeadTracker.requestAccess { [weak self] granted in
                guard let self else { return }
                self.message = nil
                if granted { self.turnOn() } else { self.message = "Camera access was declined, so head tracking stays off." }
            }
        default:
            message = "BRIR Convolver doesn't have camera access. Allow it under System Settings → Privacy & Security → "
                + "Camera, then turn head tracking on again."
        }
    }

    private func turnOn() {
        enabled = true
        defaults.set(true, forKey: Self.enabledKey)
        cameras = HeadTracker.cameras()
        Log.system.notice("head tracking on")
        if calibration == nil || calibration?.cameraID != cameraID { beginCalibration() } else { updateCamera() }
    }

    private func turnOff() {
        enabled = false
        defaults.set(false, forKey: Self.enabledKey)
        if calibrationVisible { closeCalibration() }
        pose = .forward
        updateCamera()
        retarget()   // back to the directions the convolver was built with
        Log.system.notice("head tracking off")
    }

    func refreshCameras() { cameras = HeadTracker.cameras() }

    private func cameraChanged() {
        if cameraRunning {
            tracker.stop()
            cameraRunning = false
        }
        // A calibration belongs to one camera position.
        if enabled && calibration?.cameraID != cameraID && !calibrationVisible { beginCalibration() } else { updateCamera() }
    }

    // MARK: Convolver

    /// A directional folder was loaded (or something else replaced it).
    func setAvailable(_ a: Bool) {
        available = a
        if !a { detach() }
    }

    /// Called when a convolver built from a directional folder starts. `directions` is the exported direction each
    /// speaker's BRIR came from, `positions` where the user put each speaker.
    func attach(convolver: Convolver, folder: DirectionalFolder, directions: [Speaker: Direction],
                positions: [Speaker: Direction]) {
        conv = convolver
        files = folder.files
        index = DirectionIndex(folder.files.keys)
        failed = []
        tracked = convolver.sourceSpeakers.enumerated().compactMap { i, sp in
            guard let d = directions[sp] else { return nil }
            return Tracked(source: i, speaker: sp, world: positions[sp] ?? sp.defaultDirection, base: d, applied: d)
        }
        attached = true
        updateCamera()
        retarget()
    }

    func detach() {
        conv = nil
        tracked = []
        index = nil
        attached = false
        trackedSummary = ""
        updateCamera()
    }

    /// Choose each speaker's file for the current pose and swap any that changed.
    private func retarget() {
        guard let conv, let index else { return }
        let active = enabled && calibration != nil && !calibrationVisible
        let head = active ? pose : .forward
        for i in tracked.indices {
            let target: Direction
            if active {
                let rel = HeadRotation.relative(tracked[i].world, head: head)
                target = index.nearest(elevation: rel.elevation, azimuth: rel.azimuth,
                                       current: tracked[i].applied, hysteresis: Self.hysteresis)
            } else {
                target = tracked[i].base
            }
            if target != tracked[i].applied && !tracked[i].inFlight && !failed.contains(target) {
                load(i, target, conv)
            }
        }
        let summary = enabled ? tracked.map { "\($0.speaker.rawValue) \($0.applied.label)" }.joined(separator: " · ") : ""
        if summary != trackedSummary { trackedSummary = summary }
    }

    private func load(_ i: Int, _ dir: Direction, _ conv: Convolver) {
        guard let url = files[dir] else { return }
        tracked[i].inFlight = true
        let source = tracked[i].source, rate = conv.sampleRate, maxLength = conv.partitions * conv.blockSize
        let cache = self.cache
        loader.async {
            let result = Result { () throws -> Bool in
                let ir = try cache.ir(for: dir, url: url, rate: rate, maxLength: maxLength)
                return conv.swapIR(source: source, left: ir.left, right: ir.right)
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { HeadTrackingController.shared.loaded(conv, i, dir, url, result) }
            }
        }
    }

    private func loaded(_ c: Convolver, _ i: Int, _ dir: Direction, _ url: URL, _ result: Result<Bool, Error>) {
        guard c === conv, i < tracked.count else { return }
        tracked[i].inFlight = false
        switch result {
        case .success(true):
            tracked[i].applied = dir
        case .success(false):
            // That speaker's previous swap is still crossfading (≈ 20 ms); try again shortly.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in MainActor.assumeIsolated { self?.retarget() } }
            return
        case .failure(let e):
            failed.insert(dir)
            message = "Couldn't use \(url.lastPathComponent): \(e.localizedDescription)"
            Log.system.error("head tracking: \(url.lastPathComponent, privacy: .public): \(e.localizedDescription, privacy: .public)")
        }
        retarget()
    }

    // MARK: Camera

    private func updateCamera() {
        let want = calibrationVisible || (enabled && calibration != nil && attached)
        if want && !cameraRunning {
            guard HeadTracker.authorization == .authorized else {
                message = "BRIR Convolver doesn't have camera access. Allow it under System Settings → Privacy & Security → Camera."
                return
            }
            do {
                try tracker.start(cameraID: cameraID.isEmpty ? nil : cameraID)
                cameraRunning = true
                lastFaceTime = ProcessInfo.processInfo.systemUptime
                lastPoseTime = lastFaceTime
            } catch {
                message = "Camera: \(error.localizedDescription)"
            }
        } else if !want && cameraRunning {
            tracker.stop()
            cameraRunning = false
            faceVisible = false
            raw = nil
        }
    }

    private func ingest(_ r: RawPose?) {
        raw = r
        if faceVisible != (r != nil) { faceVisible = r != nil }
        let now = ProcessInfo.processInfo.systemUptime
        if let r { recent.append((now, r)) }
        recent.removeAll { now - $0.0 > Self.recenterWindow }
        if calibrationVisible {
            if calibrationPhase == .capturing, let r { samples.append(r) }
            return
        }
        guard enabled, let cal = calibration else { return }
        let dt = max(0, min(0.5, now - lastPoseTime))
        lastPoseTime = now
        let target: HeadPose, tau: Double
        if let r {
            lastFaceTime = now
            target = cal.pose(r, reverseYaw: reverseYaw, reversePitch: reversePitch)
            tau = Self.followTau
        } else if now - lastFaceTime > Self.holdWhenLost {
            target = .forward
            tau = Self.returnTau
        } else {
            return   // briefly lost: hold the last pose
        }
        let a = 1 - exp(-dt / tau)
        let next = HeadPose(yaw: pose.yaw + (target.yaw - pose.yaw) * a, pitch: pose.pitch + (target.pitch - pose.pitch) * a)
        if abs(next.yaw - pose.yaw) > 0.05 || abs(next.pitch - pose.pitch) > 0.05 { pose = next }
        retarget()
    }

    // MARK: Calibration

    /// Show the "face forward" sheet (first use, or after switching cameras).
    func beginCalibration() {
        calibrationVisible = true
        calibrationPhase = .ready
        calibrationProblem = nil
        updateCamera()
        retarget()   // hold the speakers still (facing forward) while calibrating
    }

    /// Start (or Try again): count down, then capture.
    func startCalibration() {
        calibrationProblem = nil
        calibrationPhase = .countdown
        phaseDeadline = ProcessInfo.processInfo.systemUptime + Self.countdownSeconds
        countdown = Int(Self.countdownSeconds)
        if calibrationTimer == nil {
            // Common run-loop modes so it keeps ticking while the mouse is held down anywhere in the app.
            let t = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.calibrationTick() } }
            RunLoop.main.add(t, forMode: .common)
            calibrationTimer = t
        }
    }

    private func calibrationTick() {
        let now = ProcessInfo.processInfo.systemUptime
        switch calibrationPhase {
        case .countdown:
            let left = phaseDeadline - now
            let c = max(0, Int(left.rounded(.up)))
            if c != countdown { countdown = c }
            if left <= 0 {
                calibrationPhase = .capturing
                samples = []
                phaseDeadline = now + Self.captureSeconds
            }
        case .capturing:
            if now >= phaseDeadline { finishCapture() }
        default:
            stopTimer()
        }
    }

    private static func median(_ v: [RawPose]) -> RawPose {
        func m(_ x: [Double]) -> Double {
            let s = x.sorted()
            return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
        }
        return RawPose(yaw: m(v.map(\.yaw)), pitch: m(v.map(\.pitch)))
    }

    private func finishCapture() {
        stopTimer()
        guard samples.count >= Self.minimumSamples else {
            calibrationPhase = .failed
            calibrationProblem = "The camera couldn't see your face. Make sure it can see you, then try again."
            NSSound(named: NSSound.Name("Basso"))?.play()
            return
        }
        setForward(Self.median(samples))
        NSSound(named: NSSound.Name("Tink"))?.play()
        calibrationPhase = .done
    }

    private func setForward(_ f: RawPose) {
        let cal = HeadCalibration(cameraID: cameraID, forward: f)
        calibration = cal
        defaults.set(try? JSONEncoder().encode(cal), forKey: Self.calibrationKey)
        Log.system.notice("head tracking forward set: \(String(describing: cal), privacy: .public)")
    }

    /// Make the direction the listener is looking right now (the last half second) straight ahead.
    func recenter() {
        guard recent.count >= 3 else {
            message = "Can't recenter: the camera can't see your face right now."
            return
        }
        message = nil
        setForward(Self.median(recent.map { $0.1 }))
        retarget()
    }

    private func stopTimer() {
        calibrationTimer?.invalidate()
        calibrationTimer = nil
    }

    /// Done button.
    func finishCalibration() {
        closeCalibration()
        pose = .forward
        updateCamera()
        retarget()
    }

    /// Cancel, or the sheet was dismissed. Without a usable calibration, head tracking turns back off.
    func cancelCalibration() {
        guard calibrationVisible else { return }
        closeCalibration()
        if enabled && (calibration == nil || calibration?.cameraID != cameraID) {
            enabled = false
            defaults.set(false, forKey: Self.enabledKey)
            message = "Head tracking needs to know where straight ahead is for this camera. Turn it on again to set it."
        }
        updateCamera()
        retarget()
    }

    private func closeCalibration() {
        stopTimer()
        calibrationVisible = false
        calibrationPhase = .ready
        samples = []
    }
}

/// Directional BRIRs loaded for head tracking, resampled to the convolver's rate.
/// `@unchecked Sendable`: it's handed to the loader queue and only ever used there (a serial queue), so its state
/// is never touched from two threads.
final class DirectionalIRCache: @unchecked Sendable {
    private var rate = 0.0, maxLength = 0
    private var store: [Direction: (left: [Double], right: [Double])] = [:]
    private var order: [Direction] = []
    /// About 50 MB for 0.5 s BRIRs at 48 kHz.
    static let capacity = 96

    func ir(for d: Direction, url: URL, rate r: Double, maxLength m: Int) throws -> (left: [Double], right: [Double]) {
        if r != rate || m != maxLength {
            store = [:]; order = []; rate = r; maxLength = m
        }
        if let hit = store[d] { return hit }
        let wav = try WAVFile(url: url)
        guard wav.channelCount == 2 else {
            throw NSError(domain: "BRIR", code: 3, userInfo: [NSLocalizedDescriptionKey:
                "\(url.lastPathComponent) has \(wav.channelCount) channels; directional BRIRs are stereo (left ear, right ear)."])
        }
        var ch = [wav.channels[0], wav.channels[1]]
        if wav.sampleRate != r {
            let src = ch, from = wav.sampleRate
            var out = [[Double]](repeating: [], count: 2)
            out.withUnsafeMutableBufferPointer { o in
                let base = o.baseAddress!
                DispatchQueue.concurrentPerform(iterations: 2) { i in (base + i).pointee = Resampler.resample(src[i], from: from, to: r) }
            }
            ch = out
        }
        let ir = (left: Array(ch[0].prefix(m)), right: Array(ch[1].prefix(m)))
        store[d] = ir
        order.append(d)
        if order.count > Self.capacity { store[order.removeFirst()] = nil }
        return ir
    }
}
