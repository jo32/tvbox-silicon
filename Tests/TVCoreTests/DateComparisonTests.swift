import Foundation
import Testing

// The shadowing Date <=/>= (DateComparison.swift) must agree with Foundation's.
struct DateComparisonTests {
    @Test func matchesFoundationOrdering() {
        let a = Date(timeIntervalSinceReferenceDate: 100)
        let b = Date(timeIntervalSinceReferenceDate: 200)
        #expect(a <= b)
        #expect(!(b <= a))
        #expect(a <= a)
        #expect(b >= a)
        #expect(!(a >= b))
        #expect(a >= a)
        #expect([b, a, b].filter { $0 >= b }.count == 2)
    }
}
