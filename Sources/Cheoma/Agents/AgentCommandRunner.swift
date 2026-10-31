import Foundation

/// 터미널 연동에 쓰는 짧은 명령(tmux, osascript)을 실행하고 출력을 모은다.
/// 백그라운드 큐에서 부르는 동기 함수: 끝날 때까지(또는 시간이 다 될 때까지) 기다린다
enum AgentCommandRunner {
    struct Result {
        var status: Int32
        var output: String
        var error: String
        var timedOut: Bool
    }

    /// 실행 파일을 인자와 함께 돌린다. 시간이 넘으면 끝내고 timedOut = true.
    /// 실행 자체를 못 하면(파일 없음 등) 던진다
    static func run(_ executable: String, _ arguments: [String], input: String? = nil,
                    environment: [String: String]? = nil, timeout: TimeInterval) throws -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment { process.environment = environment }
        let outPipe = Pipe(), errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        let inPipe = input.map { _ in Pipe() }
        process.standardInput = inPipe ?? FileHandle.nullDevice

        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        try process.run()

        // 출력이 파이프 버퍼(64KB)보다 크면 자식이 쓰기에서 멈추므로, 끝나기를 기다리는 동안 따로 읽는다
        let output = PipeCollector(outPipe.fileHandleForReading)
        let error = PipeCollector(errPipe.fileHandleForReading)
        if let inPipe, let input {
            let handle = inPipe.fileHandleForWriting
            DispatchQueue.global(qos: .userInitiated).async {
                try? handle.write(contentsOf: Data(input.utf8))
                try? handle.close()
            }
        }

        var timedOut = false
        if finished.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            process.terminate()
            if finished.wait(timeout: .now() + 0.5) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = finished.wait(timeout: .now() + 0.5)
            }
        }
        // 자식이 띄운 손자(tmux 서버 등)가 파이프를 물고 있어도 오래 기다리지 않는다
        let deadline = DispatchTime.now() + 0.5
        return Result(status: process.isRunning ? -1 : process.terminationStatus,
                      output: output.text(waitingUntil: deadline),
                      error: error.text(waitingUntil: deadline),
                      timedOut: timedOut)
    }

    /// 파이프를 끝까지(EOF) 읽어서 모아 둔다
    private final class PipeCollector: @unchecked Sendable {
        private var data = Data()
        private let lock = NSLock()
        private let done = DispatchSemaphore(value: 0)

        init(_ handle: FileHandle) {
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                while true {
                    let chunk = handle.availableData
                    if chunk.isEmpty { break }
                    lock.withLock { data.append(chunk) }
                }
                done.signal()
            }
        }

        func text(waitingUntil deadline: DispatchTime) -> String {
            _ = done.wait(timeout: deadline)
            return lock.withLock { String(decoding: data, as: UTF8.self) }
        }
    }
}

extension AgentCommandRunner {
    /// 셸에 넘길 글자를 작은따옴표로 감싼다 (안의 작은따옴표도 안전하게)
    static func shellQuoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// 끝의 빈 줄을 지운다. ANSI 색 코드만 남은 줄도 빈 줄로 친다
    static func trimmingTrailingBlankLines(_ text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        while let last = lines.last, ANSIText.plain(last).allSatisfy(\.isWhitespace) {
            lines.removeLast()
        }
        return lines.joined(separator: "\n")
    }
}
