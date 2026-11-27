import CoreAudio
import AudioToolbox
import Foundation
import Darwin

struct AudioDeviceInfo: Identifiable, Hashable {
    let id: AudioObjectID
    let uid: String
    let name: String
    let outputChannels: Int
    var inputChannels: Int = 0
}

struct AudioProcessInfo: Hashable {
    let objectID: AudioObjectID
    let pid: pid_t
    let bundleID: String
    let path: String
    var displayName: String {
        if !bundleID.isEmpty { return bundleID }
        return (path as NSString).lastPathComponent
    }
}

struct CAError: LocalizedError {
    let what: String
    let status: OSStatus
    var errorDescription: String? {
        let be = UInt32(bitPattern: status).bigEndian
        let bytes = withUnsafeBytes(of: be) { Array($0) }
        let fourCC = bytes.allSatisfy { $0 >= 32 && $0 < 127 } ? " '\(String(bytes: bytes, encoding: .ascii)!)'" : ""
        return "\(what) failed (OSStatus \(status)\(fourCC))"
    }
}

@inline(__always) func check(_ status: OSStatus, _ what: @autoclosure () -> String) throws {
    if status != noErr { throw CAError(what: what(), status: status) }
}

enum CA {
    static let system = AudioObjectID(kAudioObjectSystemObject)

    static func address(_ selector: AudioObjectPropertySelector,
                        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                        _ element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    /// Read a fixed-size property. `T` must be a plain value type: Core Audio writes raw bytes into it.
    static func get<T: BitwiseCopyable>(_ obj: AudioObjectID, _ selector: AudioObjectPropertySelector,
                       scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, initial: T) -> T? {
        var addr = address(selector, scope)
        var value = initial
        var size = UInt32(MemoryLayout<T>.size)
        let st = AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, &value)
        return st == noErr ? value : nil
    }

