import Foundation

enum Format {
    static func percent(_ fraction: Double?) -> String {
        guard let fraction else { return "—" }
        return "\(Int((fraction * 100).rounded()))%"
    }

    static func watts(_ watts: Double?) -> String {
        guard let watts else { return "—" }
        // 반올림해서 10.00W가 되는 값은 10.0W로 (자리 수가 갑자기 늘지 않게)
        return abs(watts) < 9.995 ? String(format: "%.2fW", watts) : String(format: "%.1fW", watts)
    }

    static func celsius(_ value: Double?) -> String {
        guard let value else { return "—" }
        return "\(Int(value.rounded()))°C"
    }

    /// 메모리는 활성 상태 보기와 같게 1024 기준
    static func memory(_ bytes: UInt64) -> String {
        String(format: "%.1fGB", Double(bytes) / 1_073_741_824)
    }

    /// 앱 하나의 메모리: 1GB 아래는 MB
    static func processMemory(_ bytes: UInt64) -> String {
        let megabytes = Double(bytes) / 1_048_576
        // 반올림해서 1024MB가 되는 값부터 GB
        return megabytes < 1023.5 ? String(format: "%.0fMB", megabytes) : String(format: "%.1fGB", megabytes / 1024)
    }

    /// 앱 하나의 CPU: 코어 1개 = 100% (활성 상태 보기와 같은 기준)
    static func processCPU(_ cores: Double) -> String {
        let percent = cores * 100
        return percent < 9.95 ? String(format: "%.1f%%", percent) : "\(Int(percent.rounded()))%"
    }

    /// 저장장치는 Finder와 같게 1000 기준
    static func storage(_ bytes: Int64) -> String {
        let gb = Double(bytes) / 1_000_000_000
        // 반올림해서 1000GB가 되는 값부터 TB
        return gb >= 999.5 ? String(format: "%.2fTB", gb / 1000) : String(format: "%.0fGB", gb)
    }

    static func rate(_ bytesPerSecond: Double?) -> String {
        guard let value = bytesPerSecond else { return "—" }
        let units = ["B/s", "KB/s", "MB/s", "GB/s"]
        var v = max(value, 0)
        var i = 0
        // 반올림해서 1000이 되는 값(999.6KB/s → "1000KB/s")도 다음 단위로 넘긴다
        while v >= (i == 0 ? 1000 : 999.5), i < units.count - 1 { v /= 1000; i += 1 }
        return i == 0 ? "\(Int(v))\(units[i])" : String(format: v < 9.95 ? "%.1f%@" : "%.0f%@", v, units[i])
    }

    static func duration(minutes: Int?) -> String {
        guard let minutes else { return "계산 중" }
        return minutes >= 60 ? "\(minutes / 60)시간 \(minutes % 60)분" : "\(minutes)분"
    }
}
