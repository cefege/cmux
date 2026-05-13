import Foundation

public struct Winsize: Sendable, Hashable {
    public var columns: UInt16
    public var rows: UInt16
    public var widthPixels: UInt16
    public var heightPixels: UInt16

    public init(
        columns: UInt16,
        rows: UInt16,
        widthPixels: UInt16 = 0,
        heightPixels: UInt16 = 0
    ) {
        self.columns = columns
        self.rows = rows
        self.widthPixels = widthPixels
        self.heightPixels = heightPixels
    }

    public static let fallback = Winsize(columns: 80, rows: 24, widthPixels: 0, heightPixels: 0)
}
