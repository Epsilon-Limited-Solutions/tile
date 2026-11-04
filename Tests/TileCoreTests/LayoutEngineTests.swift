import CoreGraphics
import Testing
@testable import TileCore

struct LayoutEngineTests {
    /// AX visible frames of the fixtures.
    static let laptop = CGRect(x: 0, y: 33, width: 1512, height: 868)
    static let vertical = CGRect(x: 1512, y: -1343, width: 1440, height: 2530)

    func frame(_ shape: WindowLayout.Shape, _ visible: CGRect = laptop, gaps: Gaps = Gaps(),
               size: CGSize = .zero) -> CGRect {
        LayoutEngine.frame(for: shape, in: visible, gaps: gaps, currentSize: size)
    }

    func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> WindowLayout.Shape {
        .rect(CGRect(x: x, y: y, width: w, height: h))
    }

    func grid(_ columns: Int, _ rows: Int, _ cell: [Int]) -> WindowLayout.Shape {
        .grid(columns: columns, rows: rows,
              cell: GridCell(column: cell[0], row: cell[1], columnSpan: cell[2], rowSpan: cell[3]))
    }

    @Test func halvesAndQuarters() {
        #expect(frame(rect(0, 0, 0.5, 1)) == CGRect(x: 0, y: 33, width: 756, height: 868))
        #expect(frame(rect(0.5, 0, 0.5, 1)) == CGRect(x: 756, y: 33, width: 756, height: 868))
        #expect(frame(rect(0, 0, 1, 0.5)) == CGRect(x: 0, y: 33, width: 1512, height: 434))
        #expect(frame(rect(0.5, 0.5, 0.5, 0.5)) == CGRect(x: 756, y: 467, width: 756, height: 434))
        #expect(frame(rect(0, 0, 1, 1)) == Self.laptop)
    }

    @Test func gridThirdsOnLandscape() {
        #expect(frame(grid(3, 1, [0, 0, 1, 1])) == CGRect(x: 0, y: 33, width: 504, height: 868))
        #expect(frame(grid(3, 1, [1, 0, 1, 1])) == CGRect(x: 504, y: 33, width: 504, height: 868))
        #expect(frame(grid(3, 1, [2, 0, 1, 1])) == CGRect(x: 1008, y: 33, width: 504, height: 868))
        #expect(frame(grid(3, 1, [0, 0, 2, 1])) == CGRect(x: 0, y: 33, width: 1008, height: 868))
    }

    @Test func thirdsOfAnUnevenHeightAbutWithNoSliver() {
        // 2530 / 3 = 843.33: rounding each edge, not each size, keeps them touching.
        let top = frame(grid(1, 3, [0, 0, 1, 1]), Self.vertical)
        let middle = frame(grid(1, 3, [0, 1, 1, 1]), Self.vertical)
        let bottom = frame(grid(1, 3, [0, 2, 1, 1]), Self.vertical)
        #expect(top == CGRect(x: 1512, y: -1343, width: 1440, height: 843))
        #expect(middle == CGRect(x: 1512, y: -500, width: 1440, height: 844))
        #expect(bottom == CGRect(x: 1512, y: 344, width: 1440, height: 843))
        #expect(top.maxY == middle.minY && middle.maxY == bottom.minY && bottom.maxY == Self.vertical.maxY)
    }

    @Test func gridSpans() {
        // Main + sidebar from the example config: 4 of 6 columns, all 4 rows.
        #expect(frame(grid(6, 4, [0, 0, 4, 4])) == CGRect(x: 0, y: 33, width: 1008, height: 868))
        #expect(frame(grid(6, 4, [4, 1, 2, 2])) == CGRect(x: 1008, y: 250, width: 504, height: 434))
    }

    @Test func outerGapInsetsTheScreenEdge() {
        let gaps = Gaps(outer: 10, inner: 0)
        #expect(frame(rect(0, 0, 1, 1), gaps: gaps) == CGRect(x: 10, y: 43, width: 1492, height: 848))
        #expect(frame(rect(0, 0, 0.5, 1), gaps: gaps) == CGRect(x: 10, y: 43, width: 746, height: 848))
    }

