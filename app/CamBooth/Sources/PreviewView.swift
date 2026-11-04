import AVFoundation
import SwiftUI

/// SwiftUI has no native camera preview, so this wraps the system's
/// AVCaptureVideoPreviewLayer (GPU-composited, no frame copies through our code).
struct PreviewView: NSViewRepresentable {
    let session: AVCaptureSession
    let mirrored: Bool

    func makeNSView(context: Context) -> PreviewNSView {
        let view = PreviewNSView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspect
        return view
    }

    func updateNSView(_ view: PreviewNSView, context: Context) {
        // A layer transform is free (GPU) and works before the connection exists.
        view.previewLayer.transform = mirrored ? CATransform3DMakeScale(-1, 1, 1) : CATransform3DIdentity
    }
}

final class PreviewNSView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func makeBackingLayer() -> CALayer { AVCaptureVideoPreviewLayer() }

    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
}
