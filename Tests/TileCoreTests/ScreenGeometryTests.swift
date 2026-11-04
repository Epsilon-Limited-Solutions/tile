import CoreGraphics
import Testing
@testable import TileCore

struct ScreenGeometryTests {
    let geometry = ScreenGeometry(displays: Fixtures.desk + [Fixtures.above, Fixtures.below])

    @Test func primaryIsTheMenuBarDisplay() {
        #expect(geometry.primaryFrame == Fixtures.laptop.frame)
        // Even when it isn't listed first.
        let reordered = ScreenGeometry(displays: [Fixtures.verticalRight, Fixtures.laptop])
        #expect(reordered.primaryFrame == Fixtures.laptop.frame)
    }

    @Test func primaryDisplayFlipsToTopLeftOrigin() {
        #expect(geometry.axFrame(of: Fixtures.laptop) == CGRect(x: 0, y: 0, width: 1512, height: 982))
        // 33pt menu bar above the visible frame.
        #expect(geometry.axVisibleFrame(of: Fixtures.laptop) == CGRect(x: 0, y: 33, width: 1512, height: 868))
    }

    @Test func portraitDisplaysTallerThanThePrimary() {
        #expect(geometry.axFrame(of: Fixtures.verticalLeft) == CGRect(x: -1440, y: -1299, width: 1440, height: 2560))
        #expect(geometry.axVisibleFrame(of: Fixtures.verticalLeft) == CGRect(x: -1440, y: -1269, width: 1440, height: 2530))
        #expect(geometry.axFrame(of: Fixtures.verticalRight) == CGRect(x: 1512, y: -1373, width: 1440, height: 2560))
        // The spike put a window at visible origin + (40, 40) = (1552, -1303), and
        // it landed on this display.
        #expect(geometry.axVisibleFrame(of: Fixtures.verticalRight) == CGRect(x: 1512, y: -1343, width: 1440, height: 2530))
    }

    @Test func displaysAboveAndBelow() {
        #expect(geometry.axFrame(of: Fixtures.above) == CGRect(x: 0, y: -1080, width: 1920, height: 1080))
        #expect(geometry.axFrame(of: Fixtures.below) == CGRect(x: -200, y: 982, width: 1920, height: 1080))
    }

    @Test(arguments: [
        CGRect(x: 0, y: 0, width: 100, height: 100),
        CGRect(x: -1440, y: -279, width: 1440, height: 2560),
        CGRect(x: 12.5, y: -3000.25, width: 7, height: 9),
    ])
    func flipIsItsOwnInverse(rect: CGRect) {
        let primary = Fixtures.laptop.frame
        #expect(ScreenGeometry.flip(ScreenGeometry.flip(rect, primaryFrame: primary), primaryFrame: primary) == rect)
    }

    @Test func windowBelongsToTheDisplayItOverlapsMost() {
        #expect(geometry.display(for: CGRect(x: 100, y: 100, width: 400, height: 300))?.id == Fixtures.laptop.id)
        // 112pt on the laptop, 288pt on the right Dell.
        #expect(geometry.display(for: CGRect(x: 1400, y: 100, width: 400, height: 300))?.id == Fixtures.verticalRight.id)
        #expect(geometry.display(for: CGRect(x: -800, y: -1200, width: 400, height: 300))?.id == Fixtures.verticalLeft.id)
        #expect(geometry.display(for: CGRect(x: 100, y: -500, width: 400, height: 300))?.id == Fixtures.above.id)
    }

    @Test func offscreenWindowBelongsToTheNearestDisplay() {
        #expect(geometry.display(for: CGRect(x: 5000, y: 0, width: 10, height: 10))?.id == Fixtures.verticalRight.id)
        #expect(geometry.display(for: CGRect(x: -5000, y: 0, width: 10, height: 10))?.id == Fixtures.verticalLeft.id)
        #expect(ScreenGeometry(displays: []).display(for: .zero) == nil)
    }

    @Test func nextAndPreviousDisplayGoLeftToRightAndWrap() {
        let desk = ScreenGeometry(displays: Fixtures.desk)
        #expect(desk.orderedDisplays.map(\.id) == [2, 1, 3])
        #expect(desk.display(1, from: Fixtures.laptop)?.id == Fixtures.verticalRight.id)
        #expect(desk.display(1, from: Fixtures.verticalRight)?.id == Fixtures.verticalLeft.id)
        #expect(desk.display(-1, from: Fixtures.laptop)?.id == Fixtures.verticalLeft.id)
        #expect(desk.display(-1, from: Fixtures.verticalLeft)?.id == Fixtures.verticalRight.id)
        #expect(desk.display(1, from: Fixtures.above) == nil)
        let alone = ScreenGeometry(displays: [Fixtures.laptop])
        #expect(alone.display(1, from: Fixtures.laptop)?.id == Fixtures.laptop.id)
    }

    @Test func mappingKeepsFractionalPositionAndSize() {
        let laptop = geometry.axVisibleFrame(of: Fixtures.laptop)
        let vertical = geometry.axVisibleFrame(of: Fixtures.verticalRight)
        let leftHalf = CGRect(x: 0, y: 33, width: 756, height: 868)
        #expect(ScreenGeometry.map(leftHalf, from: laptop, to: vertical) == CGRect(x: 1512, y: -1343, width: 720, height: 2530))
        // Middle quarter of the laptop lands in the middle quarter of the Dell.
        let middle = CGRect(x: 378, y: 250, width: 756, height: 434)
        #expect(ScreenGeometry.map(middle, from: laptop, to: vertical) == CGRect(x: 1872, y: -711, width: 720, height: 1266))
        #expect(ScreenGeometry.map(leftHalf, from: laptop, to: laptop) == leftHalf)
    }

    @Test func orientation() {
        #expect(Orientation(of: Fixtures.laptop.frame.size) == .landscape)
        #expect(Orientation(of: Fixtures.verticalLeft.frame.size) == .portrait)
        #expect(Orientation(of: CGSize(width: 100, height: 100)) == .landscape)
    }
}
