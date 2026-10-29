import Foundation

/// GPU 드라이버(IOAccelerator)가 노출하는 사용률. 활성 상태 보기의 GPU 기록과 같은 값.
final class GPUSampler {
    func sample() -> Double? {
        for value in IORegistry.property("PerformanceStatistics", matching: "IOAccelerator") {
            guard let stats = value as? [String: Any], let utilization = stats.double("Device Utilization %") else { continue }
            return utilization / 100
        }
        return nil
    }
}
