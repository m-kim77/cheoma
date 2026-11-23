import Accelerate
import AVFoundation
import CoreAudio
import IOKit

// 받아쓰기 마이크: 키를 누르는 동안만 열고, 하드웨어 형식 그대로 버퍼를 엔진에 넘긴다.

/// 마이크 권한 (시스템 설정 → 개인정보 보호 및 보안 → 마이크)
enum MicrophonePermission {
    static var status: AVAuthorizationStatus { AVCaptureDevice.authorizationStatus(for: .audio) }

    /// 아직 묻지 않았으면 시스템 창으로 묻는다. 이미 정해졌으면 묻지 않고 그 답을 돌려준다
    static func request() async -> Bool {
        switch status {
        case .authorized: true
        case .notDetermined: await AVCaptureDevice.requestAccess(for: .audio)
        default: false
        }
    }
}

// MARK: - 입력 장치 고르기

/// 입력 장치 하나. 고르는 규칙을 실제 장치 없이 시험할 수 있게 값만 담는다
struct AudioInputDevice: Equatable {
    var id: AudioDeviceID
    var uid: String
    var name: String
    /// kAudioDeviceTransportType… (내장 'bltn', 블루투스 'blue', 블루투스 LE 'blea', USB 'usb ')
    var transportType: UInt32
    /// 입력 쪽 데이터 소스 (내장 마이크 'imic', 이어폰 단자 마이크 'emic'). 장치가 알려 주지 않으면 nil
    var dataSource: UInt32?

    var isBluetooth: Bool {
        transportType == kAudioDeviceTransportTypeBluetooth || transportType == kAudioDeviceTransportTypeBluetoothLE
    }

    var isBuiltInMicrophone: Bool {
        AudioInputRouting.isBuiltInMicrophone(transportType: transportType, uid: uid, dataSource: dataSource)
    }
}

enum AudioInputRouting {
    static let internalMicrophoneSource: UInt32 = 0x696D_6963   // 'imic'
    static let externalMicrophoneSource: UInt32 = 0x656D_6963   // 'emic'

    /// 노트북 몸체의 마이크인지 (덮개를 닫으면 소리가 안 들어온다).
    /// 이어폰 단자 마이크도 같은 내장 코덱이라 연결 방식만으로는 못 가린다. 데이터 소스를 보고, 없으면 시스템이 붙이는 UID를 본다
    /// (VoiceInk의 AudioDeviceManager.swift와 같은 규칙)
    static func isBuiltInMicrophone(transportType: UInt32, uid: String, dataSource: UInt32?) -> Bool {
        guard transportType == kAudioDeviceTransportTypeBuiltIn else { return false }
        switch dataSource {
        case internalMicrophoneSource: return true
        case externalMicrophoneSource: return false
        default: return uid == "BuiltInMicrophoneDevice"
        }
    }

    /// 시스템 기본 입력 대신 열 장치. nil이면 기본 입력을 그대로 쓴다.
    /// 블루투스 헤드셋 마이크를 열면 헤드셋이 통화 음질(HFP)로 바뀌어 듣던 소리가 나빠지니, 내장 마이크가 있으면 그쪽을 쓴다.
    /// 덮개를 닫았으면 내장 마이크에 소리가 안 들어오니 기본 입력(헤드셋)을 쓴다
    static func override(devices: [AudioInputDevice], defaultID: AudioDeviceID?,
                         prefersBuiltInMicrophone: Bool, isLidClosed: Bool) -> AudioInputDevice? {
        guard prefersBuiltInMicrophone, !isLidClosed,
              let current = devices.first(where: { $0.id == defaultID }), current.isBluetooth,
              let builtIn = devices.first(where: \.isBuiltInMicrophone) else { return nil }
        return builtIn
    }

    /// 지금 열면 블루투스 마이크가 열리는지 (내장 마이크로 바꿔 열면 아니다)
    static func opensBluetooth(devices: [AudioInputDevice], defaultID: AudioDeviceID?,
                               prefersBuiltInMicrophone: Bool, isLidClosed: Bool) -> Bool {
        let opened = override(devices: devices, defaultID: defaultID, prefersBuiltInMicrophone: prefersBuiltInMicrophone,
                              isLidClosed: isLidClosed) ?? devices.first { $0.id == defaultID }
        return opened?.isBluetooth == true
    }
}

