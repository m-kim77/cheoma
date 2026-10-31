import XCTest
@testable import Cheoma

final class CounterRateTests: XCTestCase {
    func testFirstSampleOnlySetsBaseline() {
        var rate = CounterRate<Int>()
        XCTAssertNil(rate.update([1: (100, 100)], now: 0))
    }

    func testRatePerSecondAcrossDevices() throws {
        var rate = CounterRate<Int>()
        _ = rate.update([1: (1_000, 500), 2: (0, 0)], now: 10)
        let result = try XCTUnwrap(rate.update([1: (3_000, 1_500), 2: (2_000, 0)], now: 12))
        XCTAssertEqual(result.inPerSecond, 2_000)   // (2000 + 2000) / 2s
        XCTAssertEqual(result.outPerSecond, 500)
    }

    /// 외장 디스크·USB 이더넷을 빼면 합계가 줄어든다. 예전에는 여기서 UInt64가 넘쳐 1.8e19 B/s가 나왔다
    func testRemovedDeviceDoesNotWrapAround() throws {
        var rate = CounterRate<Int>()
        _ = rate.update([1: (5_000, 5_000), 2: (900_000_000, 900_000_000)], now: 0)
        let result = try XCTUnwrap(rate.update([1: (6_000, 5_500)], now: 1))
        XCTAssertEqual(result.inPerSecond, 1_000)
        XCTAssertEqual(result.outPerSecond, 500)
    }

    func testCounterResetCountsAsZero() throws {
        var rate = CounterRate<Int>()
        _ = rate.update([1: (5_000, 5_000)], now: 0)
        let result = try XCTUnwrap(rate.update([1: (10, 6_000)], now: 1))
        XCTAssertEqual(result.inPerSecond, 0)
        XCTAssertEqual(result.outPerSecond, 1_000)
    }

    func testNewDeviceStartsFromItsOwnBaseline() throws {
        var rate = CounterRate<Int>()
        _ = rate.update([1: (0, 0)], now: 0)
        // 새로 꽂은 장치의 누적값(수 GB)이 한 번에 들어오면 안 된다
        let result = try XCTUnwrap(rate.update([1: (100, 0), 2: (8_000_000_000, 0)], now: 1))
        XCTAssertEqual(result.inPerSecond, 100)
    }

    /// 잠자기 등으로 오래 못 쟀으면 그 사이 평균(거의 0)을 기록하지 않는다
    func testLongGapGivesNoValue() {
        var rate = CounterRate<Int>()
        _ = rate.update([1: (0, 0)], now: 0)
        XCTAssertNil(rate.update([1: (1_000, 0)], now: 60))
        XCTAssertNotNil(rate.update([1: (2_000, 0)], now: 61))
    }

    func testSamplersStillRead() {
        // 실제 기기에서 두 번 읽으면 두 번째부터 값이 나온다 (센서가 막힌 OS가 아니라면)
        let network = NetworkSampler()
        _ = network.sample()
        usleep(200_000)
        XCTAssertNotNil(network.sample())
        let disk = DiskSampler()
        _ = disk.sample()
        usleep(200_000)
        XCTAssertNotNil(disk.sample()?.rate)
    }
}

final class TimeSeriesTests: XCTestCase {
    func testSummaryMaximumUsesMinutePeaks() throws {
        var series = TimeSeries()
        let start = 1_000_000.0
        // 오래된 1분 구간: 평균은 낮지만 순간 최대가 90
        for second in 0..<60 { series.append(second == 30 ? 90 : 10, at: start + Double(second)) }
        // 1시간 넘게 지난 뒤의 원본 점들 (앞 구간은 1분 평균으로만 남는다)
        let later = start + 2 * 3600
        for second in 0..<10 { series.append(20, at: later + Double(second)) }
        series.prune(now: later + 10)
        let summary = try XCTUnwrap(series.summary(since: start - 1))
        XCTAssertEqual(summary.maximum, 90)
    }

    /// 24시간 평균: 1분 평균 점 하나는 원본 점 60개 몫이라 최근 1시간에 쏠리지 않아야 한다
    func testSummaryWeighsMinutePoints() throws {
        var series = TimeSeries()
        let start = 1_000_000.0
        // 3시간 동안 1초마다: 처음 2시간은 0, 마지막 1시간은 100
        for second in 0..<(3 * 3600) {
            series.append(second < 2 * 3600 ? 0 : 100, at: start + Double(second))
        }
        let now = start + 3 * 3600
        let summary = try XCTUnwrap(series.summary(since: now - 3 * 3600))
        XCTAssertEqual(summary.average, 100.0 / 3, accuracy: 2)
    }

    func testDiscardAbove() {
        var series = TimeSeries()
        series.append(1_000, at: 1)
        series.append(1.8e19, at: 2)
        series.append(2_000, at: 3)
        series.discard(above: 100e9)
        XCTAssertEqual(series.points(since: 0).map(\.value), [1_000, 2_000])
    }

    func testHistoryDropsImpossibleNetworkValuesOnly() {
        var history = StatsHistory()
        history.record(.networkIn, 1.8e19, at: 1)
        history.record(.networkIn, 5_000, at: 2)
        history.record(.cpu, 0.5, at: 1)
        history.discardImpossibleValues()
        XCTAssertEqual(history[.networkIn].points(since: 0).map(\.value), [5_000])
        XCTAssertEqual(history[.cpu].points(since: 0).count, 1)
    }
}

final class FormatTests: XCTestCase {
    func testRateSwitchesUnitWhenRoundingUp() {
        XCTAssertEqual(Format.rate(999), "999B/s")
        XCTAssertEqual(Format.rate(999_600), "1.0MB/s")
        XCTAssertEqual(Format.rate(9_960), "10KB/s")
        XCTAssertEqual(Format.rate(1_500_000), "1.5MB/s")
        XCTAssertEqual(Format.rate(-5), "0B/s")
        XCTAssertEqual(Format.rate(nil), "—")
    }

    func testWattsAndMemoryBoundaries() {
        XCTAssertEqual(Format.watts(9.996), "10.0W")
        XCTAssertEqual(Format.watts(9.5), "9.50W")
        XCTAssertEqual(Format.processMemory(UInt64(1023.6 * 1_048_576)), "1.0GB")
        XCTAssertEqual(Format.processMemory(500 * 1_048_576), "500MB")
        XCTAssertEqual(Format.storage(999_600_000_000), "1.00TB")
        XCTAssertEqual(Format.storage(512_000_000_000), "512GB")
        XCTAssertEqual(Format.processCPU(0.0996), "10%")
        XCTAssertEqual(Format.processCPU(0.05), "5.0%")
    }
}
