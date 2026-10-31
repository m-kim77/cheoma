import Foundation

/// 그래프로 그리는 측정 항목 (raw 값은 저장 파일의 키)
enum Metric: String, CaseIterable {
    case cpu, gpu
    case systemPower, cpuPower, gpuPower
    case networkIn, networkOut
    case cpuTemperature, gpuTemperature
}

/// 측정값 하나의 시간 기록.
/// 최근 1시간은 1초 간격 그대로, 그보다 오래된 24시간은 1분 평균으로 줄여서 보관한다 (항목당 최대 약 5천 개).
struct TimeSeries: Codable {
    struct Point: Codable {
        var time: TimeInterval   // timeIntervalSinceReferenceDate
        var value: Double
        /// 1분으로 줄인 점은 그 1분 동안의 최대값 (원본 점은 value와 같다)
        var peak: Double

        // 저장 파일 크기를 줄이려고 짧은 키를 쓴다
        private enum CodingKeys: String, CodingKey { case time = "t", value = "v", peak = "p" }

        init(time: TimeInterval, value: Double, peak: Double? = nil) {
            self.time = time
            self.value = value
            self.peak = peak ?? value
        }
    }

    static let fineSpan: TimeInterval = 60 * 60
    static let coarseSpan: TimeInterval = 24 * 60 * 60
    static let coarseStep: TimeInterval = 60

    private(set) var fine: [Point] = []
    private(set) var coarse: [Point] = []
    private var bucket: Bucket?

    /// 아직 다 차지 않은 1분 구간
    private struct Bucket: Codable {
        var start: TimeInterval
        var sum: Double
        var count: Int
        var peak: Double
    }

    mutating func append(_ value: Double, at time: TimeInterval) {
        fine.append(Point(time: time, value: value))
        Self.drop(&fine, before: time - Self.fineSpan)

        let start = (time / Self.coarseStep).rounded(.down) * Self.coarseStep
        if let bucket, bucket.start != start {
            coarse.append(Point(time: bucket.start + Self.coarseStep / 2,
                                value: bucket.sum / Double(bucket.count), peak: bucket.peak))
            Self.drop(&coarse, before: time - Self.coarseSpan)
            self.bucket = nil
        }
        let current = bucket ?? Bucket(start: start, sum: 0, count: 0, peak: -.infinity)
        bucket = Bucket(start: start, sum: current.sum + value, count: current.count + 1, peak: max(current.peak, value))
    }

    /// 저장된 기록을 불러온 뒤 보관 기간이 지난 점을 버린다
    mutating func prune(now: TimeInterval) {
        Self.drop(&fine, before: now - Self.fineSpan)
        Self.drop(&coarse, before: now - Self.coarseSpan)
    }

    /// limit보다 큰 점을 버린다 (예전 버전이 남긴 말이 안 되는 값을 지울 때)
    mutating func discard(above limit: Double) {
        fine.removeAll { $0.peak > limit }
        coarse.removeAll { $0.peak > limit }
        if let bucket, bucket.peak > limit { self.bucket = nil }
    }

    /// start 이후의 점들 (오래된 → 최신). 1시간보다 오래된 구간은 1분 평균으로 채운다.
    /// 그래프 왼쪽 끝에서 선이 끊기지 않도록 start 바로 앞의 점 하나를 포함한다.
    func points(since start: TimeInterval) -> [Point] {
        let fineStart = fine.first?.time ?? .infinity
        guard start < fineStart else { return Array(fine[Self.indexBefore(start, in: fine)...]) }
        let older = coarse[Self.indexBefore(start, in: coarse)...].prefix { $0.time < fineStart }
        return Array(older) + fine
    }

