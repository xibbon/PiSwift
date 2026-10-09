extension Delta {
    /// Finds a bounded suffix/prefix overlap in UTF-16 code units.
    /// Port of chord `delta/index.ts:87–110`, v1.1.0, including candidate limits.
    public static func overlap(_ a: String, _ b: String, scan: Int, probe: Int = 64, maxCandidates: Int = 8) -> Int {
        let a = Array(a.utf16)
        let b = Array(b.utf16)
        if a.isEmpty || b.isEmpty || scan == 0 { return 0 }
        // JavaScript slice with a start past the end gives an empty tail for scan < 0.
        let tail = scan < 0 ? a[a.endIndex...] : a.suffix(min(scan, a.count))
        for h in [min(probe, b.count), 1] {
            // slice(0, negative) excludes that many units from the end.
            let headCount = h < 0 ? (h < -b.count ? 0 : b.count + h) : h
            let head = b.prefix(headCount)
            var tried = 0
            var from = tail.startIndex
            while let k = indexOf(head, in: tail, from: from) {
                tried += 1
                if tried > maxCandidates { break }
                let n = tail.endIndex - k
                if n <= b.count && tail[k...].elementsEqual(b.prefix(n)) { return n }
                from = k + 1
                // indexOf an empty head clamps a past-end start to the end.
                // This reproduces its repeated end candidate until the bound stops it.
            }
            if h == 1 { break }
        }
        return 0
    }

    private static func indexOf(_ head: ArraySlice<UInt16>, in tail: ArraySlice<UInt16>, from: Int) -> Int? {
        if head.isEmpty { return min(from, tail.endIndex) }
        guard head.count <= tail.count, from <= tail.endIndex - head.count else { return nil }
        for k in from...(tail.endIndex - head.count) {
            if tail[k..<(k + head.count)].elementsEqual(head) { return k }
        }
        return nil
    }
}
