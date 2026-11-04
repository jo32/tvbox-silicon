// The decision itself is framework-light — CoreMedia for the transfer, CoreVideo for the format —
// so the whole type is built everywhere, and only "can this screen show HDR right now" needs UIKit.
// The Mac answers false there, which is what makes it the same SDR path the iPhone takes with the
// brightness turned down.
#if canImport(AVFoundation)
import Foundation
import AVFoundation
import CoreVideo
#if canImport(UIKit)
import UIKit
#endif

/// What a video's colour actually is, and whether this screen can show it.
///
/// Rex carries `libplacebo` and `libdovi` and a `DoviMatrix` module to do this properly — a full
/// GPU tone-mapping pipeline, twelve upscale modes, Dolby Vision profile 5/7 reshaping. 映匣's
/// FFmpeg is a decode-only build (679 objects, no `avfilter`, no `libplacebo`), so that road is not
/// open without vendoring two more C libraries and a shader set.
///
/// What *is* open is the route Apple already ships, and it is the right one for an AVPlayer-based
/// player: the system does the tone mapping when the display supports it, and refuses to invent
/// brightness when it does not. This type does the part that is actually missing in 映匣 — deciding
/// **what the file is** and **whether to hand it over untouched, tone-map it, or leave it alone**.
///
/// The three cases are genuinely different and each has a wrong answer that looks reasonable:
///
/// * **HDR file, HDR screen** — pass it through. Tone-mapping here would clip highlights the screen
///   can display. This is where a naive "always convert to SDR" implementation loses the whole
///   point of an HDR transfer.
/// * **HDR file, SDR screen** — hand it to the system for tone mapping. Doing it by hand needs the
///   mastering metadata, which is often absent; the system's own fallback is better than a guess.
/// * **SDR file, HDR screen** — leave it alone. Rex offers an experimental SDR→HDR boost
///   (`mac.playback.sdrToHDR.footer`) and is explicit that it only touches highlights and only on a
///   capable display, and that it costs power. Treating "the screen is HDR" as an instruction to
///   stretch every SDR file is the classic mistake.
public struct HDRDisplay: Sendable {

    /// The transfer function a file uses.
    public enum Transfer: String, Sendable, Codable {
        case sdr          // Rec.709 / sRGB
        case hlg          // ARIB STD-B67, broadcast HDR
        case pq           // SMPTE ST 2084, used by HDR10 and Dolby Vision
        case dolbyVision  // PQ with dynamic metadata on top
        case unknown

        public var isHDR: Bool { self != .sdr && self != .unknown }
    }

    /// The decision, which the player acts on.
    public enum Action: Sendable, Equatable {
        /// Play it as it is; the screen can show exactly this.
        case passthrough
        /// Let the system tone-map down to SDR.
        case toneMapToSDR
        /// Play the SDR file unchanged. The default, and correct most of the time.
        case unchanged
        /// The file is Dolby Vision and this device has no decoder for its profile.
        case unsupportedDolbyVision(String)
    }

    public init() {}

    // MARK: Reading the file

    /// Reads the transfer function from a track's format description.
    ///
    /// `kCMFormatDescriptionExtension_TransferFunction` is the authoritative field. Dolby Vision is
    /// not a transfer function but an overlay: the base layer still says PQ, so DV is detected from
    /// the sample description's four-character code instead of guessing from the transfer.
    public static func transfer(of description: CMFormatDescription?) -> Transfer {
        guard let description else { return .unknown }
        guard let extensions = CMFormatDescriptionGetExtensions(description) as? [String: Any] else {
            return .unknown
        }

        if let codec = fourCharCode(of: description), codec == "dvh1" || codec == "dvhe" {
            return .dolbyVision
        }

        guard let raw = extensions[kCMFormatDescriptionExtension_TransferFunction as String] as? String else {
            return .unknown
        }
        switch raw {
        case String(kCMFormatDescriptionTransferFunction_ITU_R_709_2):
            return .sdr
        case String(kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ):
            return .pq
        case String(kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG):
            return .hlg
        default:
            return .unknown
        }
    }

