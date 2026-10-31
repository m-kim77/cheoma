import Foundation

/// JSONL 한 줄을 통째로 디코딩하지 않고 필요한 값만 꺼내는 바이트 스캐너.
/// 에이전트 기록은 수백 MB이고 대부분이 도구 출력이라, 최상위 키를 훑다가 필요 없는 줄이면 바로 그만둔다.
/// 문자열 안의 따옴표는 늘 \" 로 이스케이프되므로 구조만 따라가면 내용에 속지 않는다
struct JSONBytes {
    let base: UnsafePointer<UInt8>
    let end: Int

    init(base: UnsafePointer<UInt8>, count: Int) {
        self.base = base
        self.end = count
    }

    private static let quote = UInt8(ascii: "\"")
    private static let backslash = UInt8(ascii: "\\")

    @inline(__always) func byte(_ i: Int) -> UInt8? { i < end ? base[i] : nil }

    @inline(__always) func skipSpace(_ i: Int) -> Int {
        var i = i
        while i < end, base[i] == 0x20 || base[i] == 0x0A || base[i] == 0x0D || base[i] == 0x09 { i += 1 }
        return i
    }

    /// i는 여는 따옴표. 닫는 따옴표 다음 위치
    func stringEnd(_ i: Int) -> Int? {
        var j = i + 1
        while j < end {
            guard let found = memchr(base + j, Int32(Self.quote), end - j) else { return nil }
            let k = UnsafeRawPointer(found).assumingMemoryBound(to: UInt8.self) - base
            // 바로 앞의 역슬래시가 홀수 개면 이스케이프된 따옴표
            var backslashes = 0
            var b = k - 1
            while b > i, base[b] == Self.backslash {
                backslashes += 1
                b -= 1
            }
            if backslashes % 2 == 0 { return k + 1 }
            j = k + 1
        }
        return nil
    }

    /// i에서 시작하는 값 하나의 끝 위치
    func valueEnd(_ i: Int) -> Int? {
        guard i < end else { return nil }
        switch base[i] {
        case Self.quote:
            return stringEnd(i)
        case UInt8(ascii: "{"), UInt8(ascii: "["):
            var depth = 0
            var j = i
            while j < end {
                switch base[j] {
                case Self.quote:
                    guard let e = stringEnd(j) else { return nil }
                    j = e
                    continue
                case UInt8(ascii: "{"), UInt8(ascii: "["):
                    depth += 1
                case UInt8(ascii: "}"), UInt8(ascii: "]"):
                    depth -= 1
                    if depth == 0 { return j + 1 }
                default:
                    break
                }
                j += 1
            }
            return nil
        default:
            var j = i
            while j < end {
                let c = base[j]
                if c == UInt8(ascii: ",") || c == UInt8(ascii: "}") || c == UInt8(ascii: "]") || c == 0x20 || c == 0x0A || c == 0x0D || c == 0x09 { break }
                j += 1
            }
            return j > i ? j : nil
        }
    }

    /// 객체의 멤버를 차례로 넘긴다 (key는 따옴표 안쪽, value는 값 전체). body가 false를 돌려주면 멈춘다
    func forEachMember(ofObjectAt start: Int, _ body: (_ key: Range<Int>, _ value: Range<Int>) -> Bool) {
        var j = skipSpace(start)
        guard j < end, base[j] == UInt8(ascii: "{") else { return }
        j += 1
        while true {
            j = skipSpace(j)
            guard j < end, base[j] == Self.quote, let keyEnd = stringEnd(j) else { return }
            let key = (j + 1)..<(keyEnd - 1)
            j = skipSpace(keyEnd)
            guard j < end, base[j] == UInt8(ascii: ":") else { return }
            j = skipSpace(j + 1)
            guard let valueEnd = valueEnd(j) else { return }
            if !body(key, j..<valueEnd) { return }
            j = skipSpace(valueEnd)
            guard j < end, base[j] == UInt8(ascii: ",") else { return }
            j += 1
        }
    }

    /// 배열의 원소를 차례로 넘긴다. body가 false를 돌려주면 멈춘다
    func forEachElement(ofArrayAt start: Int, _ body: (_ value: Range<Int>) -> Bool) {
        var j = skipSpace(start)
        guard j < end, base[j] == UInt8(ascii: "[") else { return }
        j = skipSpace(j + 1)
        if j < end, base[j] == UInt8(ascii: "]") { return }
        while true {
            j = skipSpace(j)
            guard let valueEnd = valueEnd(j) else { return }
            if !body(j..<valueEnd) { return }
            j = skipSpace(valueEnd)
            guard j < end, base[j] == UInt8(ascii: ",") else { return }
            j += 1
        }
    }

