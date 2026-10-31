import Foundation

// Claude Code 기록 (<설정 폴더>/projects/<작업 폴더>/<세션>.jsonl, 하위 에이전트는 <세션>/subagents/**.jsonl) 읽기.
//
// 비용: cost-state(세션 누적 비용)는 세션이 끝날 때만, 시각 없이 기록된다. 그래서 오늘 · 5시간 구간으로 나눌 수 없고 돌고 있는 세션에는 아예 없다.
// 대신 cost-state의 모델별 토큰과 비용으로 모델별 단가를 배우고(가격표를 코드에 넣지 않는다), 응답마다 기록된 토큰에 곱한다.
// 실제 기록으로 확인한 요금 구조: 입력 단가를 1로 놓으면 출력 5, 캐시 읽기 0.05, 5분 캐시 쓰기 1.25, 1시간 캐시 쓰기 2.
// 하위 에이전트가 없는 세션 61개에서 이 계산이 cost-state와 소수점까지 맞았다

extension AgentUsageReader {
    enum ClaudePricing {
        /// 입력 토큰 단가로 환산한 무게. 비용 = 모델 단가 × 무게
        static func weight(input: Int, output: Int, cacheRead: Int, cacheCreation: Int, cacheCreation5m: Int) -> Double {
            // 5분 · 1시간 구분이 없으면 1시간으로 본다 (Claude Code 기본값. 구분이 없는 옛 기록도 이렇게 해야 cost-state와 맞는다)
            let oneHour = max(0, cacheCreation - cacheCreation5m)
            return Double(input) + 5 * Double(output) + 0.05 * Double(cacheRead) + 1.25 * Double(cacheCreation5m) + 2 * Double(oneHour)
        }
    }

    /// 어시스턴트 응답 하나의 사용량
    struct ClaudeRecord {
        var time: Double
        var model: Int
        var weight: Double
        var tokens: Int
    }

    /// 기록 파일 하나를 어디까지 읽었는지와 거기서 알게 된 것
    final class ClaudeFile {
        var stat: JSONLFile.Stat
        var offset: Int64 = 0
        let isSubagent: Bool
        /// 세션 ID (하위 에이전트는 부모 세션)
        let sessionID: String
        /// 파일 안 중복 제거 (스트리밍 중에는 같은 메시지가 여러 줄로 기록된다)
        var keys = Set<Int>()
        /// 파일 전체의 모델별 무게 (세션 비용용)
        var weights: [Int: Double] = [:]
        var cwd: String?
        var title: String?
        var summary: String?
        var lastMessage: String?
        var isTurnComplete: Bool?
        var hasMessages = false

        init(stat: JSONLFile.Stat, isSubagent: Bool, sessionID: String) {
            self.stat = stat
            self.isSubagent = isSubagent
            self.sessionID = sessionID
        }
    }

    /// 설정 폴더 하나 (= 계정 하나)
    final class ClaudeAccount {
        let dir: String
        var files: [String: ClaudeFile] = [:]
        /// 계정 전체 중복 제거. 이어 하기(--resume)는 이전 대화를 새 파일에 다시 적는다
        var seen = Set<Int>()
        var records: [ClaudeRecord] = []
        var needsSort = false
        /// 지난번에 본 최상위 기록 파일들 (경로, 상태). 최근 세션 목록과 단가 배우기에 쓴다
        var sessionFiles: [(path: String, stat: JSONLFile.Stat)] = []

        init(dir: String) { self.dir = dir }

        func reset() {
            files = [:]
            seen = []
            records = []
            needsSort = false
        }
    }

    /// 세션 끝의 cost-state 하나
    struct CostStateSample {
        var totalCostUSD: Double
        /// 모델 이름 → (무게, 비용)
        var models: [String: (weight: Double, cost: Double)]
        var hasUnknownModelCost: Bool
    }

    // MARK: - 줄 읽기

