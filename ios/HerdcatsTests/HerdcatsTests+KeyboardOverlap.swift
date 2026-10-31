import CoreGraphics
import Testing
@testable import Herdcats

@Suite("Keyboard overlap")
struct KeyboardOverlapTests {
    private let phone = CGRect(x: 0, y: 0, width: 393, height: 852)

    @Test func dockedKeyboardCoversItsHeight() {
        let keyboard = CGRect(x: 0, y: 852 - 336, width: 393, height: 336)
        #expect(keyboardOverlap(keyboardFrameInWindow: keyboard, windowBounds: phone) == 336)
    }

    @Test func hiddenKeyboardCoversNothing() {
        let keyboard = CGRect(x: 0, y: 852, width: 393, height: 336)
        #expect(keyboardOverlap(keyboardFrameInWindow: keyboard, windowBounds: phone) == 0)
    }

    @Test func floatingKeyboardCoversNothing() {
        let keyboard = CGRect(x: 120, y: 300, width: 320, height: 260)
        #expect(keyboardOverlap(keyboardFrameInWindow: keyboard, windowBounds: phone) == 0)
    }

    @Test func windowShorterThanScreenIsCoveredFromKeyboardTop() {
        // Stage Manager window 600pt tall; the docked keyboard's top sits at
        // y=400 in window coordinates and runs past the window's bottom.
        let window = CGRect(x: 0, y: 0, width: 700, height: 600)
        let keyboard = CGRect(x: 0, y: 400, width: 700, height: 420)
        #expect(keyboardOverlap(keyboardFrameInWindow: keyboard, windowBounds: window) == 200)
    }

    @Test func keyboardBelowAShortWindowCoversNothing() {
        let window = CGRect(x: 0, y: 0, width: 700, height: 600)
        let keyboard = CGRect(x: 0, y: 650, width: 700, height: 420)
        #expect(keyboardOverlap(keyboardFrameInWindow: keyboard, windowBounds: window) == 0)
    }

    @Test func keyboardBesideTheWindowCoversNothing() {
        let window = CGRect(x: 0, y: 0, width: 400, height: 800)
        let keyboard = CGRect(x: 400, y: 500, width: 400, height: 300)
        #expect(keyboardOverlap(keyboardFrameInWindow: keyboard, windowBounds: window) == 0)
    }
}