    @Test func innerGapOnlyOnEdgesFacingAnotherRegion() {
        let gaps = Gaps(outer: 10, inner: 10)
        let left = frame(rect(0, 0, 0.5, 1), gaps: gaps)
        let right = frame(rect(0.5, 0, 0.5, 1), gaps: gaps)
        #expect(left == CGRect(x: 10, y: 43, width: 741, height: 848))
        #expect(right == CGRect(x: 761, y: 43, width: 741, height: 848))
        #expect(right.minX - left.maxX == 10)

        #expect(frame(rect(0, 0, 0.5, 0.5), gaps: gaps) == CGRect(x: 10, y: 43, width: 741, height: 419))
        #expect(frame(rect(0.5, 0.5, 0.5, 0.5), gaps: gaps) == CGRect(x: 761, y: 472, width: 741, height: 419))
        #expect(frame(rect(0, 0, 1, 1), gaps: gaps) == CGRect(x: 10, y: 43, width: 1492, height: 848))
    }

    @Test func handWrittenFractionsNearTheEdgeCountAsTheEdge() {
        // 0.6667 + 0.3333 isn't exactly 1; the right edge must still get no inner gap.
        let gaps = Gaps(outer: 0, inner: 10)
        #expect(frame(rect(0.6667, 0, 0.3333, 1), gaps: gaps) == CGRect(x: 1013, y: 33, width: 499, height: 868))
    }

    @Test func almostFull() {
        #expect(frame(rect(0.05, 0.05, 0.9, 0.9)) == CGRect(x: 76, y: 76, width: 1360, height: 782))
    }

    @Test func centerKeepsSize() {
        #expect(frame(.center, size: CGSize(width: 800, height: 600)) == CGRect(x: 356, y: 167, width: 800, height: 600))
        #expect(frame(.center, Self.vertical, size: CGSize(width: 800, height: 600))
                == CGRect(x: 1832, y: -378, width: 800, height: 600))
    }

    @Test func centerShrinksAWindowBiggerThanTheScreen() {
        #expect(frame(.center, size: CGSize(width: 3000, height: 2000)) == Self.laptop)
        #expect(frame(.center, gaps: Gaps(outer: 10), size: CGSize(width: 3000, height: 500))
                == CGRect(x: 10, y: 217, width: 1492, height: 500))
    }

    @Test(arguments: [LayoutEngineTests.laptop, LayoutEngineTests.vertical])
    func defaultLayoutsTileEveryDisplayWithoutGapsOrOverlaps(visible: CGRect) throws {
        let config = try Fixtures.config(Config.defaultJSON)
        func f(_ id: String) throws -> CGRect {
            try LayoutEngine.frame(for: #require(config.layout(id)).shape, in: visible)
        }
        #expect(try f("left-half").maxX == f("right-half").minX)
        #expect(try f("top-half").maxY == f("bottom-half").minY)
        #expect(try f("left-third").maxX == f("center-third").minX)
        #expect(try f("center-third").maxX == f("right-third").minX)
        #expect(try f("left-two-thirds").maxX == f("right-third").minX)
        #expect(try f("left-third").maxX == f("right-two-thirds").minX)
        #expect(try f("top-third").maxY == f("middle-third").minY)
        #expect(try f("middle-third").maxY == f("bottom-third").minY)
        #expect(try f("top-two-thirds").maxY == f("bottom-third").minY)
        #expect(try f("full") == visible)
        for layout in config.layouts {
            let frame = LayoutEngine.frame(for: layout.shape, in: visible, currentSize: CGSize(width: 500, height: 400))
            #expect(visible.contains(frame), "\(layout.id) leaves the screen: \(frame)")
            #expect(frame.width > 0 && frame.height > 0, "\(layout.id) is empty: \(frame)")
        }
    }
}
