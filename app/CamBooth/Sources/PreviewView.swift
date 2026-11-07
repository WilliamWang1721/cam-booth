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
        // Preview and saved file must agree on orientation (see CameraModel.fixOrientationLocked).
        view.previewLayer.connection?.videoOrientation = .landscapeRight
        return view
    }

    func updateNSView(_ view: PreviewNSView, context: Context) {
        // Mirroring is applied on the capture connections in CameraModel (on the
        // session queue, inside its configuration blocks), so the preview layer
        // mirrors for free through the connection. Writing the connection here
        // would race those writes from the main thread; the transform below is
        // only a fallback for preview connections that do not support mirroring.
        if let connection = view.previewLayer.connection, connection.isVideoMirroringSupported {
            view.previewLayer.transform = CATransform3DIdentity
        } else {
            view.previewLayer.transform = mirrored ? CATransform3DMakeScale(-1, 1, 1) : CATransform3DIdentity
        }
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
