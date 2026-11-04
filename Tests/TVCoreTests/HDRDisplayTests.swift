import Foundation
import Testing
@testable import TVCore

/// `HDRDisplay` is the one place that decides whether a picture has to be flattened to SDR. These
/// pin the two halves of that decision: what ffprobe's numbers mean, and what the screen allows.
@Suite struct HDRDisplayTests {

    @Test func ffprobeCurvesMapToTheSameTransfersTheFormatDescriptionReports() {
        // 16 = SMPTE ST 2084 (PQ, what HDR10 and Dolby Vision carry), 18 = ARIB STD-B67 (HLG).
        #expect(HDRDisplay.Transfer(colorTransfer: 16) == .pq)
        #expect(HDRDisplay.Transfer(colorTransfer: 18) == .hlg)
        // 1 = BT.709, 6 = BT.601: both ordinary SDR.
        #expect(HDRDisplay.Transfer(colorTransfer: 1) == .sdr)
        #expect(HDRDisplay.Transfer(colorTransfer: 6) == .sdr)
        // Anything else is unknown, which the caller treats as SDR: converting a picture that may
        // already be SDR would wash it out.
        #expect(HDRDisplay.Transfer(colorTransfer: 2) == .unknown)
        #expect(HDRDisplay.Transfer(colorTransfer: 14) == .unknown)
    }

    @Test func aDolbyVisionProfileOutranksTheBaseCurve() {
        // DV is an overlay on a PQ base layer, so a profile means DV whatever the curve says.
        #expect(HDRDisplay.Transfer(colorTransfer: 16, dolbyVisionProfile: 5) == .dolbyVision)
        #expect(HDRDisplay.Transfer(colorTransfer: 16, dolbyVisionProfile: 8) == .dolbyVision)
        // ffprobe reports "no DV" as -1, which has to fall through to the curve rather than count.
        #expect(HDRDisplay.Transfer(colorTransfer: 16, dolbyVisionProfile: -1) == .pq)
        #expect(HDRDisplay.Transfer(colorTransfer: 18, dolbyVisionProfile: nil) == .hlg)
    }

    @Test func theActionFollowsWhatTheScreenCanShow() {
        let display = HDRDisplay()
        // HDR file, HDR screen: pass it through untouched.
        #expect(display.action(for: .pq, displaySupportsHDR: true) == .passthrough)
        #expect(display.action(for: .hlg, displaySupportsHDR: true) == .passthrough)
        // HDR file, SDR screen: hand it to the encoder to flatten.
        #expect(display.action(for: .pq, displaySupportsHDR: false) == .toneMapToSDR)
        #expect(display.action(for: .hlg, displaySupportsHDR: false) == .toneMapToSDR)
        // SDR file: leave it alone, even on an HDR screen.
        #expect(display.action(for: .sdr, displaySupportsHDR: true) == .unchanged)
        #expect(display.action(for: .unknown, displaySupportsHDR: false) == .unchanged)
    }

    @Test func profileFiveOnAnSDRScreenIsReportedRatherThanInvented() {
        let display = HDRDisplay()
        // Profile 5 has no HDR10 picture to map, so there is nothing honest to tone-map.
        guard case .unsupportedDolbyVision = display.action(for: .dolbyVision, displaySupportsHDR: false, dolbyVisionProfile: 5)
        else {
            Issue.record("Profile 5 on an SDR screen must be reported as unsupported")
            return
        }
        // A profile 8 track carries a standard PQ base layer, so it tone-maps like any other PQ file.
        #expect(display.action(for: .dolbyVision, displaySupportsHDR: false, dolbyVisionProfile: 8) == .toneMapToSDR)
        #expect(display.action(for: .dolbyVision, displaySupportsHDR: true, dolbyVisionProfile: 5) == .passthrough)
    }

    @Test func theRemuxPlanFlattensWhatTheScreenCannotShowAndCopiesWhatItCan() {
        let sdr = RemuxPlan.Device(hevc: true, av1: false, hevcEncoder: true, hdr: false)
        let hdr = RemuxPlan.Device(hevc: true, av1: false, hevcEncoder: true, hdr: true)
        let pq = Stream(index: 0, kind: .video, codec: "h265", width: 3840, height: 2160, bitDepth: 10, colorTransfer: 16)

        #expect(RemuxPlan.videoTrack(pq, device: sdr).toneMap)
        #expect(!RemuxPlan.videoTrack(pq, device: hdr).toneMap)
        // Dolby Vision 5 keeps its picture rather than being mapped from something it never held.
        let vision5 = Stream(index: 0, kind: .video, codec: "hevc", width: 3840, height: 2160, bitDepth: 10, colorTransfer: 16, doviProfile: 5)
        #expect(!RemuxPlan.videoTrack(vision5, device: sdr).toneMap)
    }
}

/// The plan's stream type is internal, so the test builds one the same way the plan does.
private typealias Stream = RemuxPlan.Stream