// MARK: - 소리 크기

/// 버퍼의 소리 크기를 0…1로 바꾼다. 말소리는 대개 -50…-10 dB 사이라 그 구간을 0…1로 늘려 보여 준다
enum AudioLevelMeter {
    static let floorDecibels: Float = -50
    static let ceilingDecibels: Float = -10

    static func level(rms: Float) -> Float {
        guard rms.isFinite, rms > 0 else { return 0 }
        let decibels = 20 * log10f(rms)
        return min(max((decibels - floorDecibels) / (ceilingDecibels - floorDecibels), 0), 1)
    }

    /// 모든 채널을 합친 RMS (float32 · int16 버퍼)
    static func rms(of buffer: AVAudioPCMBuffer) -> Float {
        let frames = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        guard frames > 0, channels > 0 else { return 0 }
        // 교차(interleaved) 버퍼는 첫 포인터에 모든 채널이 번갈아 들어 있다
        let pointers = buffer.format.isInterleaved ? 1 : channels
        let samplesPerPointer = buffer.format.isInterleaved ? frames * channels : frames
        var squares: Float = 0
        if let data = buffer.floatChannelData {
            for index in 0..<pointers {
                let value = rms(UnsafeBufferPointer(start: data[index], count: samplesPerPointer))
                squares += value * value
            }
        } else if let data = buffer.int16ChannelData {
            for index in 0..<pointers {
                var sum: Float = 0
                for sample in UnsafeBufferPointer(start: data[index], count: samplesPerPointer) {
                    let value = Float(sample) / 32768
                    sum += value * value
                }
                squares += sum / Float(samplesPerPointer)
            }
        } else {
            return 0
        }
        return (squares / Float(pointers)).squareRoot()
    }

    static func rms(_ samples: UnsafeBufferPointer<Float>) -> Float {
        guard let base = samples.baseAddress, !samples.isEmpty else { return 0 }
        var result: Float = 0
        vDSP_rmsqv(base, 1, &result, vDSP_Length(samples.count))
        return result.isFinite ? result : 0
    }
}

/// 소리 크기 막대가 떨리지 않게 한다. 커질 때는 빨리 따라가고 작아질 때는 천천히 내려온다
struct AudioLevelSmoother {
    var attack: Float = 0.6
    var release: Float = 0.2
    private(set) var value: Float = 0

    mutating func next(_ target: Float) -> Float {
        let target = target.isFinite ? min(max(target, 0), 1) : 0
        value += (target - value) * (target > value ? attack : release)
        if value < 0.001 { value = 0 }
        return value
    }
}

// MARK: - 마이크

/// AVAudioEngine 입력 노드에 탭을 달아 마이크 버퍼를 받는다.
/// 열 때마다 엔진을 새로 만들고 멈추면 버린다. 장치를 완전히 놓아야 AirPods가 통화 음질에서 돌아온다.
/// start · stop은 메인 스레드에서 부른다. onBuffer는 오디오 스레드, onLevel · onInterrupted는 메인 스레드에서 온다
final class DictationAudioCapture: DictationAudioSource {
    /// 이만큼 지나도 버퍼가 하나도 오지 않으면 마이크가 멈춘 것으로 본다 (블루투스 헤드셋은 여는 데 1초쯤 걸린다)
    static let silenceTimeout: TimeInterval = 2
    static let levelInterval: TimeInterval = 0.05

    var onBuffer: ((AVAudioPCMBuffer) -> Void)? {
        didSet { tap?.setHandler(onBuffer) }
    }
    var onLevel: ((Float) -> Void)?
    /// 듣는 도중 마이크가 바뀌거나 빠졌다. 마이크를 이미 닫은 뒤에 부른다
    var onInterrupted: ((DictationError) -> Void)?

    /// 지금 열린 입력 장치 (닫혀 있으면 nil)
    private(set) var activeDevice: AudioInputDevice?
    var isRunning: Bool { engine != nil }

