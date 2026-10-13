import Foundation
import Security
import NIOSSH
import SwiftUI
import UIKit
import Testing
@testable import Herdcats

@Suite("Pane output presentation")
struct PaneOutputPresentationTests {
    @Test func trimsTrailingSpacesButPreservesText() {
        let ansi = "\u{1B}[32mcolored\u{1B}[0m" + String(repeating: " ", count: 12)
        let lines = PaneOutputPresentation.trimmedLines(from: ansi, palette: TerminalPalette(palette: .moonlit, dark: true))
        #expect(lines.count == 1)
        #expect(lines[0].plain == "colored")
        #expect(String(lines[0].attributed.characters) == "colored")
        #expect(lines[0].attributed.foregroundColor != nil)
    }

    @Test func diffTintMarksPlusMinusInsideHunksAndIgnoresBulletsOutside() {
        var oldHunkLines = 0
        var newHunkLines = 0
        let lines = [
            "@@ -1 +1 @@",
            "- old",
            "+ new",
            "",
            "  - A normal bullet",
            "  + Another bullet"
        ]
        let tints = lines.map {
            PaneOutputPresentation.diffTint(
                for: $0,
                oldHunkLines: &oldHunkLines,
                newHunkLines: &newHunkLines
            )
        }
        #expect(tints == [nil, .deletion, .addition, nil, nil, nil])
    }

    @Test func trimmedLinesPreserveExplicitBackgroundInBothAppearances() {
        #expect(PaneOutputPresentation.trimmedLines(from: "", palette: TerminalPalette(palette: .moonlit, dark: true)).isEmpty)

        let ansi = "\u{1B}[48;2;0;0;0mblack bg\u{1B}[0m  "
        let dark = PaneOutputPresentation.trimmedLines(from: ansi, palette: TerminalPalette(palette: .moonlit, dark: true))
        let light = PaneOutputPresentation.trimmedLines(from: ansi, palette: TerminalPalette(palette: .moonlit, dark: false))
        #expect(dark.map(\.plain) == ["black bg"])
        #expect(light.map(\.plain) == ["black bg"])
        #expect(dark[0].attributed.backgroundColor != nil)
        #expect(light[0].attributed.backgroundColor != nil)
        #expect(dark[0].attributed.backgroundColor == light[0].attributed.backgroundColor)
    }
}

@Suite("ANSI text")
struct ANSITextTests {
    @Test func stripsSequencesAndKeepsPlainText() {
        let ansi = "\u{1B}[32mgreen\u{1B}[0m plain \u{1B}[31mred\u{1B}[0m"
        let lines = ANSIText.lines(from: ansi)
        #expect(lines.count == 1)
        #expect(lines[0].plain == "green plain red")
    }

    @Test func preservesTruecolorAndLineBreaks() {
        let ansi = "\u{1B}[38;2;168;181;230mblue\u{1B}[0m\n\u{1B}[48;2;47;50;57m bg \u{1B}[0m"
        let lines = ANSIText.lines(from: ansi)
        #expect(lines.map(\.plain) == ["blue", " bg "])
        #expect(lines[0].attributed.foregroundColor != nil)
        #expect(lines[1].attributed.backgroundColor != nil)
    }

    @Test func preservesExplicitColorsForLightBackground() {
        let ansi = "\u{1B}[48;2;0;0;0mblack bg\u{1B}[0m"
        let dark = ANSIText.lines(from: ansi)
        let light = ANSIText.lines(from: ansi, palette: TerminalPalette(palette: .moonlit, dark: false))
        #expect(dark[0].attributed.backgroundColor != nil)
        #expect(light[0].attributed.backgroundColor != nil)
        #expect(dark[0].attributed.backgroundColor == light[0].attributed.backgroundColor)
    }

