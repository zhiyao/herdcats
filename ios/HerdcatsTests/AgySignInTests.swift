import Foundation
import Testing
@testable import Herdcats

@Suite("Agy sign-in")
struct AgySignInTests {
    @Test func answersTerminalIdentificationAcrossPacketBoundaries() {
        var terminal = AgyTerminalResponder()
        #expect(terminal.responses(to: "\u{1B}[").isEmpty)
        #expect(terminal.responses(to: ">c") == "\u{1B}[>0;0;0c")
        #expect(terminal.responses(to: "login text").isEmpty)
        #expect(terminal.responses(to: "\u{1B}[>0c\u{1B}[c") == "\u{1B}[>0;0;0c\u{1B}[?1;0c")
    }

    @Test func ignoresDisplaySequencesAndQueriesInsideTerminalStrings() {
        var terminal = AgyTerminalResponder()
        #expect(terminal.responses(to: "\u{1B}[32mGreen\u{1B}[0m\u{1B}]title \u{1B}[>c\u{07}").isEmpty)
        #expect(terminal.responses(to: "\u{1B}_graphics \u{1B}[>c\u{1B}\\").isEmpty)
        #expect(terminal.responses(to: "\u{1B}[>c") == "\u{1B}[>0;0;0c")
    }

    @Test func loadingOutputDoesNotRenderAsAnEmptyTerminalCard() {
        var transcript = AgySignInTranscript(waitsForReadyMarker: true)
        transcript.append(AgySignInTranscript.readyMarker + "\r\n\u{1B}[>c")
        #expect(transcript.displayText.isEmpty)
        transcript.append("Select login method:\n")
        #expect(transcript.displayText == "Select login method:")
    }

    @Test func recognizesCurrentSSHAuthorizationCodePrompt() throws {
        var transcript = AgySignInTranscript()
        transcript.append("After authenticating, copy the code displayed in the browser and paste it below:\r\n\n authorization code...\r\n")
        #expect(transcript.awaitingCode)
        #expect(try AgySignInInput.code("fixture-code").terminalText(awaitingCode: transcript.awaitingCode) == "fixture-code\r")
    }

    @Test func hidesBootstrapUntilSplitReadyMarkerArrives() {
        var transcript = AgySignInTranscript(waitsForReadyMarker: true)
        transcript.append("Last login: today\nexec /bin/sh ...\nHERDRCAT_AGY_")
        #expect(transcript.plainText.isEmpty)
        transcript.append("LOGIN_READY\r\nSelect login method:\n")
        #expect(transcript.isChoosingLoginMethod)
        #expect(!transcript.plainText.contains("Last login"))
        #expect(!transcript.plainText.contains("exec /bin/sh"))
    }

    @Test func parsesSplitAuthorizationLinkAndPrompt() {
        var transcript = AgySignInTranscript()
        transcript.append("\u{1B}[32mhttps://accounts.google.com/o/oauth2/auth?client_id=fixture&state=")
        #expect(transcript.authorizationURL == nil)
        transcript.append("test\u{1B}[0m\r\nEnter the authorization ")
        #expect(transcript.authorizationURL?.absoluteString == "https://accounts.google.com/o/oauth2/auth?client_id=fixture&state=test")
        #expect(transcript.showsCodeEntry)
        #expect(!transcript.awaitingCode)
        transcript.append("code:")
        #expect(transcript.awaitingCode)
        #expect(transcript.showsCodeEntry)
        transcript.markCodeSubmitted()
        #expect(!transcript.showsCodeEntry)
    }

    @Test func ignoresUnrelatedAndUntrustedLinks() {
        for value in [
            "http://accounts.google.com/o/oauth2/auth",
            "https://accounts.google.com.evil.example/auth",
            "https://accounts.google.com@evil.example/auth",
            "https://accounts.google.com:8080/auth",
            "https://antigravity.google/docs/cli/install/",
        ] {
            #expect(!AgySignInTranscript.isAuthorizationURL(URL(string: value)!))
        }
        #expect(AgySignInTranscript.isAuthorizationURL(URL(string: "https://antigravity.google/auth?state=fixture")!))
    }

    @Test func loginControlsAreRestrictedToLoginPrompts() {
        var transcript = AgySignInTranscript()
        transcript.append("Welcome to Agy\nAsk anything")
        #expect(!transcript.isChoosingLoginMethod)
        transcript.append("\nSelect login method:\nContinue with Google\n")
        #expect(transcript.isChoosingLoginMethod)
        transcript.append("https://accounts.google.com/o/oauth2/auth?state=fixture\nEnter the authorization code:")
        #expect(!transcript.isChoosingLoginMethod)
        #expect(transcript.awaitingCode)
        transcript.markCodeSubmitted()
        #expect(!transcript.isChoosingLoginMethod)
    }

    @Test func stripsTerminalTitlesWithoutSwallowingLinks() {
        var transcript = AgySignInTranscript()
        transcript.append("\u{1B}]0;Agy\u{1B}\\https://accounts.google.com/o/oauth2/auth?state=fixture\n")
        transcript.append("\u{1B}]0;Login\u{07}Enter the authorization code:")
        #expect(transcript.authorizationURL != nil)
        #expect(transcript.awaitingCode)
    }

    @Test func discardsCodeEchoAndPreventsResubmission() throws {
        var transcript = AgySignInTranscript()
        transcript.append("Paste the authorization code below:\n")
        #expect(transcript.awaitingCode)
        transcript.markCodeSubmitted()
        transcript.append("fixture-secret-code\n")
        #expect(transcript.plainText.isEmpty)
        #expect(!transcript.awaitingCode)
        #expect(throws: HerdrError.self) {
            try AgySignInInput.code("fixture-code").terminalText(awaitingCode: transcript.awaitingCode)
        }
    }

    @Test func rejectsTerminalControlCharactersAndMultilineInput() throws {
        for value in ["", " \n", "one\ntwo", "one\rtwo", "one\t two", "\u{1B}[A", String(repeating: "a", count: 8193)] {
            #expect(throws: HerdrError.self) {
                try AgySignInInput.code(value).terminalText(awaitingCode: true)
            }
        }
        #expect(try AgySignInInput.code(" 4/fixture-code_123 \n").terminalText(awaitingCode: true) == "4/fixture-code_123\r")
        #expect(throws: HerdrError.self) {
            try AgySignInInput.confirm.terminalText(awaitingCode: true)
        }
    }

    @Test func codesArePTYDataRatherThanShellCommands() throws {
        let value = "fixture;$(echo-test)`quoted`&<value>"
        #expect(try AgySignInInput.code(value).terminalText(awaitingCode: true) == value + "\r")
        let command = HerdrConnection.agyLoginRemoteCommand
        #expect(command.hasPrefix("exec /bin/sh -c "))
        #expect(command.contains(HerdrConnection.printfOctal("stty -echo")))
        #expect(command.contains(HerdrConnection.printfOctal("exec agy")))
        #expect(!command.contains(value))
        #expect(!command.contains(HerdrConnection.printfOctal("--dangerously-skip-permissions")))
    }

    @Test func boundsRetainedTerminalOutput() {
        var transcript = AgySignInTranscript()
        transcript.append(String(repeating: "a", count: 100_000))
        #expect(transcript.plainText.count == 65_536)
    }
}