    /// Read an array property. `T` must be a plain value type: Core Audio writes raw bytes into it.
    static func getArray<T: BitwiseCopyable>(_ obj: AudioObjectID, _ selector: AudioObjectPropertySelector,
                            scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, zero: T) -> [T] {
        var addr = address(selector, scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(obj, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var arr = [T](repeating: zero, count: Int(size) / MemoryLayout<T>.stride)
        guard AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, &arr) == noErr else { return [] }
        return Array(arr.prefix(Int(size) / MemoryLayout<T>.stride))
    }

    static func getString(_ obj: AudioObjectID, _ selector: AudioObjectPropertySelector,
                          scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> String? {
        var addr = address(selector, scope)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let st = AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, &value)
        guard st == noErr, let v = value else { return nil }
        return v.takeRetainedValue() as String
    }

    // MARK: Devices

    static func defaultOutputDevice() -> AudioObjectID? {
        guard let d = get(system, kAudioHardwarePropertyDefaultOutputDevice, initial: AudioObjectID(0)), d != 0 else { return nil }
        return d
    }

    @discardableResult
    static func setDefaultOutputDevice(_ dev: AudioObjectID) -> Bool {
        var addr = address(kAudioHardwarePropertyDefaultOutputDevice)
        var d = dev
        return AudioObjectSetPropertyData(system, &addr, 0, nil, UInt32(MemoryLayout<AudioObjectID>.size), &d) == noErr
    }

    static func deviceUID(_ dev: AudioObjectID) -> String? { getString(dev, kAudioDevicePropertyDeviceUID) }
    static func deviceName(_ dev: AudioObjectID) -> String? { getString(dev, kAudioObjectPropertyName) }

    static func channelCount(_ dev: AudioObjectID, scope: AudioObjectPropertyScope) -> Int {
        var addr = address(kAudioDevicePropertyStreamConfiguration, scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(dev, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, raw) == noErr else { return 0 }
        let abl = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return abl.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    static func nominalSampleRate(_ dev: AudioObjectID) -> Double? {
        get(dev, kAudioDevicePropertyNominalSampleRate, initial: Float64(0))
    }

    static func bufferFrameSize(_ dev: AudioObjectID) -> Int? {
        get(dev, kAudioDevicePropertyBufferFrameSize, initial: UInt32(0)).map(Int.init)
    }

    static func outputDevices() -> [AudioDeviceInfo] {
        let ids = getArray(system, kAudioHardwarePropertyDevices, zero: AudioObjectID(0))
        return ids.compactMap { id in
            let ch = channelCount(id, scope: kAudioObjectPropertyScopeOutput)
            guard ch > 0, let uid = deviceUID(id), !uid.hasPrefix(AudioPipeline.aggregateUIDPrefix) else { return nil }
            return AudioDeviceInfo(id: id, uid: uid, name: deviceName(id) ?? uid, outputChannels: ch)
        }
    }

    /// Devices with input channels (e.g. a loopback driver such as BlackHole), excluding our own aggregates.
    static func inputDevices() -> [AudioDeviceInfo] {
        let ids = getArray(system, kAudioHardwarePropertyDevices, zero: AudioObjectID(0))
        return ids.compactMap { id in
            let ch = channelCount(id, scope: kAudioObjectPropertyScopeInput)
            guard ch > 0, let uid = deviceUID(id), !uid.hasPrefix(AudioPipeline.aggregateUIDPrefix) else { return nil }
            return AudioDeviceInfo(id: id, uid: uid, name: deviceName(id) ?? uid,
                                   outputChannels: channelCount(id, scope: kAudioObjectPropertyScopeOutput), inputChannels: ch)
        }
    }

    @discardableResult
    static func setNominalSampleRate(_ dev: AudioObjectID, _ rate: Double) -> Bool {
        if let cur = nominalSampleRate(dev), cur == rate { return true }
        var addr = address(kAudioDevicePropertyNominalSampleRate)
        var v = Float64(rate)
        return AudioObjectSetPropertyData(dev, &addr, 0, nil, UInt32(MemoryLayout<Float64>.size), &v) == noErr
    }

    // MARK: Channel layouts

    /// Channel labels of the device's speaker configuration (Audio MIDI Setup → Configure Speakers).
    /// Tries the output scope first (where loopback drivers such as BlackHole keep it), then input.
    static func speakerLabels(_ dev: AudioObjectID) -> [AudioChannelLabel]? {
        for scope in [kAudioObjectPropertyScopeOutput, kAudioObjectPropertyScopeInput] {
            var addr = address(kAudioDevicePropertyPreferredChannelLayout, scope)
            var size: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(dev, &addr, 0, nil, &size) == noErr,
                  Int(size) >= MemoryLayout<AudioChannelLayout>.size else { continue }
            let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16)
            defer { raw.deallocate() }
            guard AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, raw) == noErr else { continue }
            if let l = labels(of: UnsafeRawPointer(raw), depth: 0), !l.isEmpty { return l }
        }
        return nil
    }

    /// Labels of an `AudioChannelLayout` in memory, expanding layout tags and bitmaps.
    static func labels(of raw: UnsafeRawPointer, depth: Int) -> [AudioChannelLabel]? {
        let layout = raw.assumingMemoryBound(to: AudioChannelLayout.self).pointee
        let n = Int(layout.mNumberChannelDescriptions)
        if n > 0 {
            let off = MemoryLayout<AudioChannelLayout>.offset(of: \AudioChannelLayout.mChannelDescriptions) ?? 12
            let d = (raw + off).assumingMemoryBound(to: AudioChannelDescription.self)
            return (0..<n).map { d[$0].mChannelLabel }
        }
        guard depth == 0 else { return nil }
        let tag = layout.mChannelLayoutTag
        var spec: UInt32
        let prop: AudioFormatPropertyID
        if tag == kAudioChannelLayoutTag_UseChannelBitmap {
            spec = layout.mChannelBitmap.rawValue
            prop = kAudioFormatProperty_ChannelLayoutForBitmap
        } else if tag != kAudioChannelLayoutTag_UseChannelDescriptions {
            spec = tag
            prop = kAudioFormatProperty_ChannelLayoutForTag
        } else {
            return nil
        }
        var size: UInt32 = 0
        let specSize = UInt32(MemoryLayout<UInt32>.size)
        guard AudioFormatGetPropertyInfo(prop, specSize, &spec, &size) == noErr, size > 0 else { return nil }
        let out = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16)
        defer { out.deallocate() }
        guard AudioFormatGetProperty(prop, specSize, &spec, &size, out) == noErr else { return nil }
        return labels(of: UnsafeRawPointer(out), depth: depth + 1)
    }