    @Test func standardAndIndexedSlotsFollowEachPalette() {
        for (palette, dark) in AppPalette.lightChoices.map({ ($0, false) }) + AppPalette.darkChoices.map({ ($0, true) }) {
            let terminal = TerminalPalette(palette: palette, dark: dark)
            #expect(terminal.colors.count == 16)
            for slot in 0..<16 {
                let foregroundCode = slot < 8 ? 30 + slot : 90 + slot - 8
                let backgroundCode = slot < 8 ? 40 + slot : 100 + slot - 8
                let direct = ANSIText.lines(from: "\u{1B}[\(foregroundCode);\(backgroundCode)mtest", palette: terminal)[0]
                let indexed = ANSIText.lines(from: "\u{1B}[38;5;\(slot);48;5;\(slot)mtest", palette: terminal)[0]
                #expect(direct.attributed.foregroundColor == indexed.attributed.foregroundColor)
                #expect(direct.attributed.backgroundColor == indexed.attributed.backgroundColor)
            }
        }
        let mocha = TerminalPalette(palette: .mocha, dark: true)
        #expect(mocha.colors[1] == 0xF38BA8)
        let solarized = TerminalPalette(palette: .solarizedDark, dark: true)
        #expect(solarized.colors[4] == 0x268BD2)
        let red = "\u{1B}[31merror"
        #expect(ANSIText.lines(from: red, palette: mocha)[0].attributed.foregroundColor
                != ANSIText.lines(from: red, palette: solarized)[0].attributed.foregroundColor)
    }

    @Test func readableExplicitAndExtendedColorsStayExactAcrossThemes() {
        for (palette, dark) in AppPalette.lightChoices.map({ ($0, false) }) + AppPalette.darkChoices.map({ ($0, true) }) {
            let terminal = TerminalPalette(palette: palette, dark: dark)
            let lines = ANSIText.lines(from: "\u{1B}[38;2;240;224;208;48;2;0;43;54mrgb\n\u{1B}[38;5;196;48;5;232mindexed", palette: terminal)
            #expect(lines[0].attributed.foregroundColor == Color(red: 240.0 / 255, green: 224.0 / 255, blue: 208.0 / 255))
            #expect(lines[0].attributed.backgroundColor == Color(red: 0, green: 43.0 / 255, blue: 54.0 / 255))
            #expect(lines[0].background == "#002b36")
            #expect(lines[1].attributed.foregroundColor == Color(red: 1, green: 0, blue: 0))
            #expect(lines[1].attributed.backgroundColor == Color(red: 8.0 / 255, green: 8.0 / 255, blue: 8.0 / 255))
        }
    }

    @Test func foregroundsMeetContrastInBothAppearancesWithoutChangingBackgrounds() throws {
        for (palette, dark) in AppPalette.lightChoices.map({ ($0, false) }) + AppPalette.darkChoices.map({ ($0, true) }) {
            let terminal = TerminalPalette(palette: palette, dark: dark)
            let backdrop = Color(uiColor: UIColor(hex: terminal.background))
            // Standard slots, extended indexed colors, pastel RGB, and dim text
            // reproduce the faint command/status colors in the reported screen.
            let samples = (0..<16).map { "\u{1B}[38;5;\($0)mtest" } + [
                "\u{1B}[38;5;231mwhite", "\u{1B}[38;5;229myellow",
                "\u{1B}[38;2;166;227;161mgreen", "\u{1B}[38;2;137;180;250mblue",
                "\u{1B}[38;2;249;226;175myellow", "\u{1B}[2mdim",
                "\u{1B}[2;38;2;166;227;161mdim green",
                "\u{1B}[38;2;20;30;40mdark text", "\u{1B}[2;38;5;232mdim black"
            ]
            for sample in samples {
                let run = ANSIText.lines(from: sample, palette: terminal)[0].attributed
                let foreground = try #require(run.foregroundColor)
                #expect(colorContrast(foreground, backdrop) >= 4.5)
                #expect(run.backgroundColor == nil)
            }
            let highlighted = ANSIText.lines(from: "\u{1B}[38;2;30;30;30;48;2;0;43;54mhighlight", palette: terminal)[0]
            let foreground = try #require(highlighted.attributed.foregroundColor)
            let background = try #require(highlighted.attributed.backgroundColor)
            #expect(colorContrast(foreground, background) >= 4.5)
            #expect(highlighted.background == "#002b36")
            #expect(background == Color(red: 0, green: 43.0 / 255, blue: 54.0 / 255))
            let lightHighlight = ANSIText.lines(from: "\u{1B}[38;2;240;240;240;48;2;253;246;227mlight highlight", palette: terminal)[0]
            let lightForeground = try #require(lightHighlight.attributed.foregroundColor)
            let lightBackground = try #require(lightHighlight.attributed.backgroundColor)
            #expect(colorContrast(lightForeground, lightBackground) >= 4.5)
            #expect(lightHighlight.background == "#fdf6e3")
        }
        // Already readable remote colors remain exact, including in dark themes.
        let dark = ANSIText.lines(from: "\u{1B}[38;2;166;227;161mgreen", palette: TerminalPalette(palette: .mocha, dark: true))[0]
        #expect(dark.attributed.foregroundColor == Color(red: 166.0 / 255, green: 227.0 / 255, blue: 161.0 / 255))
    }

    private func colorContrast(_ foreground: Color, _ background: Color) -> Double {
        func luminance(_ color: Color) -> Double {
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a)
            func linear(_ c: CGFloat) -> Double {
                let value = Double(c)
                return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
        }
        let first = luminance(foreground), second = luminance(background)
        return (max(first, second) + 0.05) / (min(first, second) + 0.05)
    }

    @Test func resetsAndReverseVideoUseThemeDefaults() {
        let palette = TerminalPalette(palette: .latte, dark: false)
        let normal = ANSIText.lines(from: "default", palette: palette)[0].attributed
        let reset = ANSIText.lines(from: "\u{1B}[31;44m\u{1B}[39;49mdefault", palette: palette)[0].attributed
        #expect(reset.foregroundColor == normal.foregroundColor)
        #expect(reset.backgroundColor == nil)
        let reverse = ANSIText.lines(from: "\u{1B}[7mdefault", palette: palette)[0].attributed
        #expect(reverse.backgroundColor == normal.foregroundColor)
        #expect(reverse.foregroundColor != normal.foregroundColor)
        let restored = ANSIText.lines(from: "\u{1B}[7m\u{1B}[27mdefault", palette: palette)[0].attributed
        #expect(restored.foregroundColor == normal.foregroundColor)
        #expect(restored.backgroundColor == nil)
    }

    @Test func panePresentationKeepsANSIRuns() {
        let ansi = "hello \u{1B}[38;5;2mcolored\u{1B}[0m world"
        let lines = PaneOutputPresentation.trimmedLines(from: ansi, palette: TerminalPalette(palette: .moonlit, dark: true))
        #expect(lines.count == 1)
        #expect(lines[0].plain == "hello colored world")
        #expect(String(lines[0].attributed.characters) == "hello colored world")
    }
}

