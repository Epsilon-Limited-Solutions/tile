import CoreGraphics

/// Display geometry in AX coordinates: origin at the top-left of the primary display,
/// y growing down. NSScreen uses the bottom-left of the primary display, y growing up.
/// Everything Tile computes (layouts, window frames) is in AX coordinates; NSScreen
/// frames are converted here and nowhere else.
public struct ScreenGeometry: Sendable {
    public let displays: [DisplayInfo]
    /// NSScreen frame of the primary display (the one with the menu bar, origin 0,0).
    public let primaryFrame: CGRect

    public init(displays: [DisplayInfo]) {
        self.displays = displays
        primaryFrame = (displays.first(where: \.isPrimary) ?? displays.first)?.frame ?? .zero
    }

    /// NSScreen rect to AX rect, or back: the flip is its own inverse.
    public static func flip(_ rect: CGRect, primaryFrame: CGRect) -> CGRect {
        CGRect(x: rect.minX, y: primaryFrame.maxY - rect.maxY, width: rect.width, height: rect.height)
    }

    public func axFrame(of display: DisplayInfo) -> CGRect {
        Self.flip(display.frame, primaryFrame: primaryFrame)
    }

    public func axVisibleFrame(of display: DisplayInfo) -> CGRect {
        Self.flip(display.visibleFrame, primaryFrame: primaryFrame)
    }

    /// The display a window is on: the one it overlaps most, or the nearest if it overlaps none.
    public func display(for windowFrame: CGRect) -> DisplayInfo? {
        var best: (display: DisplayInfo, overlap: CGFloat)?
        for display in displays {
            let overlap = axFrame(of: display).intersection(windowFrame)
            let area = overlap.isNull ? 0 : overlap.width * overlap.height
            if area > (best?.overlap ?? 0) { best = (display, area) }
        }
        if let best { return best.display }
        let center = CGPoint(x: windowFrame.midX, y: windowFrame.midY)
        return displays.min { distance(from: center, to: axFrame(of: $0)) < distance(from: center, to: axFrame(of: $1)) }
    }

    /// Left to right, then top to bottom: the order `next-display` steps through.
    public var orderedDisplays: [DisplayInfo] {
        displays.sorted {
            let a = axFrame(of: $0), b = axFrame(of: $1)
            return (a.minX, a.minY) < (b.minX, b.minY)
        }
    }

    /// The display `offset` steps from `display` in `orderedDisplays`, wrapping around.
    public func display(_ offset: Int, from display: DisplayInfo) -> DisplayInfo? {
        let ordered = orderedDisplays
        guard let index = ordered.firstIndex(where: { $0.id == display.id }) else { return nil }
        let count = ordered.count
        return ordered[((index + offset) % count + count) % count]
    }

    /// `rect` moved from one frame to another, keeping its position and size as
    /// fractions of the frame. Used by next-display and previous-display.
    public static func map(_ rect: CGRect, from source: CGRect, to target: CGRect) -> CGRect {
        func x(_ value: CGFloat) -> CGFloat { target.minX + (value - source.minX) / source.width * target.width }
        func y(_ value: CGFloat) -> CGFloat { target.minY + (value - source.minY) / source.height * target.height }
        return CGRect(roundedMinX: x(rect.minX), minY: y(rect.minY), maxX: x(rect.maxX), maxY: y(rect.maxY))
    }

    private func distance(from point: CGPoint, to rect: CGRect) -> CGFloat {
        let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
        let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
        return (dx * dx + dy * dy).squareRoot()
    }
}

public enum Orientation: String, Sendable, CaseIterable {
    case portrait, landscape

    public init(of size: CGSize) {
        self = size.height > size.width ? .portrait : .landscape
    }
}

extension CGRect {
    /// A rect from its edges, each rounded to a whole point, so neighbors computed
    /// from a shared edge abut exactly instead of overlapping or leaving a sliver.
    init(roundedMinX minX: CGFloat, minY: CGFloat, maxX: CGFloat, maxY: CGFloat) {
        let x = minX.rounded(), y = minY.rounded()
        self.init(x: x, y: y, width: maxX.rounded() - x, height: maxY.rounded() - y)
    }

    /// Same position and size within `tolerance` points.
    public func isClose(to other: CGRect, within tolerance: CGFloat) -> Bool {
        abs(minX - other.minX) <= tolerance && abs(minY - other.minY) <= tolerance
            && abs(width - other.width) <= tolerance && abs(height - other.height) <= tolerance
    }
}
