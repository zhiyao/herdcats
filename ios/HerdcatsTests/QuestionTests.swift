import Foundation
import Testing
@testable import Herdcats

@Suite("Question protocol and answers")
@MainActor struct QuestionTests {
    func frame(kind: String = "claude", seq: Int = 1, event: String = "interaction.pending", extra: [String: Any] = [:]) throws -> AgentBridgeFrame {
        let agent = kind == "claude" ? "claude" : kind == "agy" ? "antigravity_cli" : kind == "cursor" ? "cursor" : "codex"
        var data: [String: Any] = [
            "identity": ["pane_id": "w1:p1", "terminal_id": "t1", "agent": agent, "native_session_id": "session-a"],
            "generation": 1, "request_id": "ask-prompt-123", "kind": "question", "agent": agent,
            "question_kind": kind, "fresh": true, "entries": [],
            "questions": [["index": 0, "header": "Size", "text": "Which size?", "multi_select": false, "allows_other": true,
                "options": [["number": 1, "label": "Small", "description": "A small pizza"], ["number": 2, "label": "None of the above"]]]],
            "step": kind == "cursor" ? ["kind": "cursor_question", "index": 0, "total": 2] : kind == "agy" ? ["kind": "agy_question", "index": 0, "total": 1] : kind == "claude" ? ["kind": "claude_question", "index": 0] : kind == "codex_plan"
                ? ["kind": "codex_question", "index": 0, "total": 1] : ["kind": "async_queued"],
            "countdown": kind == "codex_async" ? "18s" as Any : NSNull(),
        ]
        data.merge(extra) { _, new in new }
        return try AgentBridgeFrame.decode(JSONSerialization.data(withJSONObject: ["event": event, "epoch": "epoch-a", "seq": seq, "data": data]))
    }
    func pending(_ kind: String = "claude", extra: [String: Any] = [:]) throws -> AgentPendingQuestion {
        try AgentPendingQuestion.decode(#require(frame(kind: kind, extra: extra).data))
    }
    @Test func decodesKindsAndSteps() throws {
        for kind in ["claude", "codex_plan", "codex_async", "agy", "cursor"] {
            let p = try pending(kind)
            #expect(p.questionKind.rawValue == kind)
            #expect(p.questions[0].options[0].description == "A small pizza")
        }
        #expect(try pending("codex_async").countdown == "18s")
        #expect(try pending(extra: ["step": ["kind": "claude_review"]]).step == .claudeReview)
        #expect(try pending("codex_async", extra: ["step": ["kind": "async_picker", "index": 0]]).step == .asyncPicker(index: 0))
    }
    @Test func cursorShowsOneFormQuestionAtATimeWithItsPosition() throws {
        let p = try pending("cursor")
        #expect(p.agent == "cursor")
        #expect(p.step == .cursorQuestion(index: 0, total: 2))
        #expect(p.questions.count == 1)
        // Later questions arrive as new requests, so the position is the only link.
        for step: [String: Any] in [
            ["kind": "cursor_question", "index": 1, "total": 2],
            ["kind": "cursor_question", "index": 7, "total": 8],
            ["kind": "cursor_question", "index": 0, "total": 1],
        ] { #expect(try pending("cursor", extra: ["step": step]).questionKind == .cursor) }
        for step: [String: Any] in [
            ["kind": "cursor_question", "index": 2, "total": 2],   // position past the form
            ["kind": "cursor_question", "index": 0, "total": 9],   // more questions than the client allows
            ["kind": "cursor_question", "index": 0, "total": 0],
            ["kind": "cursor_question", "index": -1, "total": 2],
            ["kind": "agy_question", "index": 0, "total": 1],      // another agent's step
            ["kind": "claude_question", "index": 0],
        ] { #expect(throws: (any Error).self) { try pending("cursor", extra: ["step": step]) }
        }
        // The form is never decoded as another agent's question, or the reverse.
        #expect(throws: (any Error).self) { try pending("cursor", extra: ["agent": "antigravity_cli", "identity": ["pane_id": "w1:p1", "terminal_id": "t1", "agent": "antigravity_cli", "native_session_id": "session-a"]]) }
        #expect(throws: (any Error).self) { try pending("agy", extra: ["step": ["kind": "cursor_question", "index": 0, "total": 1]]) }
        // Exactly one question per request.
        let two = try #require(frame(kind: "cursor").data?.questions?.first)
        var data = try #require(frame(kind: "cursor").data)
        data.questions = [two, AgentQuestion(index: 1, text: "Second?", options: [AgentQuestionOption(number: 1, label: "A")], multiSelect: false, allowsOther: true)]
        #expect(throws: (any Error).self) { try AgentPendingQuestion.decode(data) }
    }
    @Test func cursorMultiSelectWriteInAndSelectionsFollowTheRadioRules() throws {
        var data = try #require(frame(kind: "cursor").data)
        data.questions = [AgentQuestion(index: 0, text: "Features?", options: [AgentQuestionOption(number: 1, label: "One"), AgentQuestionOption(number: 2, label: "Two")], multiSelect: true, allowsOther: true)]
        let state = QuestionAnswerState()
        state.sync(try AgentPendingQuestion.decode(data))
        state.select(question: 0, option: 2)
        state.select(question: 0, option: 1)
        state.setText("Anchovies", question: 0)
        #expect(state.answers == [AgentQuestionAnswer(index: 0, options: [1, 2], text: "Anchovies")])
        // Single-select is a radio, and a write-in replaces the option.
        let single = QuestionAnswerState()
        single.sync(try pending("cursor"))
        single.select(question: 0, option: 1)
        single.setText("Medium", question: 0)
        #expect(single.answers == [AgentQuestionAnswer(index: 0, options: [], text: "Medium")])
        // Skipping would discard the whole form at the desk, so it is Terminal-only.
        #expect(single.begin(skip: true) == nil)
        #expect(single.phase == .idle)
    }
    @Test func agyMultiSelectAndWriteInPreserveDraftsAndRejectWrongSteps() throws {
        var data = try #require(frame(kind: "agy").data)
        data.questions = [AgentQuestion(index: 0, text: "Features?", options: [AgentQuestionOption(number: 1, label: "One"), AgentQuestionOption(number: 2, label: "Two")], multiSelect: true, allowsOther: true)]
        let state = QuestionAnswerState()
        state.sync(try AgentPendingQuestion.decode(data))
        state.select(question: 0, option: 2)
        state.select(question: 0, option: 1)
        state.setText("Other", question: 0)
        #expect(state.answers == [AgentQuestionAnswer(index: 0, options: [1, 2], text: "Other")])
        data.step = .codexQuestion(index: 0, total: 1)
        #expect(throws: (any Error).self) { try AgentPendingQuestion.decode(data) }
    }
    @Test func rejectsMalformedQuestions() throws {
        let base = try #require(frame().data?.questions?.first)
        let encoder = JSONEncoder(); encoder.keyEncodingStrategy = .convertToSnakeCase
        let q = try #require(JSONSerialization.jsonObject(with: encoder.encode(base)) as? [String: Any])
        var invalid: [[String: Any]] = [
            ["request_id": ""], ["request_id": String(repeating: "x", count: 265)],
            ["question_kind": "future"], ["agent": "codex"], ["questions": []],
            ["questions": Array(repeating: q, count: 9)], ["step": ["kind": "claude_question", "index": 1]],
            ["step": ["kind": "async_queued"]], ["fresh": NSNull()],
        ]
        for patch: [String: Any] in [
            ["index": 1], ["text": String(repeating: "x", count: 4097)],
            ["options": [["number": 0, "label": "Bad"]]],
            ["options": [["number": 1, "label": "A"], ["number": 1, "label": "B"]]],
            ["options": [["number": 1, "label": String(repeating: "x", count: 1025)]]],
            ["options": (1...33).map { ["number": $0, "label": "A"] }],
        ] {
            invalid.append(["questions": [q.merging(patch) { _, new in new }]])
        }
        for extra in invalid { #expect(throws: (any Error).self) { try pending(extra: extra) } }
    }
    @Test func approvalAndQuestionAreExclusiveAndResolveByScope() throws {
        let owner = UUID(), state = AgentTimelineState()
        state.begin(owner: owner, paneId: "w1:p1")
        try state.consume(frame(event: "timeline.snapshot"), owner: owner)
        try state.consume(ApprovalTests().event("interaction.pending", seq: 2), owner: owner)
        #expect(state.pendingApproval != nil)
        try state.consume(frame(seq: 3), owner: owner)
        #expect(state.pendingApproval == nil && state.pendingQuestion != nil)
        try state.consume(frame(seq: 4, event: "interaction.resolved", extra: ["generation": 2]), owner: owner)
        #expect(state.pendingQuestion != nil)
        try state.consume(frame(seq: 5, event: "interaction.resolved"), owner: owner)
        #expect(state.pendingQuestion == nil)
        try state.consume(frame(seq: 6), owner: owner)
        try state.consume(ApprovalTests().event("interaction.pending", seq: 7), owner: owner)
        #expect(state.pendingQuestion == nil && state.pendingApproval != nil)
    }
    @Test func singleAndOtherPayloadAndEnablement() throws {
        let state = QuestionAnswerState(); state.sync(try pending())
        #expect(!state.canSubmit)
        state.select(question: 0, option: 1)
        #expect(state.canSubmit)
        #expect(state.answers == [AgentQuestionAnswer(index: 0, options: [1])])
        state.setText("Other", question: 0)
        #expect(state.answers == [AgentQuestionAnswer(index: 0, options: [], text: "Other")])
        state.setText("", question: 0)
        #expect(!state.canSubmit)
        state.sync(try pending("codex_async")); state.setText("Later", question: 0)
        #expect(state.answers == [AgentQuestionAnswer(index: 0, options: [], text: "Later")])
    }
    @Test func multiAndPlanPayloads() throws {
        var p = try #require(frame().data)
        let q = try #require(p.questions?.first)
        p.questions = [AgentQuestion(index: 0, text: q.text, options: q.options, multiSelect: true, allowsOther: true)]
        let state = QuestionAnswerState(); state.sync(try AgentPendingQuestion.decode(p))
        state.select(question: 0, option: 2); state.select(question: 0, option: 1); state.setText("Extra", question: 0)
        #expect(state.answers == [AgentQuestionAnswer(index: 0, options: [1, 2], text: "Extra")])
        state.sync(try pending("codex_plan")); state.setText("Notes", question: 0)
        #expect(!state.canSubmit)
        for option: UInt32 in [1, 2] {
            state.select(question: 0, option: option)
            #expect(state.answers == [AgentQuestionAnswer(index: 0, options: [option], text: "Notes")])
        }
        state.setText("", question: 0)
        #expect(state.canSubmit)
    }
    @Test func everyQuestionMustBeAnsweredAndAsyncMayBeTextOnly() throws {
        var payload = try #require(frame().data)
        let first = try #require(payload.questions?.first)
        payload.questions = [first, AgentQuestion(index: 1, text: "Toppings?", options: first.options, multiSelect: true, allowsOther: true)]
        let state = QuestionAnswerState(); state.sync(try AgentPendingQuestion.decode(payload))
        state.select(question: 0, option: 1); #expect(!state.canSubmit)
        state.setText("Cheese", question: 1); #expect(state.canSubmit)
        #expect(state.answers?.count == 2)
        payload = try #require(frame(kind: "codex_async").data)
        payload.questions = [AgentQuestion(index: 0, text: "What next?", options: [], multiSelect: false, allowsOther: true)]
        state.sync(try AgentPendingQuestion.decode(payload))
        state.setText("Continue", question: 0)
        #expect(state.answers == [AgentQuestionAnswer(index: 0, options: [], text: "Continue")])
        let token = try #require(state.begin())
        state.sync(try pending())
        state.succeed(token: token, confirmed: true)
        #expect(state.phase == .idle)
    }
    @Test func sanitizationAndLifecycle() throws {
        #expect(QuestionAnswerState.sanitize("a\nb\r\nc\td\u{0000}\u{2028}e") == "abcde")
        #expect(QuestionAnswerState.sanitize(String(repeating: "猫", count: 501)).count == 500)
        let state = QuestionAnswerState(); state.sync(try pending("codex_async"))
        state.setText("Answer", question: 0)
        state.sync(try pending("codex_async", extra: ["countdown": "17s"]))
        #expect(state.texts[0] == "Answer")
        let token = try #require(state.begin()); #expect(!state.canSubmit)
        state.fail(token: token, error: .unavailable("invalid")); #expect(state.canSubmit)
        let retry = try #require(state.begin()); state.fail(token: retry, error: .questionFailure(code: "stale", stepsSent: 2))
        #expect(state.phase == .stale && !state.canSubmit)
        state.reset(); state.sync(try pending("codex_async"))
        let skip = try #require(state.begin(skip: true)); state.succeed(token: skip, confirmed: false)
        #expect(state.phase == .sent && state.isDisabled)
        state.reset(); state.sync(try pending(extra: ["fresh": false])); #expect(state.isDisabled)
    }
    @Test func completedRepliesStayDisabledAndUnconfirmedRepliesShowWaitingMessage() throws {
        for confirmed in [false, true] {
            let state = QuestionAnswerState(); state.sync(try pending())
            state.select(question: 0, option: 1)
            let token = try #require(state.begin())
            state.succeed(token: token, confirmed: confirmed)
            #expect(state.phase == (confirmed ? .confirmed : .sent))
            #expect(state.isDisabled)
            #expect(!state.canSubmit)
            #expect(state.message == (confirmed ? nil : "Sent. Waiting for the terminal…"))
            #expect(state.begin() == nil)
        }
    }
    @Test func phoneSendPhaseWinsOverFreshnessUpdates() throws {
        let state = QuestionAnswerState(); state.sync(try pending())
        state.select(question: 0, option: 1)
        let token = try #require(state.begin())
        state.sync(try pending(extra: ["fresh": false]))
        #expect(state.phase == .sending)
        #expect(state.message == nil)
        state.succeed(token: token, confirmed: false)
        #expect(state.phase == .sent)
        #expect(state.message == "Sent. Waiting for the terminal…")
    }
    @Test func blankTextIsOmittedBesideOptions() throws {
        let state = QuestionAnswerState(); state.sync(try pending("codex_plan"))
        state.select(question: 0, option: 1); state.setText("   ", question: 0)
        #expect(state.canSubmit)
        #expect(state.answers == [AgentQuestionAnswer(index: 0, options: [1])])
        state.setText("  Notes  ", question: 0)
        #expect(state.answers?.first?.text == "Notes")
        var payload = try #require(frame().data)
        let q = try #require(payload.questions?.first)
        payload.questions = [AgentQuestion(index: 0, text: q.text, options: q.options, multiSelect: true, allowsOther: true)]
        state.sync(try AgentPendingQuestion.decode(payload))
        state.select(question: 0, option: 1); state.setText("   ", question: 0)
        #expect(state.answers == [AgentQuestionAnswer(index: 0, options: [1])])
        state.sync(try pending()); state.setText("   ", question: 0)
        #expect(!state.canSubmit)
        state.select(question: 0, option: 1)
        #expect(state.answers == [AgentQuestionAnswer(index: 0, options: [1])])
    }
    @Test func wireParametersAndErrors() throws {
        let encoder = JSONEncoder(); encoder.keyEncodingStrategy = .convertToSnakeCase
        let params = AgentBridgeParams(requestId: "r", answers: [AgentQuestionAnswer(index: 0, options: [2], text: "Notes")])
        let json = try #require(JSONSerialization.jsonObject(with: encoder.encode(params)) as? NSDictionary)
        #expect(json == ["request_id": "r", "answers": [["index": 0, "options": [2], "text": "Notes"]]] as NSDictionary)
        let skip = try JSONSerialization.jsonObject(with: encoder.encode(AgentBridgeParams(requestId: "r", skip: true))) as? NSDictionary
        #expect(skip == ["request_id": "r", "skip": true] as NSDictionary)
        let error = try AgentBridgeFrame.decode(Data(#"{"id":"r","error":{"code":"stale","steps_sent":3}}"#.utf8)).error
        #expect(error?.stepsSent == 3)
        #expect(AgentBridgeError.questionFailure(code: "stale", stepsSent: 3).code == "stale")
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        #expect(try decoder.decode(AgentBridgeCapabilities.self, from: Data(#"{"claude_timeline":true,"questions":true}"#.utf8)).questions == true)
        #expect(try decoder.decode(AgentBridgeCapabilities.self, from: Data(#"{"claude_timeline":true}"#.utf8)).questions == nil)
    }
}

#if DEBUG && targetEnvironment(simulator)
@Suite("Question screenshot fixtures")
@MainActor struct QuestionScreenshotTests {
    @Test func fixturesDecodeAllKinds() throws {
        for kind in [AgentQuestionKind.claude, .codexPlan, .codexAsync] {
            let frame = try AgentTimelineScreenshotFixture.questionFrame(paneId: "p0", kind: kind)
            let pending = try AgentPendingQuestion.decode(#require(frame.data))
            #expect(frame.seq == 2)
            #expect(pending.questionKind == kind)
            #expect(pending.fresh)
            #expect(pending.questions.count == (kind == .codexAsync ? 1 : 2))
            if kind == .claude {
                #expect(pending.questions.map(\.header) == ["Size", "Toppings"])
                #expect(pending.questions.map(\.multiSelect) == [false, true])
                #expect(pending.questions[1].options.map(\.label) == ["Cheese", "Olives", "Basil"])
            } else if kind == .codexPlan {
                #expect(pending.questions.allSatisfy { $0.options.last?.label == "None of the above" })
            } else { #expect(pending.countdown == "18s") }
        }
    }
}
#endif
