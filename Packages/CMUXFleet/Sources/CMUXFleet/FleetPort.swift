import Foundation

/// Default TCP port used by cmux fleet peers. Reserved range so two
/// concurrent cmux instances on one Mac (e.g. DEV + STAGING) can pick
/// different ports.
public enum FleetPort {
    public static let `default`: UInt16 = 14242
    public static let multiInstanceRange: ClosedRange<UInt16> = 14242...14245
}
