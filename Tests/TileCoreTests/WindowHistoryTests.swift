import CoreGraphics
import Testing
@testable import TileCore

struct WindowHistoryTests {
    let start = CGRect(x: 200, y: 150, width: 800, height: 600)
    let left = CGRect(x: 0, y: 33, width: 756, height: 868)
    let right = CGRect(x: 756, y: 33, width: 756, height: 868)

    @Test func restoresTheFrameBeforeTheFirstMove() {
        var history = WindowHistory<Int>()
        history.record(1, from: start, to: left)
        history.record(1, from: left, to: right)
        #expect(history.takeOriginal(1) == start)
    }

    @Test func restoringForgetsTheWindow() {
        var history = WindowHistory<Int>()
        history.record(1, from: start, to: left)
        #expect(history.takeOriginal(1) == start)
        #expect(history.takeOriginal(1) == nil)
    }

    @Test func aMoveFromSomewhereElseStartsANewRun() {
        var history = WindowHistory<Int>()
        history.record(1, from: start, to: left)
        // Dragged by hand, then snapped again: restore goes to where it was dragged.
        let dragged = CGRect(x: 300, y: 300, width: 700, height: 500)
        history.record(1, from: dragged, to: right)
        #expect(history.takeOriginal(1) == dragged)
    }

    @Test func smallDriftIsStillTilesPlacement() {
        // An app nudging the frame by a few points (minimum size, character cells).
        var history = WindowHistory<Int>()
        history.record(1, from: start, to: left)
        history.record(1, from: left.insetBy(dx: 1, dy: 2), to: right)
        #expect(history.takeOriginal(1) == start)
    }

    @Test func windowsAreTrackedSeparately() {
        var history = WindowHistory<Int>()
        history.record(1, from: start, to: left)
        history.record(2, from: right, to: left)
        #expect(history.takeOriginal(2) == right)
        #expect(history.takeOriginal(1) == start)
        #expect(history.takeOriginal(3) == nil)
    }
}
