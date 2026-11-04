import AVFoundation
import AppKit

/// All capture work is delegated to AVFoundation: the movie output hands frames
/// to the hardware encoder (H.264/HEVC via VideoToolbox) and writes the file
/// directly, so no frame ever passes through our own code.
final class CameraModel: NSObject, ObservableObject {
    enum Mode: String, CaseIterable, Identifiable {
        case photo = "照片"
        case video = "视频"
        var id: String { rawValue }
    }

    enum Quality: String, CaseIterable, Identifiable {
        case hd720 = "720p"
        case hd1080 = "1080p"
        case uhd4K = "4K"
        var id: String { rawValue }
        var preset: AVCaptureSession.Preset {
            switch self {
            case .hd720: return .hd1280x720
            case .hd1080: return .hd1920x1080
            case .uhd4K: return .hd4K3840x2160
            }
        }
    }

    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "app.cambooth.session")
    private let movieOutput = AVCaptureMovieFileOutput()
    private let photoOutput = AVCapturePhotoOutput()
    private var videoInput: AVCaptureDeviceInput?
    private var audioInput: AVCaptureDeviceInput?
    private var outputsAdded = false
    private var timer: Timer?
    private var recordingStart = Date()

    @Published private(set) var authorized: Bool?          // nil = not asked yet
    @Published private(set) var devices: [AVCaptureDevice] = []
    @Published private(set) var supportedQualities: [Quality] = Quality.allCases
    @Published private(set) var isRecording = false
    @Published private(set) var elapsed = "00:00"
    @Published private(set) var lastSaved: URL?
    @Published var errorMessage: String?

    @Published var mode: Mode = .photo
    @Published var mirrored = true
    @Published var useHEVC = true
    @Published var selectedID: String? {
        didSet { if selectedID != oldValue { configure() } }
    }
    @Published var quality: Quality = .hd1080 {
        didSet { if quality != oldValue { configure() } }
    }

    // MARK: - Lifecycle

    func start() {
        Task { @MainActor in
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            authorized = granted
            guard granted else { return }
            _ = await AVCaptureDevice.requestAccess(for: .audio)   // optional: video still works without

            refreshDevices()
            NotificationCenter.default.addObserver(self, selector: #selector(devicesChanged),
                                                   name: .AVCaptureDeviceWasConnected, object: nil)
            NotificationCenter.default.addObserver(self, selector: #selector(devicesChanged),
                                                   name: .AVCaptureDeviceWasDisconnected, object: nil)
            selectedID = (AVCaptureDevice.userPreferredCamera ?? AVCaptureDevice.default(for: .video))?.uniqueID
                ?? devices.first?.uniqueID
            queue.async { self.session.startRunning() }
        }
    }

    func stop() {
        queue.async { self.session.stopRunning() }
    }

    @objc private func devicesChanged() {
        DispatchQueue.main.async {
            self.refreshDevices()
            if !self.devices.contains(where: { $0.uniqueID == self.selectedID }) {
                self.selectedID = self.devices.first?.uniqueID
            }
        }
    }

    private func refreshDevices() {
        devices = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
            mediaType: .video,
            position: .unspecified
        ).devices
    }

    // MARK: - Session configuration (always on `queue`)

    private func configure() {
        guard authorized == true, let id = selectedID, let device = AVCaptureDevice(uniqueID: id) else { return }
        let wanted = quality
        queue.async {
            self.session.beginConfiguration()
            defer { self.session.commitConfiguration() }

            if let old = self.videoInput { self.session.removeInput(old) }
            do {
                let input = try AVCaptureDeviceInput(device: device)
                guard self.session.canAddInput(input) else { return }
                self.session.addInput(input)
                self.videoInput = input
            } catch {
                self.report("无法打开摄像头：\(error.localizedDescription)")
                return
            }

            if self.audioInput == nil,
               AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
               let mic = AVCaptureDevice.default(for: .audio),
               let input = try? AVCaptureDeviceInput(device: mic),
               self.session.canAddInput(input) {
                self.session.addInput(input)
                self.audioInput = input
            }

            if !self.outputsAdded {
                if self.session.canAddOutput(self.movieOutput) { self.session.addOutput(self.movieOutput) }
                if self.session.canAddOutput(self.photoOutput) { self.session.addOutput(self.photoOutput) }
                self.outputsAdded = true
            }

            // Preset must be chosen after the input is attached; not every camera offers 4K.
            let supported = Quality.allCases.filter { self.session.canSetSessionPreset($0.preset) }
            let effective = supported.contains(wanted) ? wanted : (supported.last ?? .hd720)
            if self.session.canSetSessionPreset(effective.preset) {
                self.session.sessionPreset = effective.preset
            }
            DispatchQueue.main.async {
                self.supportedQualities = supported
                if self.quality != effective { self.quality = effective }
            }
        }
    }

    // MARK: - Capture

    func shutter() {
        switch mode {
        case .photo: takePhoto()
        case .video: isRecording ? stopRecording() : startRecording()
        }
    }

    private func takePhoto() {
        let mirror = mirrored
        queue.async {
            if let c = self.photoOutput.connection(with: .video), c.isVideoMirroringSupported {
                c.automaticallyAdjustsVideoMirroring = false
                c.isVideoMirrored = mirror
            }
            let settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
            self.photoOutput.capturePhoto(with: settings, delegate: self)
        }
    }

    private func startRecording() {
        guard let url = Self.outputURL(kind: .video) else { return }
        let mirror = mirrored
        let hevc = useHEVC
        queue.async {
            guard !self.movieOutput.isRecording else { return }
            if let c = self.movieOutput.connection(with: .video) {
                if c.isVideoMirroringSupported {
                    c.automaticallyAdjustsVideoMirroring = false
                    c.isVideoMirrored = mirror
                }
                if hevc, self.movieOutput.availableVideoCodecTypes.contains(.hevc) {
                    self.movieOutput.setOutputSettings([AVVideoCodecKey: AVVideoCodecType.hevc], for: c)
                }
            }
            self.movieOutput.startRecording(to: url, recordingDelegate: self)
        }
    }

    private func stopRecording() {
        queue.async { self.movieOutput.stopRecording() }
    }

    // MARK: - Helpers

    /// ~/Movies/Cam Booth or ~/Pictures/Cam Booth, created on demand.
    private static func outputURL(kind: CoreBridge.Kind) -> URL? {
        let base: FileManager.SearchPathDirectory = kind == .video ? .moviesDirectory : .picturesDirectory
        guard let root = FileManager.default.urls(for: base, in: .userDomainMask).first else { return nil }
        let dir = root.appendingPathComponent("Cam Booth", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(CoreBridge.fileName(kind: kind))
    }

    private func report(_ message: String) {
        DispatchQueue.main.async { self.errorMessage = message }
    }

    func revealLastSaved() {
        guard let url = lastSaved else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// Center Stage, Portrait, Studio Light, Reactions, Desk View: the system owns these effects,
    /// so we open its panel instead of re-implementing them.
    func showSystemEffects() {
        AVCaptureDevice.showSystemUserInterface(.videoEffects)
    }
}

// MARK: - Delegates

extension CameraModel: AVCapturePhotoCaptureDelegate {
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        if let error { return report("拍照失败：\(error.localizedDescription)") }
        guard let data = photo.fileDataRepresentation(), let url = Self.outputURL(kind: .photo) else { return }
        do {
            try data.write(to: url, options: .atomic)
            DispatchQueue.main.async { self.lastSaved = url }
        } catch {
            report("保存失败：\(error.localizedDescription)")
        }
    }
}

extension CameraModel: AVCaptureFileOutputRecordingDelegate {
    func fileOutput(_ output: AVCaptureFileOutput, didStartRecordingTo fileURL: URL, from connections: [AVCaptureConnection]) {
        DispatchQueue.main.async {
            self.recordingStart = Date()
            self.elapsed = "00:00"
            self.isRecording = true
            self.timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                guard let self else { return }
                self.elapsed = CoreBridge.duration(Date().timeIntervalSince(self.recordingStart))
            }
        }
    }

    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL,
                    from connections: [AVCaptureConnection], error: Error?) {
        // AVFoundation reports an "error" even for successful stops caused by e.g. a full disk; check the flag.
        let succeeded = (error as NSError?)?.userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool ?? (error == nil)
        DispatchQueue.main.async {
            self.timer?.invalidate()
            self.timer = nil
            self.isRecording = false
            if succeeded { self.lastSaved = outputFileURL }
            else if let error { self.errorMessage = "录像失败：\(error.localizedDescription)" }
        }
    }
}