    private static func fourCharCode(of description: CMFormatDescription) -> String? {
        let code = CMFormatDescriptionGetMediaSubType(description)
        let bytes = [
            UInt8((code >> 24) & 0xFF), UInt8((code >> 16) & 0xFF),
            UInt8((code >> 8) & 0xFF), UInt8(code & 0xFF),
        ]
        guard bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }) else { return nil }
        return String(bytes: bytes, encoding: .ascii)
    }

    // MARK: The decision

    /// The action to take, given the file's transfer and whether the screen can show HDR.
    ///
    /// `dolbyVisionProfile` is passed separately because DV profile 5 uses a non-standard colour
    /// space that only some devices decode; profile 7 and 8 carry a standard base layer and are
    /// handled as ordinary PQ by the system.
    public func action(for transfer: Transfer,
                       displaySupportsHDR: Bool,
                       dolbyVisionProfile: Int? = nil) -> Action {
        switch transfer {
        case .sdr, .unknown:
            // An unknown transfer is treated as SDR: converting something that might already be SDR
            // would wash it out, and passing it through is the reversible choice.
            return .unchanged

        case .hlg, .pq:
            return displaySupportsHDR ? .passthrough : .toneMapToSDR

        case .dolbyVision:
            // Profile 5 cannot be shown without a DV decoder; the others have a PQ base layer the
            // system can tone-map on its own.
            if let profile = dolbyVisionProfile, profile == 5, !displaySupportsHDR {
                return .unsupportedDolbyVision(L10n.text("Dolby Vision profile 5 needs an HDR screen"))
            }
            return displaySupportsHDR ? .passthrough : .toneMapToSDR
        }
    }

    /// Whether the screen can show HDR right now.
    ///
    /// `potentialEDRHeadroom` above 1.0 means the display can go brighter than SDR white, which is
    /// the definition that matters — a screen can be "HDR capable" in its spec sheet and still be at
    /// 1.0 when brightness is turned down, and tone-mapping for a headroom that is not there looks
    /// worse than plain SDR.
    @MainActor
    public static func displaySupportsHDR() -> Bool {
        #if os(iOS) || os(tvOS)
        return UIScreen.main.potentialEDRHeadroom > 1.01
        #else
        return false
        #endif
    }

    /// The pixel format to ask `AVPlayerItemVideoOutput` for.
    ///
    /// 10-bit when the display can take it, 8-bit otherwise. Asking for 10-bit on an SDR screen
    /// costs memory and bandwidth for bits that are then clipped away.
    public static func preferredPixelFormat(displaySupportsHDR: Bool) -> OSType {
        displaySupportsHDR ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
                           : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
    }
}

extension HDRDisplay.Transfer {
    /// The transfer an ffprobe `color_transfer` value means.
    ///
    /// Remux plans are made from ffprobe, before any `CMFormatDescription` exists, so the tone-map
    /// decision cannot go through `transfer(of:)`. The numbers are ffprobe's: 16 is SMPTE ST 2084
    /// (PQ, what HDR10 and Dolby Vision carry), 18 is ARIB STD-B67 (HLG), 1 and 6 are the Rec.709
    /// and Rec.601 SDR curves. Anything else is unknown, which the caller treats as SDR: converting
    /// something that may already be SDR would wash it out.
    public init(colorTransfer: Int, dolbyVisionProfile: Int? = nil) {
        // Dolby Vision is an overlay on a PQ base layer, so the profile decides, not the curve.
        if let dolbyVisionProfile, dolbyVisionProfile >= 0 {
            self = .dolbyVision
            return
        }
        switch colorTransfer {
        case 16: self = .pq
        case 18: self = .hlg
        case 1, 6: self = .sdr
        default: self = .unknown
        }
    }
}

#endif
