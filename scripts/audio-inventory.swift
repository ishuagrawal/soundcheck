import AppKit
import CoreAudio

@main struct Inventory {
    @MainActor static func main() throws {
        let objects = try HAL.objects(HAL.system, kAudioHardwarePropertyProcessObjectList)
        for object in objects {
            let active = (try? HAL.value(object, kAudioProcessPropertyIsRunningOutput, default: UInt32(0))) ?? 0
            guard active == 1 else { continue }
            let pid = try HAL.value(object, kAudioProcessPropertyPID, default: pid_t(0))
            let bundle = (try? HAL.string(object, kAudioProcessPropertyBundleID)) ?? ""
            let name = (try? HAL.string(object, kAudioObjectPropertyName)) ?? ""
            let devices = (try? HAL.objects(object, kAudioProcessPropertyDevices, scope: kAudioObjectPropertyScopeOutput)) ?? []
            var path = [CChar](repeating: 0, count: 4096)
            _ = proc_pidpath(pid, &path, UInt32(path.count))
            let executable = String(decoding: path.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            print("\(object) pid=\(pid) bundle=\(bundle) name=\(name) devices=\(devices) executable=\(executable)")
        }
    }
}
