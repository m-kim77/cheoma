import AVFoundation
import CoreAudio
import XCTest
@testable import Cheoma

/// 소리 크기 계산과 입력 장치 고르기. 마이크를 열지 않고 만든 버퍼 · 장치 목록으로만 본다
final class AudioLevelTests: XCTestCase {
    func testDecibelMapping() {
        XCTAssertEqual(AudioLevelMeter.level(rms: 0), 0)
        XCTAssertEqual(AudioLevelMeter.level(rms: 1), 1)
        // -50 dB 아래는 0, -10 dB 위는 1, 그 사이는 고르게
        XCTAssertEqual(AudioLevelMeter.level(rms: powf(10, -60 / 20)), 0)
        XCTAssertEqual(AudioLevelMeter.level(rms: powf(10, -50 / 20)), 0, accuracy: 0.0001)
        XCTAssertEqual(AudioLevelMeter.level(rms: powf(10, -30 / 20)), 0.5, accuracy: 0.0001)
        XCTAssertEqual(AudioLevelMeter.level(rms: powf(10, -20 / 20)), 0.75, accuracy: 0.0001)
        XCTAssertEqual(AudioLevelMeter.level(rms: powf(10, -10 / 20)), 1, accuracy: 0.0001)
        XCTAssertEqual(AudioLevelMeter.level(rms: .nan), 0)
        XCTAssertEqual(AudioLevelMeter.level(rms: -1), 0)
        XCTAssertEqual(AudioLevelMeter.level(rms: .infinity), 0)
    }

    private func floatBuffer(channels: AVAudioChannelCount, frames: AVAudioFrameCount, interleaved: Bool = false,
                             fill: (_ channel: Int, _ frame: Int) -> Float) throws -> AVAudioPCMBuffer {
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000,
                                                 channels: channels, interleaved: interleaved))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        let data = try XCTUnwrap(buffer.floatChannelData)
        for frame in 0..<Int(frames) {
            for channel in 0..<Int(channels) {
                if interleaved {
                    data[0][frame * Int(channels) + channel] = fill(channel, frame)
                } else {
                    data[channel][frame] = fill(channel, frame)
                }
            }
        }
        return buffer
    }

    func testRMSOfSine() throws {
        let buffer = try floatBuffer(channels: 1, frames: 4800) { _, frame in
            0.5 * sinf(2 * .pi * 440 * Float(frame) / 48000)
        }
        XCTAssertEqual(AudioLevelMeter.rms(of: buffer), 0.5 / (2 as Float).squareRoot(), accuracy: 0.001)
    }

    func testRMSAveragesChannels() throws {
        let buffer = try floatBuffer(channels: 2, frames: 480) { channel, _ in channel == 0 ? 0.5 : 0 }
        XCTAssertEqual(AudioLevelMeter.rms(of: buffer), (0.25 / 2 as Float).squareRoot(), accuracy: 0.0001)
    }

    func testRMSOfInterleavedFloat() throws {
        let buffer = try floatBuffer(channels: 2, frames: 480, interleaved: true) { channel, _ in channel == 0 ? 0.5 : 0 }
        XCTAssertEqual(AudioLevelMeter.rms(of: buffer), (0.25 / 2 as Float).squareRoot(), accuracy: 0.0001)
    }

    func testRMSOfInt16() throws {
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 160))
        buffer.frameLength = 160
        let data = try XCTUnwrap(buffer.int16ChannelData)
        for frame in 0..<160 { data[0][frame] = frame.isMultiple(of: 2) ? 16384 : -16384 }
        XCTAssertEqual(AudioLevelMeter.rms(of: buffer), 0.5, accuracy: 0.0001)
    }

    func testEmptyAndSilentBuffers() throws {
        let empty = try floatBuffer(channels: 1, frames: 0) { _, _ in 1 }
        XCTAssertEqual(AudioLevelMeter.rms(of: empty), 0)
        let silent = try floatBuffer(channels: 1, frames: 480) { _, _ in 0 }
        XCTAssertEqual(AudioLevelMeter.level(rms: AudioLevelMeter.rms(of: silent)), 0)
    }

    func testSmootherRisesFastAndFallsSlowly() {
        var smoother = AudioLevelSmoother()
        let rise = smoother.next(1)
        XCTAssertEqual(rise, 0.6, accuracy: 0.0001)
        XCTAssertEqual(smoother.next(1), 0.84, accuracy: 0.0001)
        let fall = 0.84 - smoother.next(0)
        XCTAssertLessThan(fall, rise)
        // 조용해지면 결국 0까지 내려온다
        for _ in 0..<60 { _ = smoother.next(0) }
        XCTAssertEqual(smoother.value, 0)
    }

    func testSmootherClampsBadInput() {
        var smoother = AudioLevelSmoother()
        XCTAssertLessThanOrEqual(smoother.next(5), 1)
        for _ in 0..<20 { _ = smoother.next(5) }
        XCTAssertEqual(smoother.value, 1, accuracy: 0.0001)
        _ = smoother.next(.nan)
        XCTAssertTrue(smoother.value.isFinite)
        XCTAssertLessThan(smoother.value, 1)
    }
}