    /// 객체에서 키 하나의 값 (처음 나온 것)
    func member(_ name: StaticString, ofObjectAt start: Int) -> Range<Int>? {
        var found: Range<Int>?
        forEachMember(ofObjectAt: start) { key, value in
            if self.key(key, is: name) {
                found = value
                return false
            }
            return true
        }
        return found
    }

    // MARK: - 값 읽기

    @inline(__always) func key(_ range: Range<Int>, is name: StaticString) -> Bool {
        range.count == name.utf8CodeUnitCount && memcmp(base + range.lowerBound, name.utf8Start, range.count) == 0
    }

    /// 문자열 값이 정확히 이 글자인지 (이스케이프 없는 짧은 값용: "assistant", "end_turn" …)
    func stringValue(_ range: Range<Int>, is text: StaticString) -> Bool {
        range.count == text.utf8CodeUnitCount + 2 && base[range.lowerBound] == Self.quote
            && memcmp(base + range.lowerBound + 1, text.utf8Start, text.utf8CodeUnitCount) == 0
    }

    /// 문자열 값이 이 글자로 시작하는지 (이스케이프되지 않은 앞부분만 본다)
    func stringValue(_ range: Range<Int>, hasPrefix text: StaticString) -> Bool {
        range.count >= text.utf8CodeUnitCount + 2 && base[range.lowerBound] == Self.quote
            && memcmp(base + range.lowerBound + 1, text.utf8Start, text.utf8CodeUnitCount) == 0
    }

    func isString(_ range: Range<Int>) -> Bool { range.count >= 2 && base[range.lowerBound] == Self.quote }
    func isObject(_ range: Range<Int>) -> Bool { !range.isEmpty && base[range.lowerBound] == UInt8(ascii: "{") }
    func isArray(_ range: Range<Int>) -> Bool { !range.isEmpty && base[range.lowerBound] == UInt8(ascii: "[") }
    func isTrue(_ range: Range<Int>) -> Bool { range.count == 4 && base[range.lowerBound] == UInt8(ascii: "t") }

    /// 따옴표 안쪽 바이트 (이스케이프 그대로). 중복 제거용 해시에 쓴다
    func rawString(_ range: Range<Int>) -> UnsafeRawBufferPointer? {
        guard isString(range) else { return nil }
        return UnsafeRawBufferPointer(start: base + range.lowerBound + 1, count: range.count - 2)
    }

    /// 문자열 값을 디코딩한다. maxBytes를 주면 원문 앞부분만 디코딩한다 (긴 메시지의 첫 줄만 필요할 때)
    func string(_ range: Range<Int>, maxBytes: Int = .max) -> String? {
        guard isString(range) else { return nil }
        let start = range.lowerBound + 1
        let stop = min(range.upperBound - 1, start + maxBytes)
        guard stop > start else { return "" }
        let raw = UnsafeBufferPointer(start: base + start, count: stop - start)
        if memchr(base + start, Int32(Self.backslash), stop - start) == nil {
            return String(decoding: raw, as: UTF8.self)
        }
        return Self.unescape(raw)
    }

