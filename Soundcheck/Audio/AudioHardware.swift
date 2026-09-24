import CoreAudio
import Foundation

struct AudioFailure: LocalizedError, Sendable {
    let operation: String
    let status: OSStatus
    var errorDescription: String? {
        let code = UInt32(bitPattern: status)
        let bytes: [UInt8] = [24, 16, 8, 0].map { UInt8((code >> $0) & 255) }
        let readable = bytes.allSatisfy { (32...126).contains($0) }
        let detail = readable ? String(bytes: bytes, encoding: .ascii)! : String(status)
        return "\(operation) (\(detail))."
    }
}

enum HAL {
    static let system = AudioObjectID(kAudioObjectSystemObject)
    static func address(_ selector: AudioObjectPropertySelector,
                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
        .init(mSelector: selector, mScope: scope, mElement: element)
    }
    static func check(_ status: OSStatus, _ operation: String) throws {
        if status != noErr { throw AudioFailure(operation: operation, status: status) }
    }
    static func value<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                         scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                         element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain,
                         default initial: T) throws -> T {
        var property = address(selector, scope: scope, element: element)
        var value = initial
        var size = UInt32(MemoryLayout<T>.size)
        try withUnsafeMutableBytes(of: &value) { bytes in
            try check(AudioObjectGetPropertyData(object, &property, 0, nil, &size, bytes.baseAddress!), "Read audio property")
        }
        return value
    }
    static func objects(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) throws -> [AudioObjectID] {
        var property = address(selector, scope: scope)
        var size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(object, &property, 0, nil, &size), "Read audio list size")
        guard size > 0 else { return [] }
        var values = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        try values.withUnsafeMutableBytes { bytes in
            try check(AudioObjectGetPropertyData(object, &property, 0, nil, &size, bytes.baseAddress!), "Read audio list")
        }
        return Array(values.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
    }
    static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> String {
        var property = address(selector)
        var string: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        try check(AudioObjectGetPropertyData(object, &property, 0, nil, &size, &string), "Read audio name")
        return string?.takeRetainedValue() as String? ?? ""
    }
    static func set<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                       scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                       element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain, value: T) throws {
        var property = address(selector, scope: scope, element: element)
        var value = value
        try withUnsafeBytes(of: &value) { bytes in
            try check(AudioObjectSetPropertyData(object, &property, 0, nil, UInt32(bytes.count), bytes.baseAddress!), "Change audio property")
        }
    }
    static func isSettable(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                          scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeOutput,
                          element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> Bool {
        var property = address(selector, scope: scope, element: element)
        var settable = DarwinBoolean(false)
        return AudioObjectHasProperty(object, &property) && AudioObjectIsPropertySettable(object, &property, &settable) == noErr && settable.boolValue
    }
    static func bufferChannels(_ device: AudioObjectID, scope: AudioObjectPropertyScope) throws -> [UInt32] {
        var property = address(kAudioDevicePropertyStreamConfiguration, scope: scope)
        var size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(device, &property, 0, nil, &size), "Read stream layout")
        guard size >= MemoryLayout<AudioBufferList>.size else { return [] }
        let storage = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { storage.deallocate() }
        try check(AudioObjectGetPropertyData(device, &property, 0, nil, &size, storage), "Read stream layout")
        return UnsafeMutableAudioBufferListPointer(storage.assumingMemoryBound(to: AudioBufferList.self)).map(\.mNumberChannels)
    }
    static func streamFormats(_ device: AudioObjectID, scope: AudioObjectPropertyScope) throws -> [AudioStreamBasicDescription] {
        try objects(device, kAudioDevicePropertyStreams, scope: scope).map {
            try value($0, kAudioStreamPropertyVirtualFormat, default: AudioStreamBasicDescription())
        }
    }
    static func validFloatFormat(_ format: AudioStreamBasicDescription) -> Bool {
        format.mFormatID == kAudioFormatLinearPCM && format.mFormatFlags & kAudioFormatFlagIsFloat != 0 &&
        format.mFormatFlags & kAudioFormatFlagIsBigEndian == 0 && format.mBitsPerChannel == 32 &&
        format.mChannelsPerFrame > 0 && format.mChannelsPerFrame <= 32 && format.mSampleRate > 0
    }
}
