import Foundation

/// Default TCP port used by cmux fleet peers. Reserved range so two
/// concurrent cmux instances on one Mac (e.g. DEV + STAGING) can pick
/// different ports.
public enum FleetPort {
    public static let `default`: UInt16 = 14242
    public static let multiInstanceRange: ClosedRange<UInt16> = 14242...14245
}

public enum FleetIPv4 {
    public static func isValid(_ s: String) -> Bool {
        let parts = s.split(separator: ".")
        guard parts.count == 4 else { return false }
        return parts.allSatisfy { UInt8($0) != nil }
    }
}