    private var engine: AVAudioEngine?
    private var format: AVAudioFormat?
    private var tap: CaptureTap?
    private var levelTimer: DispatchSourceTimer?
    private var smoother = AudioLevelSmoother()
    private var startedAt: TimeInterval = 0
    private var configurationObserver: NSObjectProtocol?
    private var aliveListener: (device: AudioDeviceID, block: AudioObjectPropertyListenerBlock)?

    deinit { stop() }

    /// Core Audio를 미리 깨워 둔다. 프로세스에서 처음 장치를 읽을 때는 40~50 ms 걸리고 그 뒤로는 0.2 ms쯤이다.
    /// 받아쓰기를 켤 때 한 번 부르면 첫 누름의 start가 빨라진다 (마이크는 열지 않는다)
    func prepare() {
        DispatchQueue.global(qos: .utility).async { _ = AudioHardware.inputDevices() }
    }

    func start(prefersBuiltInMicrophone: Bool) throws -> AVAudioFormat {
        if let format, engine?.isRunning == true { return format }
        stop()
        // 권한 없이 열면 오류 없이 조용한 소리만 온다
        switch MicrophonePermission.status {
        case .authorized:
            break
        case .notDetermined:
            // 처음이면 시스템이 묻는 창을 띄우고 이번 누름은 버린다
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
            throw DictationError.microphoneUnavailable("마이크 권한을 허용한 후 다시 시도하십시오")
        default:
            throw DictationError.microphoneDenied
        }

        let (devices, defaultID, isLidClosed) = Self.inputs(prefersBuiltInMicrophone: prefersBuiltInMicrophone)
        guard !devices.isEmpty else { throw DictationError.microphoneUnavailable("입력 장치 없음") }
        let override = AudioInputRouting.override(devices: devices, defaultID: defaultID,
                                                  prefersBuiltInMicrophone: prefersBuiltInMicrophone,
                                                  isLidClosed: isLidClosed)

        let engine = AVAudioEngine()
        let input = engine.inputNode
        // 시스템 기본 입력은 그대로 두고 이 엔진만 내장 마이크를 연다
        if let override, let unit = input.audioUnit {
            let status = AudioHardware.setCurrentDevice(override.id, of: unit)
            if status != noErr { AppLog.write("받아쓰기: 내장 마이크로 바꾸지 못해 기본 입력을 씀 (\(status))") }
        }
        let hardware = input.inputFormat(forBus: 0)
        let format = input.outputFormat(forBus: 0)
        guard hardware.sampleRate > 0, hardware.channelCount > 0 else {
            throw DictationError.microphoneUnavailable("입력 장치 없음")
        }
        // 탭 형식이 하드웨어와 다르면 AVAudioEngine이 예외로 앱을 끝낸다. 장치가 막 바뀌는 중이면 그럴 수 있어 미리 막는다
        guard format.sampleRate == hardware.sampleRate, format.channelCount == hardware.channelCount else {
            throw DictationError.microphoneUnavailable("입력 형식이 맞지 않습니다. 다시 시도하십시오")
        }

        let tap = CaptureTap(handler: onBuffer)
        // 짧게 청해도 엔진이 0.1초 단위로 줄 수 있다 (AVAudioNode 문서의 범위는 0.1…0.4초)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            tap.receive(buffer)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            tap.deactivate()
            input.removeTap(onBus: 0)
            throw DictationError.microphoneUnavailable("장치가 응답하지 않습니다 (오류 \((error as NSError).code))")
        }

