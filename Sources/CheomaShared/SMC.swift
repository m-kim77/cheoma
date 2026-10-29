import Foundation
import IOKit

/// AppleSMC 클라이언트.
/// 읽기는 일반 권한으로 된다 (1초 단위로 갱신되는 전력·온도·팬 센서).
/// 쓰기는 root 권한이 필요해서 관리자 권한 팬 도우미(CheomaFanHelper)에서만 쓴다.
public final class SMC {
    // AppleSMC 커널 확장의 SMCKeyData_t (C 구조체, 80바이트)와 메모리 배치가 같아야 한다
    private struct Version { var major: UInt8 = 0, minor: UInt8 = 0, build: UInt8 = 0, reserved: UInt8 = 0, release: UInt16 = 0 }
    private struct PLimit { var version: UInt16 = 0, length: UInt16 = 0, cpu: UInt32 = 0, gpu: UInt32 = 0, memory: UInt32 = 0 }
    private struct KeyInfo {
        var dataSize: UInt32 = 0
        var dataType: UInt32 = 0
        var attributes: UInt8 = 0
        // Swift는 구조체 꼬리 패딩에 다음 필드를 채워 넣으므로 C처럼 12바이트가 되게 직접 패딩
        var padding: (UInt8, UInt8, UInt8) = (0, 0, 0)
    }
    private struct KeyData {
        var key: UInt32 = 0
        var version = Version()
        var pLimit = PLimit()
        var keyInfo = KeyInfo()
        var result: UInt8 = 0
        var status: UInt8 = 0
        var command: UInt8 = 0
        var data32: UInt32 = 0
        var bytes: (UInt64, UInt64, UInt64, UInt64) = (0, 0, 0, 0)
    }

    private enum Command: UInt8 {
        case readKey = 5
        case writeKey = 6
        case keyAtIndex = 8
        case keyInfo = 9
    }

    private static let floatType = fourCC("flt ")
    private static let uint8Type = fourCC("ui8 ")
    private var connection: io_connect_t = 0
    private var keyInfoCache: [UInt32: KeyInfo] = [:]

    public init?() {
        guard MemoryLayout<KeyData>.stride == 80 else { return nil }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard IOServiceOpen(service, mach_task_self_, 0, &connection) == KERN_SUCCESS else { return nil }
    }

    deinit {
        IOServiceClose(connection)
    }

    /// 키가 있는지 (형식은 상관없이)
    public func hasKey(_ key: String) -> Bool {
        keyInfo(Self.fourCC(key)) != nil
    }

    /// 실수형(flt) 키 값. 키가 없거나 형식이 다르면 nil.
    public func float(_ key: String) -> Float? {
        let code = Self.fourCC(key)
        guard let info = keyInfo(code), info.dataType == Self.floatType, info.dataSize == 4 else { return nil }
        var input = KeyData()
        input.key = code
        input.keyInfo.dataSize = info.dataSize
        input.command = Command.readKey.rawValue
        guard var output = call(&input) else { return nil }
        let value = withUnsafeBytes(of: &output.bytes) { $0.load(as: Float.self) }
        return value.isFinite ? value : nil
    }

    /// 1바이트 정수(ui8) 키 값
    public func uint8(_ key: String) -> UInt8? {
        let code = Self.fourCC(key)
        guard let info = keyInfo(code), info.dataType == Self.uint8Type, info.dataSize == 1 else { return nil }
        var input = KeyData()
        input.key = code
        input.keyInfo.dataSize = info.dataSize
        input.command = Command.readKey.rawValue
        guard var output = call(&input) else { return nil }
        return withUnsafeBytes(of: &output.bytes) { $0[0] }
    }

    /// root 권한 필요. 형식이 맞지 않거나 실패하면 false.
    public func write(_ key: String, float value: Float) -> Bool {
        withUnsafeBytes(of: value) { write(key, type: Self.floatType, bytes: Array($0)) }
    }

    /// root 권한 필요. 형식이 맞지 않거나 실패하면 false.
    public func write(_ key: String, uint8 value: UInt8) -> Bool {
        write(key, type: Self.uint8Type, bytes: [value])
    }

    private func write(_ key: String, type: UInt32, bytes: [UInt8]) -> Bool {
        let code = Self.fourCC(key)
        guard let info = keyInfo(code), info.dataType == type, Int(info.dataSize) == bytes.count else { return false }
        var input = KeyData()
        input.key = code
        input.keyInfo.dataSize = info.dataSize
        input.command = Command.writeKey.rawValue
        withUnsafeMutableBytes(of: &input.bytes) { raw in
            for (index, byte) in bytes.enumerated() { raw[index] = byte }
        }
        return call(&input) != nil
    }

    /// 전체 키 이름 목록 (수천 개라 시작할 때 한 번만 호출할 것)
    public func allKeys() -> [String] {
        let countKey = Self.fourCC("#KEY")
        guard let info = keyInfo(countKey) else { return [] }
        var input = KeyData()
        input.key = countKey
        input.keyInfo.dataSize = info.dataSize
        input.command = Command.readKey.rawValue
        guard var output = call(&input) else { return [] }
        let count = withUnsafeBytes(of: &output.bytes) { UInt32(bigEndian: $0.load(as: UInt32.self)) }

        return (0..<count).compactMap { index in
            var request = KeyData()
            request.command = Command.keyAtIndex.rawValue
            request.data32 = index
            return call(&request).map { Self.string(fromFourCC: $0.key) }
        }
    }

    private func keyInfo(_ code: UInt32) -> KeyInfo? {
        if let cached = keyInfoCache[code] { return cached }
        var input = KeyData()
        input.key = code
        input.command = Command.keyInfo.rawValue
        guard let output = call(&input) else { return nil }
        keyInfoCache[code] = output.keyInfo
        return output.keyInfo
    }

    private func call(_ input: inout KeyData) -> KeyData? {
        var output = KeyData()
        var size = MemoryLayout<KeyData>.stride
        // selector 2 = kSMCHandleYPCEvent
        let result = IOConnectCallStructMethod(connection, 2, &input, MemoryLayout<KeyData>.stride, &output, &size)
        return result == KERN_SUCCESS && output.result == 0 ? output : nil
    }

    private static func fourCC(_ key: String) -> UInt32 {
        key.utf8.reduce(0) { $0 << 8 | UInt32($1) }
    }

    private static func string(fromFourCC code: UInt32) -> String {
        String(decoding: [24, 16, 8, 0].map { UInt8((code >> $0) & 0xFF) }, as: UTF8.self)
    }
}