    private static func unescape(_ raw: UnsafeBufferPointer<UInt8>) -> String {
        var out = [UInt8]()
        out.reserveCapacity(raw.count)
        var i = 0
        func hex4(_ at: Int) -> UInt32? {
            guard at + 4 <= raw.count else { return nil }
            var value: UInt32 = 0
            for k in at..<(at + 4) {
                let c = raw[k]
                let digit: UInt8
                switch c {
                case 0x30...0x39: digit = c - 0x30
                case 0x41...0x46: digit = c - 0x41 + 10
                case 0x61...0x66: digit = c - 0x61 + 10
                default: return nil
                }
                value = value << 4 | UInt32(digit)
            }
            return value
        }
        while i < raw.count {
            let c = raw[i]
            guard c == backslash, i + 1 < raw.count else {
                out.append(c)
                i += 1
                continue
            }
            let e = raw[i + 1]
            i += 2
            switch e {
            case UInt8(ascii: "n"): out.append(0x0A)
            case UInt8(ascii: "t"): out.append(0x09)
            case UInt8(ascii: "r"): out.append(0x0D)
            case UInt8(ascii: "b"): out.append(0x08)
            case UInt8(ascii: "f"): out.append(0x0C)
            case UInt8(ascii: "u"):
                guard var scalar = hex4(i) else { continue }
                i += 4
                // 서로게이트 쌍 (이모지 등)
                if (0xD800..<0xDC00).contains(scalar), i + 6 <= raw.count, raw[i] == backslash, raw[i + 1] == UInt8(ascii: "u"),
                   let low = hex4(i + 2), (0xDC00..<0xE000).contains(low) {
                    scalar = 0x10000 + ((scalar - 0xD800) << 10) + (low - 0xDC00)
                    i += 6
                }
                UTF8.encode(Unicode.Scalar(scalar) ?? "\u{FFFD}") { out.append($0) }
            default: out.append(e)
            }
        }
        return String(decoding: out, as: UTF8.self)
    }

    /// 정수 (1.0 같은 소수는 정수 부분만)
    func int(_ range: Range<Int>) -> Int? {
        var i = range.lowerBound
        guard i < range.upperBound else { return nil }
        var negative = false
        if base[i] == UInt8(ascii: "-") {
            negative = true
            i += 1
        }
        var value = 0
        var digits = 0
        while i < range.upperBound, base[i] >= 0x30, base[i] <= 0x39 {
            value = value &* 10 &+ Int(base[i] - 0x30)
            digits += 1
            i += 1
        }
        guard digits > 0 else { return nil }
        return negative ? -value : value
    }

    func double(_ range: Range<Int>) -> Double? {
        guard !range.isEmpty, range.count < 64 else { return nil }
        let c = base[range.lowerBound]
        guard c == UInt8(ascii: "-") || (c >= 0x30 && c <= 0x39) else { return nil }
        return Double(String(decoding: UnsafeBufferPointer(start: base + range.lowerBound, count: range.count), as: UTF8.self))
    }