    func parseClaudeLine(_ j: JSONBytes, file: ClaudeFile, account: ClaudeAccount, windowStart: Double) {
        guard j.byte(0) == UInt8(ascii: "{") else { return }
        var type: Range<Int>?
        var message: Range<Int>?
        var requestID: Range<Int>?
        var timestamp: Range<Int>?
        var cwd: Range<Int>?
        var subtype: Range<Int>?
        var aiTitle: Range<Int>?
        var summary: Range<Int>?
        let needsCwd = !file.isSubagent

        // 최상위 키를 훑다가 이 줄에서 더 볼 것이 없으면 멈춘다 (도구 출력이 든 큰 줄을 끝까지 넘기지 않으려고)
        j.forEachMember(ofObjectAt: 0) { key, value in
            switch key.count {
            case 3 where j.key(key, is: "cwd"): cwd = value
            case 4 where j.key(key, is: "type"): type = value
            case 7 where j.key(key, is: "message"): message = value
            case 7 where j.key(key, is: "subtype"): subtype = value
            case 7 where j.key(key, is: "aiTitle"): aiTitle = value
            case 7 where j.key(key, is: "summary"): summary = value
            case 9 where j.key(key, is: "requestId"): requestID = value
            case 9 where j.key(key, is: "timestamp"): timestamp = value
            default: break
            }
            guard let type else { return true }
            if j.stringValue(type, is: "assistant") {
                return message == nil || requestID == nil || timestamp == nil || (needsCwd && cwd == nil)
            }
            if j.stringValue(type, is: "user") {
                // 사용자 줄은 차례가 끝났는지만 본다. 작업 폴더는 아직 모를 때만 끝까지 찾는다
                if file.isSubagent { return false }
                return message == nil || (file.cwd == nil && cwd == nil)
            }
            if j.stringValue(type, is: "system") { return subtype == nil || (needsCwd && cwd == nil) }
            if j.stringValue(type, is: "ai-title") { return aiTitle == nil }
            if j.stringValue(type, is: "summary") { return summary == nil }
            return false
        }
        guard let type else { return }
        if let cwd, !file.isSubagent, let path = j.string(cwd), !path.isEmpty { file.cwd = path }

        if j.stringValue(type, is: "assistant"), let message {
            parseAssistant(j, message: message, requestID: requestID, timestamp: timestamp, file: file, account: account, windowStart: windowStart)
        } else if j.stringValue(type, is: "user"), !file.isSubagent {
            file.hasMessages = true
            file.isTurnComplete = message.map { userEndsTurn(j, message: $0) } ?? false
        } else if j.stringValue(type, is: "system"), let subtype, j.stringValue(subtype, is: "turn_duration") {
            // 차례가 끝날 때 기록된다
            file.isTurnComplete = true
        } else if let aiTitle, let title = j.string(aiTitle), !title.isEmpty {
            file.title = title
        } else if let summary, let text = j.string(summary, maxBytes: 400), !text.isEmpty {
            file.summary = text
        }
    }

