import AppKit
import Foundation

/// 이 맥에서 도는 로컬 모델 서버 하나 (Ollama, LM Studio, Unsloth Studio, llama.cpp)
struct LocalModelServer: Equatable, Sendable {
    enum Kind: String, Sendable {
        case ollama, lmStudio, unsloth, llamaCpp

        var displayName: String {
            switch self {
            case .ollama: "Ollama"
            case .lmStudio: "LM Studio"
            case .unsloth: "Unsloth"
            case .llamaCpp: "llama.cpp"
            }
        }
    }

    var kind: Kind
    /// API 주소 ("http://127.0.0.1:11434"). 서버가 꺼져 있으면 nil
    var address: String?
    /// 앱은 켜져 있지만 API 서버가 꺼져 있다 (LM Studio는 개발자 탭에서 서버를 켜야 모델이 보인다)
    var isServerOff = false
    /// 메모리에 올라온 모델
    var models: [LocalModel] = []
}

/// 메모리에 올라온 모델 하나
struct LocalModel: Equatable, Sendable {
    var name: String
    /// 모델이 차지하는 메모리 (바이트)
    var memoryBytes: Int64?
    /// "8.2B", "Q4_K_M" 같은 설명
    var detail: String?
    /// 컨텍스트 길이 (토큰)
    var contextLength: Int?
    /// 이때 메모리에서 내려간다 (Ollama keep_alive)
    var expiresAt: Date?
}

/// 로컬 모델 서버를 읽는다 (내 맥의 localhost와 프로세스만). 백그라운드 큐에서 부른다
enum LocalModelReader {
    static let ollamaAddress = "http://127.0.0.1:11434"
    static let lmStudioAddress = "http://127.0.0.1:1234"
    static let lmStudioBundleID = "ai.elementlabs.lmstudio"
    static let unslothBundleID = "ai.unsloth.studio"

    static func read() -> [LocalModelServer] {
        var result: [LocalModelServer] = []
        if let ollama = readOllama() { result.append(ollama) }
        if let lmStudio = readLMStudio() { result.append(lmStudio) }
        result += readLlamaServers()
        return result
    }

    // MARK: - Ollama

    private static func readOllama() -> LocalModelServer? {
        guard let json = getJSON(ollamaAddress + "/api/ps") else { return nil }
        let models = (json["models"] as? [[String: Any]] ?? []).map(ollamaModel)
        return LocalModelServer(kind: .ollama, address: ollamaAddress, models: models)
    }

    /// /api/ps의 모델 하나: name, size, size_vram, expires_at, context_length, details.parameter_size · quantization_level
    static func ollamaModel(_ item: [String: Any]) -> LocalModel {
        let details = item["details"] as? [String: Any]
        let detail = [details?["parameter_size"] as? String, details?["quantization_level"] as? String]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        return LocalModel(name: item["name"] as? String ?? item["model"] as? String ?? "?",
                          memoryBytes: number(item["size"]).map(Int64.init),
                          detail: detail.isEmpty ? nil : detail,
                          contextLength: number(item["context_length"]).map(Int.init),
                          expiresAt: (item["expires_at"] as? String).flatMap(parseDate))
    }

    // MARK: - LM Studio

    private static func readLMStudio() -> LocalModelServer? {
        if let json = getJSON(lmStudioAddress + "/api/v0/models") {
            let loaded = (json["data"] as? [[String: Any]] ?? []).filter { ($0["state"] as? String) == "loaded" }
            return LocalModelServer(kind: .lmStudio, address: lmStudioAddress, models: loaded.map(lmStudioModel))
        }
        guard isAppRunning(lmStudioBundleID) else { return nil }
        return LocalModelServer(kind: .lmStudio, address: nil, isServerOff: true)
    }

    /// /api/v0/models의 모델 하나: id, quantization, loaded_context_length · max_context_length
    static func lmStudioModel(_ item: [String: Any]) -> LocalModel {
        let detail = [item["arch"] as? String, item["quantization"] as? String].compactMap { $0 }.joined(separator: " · ")
        return LocalModel(name: item["id"] as? String ?? "?", memoryBytes: nil, detail: detail.isEmpty ? nil : detail,
                          contextLength: number(item["loaded_context_length"] ?? item["max_context_length"]).map(Int.init))
    }

