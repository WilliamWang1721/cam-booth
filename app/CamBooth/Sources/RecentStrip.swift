import AVFoundation
import ImageIO
import SwiftUI

/// One file captured during this session.
struct CapturedItem: Identifiable, Hashable {
    let url: URL
    let isVideo: Bool
    let duration: String

    var id: String { url.path }
    var name: String { url.lastPathComponent }
}

/// Photo Booth's strip: everything shot in this session, newest first. Drag a clip out of the
/// window to share it; the drop target gets the file URL, so Messages/Mail/Finder all work.
struct RecentStrip: View {
    let items: [CapturedItem]
    let open: (CapturedItem) -> Void
    let reveal: (CapturedItem) -> Void
    let trash: (CapturedItem) -> Void
    let share: (CapturedItem) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(items) { item in
                    ClipCell(item: item)
                        .onDrag { NSItemProvider(object: item.url as NSURL) }
                        .onTapGesture(count: 2) { open(item) }
                        .contextMenu {
                            Button("打开") { open(item) }
                            Button("分享…", systemImage: "square.and.arrow.up") { share(item) }
                            Button("在访达中显示") { reveal(item) }
                            Divider()
                            Button("移到废纸篓", role: .destructive) { trash(item) }
                        }
                        .help(item.name)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .frame(height: 88)
        .background(.bar)
    }
}

private struct ClipCell: View {
    static let size = CGSize(width: 112, height: 74)

    let item: CapturedItem
    @State private var thumbnail: NSImage?

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            thumbnailView
            if item.isVideo {
                Text(item.duration)
                    .font(.caption2.monospacedDigit())
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(.black.opacity(0.65), in: Capsule())
                    .foregroundStyle(.white)
                    .padding(4)
            }
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
        .task(id: item.id) { thumbnail = await ClipThumbnail.image(for: item) }
    }

    @ViewBuilder private var thumbnailView: some View {
        if let thumbnail {
            Image(nsImage: thumbnail)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            Rectangle().fill(Color.primary.opacity(0.06))
        }
    }
}

/// Decoding happens off the main actor and only at strip size: a 4K photo never becomes a
/// full-resolution bitmap here.
enum ClipThumbnail {
    static func image(for item: CapturedItem) async -> NSImage? {
        await Task.detached(priority: .utility) { render(item) }.value
    }

    private static func render(_ item: CapturedItem) -> NSImage? {
        guard let frame = frameImage(for: item) else { return nil }
        return NSImage(cgImage: frame, size: NSSize(width: frame.width, height: frame.height))
    }

    private static func frameImage(for item: CapturedItem) -> CGImage? {
        if !item.isVideo {
            guard let source = CGImageSourceCreateWithURL(item.url as CFURL, nil) else { return nil }
            let options = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                           kCGImageSourceThumbnailMaxPixelSize: 320] as CFDictionary
            return CGImageSourceCreateThumbnailAtIndex(source, 0, options)
        }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: item.url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 320, height: 320)
        return try? generator.copyCGImage(at: .zero, actualTime: nil)
    }
}