// Screens captured from Codex 0.155.1 via `herdr pane read --source visible`.
@Suite("Codex question answers")
struct CodexQuestionInputTests {
    private let questionList = """
      Question 1/1 (1 unanswered)
      Which color?

        1. Red                Choose Red.
        2. Blue               Choose Blue.
      › 3. None of the above  Optionally, add details in notes (tab).

      tab to add notes | enter to submit answer | esc to interrupt
    """

    @Test func notesFieldAcceptsTypedAnswer() {
        let screen = """
          Which color?

          › 3. None of the above  Optionally, add details in notes (tab).

          › Add notes

          tab or esc to clear notes | enter to submit answer
        """
        #expect(CodexQuestionInput.detect(screen) == .answerField)
    }

    @Test func noneOfTheAboveOpensNotesWithTab() {
        #expect(CodexQuestionInput.detect(questionList) == .noneOfTheAboveSelected)
        #expect(CodexQuestionInput.noneOfTheAboveSelected.openingKeys == ["tab"])
    }

    @Test func refusesWhenARealOptionIsHighlighted() {
        let screen = questionList
            .replacingOccurrences(of: "    1. Red", with: "  › 1. Red")
            .replacingOccurrences(of: "  › 3. None", with: "    3. None")
        #expect(CodexQuestionInput.detect(screen) == nil)
    }

    @Test func asyncQuestionPanelAndFreeTextField() {
        let options = """
          1 of 2
          Which size?

          › 1. Small
            2. Large
            3. Other

          enter submit   ctrl + ] skip   ⌥ + ↓ main prompt   ⌥ + ↑ next question
        """
        let freeText = """
          Any name?

          Type your answer

          enter submit   ctrl + ] skip   ⌥ + ↓ main prompt
        """
        #expect(CodexQuestionInput.detect(options) == .answerField)
        #expect(CodexQuestionInput.detect(freeText) == .answerField)
    }

    @Test func collapsedQuestionsOpenWithOptionUp() {
        let screen = """
        • Queued follow-up inputs
          ? 2 questions · 12s
            ⌥ + ↑ to answer
        › Ask Codex to do anything
          gpt-6-astra medium · Context 95% left · weekly 73% left
        """
        #expect(CodexQuestionInput.detect(screen) == .collapsed)
        #expect(CodexQuestionInput.collapsed.openingKeys == ["alt+up"])
    }

    @Test func neverTypesIntoApprovalsOrOtherMenus() {
        let approval = """
          Would you like to run the following command?

          $ touch approved.txt

        › 1. Yes, proceed (y)
          2. No, and tell Codex what to do differently (esc)

          tab to add notes | enter to submit answer
        """
        let trust = """
        › 1. Yes, continue
          2. No, quit

          Press enter to continue
        """
        #expect(CodexQuestionInput.detect(approval) == nil)
        #expect(CodexQuestionInput.detect(trust) == nil)
        #expect(CodexQuestionInput.detect("› Ask Codex to do anything\n  gpt-6 · Context 9% left") == nil)
    }