    /// "2026-10-30T01:24:05.253Z" 같은 ISO 8601 시각 → 1970년부터 초. 수만 줄을 읽으니 포매터 대신 직접 계산한다
    func date(_ range: Range<Int>) -> Double? {
        guard isString(range), range.count >= 22 else { return nil }
        let s = range.lowerBound + 1
        func number(_ at: Int, _ length: Int) -> Int? {
            var value = 0
            for k in (s + at)..<(s + at + length) {
                let c = base[k]
                guard c >= 0x30, c <= 0x39 else { return nil }
                value = value * 10 + Int(c - 0x30)
            }
            return value
        }
        guard let year = number(0, 4), let month = number(5, 2), let day = number(8, 2),
              let hour = number(11, 2), let minute = number(14, 2), let second = number(17, 2),
              (1...12).contains(month) else { return nil }
        var i = s + 19
        let stop = range.upperBound - 1
        var fraction = 0.0
        if i < stop, base[i] == UInt8(ascii: ".") {
            i += 1
            var scale = 0.1
            while i < stop, base[i] >= 0x30, base[i] <= 0x39 {
                fraction += Double(base[i] - 0x30) * scale
                scale /= 10
                i += 1
            }
        }
        var offset = 0
        if i < stop, base[i] == UInt8(ascii: "+") || base[i] == UInt8(ascii: "-"), i + 6 <= stop {
            let sign = base[i] == UInt8(ascii: "-") ? -1 : 1
            if let h = number(i - s + 1, 2), let m = number(i - s + 4, 2) { offset = sign * (h * 3_600 + m * 60) }
        }
        // 그레고리력 날짜 → 1970-01-01부터 일수 (Howard Hinnant의 days_from_civil)
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let mp = (month + 9) % 12
        let doy = (153 * mp + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        let days = era * 146_097 + doe - 719_468
        return Double(days * 86_400 + hour * 3_600 + minute * 60 + second - offset) + fraction
    }

    /// 문자열 바이트를 해시 (메시지 ID 중복 제거용, 프로세스 안에서만 쓴다)
    func hash(_ ranges: Range<Int>...) -> Int {
        var hasher = Hasher()
        for range in ranges {
            hasher.combine(bytes: UnsafeRawBufferPointer(start: base + range.lowerBound, count: range.count))
            hasher.combine(0xFF as UInt8)
        }
        return hasher.finalize()
    }
}

/// JSONL 파일을 이어서 읽는다
enum JSONLFile {
    /// 파일의 offset부터 size까지 읽어 완성된 줄마다 body를 부른다.
    /// 마지막 줄이 아직 덜 써졌으면(줄바꿈 없음) 그 앞까지만 읽은 것으로 치고, 다음에 그 줄부터 다시 읽는다. 돌려주는 값은 다음에 읽을 위치
    static func readLines(path: String, from offset: Int64, to size: Int64, buffer: inout [UInt8], _ body: (JSONBytes) -> Void) -> Int64 {
        let fd = open(path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return offset }
        defer { close(fd) }
        var position = offset
        var carry = 0
        // 이보다 긴 한 줄(큰 이미지 첨부 등)은 버린다
        let maxLine = 128 << 20
        var skippingLongLine = false
        if buffer.count < 1 << 20 { buffer = [UInt8](repeating: 0, count: 4 << 20) }
        while position < size {
            if carry == buffer.count {
                if buffer.count >= maxLine {
                    carry = 0
                    skippingLongLine = true
                } else {
                    buffer.append(contentsOf: [UInt8](repeating: 0, count: buffer.count))
                }
            }
            let want = min(buffer.count - carry, Int(size - position))
            let n = buffer.withUnsafeMutableBytes { raw in pread(fd, raw.baseAddress! + carry, want, off_t(position)) }
            guard n > 0 else { break }
            position += Int64(n)
            let filled = carry + n
            var lineStart = 0
            buffer.withUnsafeBufferPointer { buf in
                let base = buf.baseAddress!
                while lineStart < filled, let found = memchr(base + lineStart, 0x0A, filled - lineStart) {
                    let newline = UnsafeRawPointer(found).assumingMemoryBound(to: UInt8.self) - base
                    if skippingLongLine {
                        skippingLongLine = false
                    } else if newline > lineStart {
                        body(JSONBytes(base: base + lineStart, count: newline - lineStart))
                    }
                    lineStart = newline + 1
                }
            }
            carry = filled - lineStart
            if carry > 0, lineStart > 0 {
                buffer.withUnsafeMutableBytes { raw in
                    let base = raw.baseAddress!
                    memmove(base, base + lineStart, carry)
                }
            }
        }
        return skippingLongLine ? position : position - Int64(carry)
    }

    /// 파일 끝 maxBytes 안의 완성된 줄들 (첫 줄은 잘렸을 수 있어서 버린다)
    static func readTail(path: String, size: Int64, maxBytes: Int64, buffer: inout [UInt8], _ body: (JSONBytes) -> Void) {
        let start = max(0, size - maxBytes)
        var skippedFirst = start == 0
        _ = readLines(path: path, from: start, to: size, buffer: &buffer) { line in
            if !skippedFirst {
                skippedFirst = true
                return
            }
            body(line)
        }
    }

    struct Stat: Equatable {
        var inode: UInt64
        var size: Int64
        var mtime: Double
    }

    static func stat(_ path: String) -> Stat? {
        var info = Darwin.stat()
        guard Darwin.stat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return nil }
        let mtime = Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1e9
        return Stat(inode: UInt64(info.st_ino), size: Int64(info.st_size), mtime: mtime)
    }

    /// 폴더 안 항목 이름과 폴더인지 여부 (FileManager보다 훨씬 가볍다: 15초마다 수천 개를 본다)
    static func list(_ path: String) -> [(name: String, isDirectory: Bool)] {
        guard let dir = opendir(path) else { return [] }
        defer { closedir(dir) }
        var result: [(String, Bool)] = []
        while let entry = readdir(dir) {
            let name = withUnsafeBytes(of: entry.pointee.d_name) { raw in
                String(decoding: raw.prefix(Int(entry.pointee.d_namlen)), as: UTF8.self)
            }
            if name.hasPrefix(".") { continue }
            let type = entry.pointee.d_type
            let isDirectory: Bool
            if type == DT_UNKNOWN || type == DT_LNK {
                var info = Darwin.stat()
                isDirectory = Darwin.stat(path + "/" + name, &info) == 0 && (info.st_mode & S_IFMT) == S_IFDIR
            } else {
                isDirectory = type == DT_DIR
            }
            result.append((name, isDirectory))
        }
        return result
    }
}
