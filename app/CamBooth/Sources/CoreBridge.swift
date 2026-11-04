import Foundation

/// Thin Swift wrapper over the Rust core (see core/include/cambooth_core.h).
enum CoreBridge {
    enum Kind: Int32 {
        case photo = 0
        case video = 1
    }

    static func fileName(kind: Kind, date: Date = Date()) -> String {
        var buf = [CChar](repeating: 0, count: 128)
        let tz = Int32(TimeZone.current.secondsFromGMT(for: date))
        let n = cb_output_filename(kind.rawValue, Int64(date.timeIntervalSince1970), tz, &buf, buf.count)
        if n >= 0 { return String(cString: buf) }
        return "Cam Booth \(Int(date.timeIntervalSince1970)).\(kind == .photo ? "jpg" : "mov")"
    }

    static func duration(_ interval: TimeInterval) -> String {
        var buf = [CChar](repeating: 0, count: 32)
        let ms = UInt64(max(0, interval) * 1000)
        return cb_format_duration(ms, &buf, buf.count) >= 0 ? String(cString: buf) : "00:00"
    }
}