    @Test func answerTextIsSingleLine() {
        #expect(CodexQuestionInput.answerText("  Medium\n\n3 & $x 'q'  \n") == "Medium 3 & $x 'q'")
        #expect(CodexQuestionInput.answerText(" \n ").isEmpty)
    }

    @Test func recognizesAgentBlockedErrors() {
        #expect(HerdrConnection.isAgentBlocked(HerdrError.api(code: "agent_blocked", message: "blocked")))
        #expect(!HerdrConnection.isAgentBlocked(HerdrError.api(code: "agent_not_ready", message: "")))
    }
}

// MARK: - Fixtures (captured from `herdr` 0.8.2 on a live session)

let workspaceListJSON = """
{"id":"cli:workspace:list","result":{"type":"workspace_list","workspaces":[
{"active_tab_id":"w4:tD","agent_status":"idle","focused":false,"label":"ExampleApp","number":1,
"pane_count":3,"tab_count":2,"workspace_id":"w4",
"worktree":{"checkout_path":"/Users/demo/Projects/samplenotes","is_linked_worktree":false,
"repo_key":"/Users/demo/Projects/samplenotes/.git","repo_name":"samplenotes",
"repo_root":"/Users/demo/Projects/samplenotes"}},
{"active_tab_id":"w32:t1","agent_status":"idle","focused":false,"label":"samplemedia","number":2,
"pane_count":3,"tab_count":1,"workspace_id":"w32"},
{"active_tab_id":"w4H:t1","agent_status":"working","focused":true,"label":"herdrcat","number":3,
"pane_count":1,"tab_count":1,"workspace_id":"w4H"}
]}}
"""

let agentListJSON = """
{"id":"cli:agent:list","result":{"type":"agent_list","agents":[
{"agent":"cursor","agent_session":{"agent":"cursor","kind":"id","source":"herdr:cursor",
"value":"08bd0ba3"},"agent_status":"idle","cwd":"/Users/demo/Projects/samplenotes","focused":false,
"foreground_cwd":"/Users/demo/Projects/samplenotes","pane_id":"w4:p2V","revision":5,"state_change_seq":52,
"tab_id":"w4:tD","terminal_id":"term_65b95f43d22fa2","terminal_title":"App Store Text",
"terminal_title_stripped":"App Store Text","workspace_id":"w4"},
{"agent":"claude","agent_status":"blocked","cwd":"/Users/demo/Projects/sampleshop","focused":false,
"foreground_cwd":"/Users/demo/Projects/sampleshop","pane_id":"w3W:p4","revision":5,
"state_change_seq":1688,"tab_id":"w3W:t1","terminal_id":"term_65b95f43eccd915",
"terminal_title":"✳ Sharing with Android","terminal_title_stripped":"Sharing with Android",
"workspace_id":"w4"},
{"agent":"pi","agent_status":"working","cwd":"/Users/demo/Projects/herdrcat","focused":true,
"foreground_cwd":"/Users/demo/Projects/herdrcat","pane_id":"w4H:p1","revision":24,"state_change_seq":1698,
"tab_id":"w4H:t1","terminal_id":"term_65bcbc849dd5a28","terminal_title":"π - herdrcat",
"terminal_title_stripped":"π - herdrcat","workspace_id":"w4H"}
]}}
"""

