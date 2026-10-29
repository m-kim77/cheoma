import Foundation
import IOKit

enum Sysctl {
    static func read<T: BitwiseCopyable>(_ name: String, initial: T) -> T? {
        var value = initial
        var size = MemoryLayout<T>.size
        return sysctlbyname(name, &value, &size, nil, 0) == 0 ? value : nil
    }
}

enum IORegistry {
    /// 이름이 일치하는 모든 서비스의 프로퍼티
    static func properties(matching className: String) -> [[String: Any]] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(className), &iterator) == KERN_SUCCESS else {
            return []
        }
        defer { IOObjectRelease(iterator) }
        var result: [[String: Any]] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            if let props = properties(of: service) { result.append(props) }
            IOObjectRelease(service)
        }
        return result
    }

    /// 이름이 일치하는 모든 서비스에서 속성 하나만 읽는다 (전체 속성을 복사하는 것보다 훨씬 가볍다)
    static func property(_ key: String, matching className: String) -> [Any] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(className), &iterator) == KERN_SUCCESS else {
            return []
        }
        defer { IOObjectRelease(iterator) }
        var result: [Any] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            if let value = IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() {
                result.append(value)
            }
            IOObjectRelease(service)
        }
        return result
    }

    static func properties(of service: io_service_t) -> [String: Any]? {
        var props: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS else {
            return nil
        }
        return props?.takeRetainedValue() as? [String: Any]
    }
}

extension Dictionary where Key == String, Value == Any {
    /// IORegistry 값은 음수가 UInt64로 들어오는 경우가 있어서 Int64 비트로 해석한다
    func int64(_ key: String) -> Int64? { (self[key] as? NSNumber)?.int64Value }
    func double(_ key: String) -> Double? { (self[key] as? NSNumber)?.doubleValue }
}
