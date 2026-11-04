import CoreGraphics

/// A named place for a window. Fractions are of the display's visible frame, origin top-left.
public struct WindowLayout: Equatable, Sendable {
    public let id: String
    public let name: String
    public let shape: Shape

    public init(id: String, name: String, shape: Shape) {
        self.id = id
        self.name = name
        self.shape = shape
    }

    public enum Shape: Equatable, Sendable {
        /// x, y, width, height as fractions (0-1).
        case rect(CGRect)
        case grid(columns: Int, rows: Int, cell: GridCell)
        /// Centered, keeping the window's current size.
        case center

        /// The shape as a fractional rect; nil for `.center`, which depends on the window.
        var fractions: CGRect? {
            switch self {
            case .rect(let rect):
                return rect
            case .grid(let columns, let rows, let cell):
                return CGRect(x: CGFloat(cell.column) / CGFloat(columns),
                              y: CGFloat(cell.row) / CGFloat(rows),
                              width: CGFloat(cell.columnSpan) / CGFloat(columns),
                              height: CGFloat(cell.rowSpan) / CGFloat(rows))
            case .center:
                return nil
            }
        }
    }
}

/// A block of grid cells: top-left cell plus spans, all in cells.
public struct GridCell: Equatable, Sendable {
    public let column: Int
    public let row: Int
    public let columnSpan: Int
    public let rowSpan: Int

    public init(column: Int, row: Int, columnSpan: Int, rowSpan: Int) {
        self.column = column
        self.row = row
        self.columnSpan = columnSpan
        self.rowSpan = rowSpan
    }
}

/// Space between windows and around the screen edge, in points.
public struct Gaps: Equatable, Sendable {
    public var outer: CGFloat
    /// Applied only to edges that face another region, half on each side.
    public var inner: CGFloat

    public init(outer: CGFloat = 0, inner: CGFloat = 0) {
        self.outer = outer
        self.inner = inner
    }
}

public enum LayoutEngine {
    /// A fractional edge this close to 0 or 1 counts as the screen edge, so
    /// hand-written thirds like 0.333 + 0.667 don't get an inner gap at the border.
    static let edgeTolerance: CGFloat = 0.001

    /// The window frame for `shape` on a display whose visible frame is `visibleFrame`.
    /// AX coordinates in and out, edges rounded to whole points. `currentSize` is the
    /// window's size now; only `.center` uses it.
    public static func frame(for shape: WindowLayout.Shape, in visibleFrame: CGRect, gaps: Gaps = Gaps(),
                             currentSize: CGSize = .zero) -> CGRect {
        let area = visibleFrame.insetBy(dx: gaps.outer, dy: gaps.outer)
        guard let f = shape.fractions else {
            let width = min(currentSize.width, area.width), height = min(currentSize.height, area.height)
            let minX = area.midX - width / 2, minY = area.midY - height / 2
            return CGRect(roundedMinX: minX, minY: minY, maxX: minX + width, maxY: minY + height)
        }
        let half = gaps.inner / 2
        var minX = area.minX + f.minX * area.width
        var maxX = area.minX + f.maxX * area.width
        var minY = area.minY + f.minY * area.height
        var maxY = area.minY + f.maxY * area.height
        if f.minX > edgeTolerance { minX += half }
        if f.maxX < 1 - edgeTolerance { maxX -= half }
        if f.minY > edgeTolerance { minY += half }
        if f.maxY < 1 - edgeTolerance { maxY -= half }
        return CGRect(roundedMinX: minX, minY: minY, maxX: maxX, maxY: maxY)
    }
}