    /// start 이후의 평균과 최대. 최대는 1분 평균이 아니라 그 1분 안의 최대값(peak)이라 그래프에 보이는 봉우리와 같다.
    /// 그래프 탭이 다시 그릴 때마다 부르니 배열을 만들지 않고 한 번 훑는다
    func summary(since start: TimeInterval) -> (average: Double, maximum: Double)? {
        let fineStart = fine.first?.time ?? .infinity
        // 1분 평균 점 하나는 원본 점 여러 개 몫이다. 원본 간격(1~2초)으로 나눠 무게를 맞춰야
        // 24시간 평균이 최근 1시간 쪽으로 쏠리지 않는다
        let fineSpacing = fine.count > 1 ? max((fine[fine.count - 1].time - fine[0].time) / Double(fine.count - 1), 1) : 1
        var sum = 0.0
        var weight = 0.0
        var maximum = -Double.infinity
        func add(_ point: Point, weight w: Double) {
            sum += point.value * w
            weight += w
            maximum = max(maximum, point.peak)
        }
        if start < fineStart {
            for point in coarse[Self.indexBefore(start, in: coarse)...] where point.time >= start && point.time < fineStart {
                add(point, weight: Self.coarseStep / fineSpacing)
            }
        }
        for point in fine[Self.indexBefore(start, in: fine)...] where point.time >= start { add(point, weight: 1) }
        guard weight > 0 else { return nil }
        return (sum / weight, maximum)
    }

    private static func indexBefore(_ time: TimeInterval, in points: [Point]) -> Int {
        var low = 0
        var high = points.count
        while low < high {
            let mid = (low + high) / 2
            if points[mid].time < time { low = mid + 1 } else { high = mid }
        }
        return max(low - 1, 0)
    }

    private static func drop(_ points: inout [Point], before cutoff: TimeInterval) {
        guard let first = points.first, first.time < cutoff else { return }
        points.removeFirst(points.firstIndex { $0.time >= cutoff } ?? points.count)
    }
}

struct StatsHistory {
    private var series: [Metric: TimeSeries] = [:]

    subscript(metric: Metric) -> TimeSeries { series[metric] ?? TimeSeries() }

    mutating func append(_ s: StatsSnapshot, at time: TimeInterval) {
        record(.cpu, s.cpu, at: time)
        record(.gpu, s.gpu, at: time)
        record(.systemPower, s.power?.systemWatts, at: time)
        record(.cpuPower, s.power?.components?.cpu, at: time)
        record(.gpuPower, s.power?.components?.gpu, at: time)
        record(.networkIn, s.network?.inPerSecond, at: time)
        record(.networkOut, s.network?.outPerSecond, at: time)
        record(.cpuTemperature, s.thermal?.cpu, at: time)
        record(.gpuTemperature, s.thermal?.gpu, at: time)
    }

    mutating func record(_ metric: Metric, _ value: Double?, at time: TimeInterval) {
        guard let value, value.isFinite else { return }
        series[metric, default: TimeSeries()].append(value, at: time)
    }

    mutating func prune(now: TimeInterval) {
        for metric in Array(series.keys) { series[metric]?.prune(now: now) }
    }

    /// 예전 버전은 USB 이더넷 등을 뺄 때 네트워크 속도를 1.8e19 B/s로 기록했다. 남아 있으면 그래프 눈금이
    /// 24시간 동안 망가지므로 불러올 때 지운다 (100GB/s는 어떤 맥의 네트워크로도 나올 수 없는 값)
    mutating func discardImpossibleValues() {
        for metric in [Metric.networkIn, .networkOut] { series[metric]?.discard(above: 100e9) }
    }
}

/// 앱을 다시 켜도 그래프 기록이 이어지도록 파일로 저장한다 (항목 이름을 문자열 키로)
extension StatsHistory: Codable {
    init(from decoder: Decoder) throws {
        let saved = try [String: TimeSeries](from: decoder)
        series = Dictionary(uniqueKeysWithValues: saved.compactMap { key, value in Metric(rawValue: key).map { ($0, value) } })
    }

    func encode(to encoder: Encoder) throws {
        try Dictionary(uniqueKeysWithValues: series.map { ($0.key.rawValue, $0.value) }).encode(to: encoder)
    }
}