    // MARK: - llama-server (Unsloth Studio · llama.cpp)

    /// llama-server 프로세스마다 하나. Unsloth Studio가 띄운 것은 Unsloth로 묶는다.
    /// Unsloth 앱이 켜져 있는데 모델이 없으면 빈 Unsloth를 하나 둔다
    private static func readLlamaServers() -> [LocalModelServer] {
        var unsloth = LocalModelServer(kind: .unsloth)
        var others: [LocalModelServer] = []
        for process in AgentScanner.processes(named: ["llama-server"]) {
            let (model, port) = llamaServerArguments(process.arguments)
            let address = port.map { "http://127.0.0.1:\($0)" }
            let item = LocalModel(name: model.map(modelName) ?? "모델", memoryBytes: process.residentBytes)
            if process.path.contains("unsloth") || process.ancestorPaths.contains(where: { $0.contains("Unsloth") || $0.contains("unsloth") }) {
                unsloth.address = unsloth.address ?? address
                unsloth.models.append(item)
            } else {
                others.append(LocalModelServer(kind: .llamaCpp, address: address, models: [item]))
            }
        }
        let unslothRunning = !unsloth.models.isEmpty || isAppRunning(unslothBundleID)
        return (unslothRunning ? [unsloth] : []) + others
    }

    /// llama-server 인자에서 모델 이름(--alias가 있으면 그것, 없으면 모델 파일 · HF 저장소)과 포트 (기본 8080)
    static func llamaServerArguments(_ arguments: [String]) -> (model: String?, port: Int?) {
        var model: String?
        var alias: String?
        var port: Int?
        var index = 1
        while index < arguments.count {
            let next = index + 1 < arguments.count ? arguments[index + 1] : nil
            switch arguments[index] {
            case "-m", "--model": model = next; index += 1
            case "-hf", "-hfr", "--hf-repo": model = model ?? next; index += 1
            case "-a", "--alias": alias = next; index += 1
            case "--port": port = next.flatMap(Int.init); index += 1
            default: break
            }
            index += 1
        }
        return (alias ?? model, port ?? 8080)
    }

    /// 모델 파일 경로 → 이름 ("…/Qwen3-8B-Q4_K_M.gguf" → "Qwen3-8B-Q4_K_M")
    static func modelName(_ path: String) -> String {
        let last = (path as NSString).lastPathComponent
        return last.hasSuffix(".gguf") ? String(last.dropLast(5)) : last
    }

    // MARK: - 도우미

    private static func isAppRunning(_ bundleID: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    /// localhost GET. 서버가 없으면 바로 실패한다 (연결 거부). 느린 서버를 오래 기다리지 않는다
    private static func getJSON(_ address: String) -> [String: Any]? {
        guard let url = URL(string: address) else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 0.8)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var body: Data?
        let task = session.dataTask(with: request) { data, response, _ in
            if let http = response as? HTTPURLResponse, http.statusCode == 200 { body = data }
            done.signal()
        }
        task.resume()
        if done.wait(timeout: .now() + 1.0) == .timedOut { task.cancel() }
        return body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        configuration.timeoutIntervalForRequest = 0.8
        return URLSession(configuration: configuration)
    }()

    private static func number(_ value: Any?) -> Double? {
        (value as? NSNumber)?.doubleValue
    }

    private static func parseDate(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        // Ollama는 소수점 아래 9자리 ("2026-11-02T02:10:00.123456789+09:00"): 3자리로 줄여 본다
        if let dot = text.firstIndex(of: "."), let zone = text[dot...].firstIndex(where: { $0 == "+" || $0 == "-" || $0 == "Z" }) {
            let fraction = text[text.index(after: dot)..<zone].prefix(3)
            let trimmed = String(text[..<dot]) + "." + fraction + String(text[zone...])
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return formatter.date(from: trimmed)
        }
        return formatter.date(from: text)
    }
}
