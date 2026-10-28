import Foundation
import CoreFoundation

/// Read a JSON boolean without converting the numbers 0 and 1 to booleans.
package func jsonBoolean(_ value: Any?) -> Bool? {
    guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
    return number.boolValue
}
