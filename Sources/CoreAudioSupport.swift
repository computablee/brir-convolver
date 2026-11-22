import CoreAudio
import AudioToolbox
import Foundation
import Darwin

struct AudioDeviceInfo: Identifiable, Hashable {
    let id: AudioObjectID
    let uid: String
    let name: String
    let outputChannels: Int
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

    static func get<T>(_ obj: AudioObjectID, _ selector: AudioObjectPropertySelector,
                       scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, initial: T) -> T? {
        var addr = address(selector, scope)
        var value = initial
        var size = UInt32(MemoryLayout<T>.size)
        let st = AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, &value)
        return st == noErr ? value : nil
    }

    static func getArray<T>(_ obj: AudioObjectID, _ selector: AudioObjectPropertySelector,
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