final class AudioInputRoutingTests: XCTestCase {
    private let builtIn = AudioInputDevice(id: 81, uid: "BuiltInMicrophoneDevice", name: "MacBook Pro 마이크",
                                           transportType: kAudioDeviceTransportTypeBuiltIn,
                                           dataSource: AudioInputRouting.internalMicrophoneSource)
    private let headsetJack = AudioInputDevice(id: 92, uid: "BuiltInHeadphoneInputDevice", name: "외부 마이크",
                                               transportType: kAudioDeviceTransportTypeBuiltIn,
                                               dataSource: AudioInputRouting.externalMicrophoneSource)
    private let airPods = AudioInputDevice(id: 120, uid: "AC-12-34:input", name: "AirPods Pro",
                                           transportType: kAudioDeviceTransportTypeBluetooth, dataSource: nil)
    private let leAudio = AudioInputDevice(id: 121, uid: "LE-56-78:input", name: "보청기",
                                           transportType: kAudioDeviceTransportTypeBluetoothLE, dataSource: nil)
    private let usb = AudioInputDevice(id: 130, uid: "AppleUSBAudioEngine:mic", name: "USB 마이크",
                                       transportType: kAudioDeviceTransportTypeUSB, dataSource: nil)

    private func choose(_ devices: [AudioInputDevice], default id: AudioDeviceID?,
                        prefers: Bool = true, lidClosed: Bool = false) -> AudioInputDevice? {
        AudioInputRouting.override(devices: devices, defaultID: id, prefersBuiltInMicrophone: prefers, isLidClosed: lidClosed)
    }

    func testBluetoothDefaultUsesBuiltInMicrophone() {
        XCTAssertEqual(choose([builtIn, airPods], default: airPods.id), builtIn)
        XCTAssertEqual(choose([airPods, headsetJack, builtIn], default: airPods.id), builtIn)
        XCTAssertEqual(choose([builtIn, leAudio], default: leAudio.id), builtIn)
    }

    func testKeepsDefaultWhenNotPreferred() {
        XCTAssertNil(choose([builtIn, airPods], default: airPods.id, prefers: false))
    }

    func testKeepsDefaultWhenLidIsClosed() {
        XCTAssertNil(choose([builtIn, airPods], default: airPods.id, lidClosed: true))
    }

    func testKeepsDefaultWithoutBuiltInMicrophone() {
        // 맥 mini · Studio, 또는 이어폰 단자 마이크만 있을 때
        XCTAssertNil(choose([airPods], default: airPods.id))
        XCTAssertNil(choose([headsetJack, airPods], default: airPods.id))
    }

    func testKeepsNonBluetoothDefault() {
        XCTAssertNil(choose([builtIn, airPods, usb], default: usb.id))
        XCTAssertNil(choose([builtIn, airPods], default: builtIn.id))
        XCTAssertNil(choose([builtIn, headsetJack], default: headsetJack.id))
    }

    func testUnknownDefaultKeepsSystemChoice() {
        XCTAssertNil(choose([builtIn, airPods], default: nil))
        XCTAssertNil(choose([builtIn, airPods], default: 999))
        XCTAssertNil(choose([], default: airPods.id))
    }

    func testBuiltInMicrophoneDetection() {
        let builtInTransport = kAudioDeviceTransportTypeBuiltIn
        XCTAssertTrue(AudioInputRouting.isBuiltInMicrophone(transportType: builtInTransport, uid: "BuiltInMicrophoneDevice",
                                                            dataSource: AudioInputRouting.internalMicrophoneSource))
        // 데이터 소스를 알려 주지 않는 드라이버는 UID로 가린다
        XCTAssertTrue(AudioInputRouting.isBuiltInMicrophone(transportType: builtInTransport, uid: "BuiltInMicrophoneDevice",
                                                            dataSource: nil))
        XCTAssertFalse(AudioInputRouting.isBuiltInMicrophone(transportType: builtInTransport, uid: "BuiltInHeadphoneInputDevice",
                                                             dataSource: nil))
        // 이어폰 단자 마이크로 바뀐 내장 입력
        XCTAssertFalse(AudioInputRouting.isBuiltInMicrophone(transportType: builtInTransport, uid: "BuiltInMicrophoneDevice",
                                                             dataSource: AudioInputRouting.externalMicrophoneSource))
        XCTAssertFalse(AudioInputRouting.isBuiltInMicrophone(transportType: kAudioDeviceTransportTypeUSB,
                                                             uid: "BuiltInMicrophoneDevice", dataSource: nil))
    }

    /// 블루투스 마이크를 열게 되는 때 (그때는 정말 듣기 시작할 때까지 열지 않는다)
    func testOpensBluetooth() {
        func opens(_ devices: [AudioInputDevice], default id: AudioDeviceID?, prefers: Bool = true, lidClosed: Bool = false) -> Bool {
            AudioInputRouting.opensBluetooth(devices: devices, defaultID: id, prefersBuiltInMicrophone: prefers, isLidClosed: lidClosed)
        }
        XCTAssertFalse(opens([builtIn, airPods], default: airPods.id))
        XCTAssertTrue(opens([builtIn, airPods], default: airPods.id, lidClosed: true))
        XCTAssertTrue(opens([builtIn, airPods], default: airPods.id, prefers: false))
        XCTAssertTrue(opens([airPods], default: airPods.id))
        XCTAssertTrue(opens([builtIn, leAudio], default: leAudio.id, prefers: false))
        XCTAssertFalse(opens([builtIn, airPods, usb], default: usb.id))
        XCTAssertFalse(opens([builtIn, airPods], default: nil))
    }

    func testBluetoothTransports() {
        XCTAssertTrue(airPods.isBluetooth)
        XCTAssertTrue(leAudio.isBluetooth)
        XCTAssertFalse(builtIn.isBluetooth)
        XCTAssertFalse(usb.isBluetooth)
    }
}
