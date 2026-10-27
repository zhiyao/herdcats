import Foundation

enum AgentQuestionKind: String, Codable, Sendable { case claude, agy, cursor, codexPlan = "codex_plan", codexAsync = "codex_async" }
struct AgentQuestionOption: Codable, Equatable, Sendable {
    let number: UInt32
    let label: String
    var description: String? = nil
}
struct AgentQuestion: Codable, Equatable, Sendable {
    let index: Int
    var header: String? = nil
    let text: String
    let options: [AgentQuestionOption]
    let multiSelect: Bool
    let allowsOther: Bool
}
enum AgentQuestionStep: Codable, Equatable, Sendable {
    case claudeQuestion(index: Int), claudeReview, codexQuestion(index: Int, total: Int), agyQuestion(index: Int, total: Int)
    /// The one question a Cursor form is showing now; `index` and `total` locate it in the form.
    case cursorQuestion(index: Int, total: Int)
    case asyncQueued, asyncPicker(index: Int)
    private enum CodingKeys: String, CodingKey { case kind, index, total }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .kind) {
        case "claude_question": self = .claudeQuestion(index: try c.decode(Int.self, forKey: .index))
        case "claude_review": self = .claudeReview
        case "agy_question": self = .agyQuestion(index: try c.decode(Int.self, forKey: .index), total: try c.decode(Int.self, forKey: .total))
        case "cursor_question": self = .cursorQuestion(index: try c.decode(Int.self, forKey: .index), total: try c.decode(Int.self, forKey: .total))
        case "codex_question": self = .codexQuestion(index: try c.decode(Int.self, forKey: .index), total: try c.decode(Int.self, forKey: .total))
        case "async_queued": self = .asyncQueued
        case "async_picker": self = .asyncPicker(index: try c.decode(Int.self, forKey: .index))
        default: throw AgentBridgeError.invalidFrame
        }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .claudeQuestion(let index):
            try c.encode("claude_question", forKey: .kind); try c.encode(index, forKey: .index)
        case .claudeReview: try c.encode("claude_review", forKey: .kind)
        case .agyQuestion(let index, let total):
            try c.encode("agy_question", forKey: .kind); try c.encode(index, forKey: .index); try c.encode(total, forKey: .total)
        case .cursorQuestion(let index, let total):
            try c.encode("cursor_question", forKey: .kind); try c.encode(index, forKey: .index); try c.encode(total, forKey: .total)
        case .codexQuestion(let index, let total):
            try c.encode("codex_question", forKey: .kind); try c.encode(index, forKey: .index); try c.encode(total, forKey: .total)
        case .asyncQueued: try c.encode("async_queued", forKey: .kind)
        case .asyncPicker(let index):
            try c.encode("async_picker", forKey: .kind); try c.encode(index, forKey: .index)
        }
    }
    func isValid(kind: AgentQuestionKind, count: Int) -> Bool {
        switch (kind, self) {
        case (.claude, .claudeQuestion(let index)), (.codexAsync, .asyncPicker(let index)): return (0..<count).contains(index)
        case (.claude, .claudeReview): return true
        case (.agy, .agyQuestion(let index, let total)), (.codexPlan, .codexQuestion(let index, let total)): return total == count && (0..<count).contains(index)
        // A Cursor form is answered one visible question at a time; the next arrives as a new request.
        case (.cursor, .cursorQuestion(let index, let total)): return count == 1 && (1...8).contains(total) && (0..<total).contains(index)
        case (.codexAsync, .asyncQueued): return true
        default: return false
        }
    }
}
struct AgentPendingQuestion: Equatable, Sendable {
    let identity: AgentTimelineIdentity
    let generation: UInt64
    let requestId: String
    let agent: String
    let questionKind: AgentQuestionKind
    let questions: [AgentQuestion]
    let step: AgentQuestionStep
    let fresh: Bool
    let countdown: String?

    static func decode(_ data: AgentBridgePayload) throws -> Self {
        func validId(_ value: String) -> Bool { !value.isEmpty && value.utf8.count <= 264 }
        guard data.kind == "question", let identity = data.identity,
            [identity.paneId, identity.terminalId, identity.nativeSessionId].allSatisfy(validId),
            let generation = data.generation, let requestId = data.requestId, validId(requestId),
            let agent = data.agent, agent == identity.agent,
            let kind = data.questionKind.flatMap(AgentQuestionKind.init(rawValue:)),
            agent == (kind == .claude ? "claude" : kind == .agy ? "antigravity_cli" : kind == .cursor ? "cursor" : "codex"),
            let questions = data.questions, !questions.isEmpty, questions.count <= 8,
            kind != .codexAsync || questions.count == 1,
            questions.enumerated().allSatisfy({ offset, q in
                q.index == offset && !q.text.isEmpty && q.text.utf8.count <= 4096
                && (q.header?.utf8.count ?? 0) <= 1024
                && (!q.options.isEmpty || (kind == .codexAsync && q.allowsOther)) && q.options.count <= 32
                && Set(q.options.map(\.number)).count == q.options.count
                && q.options.allSatisfy { $0.number > 0 && !$0.label.isEmpty && $0.label.utf8.count <= 1024
                    && ($0.description?.utf8.count ?? 0) <= 4096 }
                && (kind == .claude || kind == .agy || kind == .cursor || !q.multiSelect)
            }),
            let step = data.step, step.isValid(kind: kind, count: questions.count), let fresh = data.fresh,
            (data.countdown?.utf8.count ?? 0) <= 1024
        else { throw AgentBridgeError.invalidFrame }
        return Self(identity: identity, generation: generation, requestId: requestId, agent: agent,
            questionKind: kind, questions: questions, step: step, fresh: fresh, countdown: data.countdown)
    }
}
struct AgentQuestionAnswer: Codable, Equatable, Sendable {
    let index: Int
    let options: [UInt32]
    var text: String? = nil
}