        self.engine = engine
        self.format = format
        self.tap = tap
        let currentID = input.audioUnit.flatMap(AudioHardware.currentDevice(of:)) ?? override?.id ?? defaultID
        activeDevice = devices.first { $0.id == currentID }
        smoother = AudioLevelSmoother()
        startedAt = ProcessInfo.processInfo.systemUptime
        observeChanges(of: engine, device: currentID)
        startLevelTimer()
        return format
    }

    /// 장치를 열지 않고 읽는다 (prepare 뒤로는 0.2 ms쯤). 이미 열려 있으면 그것을 그대로 쓰니 false
    func opensBluetoothInput(prefersBuiltInMicrophone: Bool) -> Bool {
        if engine?.isRunning == true { return false }
        let (devices, defaultID, isLidClosed) = Self.inputs(prefersBuiltInMicrophone: prefersBuiltInMicrophone)
        return AudioInputRouting.opensBluetooth(devices: devices, defaultID: defaultID,
                                                prefersBuiltInMicrophone: prefersBuiltInMicrophone, isLidClosed: isLidClosed)
    }

    /// 입력 장치들 · 기본 입력 · 덮개 상태 (덮개는 기본 입력이 블루투스일 때만 본다)
    private static func inputs(prefersBuiltInMicrophone: Bool) -> (devices: [AudioInputDevice], defaultID: AudioDeviceID?,
                                                                   isLidClosed: Bool) {
        let devices = AudioHardware.inputDevices()
        let defaultID = AudioHardware.defaultInputDeviceID()
        let defaultIsBluetooth = devices.first { $0.id == defaultID }?.isBluetooth == true
        return (devices, defaultID, prefersBuiltInMicrophone && defaultIsBluetooth && AudioHardware.isLidClosed)
    }

    /// 마이크를 닫는다. 여러 번 불러도 된다
    func stop() {
        guard let engine else { return }
        tap?.deactivate()
        levelTimer?.cancel()
        levelTimer = nil
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        configurationObserver = nil
        if let aliveListener {
            var address = AudioHardware.address(kAudioDevicePropertyDeviceIsAlive)
            AudioObjectRemovePropertyListenerBlock(aliveListener.device, &address, .main, aliveListener.block)
        }
        aliveListener = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        self.engine = nil
        format = nil
        tap = nil
        activeDevice = nil
    }

    // MARK: 바뀜 감지

    private func observeChanges(of engine: AVAudioEngine, device: AudioDeviceID?) {
        // 듣는 도중 장치의 형식이 바뀌면(이어폰을 뽑음 · 기본 입력이 바뀜) 엔진이 스스로 멈추고 알린다.
        // 엔진에 넘긴 형식이 더는 맞지 않으니 이어 붙이지 않고 멈춘다
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self, weak engine] _ in
            guard let self, let engine, engine === self.engine else { return }
            // 아직 돌고 있으면 장치를 고르며 생긴 알림이다
            guard !engine.isRunning else { return }
            self.interrupt(.microphoneUnavailable("마이크가 변경되었습니다"))
        }
        // 쓰던 장치가 빠졌다 (USB 마이크를 뽑음 · 헤드셋 연결이 끊김)
        guard let device else { return }
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self, self.activeDevice?.id == device, !AudioHardware.isAlive(device) else { return }
            self.interrupt(.microphoneUnavailable("마이크 연결이 끊어졌습니다"))
        }
        var address = AudioHardware.address(kAudioDevicePropertyDeviceIsAlive)
        if AudioObjectAddPropertyListenerBlock(device, &address, .main, block) == noErr {
            aliveListener = (device, block)
        }
    }

    private func interrupt(_ error: DictationError) {
        guard engine != nil else { return }
        AppLog.write("받아쓰기: \(error.message)")
        stop()
        onInterrupted?(error)
    }

    // MARK: 소리 크기

    private func startLevelTimer() {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        let interval = DispatchTimeInterval.milliseconds(Int(Self.levelInterval * 1000))
        timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(10))
        timer.setEventHandler { [weak self] in self?.reportLevel() }
        timer.resume()
        levelTimer = timer
    }

    private func reportLevel() {
        guard let tap else { return }
        let reading = tap.takeLevel()
        if reading.buffers == 0, ProcessInfo.processInfo.systemUptime - startedAt > Self.silenceTimeout {
            interrupt(.microphoneUnavailable("마이크에서 소리가 들어오지 않습니다"))
            return
        }
        onLevel?(smoother.next(reading.level))
    }
}

/// 오디오 스레드(탭)와 메인 스레드가 같이 보는 값. 멈춘 뒤 늦게 온 버퍼는 넘기지 않는다
private final class CaptureTap: @unchecked Sendable {
    private let lock = NSLock()
    private var isActive = true
    private var handler: ((AVAudioPCMBuffer) -> Void)?
    /// 지난번에 읽은 뒤로 가장 큰 소리 (버퍼가 0.1초마다 와서 0.05초마다 읽으면 새 버퍼가 없을 때도 있다)
    private var peak: Float?
    private var lastLevel: Float = 0
    private var buffers = 0