    private func parseAssistant(_ j: JSONBytes, message: Range<Int>, requestID: Range<Int>?, timestamp: Range<Int>?,
                                file: ClaudeFile, account: ClaudeAccount, windowStart: Double) {
        var model: Range<Int>?
        var id: Range<Int>?
        var stopReason: Range<Int>?
        var usage: Range<Int>?
        var content: Range<Int>?
        j.forEachMember(ofObjectAt: message.lowerBound) { key, value in
            switch key.count {
            case 2 where j.key(key, is: "id"): id = value
            case 5 where j.key(key, is: "model"): model = value
            case 5 where j.key(key, is: "usage"): usage = value
            case 7 where j.key(key, is: "content"): content = value
            case 11 where j.key(key, is: "stop_reason"): stopReason = value
            default: break
            }
            return true
        }

        if !file.isSubagent {
            file.hasMessages = true
            // 도구를 쓰려고 멈춘 응답이면 아직 차례 중이다. 스트리밍 중간 줄은 stop_reason이 비어 있다
            if let stopReason, j.isString(stopReason) {
                file.isTurnComplete = !j.stringValue(stopReason, is: "tool_use")
            } else {
                file.isTurnComplete = false
            }
            if let content, let text = lastText(j, content: content) { file.lastMessage = text }
        }

        guard let usage, let model, j.isString(model), !j.stringValue(model, is: "<synthetic>") else { return }
        var input = 0, output = 0, cacheRead = 0, cacheCreation = 0, cacheCreation5m = 0
        j.forEachMember(ofObjectAt: usage.lowerBound) { key, value in
            if j.key(key, is: "input_tokens") {
                input = j.int(value) ?? 0
            } else if j.key(key, is: "output_tokens") {
                output = j.int(value) ?? 0
            } else if j.key(key, is: "cache_read_input_tokens") {
                cacheRead = j.int(value) ?? 0
            } else if j.key(key, is: "cache_creation_input_tokens") {
                cacheCreation = j.int(value) ?? 0
            } else if j.key(key, is: "cache_creation"), j.isObject(value) {
                if let five = j.member("ephemeral_5m_input_tokens", ofObjectAt: value.lowerBound) { cacheCreation5m = j.int(five) ?? 0 }
            }
            return true
        }
        let tokens = input + output + cacheRead + cacheCreation
        guard tokens > 0 else { return }
        let weight = ClaudePricing.weight(input: input, output: output, cacheRead: cacheRead,
                                          cacheCreation: cacheCreation, cacheCreation5m: cacheCreation5m)
        let modelID = modelIndex(j, model)

        let key: Int? = if let id, let requestID, j.isString(id), j.isString(requestID) { j.hash(id, requestID) } else { nil }
        if let key {
            guard file.keys.insert(key).inserted else { return }
        }
        file.weights[modelID, default: 0] += weight

        guard let timestamp, let time = j.date(timestamp), time >= windowStart else { return }
        if let key {
            guard account.seen.insert(key).inserted else { return }
        }
        if let last = account.records.last, last.time > time { account.needsSort = true }
        account.records.append(ClaudeRecord(time: time, model: modelID, weight: weight, tokens: tokens))
    }

    /// 사용자 줄이 차례를 끝내는지. 도구 결과나 새 지시는 차례 중, 중단 · 로컬 명령(/model 등)은 다음 지시를 기다리는 상태
    private func userEndsTurn(_ j: JSONBytes, message: Range<Int>) -> Bool {
        guard let content = j.member("content", ofObjectAt: message.lowerBound) else { return false }
        if j.isString(content) {
            return j.stringValue(content, hasPrefix: "[Request interrupted") || j.stringValue(content, hasPrefix: "<local-command")
                || j.stringValue(content, hasPrefix: "<command-name>")
        }
        var ends = false
        j.forEachElement(ofArrayAt: content.lowerBound) { block in
            if let text = j.member("text", ofObjectAt: block.lowerBound) {
                ends = j.stringValue(text, hasPrefix: "[Request interrupted")
            }
            return false
        }
        return ends
    }

    /// 응답의 마지막 글 블록에서 첫 줄 (100자까지)
    private func lastText(_ j: JSONBytes, content: Range<Int>) -> String? {
        guard j.isArray(content) else { return nil }
        var last: Range<Int>?
        j.forEachElement(ofArrayAt: content.lowerBound) { block in
            if let type = j.member("type", ofObjectAt: block.lowerBound), j.stringValue(type, is: "text"),
               let text = j.member("text", ofObjectAt: block.lowerBound) {
                last = text
            }
            return true
        }
        guard let last, let text = j.string(last, maxBytes: 2_000) else { return nil }
        return Self.firstLine(text)
    }

