import AVFoundation
import Foundation

/// Thin Swift wrapper over the Rust core (see core/include/cambooth_core.h).
enum CoreBridge {
    enum Kind: Int32 {
        case photo = 0
        case video = 1
    }

    /// Names the capture at shutter time. Videos are named with the *final*
    /// extension the user picked in 高级设置; the raw QuickTime encode is
    /// moved aside first (see `VideoExport.convert`).
    static func fileName(kind: Kind, date: Date = Date(), format: VideoFormat = .mov) -> String {
        var buf = [CChar](repeating: 0, count: 128)
        let tz = Int32(TimeZone.current.secondsFromGMT(for: date))
        let code = kind == .photo ? Int32(0) : format.code
        let n = cb_output_filename(kind.rawValue, code, Int64(date.timeIntervalSince1970), tz, &buf, buf.count)
        if n >= 0 { return String(cString: buf) }
        let ext = kind == .photo ? "jpg" : format.rawValue
        return "Cam Booth \(Int(date.timeIntervalSince1970)).\(ext)"
    }

    static func duration(_ interval: TimeInterval) -> String {
        var buf = [CChar](repeating: 0, count: 32)
        let ms = UInt64(max(0, interval) * 1000)
        return cb_format_duration(ms, &buf, buf.count) >= 0 ? String(cString: buf) : "00:00"
    }

    static func avconvertPreset(for format: VideoFormat) -> String {
        var buf = [CChar](repeating: 0, count: 64)
        return cb_video_preset(format.code, &buf, buf.count) >= 0 ? String(cString: buf) : "PresetQuickTimeMovie"
    }
}