    init(handler: ((AVAudioPCMBuffer) -> Void)?) {
        self.handler = handler
    }

    func setHandler(_ handler: ((AVAudioPCMBuffer) -> Void)?) {
        lock.lock()
        self.handler = handler
        lock.unlock()
    }

    func deactivate() {
        lock.lock()
        isActive = false
        handler = nil
        lock.unlock()
    }

    /// 오디오 스레드
    func receive(_ buffer: AVAudioPCMBuffer) {
        let level = AudioLevelMeter.level(rms: AudioLevelMeter.rms(of: buffer))
        lock.lock()
        guard isActive else {
            lock.unlock()
            return
        }
        peak = max(peak ?? 0, level)
        buffers += 1
        let handler = handler
        lock.unlock()
        handler?(buffer)
    }

    /// 메인 스레드. 새 버퍼가 없으면 지난 값을 그대로 쓴다
    func takeLevel() -> (level: Float, buffers: Int) {
        lock.lock()
        defer { lock.unlock() }
        if let peak {
            lastLevel = peak
            self.peak = nil
        }
        return (lastLevel, buffers)
    }
}

// MARK: - Core Audio 읽기

/// 입력 장치 목록 · 기본 입력 · 덮개 상태를 읽는다 (장치를 열지 않는다)
enum AudioHardware {
    static func address(_ selector: AudioObjectPropertySelector,
                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    /// 입력 채널이 있는 장치들
    static func inputDevices() -> [AudioInputDevice] {
        var address = address(kAudioHardwarePropertyDevices)
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            guard inputChannelCount(id) > 0 else { return nil }
            return AudioInputDevice(
                id: id,
                uid: string(id, kAudioDevicePropertyDeviceUID) ?? "",
                name: string(id, kAudioObjectPropertyName) ?? "",
                transportType: value(id, kAudioDevicePropertyTransportType, initial: UInt32(0)) ?? 0,
                dataSource: value(id, kAudioDevicePropertyDataSource, scope: kAudioDevicePropertyScopeInput, initial: UInt32(0))
            )
        }
    }

    static func defaultInputDeviceID() -> AudioDeviceID? {
        let id = value(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultInputDevice,
                       initial: AudioDeviceID(kAudioObjectUnknown))
        return id == AudioDeviceID(kAudioObjectUnknown) ? nil : id
    }

    static func isAlive(_ id: AudioDeviceID) -> Bool {
        (value(id, kAudioDevicePropertyDeviceIsAlive, initial: UInt32(0)) ?? 0) != 0
    }

    /// 노트북 덮개를 닫았는지 (데스크톱 맥은 늘 false)
    static var isLidClosed: Bool {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != 0 else { return false }
        defer { IOObjectRelease(service) }
        let value = IORegistryEntryCreateCFProperty(service, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)
        return (value?.takeRetainedValue() as? Bool) ?? false
    }

    /// 입력 노드(AUHAL)가 열 장치를 바꾼다. 엔진을 시작하기 전에만 된다
    static func setCurrentDevice(_ id: AudioDeviceID, of unit: AudioUnit) -> OSStatus {
        var device = id
        return AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                    &device, UInt32(MemoryLayout<AudioDeviceID>.size))
    }

    static func currentDevice(of unit: AudioUnit) -> AudioDeviceID? {
        var device = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                          &device, &size)
        return status == noErr && device != AudioDeviceID(kAudioObjectUnknown) ? device : nil
    }

    private static func inputChannelCount(_ id: AudioDeviceID) -> Int {
        var address = address(kAudioDevicePropertyStreamConfiguration, scope: kAudioDevicePropertyScopeInput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let storage = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { storage.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, storage) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(storage.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func value<T>(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector,
                                 scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, initial: T) -> T? {
        var address = address(selector, scope: scope)
        var size = UInt32(MemoryLayout<T>.size)
        var value = initial
        let status = withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(id, &address, 0, nil, &size, $0) }
        return status == noErr ? value : nil
    }

    private static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = address(selector)
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var value: Unmanaged<CFString>?
        let status = withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(id, &address, 0, nil, &size, $0) }
        guard status == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }
}
