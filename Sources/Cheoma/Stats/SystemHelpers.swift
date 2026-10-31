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
        var result: [Any] = []
        forEach(matching: className) { service in
            if let value = property(key, of: service) { result.append(value) }
        }
        return result
    }

    static func property(_ key: String, of service: io_service_t) -> Any? {
        IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }

    /// 이름이 일치하는 서비스마다 body를 부른다 (service는 body가 끝나면 놓는다)
    static func forEach(matching className: String, _ body: (io_service_t) -> Void) {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(className), &iterator) == KERN_SUCCESS else {
            return
        }
        defer { IOObjectRelease(iterator) }
        while case let service = IOIteratorNext(iterator), service != 0 {
            body(service)
            IOObjectRelease(service)
        }
    }

    /// 장치를 뺐다 다시 꽂아도 겹치지 않는 레지스트리 번호
    static func entryID(of service: io_service_t) -> UInt64? {
        var id: UInt64 = 0
        return IORegistryEntryGetRegistryEntryID(service, &id) == KERN_SUCCESS ? id : nil
    }

    /// 바로 위(IOService 평면) 서비스의 클래스 이름
    static func parentClassName(of service: io_service_t) -> String? {
        var parent: io_registry_entry_t = 0
        guard IORegistryEntryGetParentEntry(service, kIOServicePlane, &parent) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(parent) }
        var name = [CChar](repeating: 0, count: 128)
        guard IOObjectGetClass(parent, &name) == KERN_SUCCESS else { return nil }
        return String(cString: name)
    }

    static func properties(of service: io_service_t) -> [String: Any]? {
        var props: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS else {
            return nil
        }
        return props?.takeRetainedValue() as? [String: Any]
    }
}

/// 잠자기 시간을 포함하고, 시스템 시계를 바꿔도 뒤로 가지 않는 시간(초). 속도를 계산할 때 dt로 쓴다
enum MonotonicClock {
    static var now: TimeInterval { Double(clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)) / 1e9 }
}

/// 장치·인터페이스마다 따로 쌓이는 누적 바이트 카운터로 초당 속도를 구한다.
/// 합계로 빼면 외장 디스크나 USB 이더넷을 뺄 때 합계가 줄어 UInt64가 거꾸로 넘치고(1.8e19 B/s),
/// 그 값이 기록 파일에 남아 그래프 눈금을 망가뜨린다. 그래서 장치마다 빼고, 줄어든 카운터(뺐다 꽂음·초기화)와
/// 새로 생긴 장치는 이번엔 0으로 보고 기준값만 바꾼다.
struct CounterRate<Key: Hashable> {
    typealias Counters = [Key: (in: UInt64, out: UInt64)]

    /// 잠자기 등으로 이보다 오래 못 쟀으면 그 사이 평균은 의미가 없어서 이번 값은 버리고 기준만 잡는다
    static var maximumInterval: TimeInterval { 10 }

    private var previous: Counters = [:]
    private var previousTime: TimeInterval?

    mutating func update(_ counters: Counters, now: TimeInterval = MonotonicClock.now) -> ThroughputRate? {
        defer {
            previous = counters
            previousTime = now
        }
        guard let previousTime else { return nil }
        let dt = now - previousTime
        guard dt > 0, dt <= Self.maximumInterval else { return nil }
        var incoming: UInt64 = 0
        var outgoing: UInt64 = 0
        for (key, current) in counters {
            guard let before = previous[key] else { continue }
            if current.in >= before.in { incoming += current.in - before.in }
            if current.out >= before.out { outgoing += current.out - before.out }
        }
        return ThroughputRate(inPerSecond: Double(incoming) / dt, outPerSecond: Double(outgoing) / dt)
    }
}

extension Dictionary where Key == String, Value == Any {
    /// IORegistry 값은 음수가 UInt64로 들어오는 경우가 있어서 Int64 비트로 해석한다
    func int64(_ key: String) -> Int64? { (self[key] as? NSNumber)?.int64Value }
    func double(_ key: String) -> Double? { (self[key] as? NSNumber)?.doubleValue }
}
