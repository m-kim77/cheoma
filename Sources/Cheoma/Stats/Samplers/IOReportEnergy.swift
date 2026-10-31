import Foundation

/// IOReport(비공개 라이브러리)의 "Energy Model" 채널로 SoC 구성요소별 전력을 읽는다.
/// powermetrics와 달리 sudo가 필요 없다. 비공개 API라 OS 업데이트로 바뀌면 nil을 돌려준다.
final class IOReportEnergy {
    struct Reading: Equatable {
        var cpu: Double = 0
        var gpu: Double = 0
        var ane: Double = 0
        var dram: Double = 0
        var display: Double = 0
    }

    private typealias CopyChannels = @convention(c) (CFString?, CFString?, UInt64, UInt64, UInt64) -> Unmanaged<CFMutableDictionary>?
    private typealias CreateSubscription = @convention(c) (UnsafeMutableRawPointer?, CFMutableDictionary, UnsafeMutablePointer<Unmanaged<CFMutableDictionary>?>, UInt64, CFTypeRef?) -> OpaquePointer?
    private typealias CreateSamples = @convention(c) (OpaquePointer, CFMutableDictionary, CFTypeRef?) -> Unmanaged<CFDictionary>?
    private typealias CreateDelta = @convention(c) (CFDictionary, CFDictionary, CFTypeRef?) -> Unmanaged<CFDictionary>?
    private typealias GetInteger = @convention(c) (CFDictionary, Int32) -> Int64
    private typealias GetString = @convention(c) (CFDictionary) -> Unmanaged<CFString>?

    private let createSamples: CreateSamples
    private let createDelta: CreateDelta
    private let integerValue: GetInteger
    private let channelName: GetString
    private let unitLabel: GetString
    private let subscription: OpaquePointer
    private let channels: CFMutableDictionary
    private var previous: (samples: CFDictionary, time: TimeInterval)?
    /// 이보다 오래 못 쟀으면(잠자기 등) 그 사이 평균이 0에 가까워 기록을 끌어내리므로 버리고 기준만 잡는다
    private static let maximumInterval: TimeInterval = 30

    private enum Kind { case cpu, gpu, ane, anePart, dram, display }
    /// 채널 이름 → 종류와 줄 단위 (이름은 바뀌지 않으므로 처음 본 뒤로는 다시 해석하지 않는다)
    private var classified: [String: (kind: Kind, joules: Double)?] = [:]

    init?() {
        guard let lib = dlopen("/usr/lib/libIOReport.dylib", RTLD_NOW) else { return nil }
        func symbol<T>(_ name: String, as _: T.Type) -> T? {
            dlsym(lib, name).map { unsafeBitCast($0, to: T.self) }
        }
        guard let copyChannels = symbol("IOReportCopyChannelsInGroup", as: CopyChannels.self),
              let createSubscription = symbol("IOReportCreateSubscription", as: CreateSubscription.self),
              let createSamples = symbol("IOReportCreateSamples", as: CreateSamples.self),
              let createDelta = symbol("IOReportCreateSamplesDelta", as: CreateDelta.self),
              let integerValue = symbol("IOReportSimpleGetIntegerValue", as: GetInteger.self),
              let channelName = symbol("IOReportChannelGetChannelName", as: GetString.self),
              let unitLabel = symbol("IOReportChannelGetUnitLabel", as: GetString.self),
              let all = copyChannels("Energy Model" as CFString, nil, 0, 0, 0)?.takeRetainedValue()
        else { return nil }

        // "Energy Model"에는 코어별 등 채널이 수백 개 있다. 쓰는 것만 구독해야 매번 읽고 푸는 비용이 작다
        let wanted = ((all as NSDictionary)["IOReportChannels"] as? [CFDictionary] ?? []).filter { item in
            (channelName(item)?.takeUnretainedValue() as String?).map(Self.isWanted) ?? false
        }
        let channels: CFMutableDictionary
        if wanted.isEmpty {
            channels = all  // 이름이 바뀐 OS면 예전처럼 전부 구독
        } else {
            let filtered = NSMutableDictionary(dictionary: all as NSDictionary)
            filtered["IOReportChannels"] = wanted as NSArray
            channels = filtered as CFMutableDictionary
        }

        var subscribed: Unmanaged<CFMutableDictionary>?
        guard let subscription = createSubscription(nil, channels, &subscribed, 0, nil) else { return nil }
        subscribed?.release()

        self.createSamples = createSamples
        self.createDelta = createDelta
        self.integerValue = integerValue
        self.channelName = channelName
        self.unitLabel = unitLabel
        self.subscription = subscription
        self.channels = channels
    }

    /// 직전 샘플과의 에너지 차이 / 시간 = 평균 전력(W)
    func sample() -> Reading? {
        guard let current = createSamples(subscription, channels, nil)?.takeRetainedValue() else { return nil }
        let now = MonotonicClock.now
        defer { previous = (current, now) }
        guard let previous else { return nil }
        let dt = now - previous.time
        guard dt > 0, dt <= Self.maximumInterval,
              let delta = createDelta(previous.samples, current, nil)?.takeRetainedValue(),
              let items = (delta as NSDictionary)["IOReportChannels"] as? [CFDictionary] else { return nil }

        var joules = Reading()
        var aneTotal: Double?
        var aneParts: Double = 0
        for item in items {
            guard let name = channelName(item)?.takeUnretainedValue() as String?,
                  let channel = classify(name, item) else { continue }
            let value = Double(integerValue(item, 0)) * channel.joules
            switch channel.kind {
            case .cpu: joules.cpu += value
            case .gpu: joules.gpu += value
            case .dram: joules.dram += value
            case .display: joules.display += value
            case .ane: aneTotal = (aneTotal ?? 0) + value
            case .anePart: aneParts += value
            }
        }
        joules.ane = aneTotal ?? aneParts

        return Reading(cpu: joules.cpu / dt, gpu: joules.gpu / dt, ane: joules.ane / dt,
                       dram: joules.dram / dt, display: joules.display / dt)
    }

    private func classify(_ name: String, _ item: CFDictionary) -> (kind: Kind, joules: Double)? {
        if let known = classified[name] { return known }
        let kind: Kind? = switch name {
        case "CPU Energy": .cpu
        case "GPU Energy": .gpu
        case "DRAM": .dram
        case "DISP", "DISPEXT": .display
        case "ANE": .ane
        // 칩에 따라 ANE가 ANE0, ANE1...로 쪼개져서만 나오기도 함
        default: Self.isANEPart(name) ? .anePart : nil
        }
        let result = kind.flatMap { kind in
            Self.joulesPerUnit(unitLabel(item)?.takeUnretainedValue() as String?).map { (kind, $0) }
        }
        classified[name] = result
        return result
    }

    private static func isWanted(_ name: String) -> Bool {
        ["CPU Energy", "GPU Energy", "DRAM", "DISP", "DISPEXT", "ANE"].contains(name) || isANEPart(name)
    }

    private static func isANEPart(_ name: String) -> Bool {
        name.count > 3 && name.hasPrefix("ANE") && name.dropFirst(3).allSatisfy(\.isNumber)
    }

    private static func joulesPerUnit(_ label: String?) -> Double? {
        switch label?.trimmingCharacters(in: .whitespaces) {
        case "mJ": 1e-3
        case "uJ", "µJ": 1e-6
        case "nJ": 1e-9
        default: nil
        }
    }
}
