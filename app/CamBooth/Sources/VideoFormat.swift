import AVFoundation
import Foundation

/// Video export format: what `AVCaptureMovieFileOutput` can write. MOV is the
/// native QuickTime container and stays the default; the others exist so a clip
/// lands in a shape other players (and other OSes) open without conversion.
enum VideoFormat: String, CaseIterable, Identifiable {
    case mov
    case mp4
    case hevc
    case m4v

    var id: String { rawValue }

    /// Raw value handed to the Rust core's `CB_FMT_*` enum.
    var code: Int32 {
        switch self {
        case .mov: return 0
        case .mp4: return 1
        case .hevc: return 2
        case .m4v: return 3
        }
    }

    var label: String {
        switch self {
        case .mov: return "MOV（QuickTime）"
        case .mp4: return "MP4（通用）"
        case .hevc: return "HEVC（.hevc）"
        case .m4v: return "M4V（Apple 设备）"
        }
    }
}
