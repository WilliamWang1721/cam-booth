import AppKit
import AVFoundation
import Foundation

/// One-tap share into the system's share sheet: Mail, Messages, AirDrop, and
/// any third-party destination macOS offers (WeChat, QQ, …) all appear there,
/// so there is no per-app integration to maintain.
enum Sharing {
    /// Present the share sheet over the key window. Returns false if the app
    /// is not frontmost / has no window, so callers can fall back to reveal.
    @discardableResult
    static func share(url: URL) -> Bool {
        guard let window = NSApp.keyWindow,
              let view = window.contentView,
              let items = items(for: url) else { return false }
        let picker = NSSharingServicePicker(items: items)
        let rect = NSRect(x: view.bounds.midX - 40, y: view.bounds.midY - 40, width: 80, height: 80)
        picker.show(relativeTo: rect, of: view, preferredEdge: .maxY)
        return true
    }

    /// Photos and videos need different items: sharing services render image
    /// previews from NSImage (not from a file URL they cannot decode), and
    /// Messages needs an NSAttributedString with an attachment to show a
    /// video thumbnail. A bare file URL works for Mail/Files but shows as a
    /// generic icon elsewhere, so hand each type its native representation.
    static func items(for url: URL) -> [Any]? {
        if isVideo(url) {
            let asset = AVURLAsset(url: url)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 320, height: 320)
            if let frame = try? generator.copyCGImage(at: .zero, actualTime: nil) {
                let image = NSImage(cgImage: frame, size: NSSize(width: frame.width, height: frame.height))
                let attachment = NSTextAttachment()
                attachment.image = image
                let text = NSAttributedString(string: " ", attributes: [.attachment: attachment])
                return [text, url]
            }
            return [url]
        }
        if let image = NSImage(contentsOf: url) { return [image, url] }
        return [url]
    }

    private static func isVideo(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return ["mov", "mp4", "hevc", "m4v", "m4a"].contains(ext)
    }
}
