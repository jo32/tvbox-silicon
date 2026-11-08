import Testing
@testable import TVCore

@Suite struct CloudDeviceTests {
    private let gb: UInt64 = 1 << 30
    private let mb = 1 << 20

    @Test func appleTVModelsGetTheirOwnLimits() {
        let hd = CloudDevice.profile(identifier: "AppleTV5,3", memory: 2 * gb)
        let first = CloudDevice.profile(identifier: "AppleTV6,2", memory: 3 * gb)
        let third = CloudDevice.profile(identifier: "AppleTV14,1", memory: 4 * gb)
        #expect([hd, first, third].allSatisfy { $0.family == .appleTV })
        #expect(hd.cap < first.cap && first.cap < third.cap)
        #expect(hd.maxConnections < third.maxConnections)
        #expect(hd.label.hasPrefix("Apple TV HD"))
    }

    @Test func anUnknownAppleTVGoesByItsMemory() {
        #expect(CloudDevice.profile(identifier: "AppleTV99,9", memory: 4 * gb).cap == 192 * mb)
        #expect(CloudDevice.profile(identifier: "AppleTV99,9", memory: 2 * gb).cap == 48 * mb)
    }

    @Test func phonesAndTabletsGoByMemory() {
        let se = CloudDevice.profile(identifier: "iPhone14,6", memory: 4 * gb)
        let pro = CloudDevice.profile(identifier: "iPhone16,2", memory: 8 * gb)
        let ipad = CloudDevice.profile(identifier: "iPad16,3", memory: 16 * gb)
        let old = CloudDevice.profile(identifier: "iPad7,5", memory: 2 * gb)
        #expect(se.family == .iPhone && ipad.family == .iPad)
        #expect(old.cap < se.cap && se.cap < pro.cap)
        #expect(pro.maxConnections >= se.maxConnections)
    }

    @Test func macsAreToldApart() {
        let silicon = CloudDevice.profile(identifier: "Mac15,6", memory: 36 * gb)
        let intel = CloudDevice.profile(identifier: "MacBookPro16,1", memory: 16 * gb, appleSilicon: false)
        let ipadApp = CloudDevice.profile(identifier: "iPad13,1", memory: 16 * gb, iOSAppOnMac: true)
        #expect(silicon.family == .mac && intel.family == .mac && ipadApp.family == .mac)
        #expect(silicon.cap > intel.cap)
        #expect(silicon.maxConnections > intel.maxConnections)
    }

    @Test func theBudgetFollowsWhatTheAppMayStillUse() {
        let tv = CloudDevice.profile(identifier: "AppleTV14,1", memory: 4 * gb)
        // 1/10 of 1 GB left is 100 MB; of 3 GB, more than the cap allows.
        #expect(CloudDevice.budget(for: tv, available: 1 * gb, constrained: false) == Int(gb) / 10)
        #expect(CloudDevice.budget(for: tv, available: 3 * gb, constrained: false) == tv.cap)
        #expect(CloudDevice.budget(for: tv, available: 100 * UInt64(mb), constrained: false) == tv.floor)
    }

    @Test func powerSavingHalvesIt() {
        let phone = CloudDevice.profile(identifier: "iPhone16,2", memory: 8 * gb)
        let normal = CloudDevice.budget(for: phone, available: 4 * gb, constrained: false)
        let saving = CloudDevice.budget(for: phone, available: 4 * gb, constrained: true)
        #expect(saving == normal / 2)
    }

    @Test func thisDeviceIsRecognized() {
        let device = CloudDevice.current
        #expect(device.family != .other)
        #expect(CloudDevice.cacheBudget >= 16 * mb)
        #expect(CloudDevice.maxConnections >= 4)
    }
}
