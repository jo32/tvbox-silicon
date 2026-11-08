import Testing
@testable import TVCore

@Suite struct CloudBufferPlanTests {
    private let chunk = CloudByteStream.chunkSize

    @Test func aBigFileOnAFastDeviceReadsFarAhead() {
        // 1 GB over 1000 s: 1 MB/s, so 90 s is 45 chunks of 2 MB.
        let plan = CloudBufferPlan.make(length: 1_000_000_000, duration: 1000, budget: 256 << 20, chunkSize: chunk)
        #expect(plan.readAhead == 43)
        #expect(plan.readAhead > CloudByteStream.readAhead)
        #expect(plan.cacheChunks >= 2 * plan.readAhead)
        #expect(plan.seconds >= 85)
    }

    @Test func aHighBitrateIsLimitedByMemoryNotByWishes() {
        // 10 GB over 1000 s: 10 MB/s; 90 s would be 900 MB.
        let plan = CloudBufferPlan.make(length: 10_000_000_000, duration: 1000, budget: 256 << 20, chunkSize: chunk)
        #expect(plan.cacheChunks == 128)
        #expect(plan.readAhead == (128 - 4) / 2)
        #expect(plan.readAhead * chunk <= 256 << 20 / 2 + chunk)
    }

    @Test func aSmallBudgetShrinksTheWindow() {
        let big = CloudBufferPlan.make(length: 1_000_000_000, duration: 1000, budget: 256 << 20, chunkSize: chunk)
        let small = CloudBufferPlan.make(length: 1_000_000_000, duration: 1000, budget: 32 << 20, chunkSize: chunk)
        #expect(small.readAhead < big.readAhead)
        #expect(small.cacheChunks == CloudBufferPlan.fewestCached)
        #expect(small.readAhead >= CloudBufferPlan.fewestAhead)
    }

    @Test func aLowBitrateKeepsTheFloor() {
        let plan = CloudBufferPlan.make(length: 100_000_000, duration: 1000, budget: 256 << 20, chunkSize: chunk)
        #expect(plan.readAhead == CloudBufferPlan.fewestAhead)
    }

    @Test func anUnknownDurationKeepsTheOldWindow() {
        let plan = CloudBufferPlan.make(length: 1_000_000_000, duration: nil, budget: 256 << 20, chunkSize: chunk)
        #expect(plan.readAhead == CloudByteStream.readAhead)
        #expect(plan.seconds == 0)
        #expect(CloudBufferPlan.make(length: 1, duration: 0, budget: 256 << 20, chunkSize: chunk).seconds == 0)
    }
}