    /// Map Core Audio channel labels to the roles the convolver understands. Returns nil if no label
    /// names a known speaker (e.g. a device that only reports discrete/unknown channels).
    static func roles(for labels: [AudioChannelLabel]) -> [InputRole]? {
        // Numeric label values from CoreAudioBaseTypes.h.
        let hasSideDirect = labels.contains(10) || labels.contains(11)
        let r: [InputRole] = labels.map { l in
            switch l {
            case 1: return .speaker(.FL)            // Left
            case 2: return .speaker(.FR)            // Right
            case 3, 42: return .speaker(.FC)        // Center, Mono
            case 4, 37: return .speaker(.LFE)       // LFEScreen, LFE2
            case 5: return .speaker(hasSideDirect ? .BL : .SL)   // LeftSurround
            case 6: return .speaker(hasSideDirect ? .BR : .SR)   // RightSurround
            case 9: return .centerSurround          // CenterSurround
            case 10: return .speaker(.SL)           // LeftSurroundDirect
            case 11: return .speaker(.SR)           // RightSurroundDirect
            case 33: return .speaker(.BL)           // RearSurroundLeft
            case 34: return .speaker(.BR)           // RearSurroundRight
            case 13, 49: return .speaker(.TFL)      // LeftTopFront (VerticalHeightLeft), LeftTopMiddle
            case 15, 51: return .speaker(.TFR)      // RightTopFront (VerticalHeightRight), RightTopMiddle
            case 16, 52: return .speaker(.TBL)      // TopBackLeft, LeftTopRear
            case 18, 54: return .speaker(.TBR)      // TopBackRight, RightTopRear
            default: return .unused
            }
        }
        return r.contains(where: { $0 != .unused }) ? r : nil
    }

    static func device(forUID uid: String) -> AudioObjectID? {
        getArray(system, kAudioHardwarePropertyDevices, zero: AudioObjectID(0)).first { deviceUID($0) == uid }
    }

    // MARK: Processes

    static func processObjects() -> [AudioProcessInfo] {
        getArray(system, kAudioHardwarePropertyProcessObjectList, zero: AudioObjectID(0)).compactMap { obj in
            guard let pid = get(obj, kAudioProcessPropertyPID, initial: pid_t(0)) else { return nil }
            return AudioProcessInfo(objectID: obj, pid: pid,
                                    bundleID: getString(obj, kAudioProcessPropertyBundleID) ?? "",
                                    path: executablePath(pid))
        }
    }

    /// Devices a process is currently playing to.
    static func processOutputDevices(_ proc: AudioObjectID) -> [AudioObjectID] {
        getArray(proc, kAudioProcessPropertyDevices, scope: kAudioObjectPropertyScopeOutput, zero: AudioObjectID(0))
    }

    static func processObject(forPID pid: pid_t) -> AudioObjectID? {
        var addr = address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var qualifier = pid
        var obj = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let st = AudioObjectGetPropertyData(system, &addr, UInt32(MemoryLayout<pid_t>.size), &qualifier, &size, &obj)
        if st == noErr, obj != 0 { return obj }
        return processObjects().first { $0.pid == pid }?.objectID
    }

    static func executablePath(_ pid: pid_t) -> String {
        var buf = [CChar](repeating: 0, count: 4096)
        let n = proc_pidpath(pid, &buf, UInt32(buf.count))
        return n > 0 ? String(cString: buf) : ""
    }

    // MARK: Listeners

    @discardableResult
    static func listen(_ obj: AudioObjectID, _ selector: AudioObjectPropertySelector,
                       scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                       queue: DispatchQueue = .main, _ handler: @escaping () -> Void) -> AudioObjectPropertyListenerBlock {
        var addr = address(selector, scope)
        let block: AudioObjectPropertyListenerBlock = { _, _ in handler() }
        AudioObjectAddPropertyListenerBlock(obj, &addr, queue, block)
        return block
    }

    static func unlisten(_ obj: AudioObjectID, _ selector: AudioObjectPropertySelector,
                         scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                         queue: DispatchQueue = .main, _ block: @escaping AudioObjectPropertyListenerBlock) {
        var addr = address(selector, scope)
        AudioObjectRemovePropertyListenerBlock(obj, &addr, queue, block)
    }
}