let tabListJSON = """
{"id":"cli:tab:list","result":{"type":"tab_list","tabs":[
{"agent_status":"idle","focused":false,"label":"1","number":13,"pane_count":2,"tab_id":"w4:tD","workspace_id":"w4"},
{"agent_status":"unknown","focused":false,"label":"2","number":17,"pane_count":1,"tab_id":"w4:tH","workspace_id":"w4"}
]}}
"""
let workspaceListWithWorktreesJSON = """
{"id":"cli:workspace:list","result":{"type":"workspace_list","workspaces":[
{"active_tab_id":"w4:tD","agent_status":"idle","focused":false,"label":"ExampleApp","number":1,
"pane_count":3,"tab_count":2,"workspace_id":"w4",
"worktree":{"checkout_path":"/Users/demo/Projects/samplenotes","is_linked_worktree":false,
"repo_key":"/Users/demo/Projects/samplenotes/.git","repo_name":"samplenotes",
"repo_root":"/Users/demo/Projects/samplenotes"}},
{"active_tab_id":"w32:t1","agent_status":"idle","focused":false,"label":"samplemedia","number":2,
"pane_count":3,"tab_count":1,"workspace_id":"w32"},
{"active_tab_id":"w35:t1","agent_status":"idle","focused":false,"label":"sampleshop","number":3,
"pane_count":2,"tab_count":1,"workspace_id":"w35",
"worktree":{"checkout_path":"/Users/demo/Projects/sampleshop","is_linked_worktree":false,
"repo_key":"/Users/demo/Projects/sampleshop/.git","repo_name":"sampleshop",
"repo_root":"/Users/demo/Projects/sampleshop"}},
{"active_tab_id":"w36:t1","agent_status":"blocked","focused":false,"label":"about","number":4,
"pane_count":1,"tab_count":1,"workspace_id":"w36",
"worktree":{"checkout_path":"/Users/demo/.herdr/worktrees/samplenotes/about","is_linked_worktree":true,
"repo_key":"/Users/demo/Projects/samplenotes/.git","repo_name":"samplenotes",
"repo_root":"/Users/demo/Projects/samplenotes"}},
{"active_tab_id":"w3W:t1","agent_status":"working","focused":true,"label":"share","number":6,
"pane_count":2,"tab_count":1,"workspace_id":"w3W",
"worktree":{"checkout_path":"/Users/demo/.herdr/worktrees/sampleshop/share","is_linked_worktree":true,
"repo_key":"/Users/demo/Projects/sampleshop/.git","repo_name":"sampleshop",
"repo_root":"/Users/demo/Projects/sampleshop"}},
{"active_tab_id":"w48:t1","agent_status":"idle","focused":false,"label":"leaderboard","number":7,
"pane_count":2,"tab_count":1,"workspace_id":"w48",
"worktree":{"checkout_path":"/Users/demo/.herdr/worktrees/samplenotes/leaderboard",
"is_linked_worktree":true,"repo_key":"/Users/demo/Projects/samplenotes/.git","repo_name":"samplenotes",
"repo_root":"/Users/demo/Projects/samplenotes"}},
{"active_tab_id":"w4C:t1","agent_status":"idle","focused":false,"label":"alpha","number":8,"pane_count":1,
"tab_count":1,"workspace_id":"w4C","worktree":{"checkout_path":"/Users/demo/.herdr/worktrees/orphan/alpha",
"is_linked_worktree":true,"repo_key":"/Users/demo/Projects/orphan/.git","repo_name":"orphan",
"repo_root":"/Users/demo/Projects/orphan"}},
{"active_tab_id":"w4E:t1","agent_status":"done","focused":false,"label":"beta","number":9,"pane_count":1,
"tab_count":1,"workspace_id":"w4E","worktree":{"checkout_path":"/Users/demo/.herdr/worktrees/orphan/beta",
"is_linked_worktree":true,"repo_key":"/Users/demo/Projects/orphan/.git","repo_name":"orphan",
"repo_root":"/Users/demo/Projects/orphan"}}
]}}
"""

let errorJSON = """
{"error":{"code":"workspace_not_found","message":"workspace w1 not found"},"id":"cli:tab:list"}
"""

let paneListJSON = """
{"id":"cli:pane:list","result":{"panes":[
{"agent":"cursor","agent_status":"idle","cwd":"/Users/demo/Projects/samplenotes","focused":true,
"label":"command","pane_id":"w4:p2V","tab_id":"w4:tD","terminal_id":"term_65b95f43d22fa2",
"terminal_title":"App Store Text","terminal_title_stripped":"App Store Text","workspace_id":"w4"},
{"agent_status":"unknown","cwd":"/Users/demo/Projects/samplenotes/ios","focused":false,"pane_id":"w4:p33",
"tab_id":"w4:tD","workspace_id":"w4"}
]}}
"""

let workspaceCreateJSON = """
{"id":"cli:workspace:create","result":{"type":"workspace_create","workspace":{"active_tab_id":"w50:t1",
"agent_status":"idle","focused":false,"label":"New Space","number":10,"pane_count":1,"tab_count":1,
"workspace_id":"w50"},"tab":{"agent_status":"idle","focused":true,"label":"1","number":1,"pane_count":1,
"tab_id":"w50:t1","workspace_id":"w50"},"root_pane":{"agent_status":"unknown",
"cwd":"/Users/demo/Projects/herdrcat","focused":true,"pane_id":"w50:p1","tab_id":"w50:t1",
"workspace_id":"w50"}}}
"""

// MARK: - Decoding
