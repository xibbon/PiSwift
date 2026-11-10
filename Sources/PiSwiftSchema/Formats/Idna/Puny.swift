// Port of packages/schema/src/formats/typebox/idna/format/puny.ts, pi-mono v1.5.2.
import Foundation

enum IdnaPuny {
    private static let base = 36
    private static let tMin = 1
    private static let tMax = 26
    private static let skew = 38
    private static let damp = 700
    private static let initialBias = 72
    private static let initialN = 128

    // JavaScript slice(4) advances four UTF-16 code units, not four grapheme clusters.
    static func aceBody(_ value: String) -> String {
        String(decoding: value.utf16.dropFirst(4), as: UTF16.self)
    }

    // IsAcePrefixed: value.toLowerCase().startsWith("xn--")
    static func isAcePrefixed(_ value: String) -> Bool {
        let u = Array(value.utf16)
        guard u.count >= 4 else { return false }
        return (u[0] == 120 || u[0] == 88) && (u[1] == 110 || u[1] == 78) && u[2] == 45 && u[3] == 45
    }

    // Adapt (RFC 3492). All arithmetic is checked by callers before entry.
    private static func adapt(_ rawDelta: Int, _ numPoints: Int, _ firstTime: Bool) -> Int? {
        guard numPoints > 0 else { return nil }
        var delta = firstTime ? rawDelta / damp : rawDelta / 2
        let increment = delta / numPoints
        let (sum, overflow) = delta.addingReportingOverflow(increment)
        if overflow { return nil }
        delta = sum
        var k = 0
        while delta > (base - tMin) * tMax / 2 {
            delta /= base - tMin
            let (next, large) = k.addingReportingOverflow(base)
            if large { return nil }
            k = next
        }
        let (numerator, large) = (base - tMin + 1).multipliedReportingOverflow(by: delta)
        if large { return nil }
        return k + numerator / (delta + skew)
    }

    // Decode. nil corresponds to upstream ThrowDontCare and its caught exception.
    static func decode(_ value: String) -> String? {
        let units = Array(value.utf16)
        var output: [UInt32] = []
        var n = initialN
        var i = 0
        var bias = initialBias
        let delim = units.lastIndex(of: 45)
        if let delim, delim > 0 {
            for j in 0..<delim {
                let cp = units[j]
                if cp >= 128 { return nil }
                output.append(UInt32(cp))
            }
        }
        var inIndex = delim.map { $0 + 1 } ?? 0
        while inIndex < units.count {
            let oldI = i
            var w = 1.0
            var k = base
            while true {
                if inIndex >= units.count { return nil }
                let ch = units[inIndex]
                inIndex += 1
                let digit: Int
                if (97...122).contains(ch) { digit = Int(ch) - 97 }
                else if (48...57).contains(ch) { digit = Int(ch) - 48 + 26 }
                else { return nil }
                let productDouble = Double(digit) * w
                if !productDouble.isFinite || productDouble > Double(Int.max) { return nil }
                let product = Int(productDouble)
                let (sum, sOverflow) = i.addingReportingOverflow(product)
                if sOverflow { return nil }
                i = sum
                let t = k <= bias ? tMin : k >= bias + tMax ? tMax : k - bias
                if digit < t { break }
                w *= Double(base - t)
                let (newK, kOverflow) = k.addingReportingOverflow(base)
                if kOverflow { return nil }
                k = newK
            }
            let outLength = output.count + 1
            guard let newBias = adapt(i - oldI, outLength, oldI == 0) else { return nil }
            bias = newBias
            let (newN, nOverflow) = n.addingReportingOverflow(i / outLength)
            if nOverflow || newN > 0x10FFFF { return nil }
            n = newN
            i %= outLength
            output.insert(UInt32(n), at: i)
            i += 1
        }
        var result = String.UnicodeScalarView()
        for cp in output {
            guard let scalar = Unicode.Scalar(cp) else { return nil }
            result.append(scalar)
        }
        return String(result)
    }

    // DigitToChar
    private static func digitToChar(_ digit: Int) -> Unicode.Scalar? {
        Unicode.Scalar(UInt32(digit < 26 ? digit + 97 : digit - 26 + 48))
    }

    // Encode. The only caller passes labels at most 63 UTF-16 units long.
    static func encode(_ input: String) -> String? {
        let codePoints = input.unicodeScalars.map { Int($0.value) }
        let basic = codePoints.filter { $0 < 128 }
        var result = String(String.UnicodeScalarView(basic.compactMap { Unicode.Scalar(UInt32($0)) }))
        if !basic.isEmpty { result.append("-") }
        var n = initialN
        var delta = 0
        var bias = initialBias
        var handled = basic.count
        while handled < codePoints.count {
            guard let m = codePoints.filter({ $0 >= n }).min() else { return nil }
            let (distance, dOverflow) = (m - n).multipliedReportingOverflow(by: handled + 1)
            if dOverflow { return nil }
            let (newDelta, sumOverflow) = delta.addingReportingOverflow(distance)
            if sumOverflow { return nil }
            delta = newDelta
            n = m
            for cp in codePoints {
                if cp < n {
                    let (next, overflow) = delta.addingReportingOverflow(1)
                    if overflow { return nil }
                    delta = next
                }
                if cp == n {
                    var q = delta
                    var k = base
                    while true {
                        let t = k <= bias ? tMin : k >= bias + tMax ? tMax : k - bias
                        if q < t { break }
                        let digit = t + (q - t) % (base - t)
                        guard let scalar = digitToChar(digit) else { return nil }
                        result.unicodeScalars.append(scalar)
                        q = (q - t) / (base - t)
                        let (nextK, overflow) = k.addingReportingOverflow(base)
                        if overflow { return nil }
                        k = nextK
                    }
                    guard let scalar = digitToChar(q), let newBias = adapt(delta, handled + 1, handled == basic.count) else { return nil }
                    result.unicodeScalars.append(scalar)
                    bias = newBias
                    delta = 0
                    handled += 1
                }
            }
            let (nextDelta, dOverflow2) = delta.addingReportingOverflow(1)
            let (nextN, nOverflow) = n.addingReportingOverflow(1)
            if dOverflow2 || nOverflow { return nil }
            delta = nextDelta
            n = nextN
        }
        return result
    }
}