    /// 비어 있지 않은 첫 줄을 100자까지
    static func firstLine(_ text: String, limit: Int = 100) -> String? {
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            return trimmed.count > limit ? String(trimmed.prefix(limit - 1)) + "…" : trimmed
        }
        return nil
    }

    private func modelIndex(_ j: JSONBytes, _ range: Range<Int>) -> Int {
        let name = j.string(range) ?? "?"
        if let index = modelIndexes[name] { return index }
        modelNames.append(name)
        modelIndexes[name] = modelNames.count - 1
        return modelNames.count - 1
    }

    // MARK: - cost-state

    /// 파일 끝의 cost-state (세션이 끝날 때 기록된다)
    func readCostState(path: String, stat: JSONLFile.Stat) -> CostStateSample? {
        var sample: CostStateSample?
        JSONLFile.readTail(path: path, size: stat.size, maxBytes: 64 << 10, buffer: &buffer) { j in
            guard let type = j.member("type", ofObjectAt: 0), j.stringValue(type, is: "cost-state") else { return }
            var total = 0.0
            var unknown = false
            var models: [String: (Double, Double)] = [:]
            j.forEachMember(ofObjectAt: 0) { key, value in
                if j.key(key, is: "totalCostUSD") {
                    total = j.double(value) ?? 0
                } else if j.key(key, is: "hasUnknownModelCost") {
                    unknown = j.isTrue(value)
                } else if j.key(key, is: "modelUsage"), j.isObject(value) {
                    j.forEachMember(ofObjectAt: value.lowerBound) { modelKey, usage in
                        var input = 0, output = 0, cacheRead = 0, cacheCreation = 0, cacheCreation5m = 0
                        var cost = 0.0
                        j.forEachMember(ofObjectAt: usage.lowerBound) { k, v in
                            if j.key(k, is: "inputTokens") {
                                input = j.int(v) ?? 0
                            } else if j.key(k, is: "outputTokens") {
                                output = j.int(v) ?? 0
                            } else if j.key(k, is: "cacheReadInputTokens") {
                                cacheRead = j.int(v) ?? 0
                            } else if j.key(k, is: "cacheCreationInputTokens") {
                                cacheCreation = j.int(v) ?? 0
                            } else if j.key(k, is: "cacheCreationEphemeral5mInputTokens") {
                                cacheCreation5m = j.int(v) ?? 0
                            } else if j.key(k, is: "costUSD") {
                                cost = j.double(v) ?? 0
                            }
                            return true
                        }
                        let name = String(decoding: UnsafeBufferPointer(start: j.base + modelKey.lowerBound, count: modelKey.count), as: UTF8.self)
                        let weight = ClaudePricing.weight(input: input, output: output, cacheRead: cacheRead,
                                                          cacheCreation: cacheCreation, cacheCreation5m: cacheCreation5m)
                        models[name] = (weight, cost)
                        return true
                    }
                }
                return true
            }
            sample = CostStateSample(totalCostUSD: total, models: models.mapValues { (weight: $0.0, cost: $0.1) }, hasUnknownModelCost: unknown)
        }
        return sample
    }

    /// 모델별 단가 (무게 1당 달러). 세션마다 비용 ÷ 무게의 중앙값
    static func learnRates(from samples: [CostStateSample]) -> [String: Double] {
        var perModel: [String: [Double]] = [:]
        for sample in samples where !sample.hasUnknownModelCost {
            for (model, usage) in sample.models where usage.weight >= 1_000 && usage.cost > 0 {
                perModel[model, default: []].append(usage.cost / usage.weight)
            }
        }
        return perModel.mapValues { values in
            let sorted = values.sorted()
            return sorted[sorted.count / 2]
        }
    }

    /// 배운 적 없는 모델은 같은 계열(opus · sonnet · haiku …)에서 이름이 가장 뒤인(대개 최신) 모델 단가를 빌린다
    static func rate(for model: String, in rates: [String: Double]) -> Double? {
        if let rate = rates[model] { return rate }
        let families = ["opus", "sonnet", "haiku", "fable"]
        guard let family = families.first(where: { model.contains($0) }) else { return nil }
        return rates.filter { $0.key.contains(family) }.max { $0.key < $1.key }?.value
    }
}
