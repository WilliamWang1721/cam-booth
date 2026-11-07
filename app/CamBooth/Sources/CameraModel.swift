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

    /// Countdown choices, mirroring the 关/3/5/10 options in the control bar.
    static let countdownChoices = [0, 3, 5, 10]

    /// Idle thresholds, mirroring the 关/1/2/5 分钟 options in 高级设置.
    static let sleepChoices = [0, 60, 120, 300]

    private enum Keys {
        static let mirrored = "mirrored"
        static let hevc = "useHEVC"
        static let countdown = "countdownSeconds"
        static let exportFormat = "videoExportFormat"
        static let micID = "selectedMicID"
        static let micGain = "micGain"
        static let sleepAfter = "cameraSleepAfterSeconds"
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
    private var countdownTimer: Timer?
    private var countdownAction: (() -> Void)?
    private var pendingPhotoURLs: [Int: URL] = [:]      // read/written on `queue` only
    private var reservedNames: Set<String> = []         // names handed out but not yet on disk

    // Idle sleep
    private var idleTimer: Timer?
    private var idleSince = Date()
    private var suspendedForIdle = false

    @Published private(set) var authorized: Bool?          // nil = not asked yet
    @Published private(set) var devices: [AVCaptureDevice] = []
    @Published private(set) var supportedQualities: [Quality] = Quality.allCases
    @Published private(set) var isRecording = false
    @Published private(set) var elapsed = "00:00"
    @Published private(set) var lastSaved: URL?
    @Published private(set) var recent: [CapturedItem] = []
    @Published private(set) var countdownRemaining = 0
    @Published private(set) var saveDirectory = SaveLocation.current
    @Published var errorMessage: String?

    @Published private(set) var micDevices: [AVCaptureDevice] = []
    @Published private(set) var selectedMicID: String?
    @Published private(set) var micGain: Double = 1.0
    @Published private(set) var micGainAvailable = false

    @Published private(set) var isSuspended = false

    @Published var mode: Mode = .photo
    @Published var mirrored: Bool {
        didSet {
            guard mirrored != oldValue else { return }
            UserDefaults.standard.set(mirrored, forKey: Keys.mirrored)
            applyMirroring(mirrored)
        }
    }
    @Published var useHEVC: Bool {
        didSet { UserDefaults.standard.set(useHEVC, forKey: Keys.hevc) }
    }
    @Published var countdownSeconds: Int {
        didSet { UserDefaults.standard.set(countdownSeconds, forKey: Keys.countdown) }
    }
    @Published var videoFormat: VideoFormat {
        didSet {
            UserDefaults.standard.set(videoFormat.rawValue, forKey: Keys.exportFormat)
        }
    }
    @Published var sleepAfterSeconds: Int {
        didSet {
            UserDefaults.standard.set(sleepAfterSeconds, forKey: Keys.sleepAfter)
            resetIdleClock()
        }
    }
    @Published var selectedID: String? {
        didSet { if selectedID != oldValue { configure() } }
    }
    @Published var quality: Quality = .hd1080 {
        didSet { if quality != oldValue { configure() } }
    }

    /// Anything the UI must not change mid-flight: switching cameras or reconfiguring the
    /// session would break both a recording and a running countdown.
    var isBusy: Bool { isRecording || countdownRemaining > 0 }

    override init() {
        let defaults = UserDefaults.standard
        mirrored = defaults.object(forKey: Keys.mirrored) as? Bool ?? true
        useHEVC = defaults.object(forKey: Keys.hevc) as? Bool ?? true
        countdownSeconds = defaults.object(forKey: Keys.countdown) as? Int ?? 0
        videoFormat = VideoFormat(
            rawValue: defaults.string(forKey: Keys.exportFormat) ?? ""
        ) ?? .mov
        sleepAfterSeconds = defaults.object(forKey: Keys.sleepAfter) as? Int ?? 0
        micGain = defaults.object(forKey: Keys.micGain) as? Double ?? 1.0
        super.init()
    }

    // MARK: - Lifecycle

    func start() {
        Task { @MainActor in
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            authorized = granted
            guard granted else { return }
            _ = await AVCaptureDevice.requestAccess(for: .audio)   // optional: video still works without

            refreshDevices()
            refreshMics()
            NotificationCenter.default.addObserver(self, selector: #selector(devicesChanged),
                                                   name: .AVCaptureDeviceWasConnected, object: nil)
            NotificationCenter.default.addObserver(self, selector: #selector(devicesChanged),
                                                   name: .AVCaptureDeviceWasDisconnected, object: nil)
            NotificationCenter.default.addObserver(self, selector: #selector(audioDevicesChanged),
                                                   name: .AVCaptureDeviceWasConnected, object: nil)
            NotificationCenter.default.addObserver(self, selector: #selector(audioDevicesChanged),
                                                   name: .AVCaptureDeviceWasDisconnected, object: nil)
            selectedID = (AVCaptureDevice.userPreferredCamera ?? AVCaptureDevice.default(for: .video))?.uniqueID
                ?? devices.first?.uniqueID
            queue.async { self.session.startRunning() }
            startIdleWatch()
        }
    }

    func stop() {
        cancelCountdown()
        stopIdleWatch()
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

    @objc private func audioDevicesChanged() {
        DispatchQueue.main.async { self.refreshMics() }
    }

    private func refreshDevices() {
        devices = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
            mediaType: .video,
            position: .unspecified
        ).devices
    }

    private func refreshMics() {
        micDevices = MicControl.devices()
        let old = selectedMicID
        let fallback = AVCaptureDevice.default(for: .audio)?.uniqueID
        selectedMicID = MicControl.resolvedID(saved: UserDefaults.standard.string(forKey: Keys.micID),
                                              devices: micDevices, fallback: fallback)
        UserDefaults.standard.set(selectedMicID, forKey: Keys.micID)
        updateMicGainAvailability()
        if old != selectedMicID || old == nil {
            configureAudio()
        }
    }

    private func updateMicGainAvailability() {
        micGainAvailable = selectedMicID.map { MicControl.inputGain(for: $0) != nil } ?? false
    }

    // MARK: - Session configuration (always on `queue`)

    private func configure() {
        guard authorized == true, let id = selectedID, let device = AVCaptureDevice(uniqueID: id) else { return }
        let wanted = quality
        let mirror = mirrored
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

            self.configureAudioLocked()

            if !self.outputsAdded {
                if self.session.canAddOutput(self.movieOutput) { self.session.addOutput(self.movieOutput) }
                if self.session.canAddOutput(self.photoOutput) { self.session.addOutput(self.photoOutput) }
                self.outputsAdded = true
            }

            self.applyMirroringLocked(mirror)
            self.fixOrientationLocked()

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

    private func configureAudio() {
        queue.async { self.configureAudioLocked() }
    }

    /// Must run on `queue` (or inside a configuration block). Re-attaches the
    /// chosen microphone; a nil choice means "no mic" (silent video).
    private func configureAudioLocked() {
        if let old = audioInput {
            session.removeInput(old)
            audioInput = nil
        }
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
              let id = selectedMicID,
              let mic = micDevices.first(where: { $0.uniqueID == id }) ?? AVCaptureDevice(uniqueID: id),
              let input = try? AVCaptureDeviceInput(device: mic),
              session.canAddInput(input) else { return }
        session.addInput(input)
        audioInput = input
        applyMicGain()
    }

    func selectMic(_ id: String?) {
        guard selectedMicID != id else { return }
        selectedMicID = id
        UserDefaults.standard.set(id, forKey: Keys.micID)
        configureAudio()
        updateMicGainAvailability()
    }

    func setMicGain(_ gain: Double) {
        micGain = gain
        UserDefaults.standard.set(gain, forKey: Keys.micGain)
        applyMicGain()
    }

    private func applyMicGain() {
        guard let id = selectedMicID else { return }
        _ = MicControl.setInputGain(micGain, for: id)
    }

    // MARK: - Orientation

    /// Root cause of "exported video is upside-down": the camera sensor
    /// reports landscape-landscape, but the connection's default video
    /// orientation is portrait. AVFoundation then records rotated frames,
    /// while the *preview* layer rotates independently — so the screen looks
    /// right and the file is flipped. Forcing landscape on every connection
    /// (preview, movie, photo) makes the three agree, and lets us drop the
    /// `.previewOrientation` workaround only some devices needed.
    private func fixOrientationLocked() {
        for output in [movieOutput, photoOutput] as [AVCaptureOutput] {
            if let c = output.connection(with: .video) {
                c.videoOrientation = .landscapeRight
            }
        }
    }

    // MARK: - Idle sleep

    private func startIdleWatch() {
        stopIdleWatch()
        guard sleepAfterSeconds > 0 else { return }
        idleSince = Date()
        idleTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.checkIdle()
        }
    }

    private func stopIdleWatch() {
        idleTimer?.invalidate()
        idleTimer = nil
    }

    private func checkIdle() {
        guard sleepAfterSeconds > 0, !isRecording, !suspendedForIdle else { return }
        guard Date().timeIntervalSince(idleSince) >= TimeInterval(sleepAfterSeconds) else { return }
        suspendForIdle()
    }

    /// Any interaction re-arms the clock.
    func touch() {
        idleSince = Date()
        if suspendedForIdle { wakeFromIdle() }
    }

    private func suspendForIdle() {
        guard authorized == true else { return }
        suspendedForIdle = true
        isSuspended = true
        cancelCountdown()
        queue.async { self.session.stopRunning() }
    }

    func wakeFromIdle() {
        guard suspendedForIdle else { return }
        suspendedForIdle = false
        isSuspended = false
        idleSince = Date()
        queue.async { self.session.startRunning() }
    }

    // MARK: - Mirroring

    /// Mirroring is a property of the capture connections, so the saved JPEG/MOV matches what the
    /// preview shows. Setting it on the preview layer alone would only flip what you see.
    private func applyMirroring(_ mirror: Bool) {
        queue.async { self.applyMirroringLocked(mirror) }
    }

    /// Must run on `queue`. A live recording keeps its current framing; changing it mid-file
    /// is not supported.
    private func applyMirroringLocked(_ mirror: Bool) {
        if !movieOutput.isRecording, let c = movieOutput.connection(with: .video), c.isVideoMirroringSupported {
            c.automaticallyAdjustsVideoMirroring = false
            c.isVideoMirrored = mirror
        }
        if let c = photoOutput.connection(with: .video), c.isVideoMirroringSupported {
            c.automaticallyAdjustsVideoMirroring = false
            c.isVideoMirrored = mirror
        }
    }

    // MARK: - Capture

    func shutter() {
        if isSuspended { wakeFromIdle(); return }
        touch()
        if countdownRemaining > 0 {
            cancelCountdown()
            return
        }
        if isRecording {
            stopRecording()
            return
        }
        let action: () -> Void = { [weak self] in
            guard let self else { return }
            if self.mode == .photo { self.takePhoto() } else { self.startRecording() }
        }
        if countdownSeconds > 0 {
            runCountdown(then: action)
        } else {
            action()
        }
    }

    private func takePhoto() {
        let mirror = mirrored
        queue.async {
            self.applyMirroringLocked(mirror)
            let settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
            self.pendingPhotoURLs[settings.uniqueID] = self.reserveURL(kind: .photo)
            self.photoOutput.capturePhoto(with: settings, delegate: self)
        }
    }

    private func startRecording() {
        let mirror = mirrored
        let hevc = useHEVC
        let format = videoFormat
        queue.async {
            guard !self.movieOutput.isRecording else { return }
            self.applyMirroringLocked(mirror)
            if let c = self.movieOutput.connection(with: .video) {
                if c.isVideoMirroringSupported {
                    c.automaticallyAdjustsVideoMirroring = false
                    c.isVideoMirrored = mirror
                }
                // macOS 14+ hardware encodes both; macOS has no `availableVideoCodecTypes`.
                let codec: AVVideoCodecType = hevc ? .hevc : .h264
                self.movieOutput.setOutputSettings([AVVideoCodecKey: codec], for: c)
            }
            let url = self.reserveURL(kind: .video)
            // Record what the user asked for when the shutter fired; the
            // high-level setting may change before the file finishes writing.
            self.recordingFormat[url] = format
            self.movieOutput.startRecording(to: url, recordingDelegate: self)
        }
    }

    private func stopRecording() {
        queue.async {
            guard self.movieOutput.isRecording else { return }
            self.movieOutput.stopRecording()
        }
    }

    // MARK: - Countdown

    private func runCountdown(then action: @escaping () -> Void) {
        countdownAction = action
        countdownRemaining = countdownSeconds
        beep(.tick)
        countdownTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] timer in
            guard let self, self.countdownRemaining > 0 else {
                timer.invalidate()
                return
            }
            self.countdownRemaining -= 1
            if self.countdownRemaining == 0 {
                timer.invalidate()
                let action = self.countdownAction
                self.countdownAction = nil
                self.beep(.go)
                action?()
            } else {
                self.beep(.tick)
            }
        }
    }

    /// The beep players live on the main actor; AVFoundation's queue and timer blocks reach them through it.
    private func beep(_ kind: CountdownSound.Kind) {
        Task { @MainActor in CountdownSound.play(kind) }
    }

    private func cancelCountdown() {
        countdownTimer?.invalidate()
        countdownTimer = nil
        countdownAction = nil
        countdownRemaining = 0
    }

    // MARK: - Helpers

    /// Video recordings are always raw QuickTime on disk. The user-chosen export
    /// format is applied *after* the hardware encode finishes (VideoExport), so
    /// the file is named with the final extension only once conversion succeeds.
    private func reserveURL(kind: CoreBridge.Kind) -> URL {
        let name = CoreBridge.fileName(kind: kind)
        let url = SaveLocation.uniqueURL(filename: name, reserved: reservedNames)
        reservedNames.insert(url.lastPathComponent)
        return url
    }

    private func releaseReservation(_ url: URL) {
        reservedNames.remove(url.lastPathComponent)
    }

    /// Video format captured at recording start, keyed by the raw file URL.
    private var recordingFormat: [URL: VideoFormat] = [:]

    private func report(_ message: String) {
        DispatchQueue.main.async { self.errorMessage = message }
    }

    private func addRecent(_ url: URL, isVideo: Bool, duration: String) {
        DispatchQueue.main.async {
            self.recent.insert(CapturedItem(url: url, isVideo: isVideo, duration: duration), at: 0)
            if self.recent.count > 24 { self.recent.removeLast(self.recent.count - 24) }
        }
    }

    private func resetIdleClock() {
        idleSince = Date()
        if sleepAfterSeconds > 0 { startIdleWatch() } else { stopIdleWatch() }
    }

    func refreshSaveLocation() {
        saveDirectory = SaveLocation.current
    }

    var saveDirectoryHint: String {
        (saveDirectory.path as NSString).abbreviatingWithTildeInPath
    }

    func open(_ item: CapturedItem) { NSWorkspace.shared.open(item.url) }

    func reveal(_ item: CapturedItem) { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }

    /// One-tap system share sheet: Mail, Messages, AirDrop, and every
    /// third-party app that registers there (WeChat, QQ, …) — no per-app code.
    @discardableResult
    func share(_ item: CapturedItem) -> Bool {
        Sharing.share(url: item.url)
    }

    /// Trash rather than delete: the user can still get the clip back.
    func trash(_ item: CapturedItem) {
        var movedTo: NSURL?
        do {
            try FileManager.default.trashItem(at: item.url, resultingItemURL: &movedTo)
        } catch {
            report("无法移到废纸篓：\(error.localizedDescription)")
            return
        }
        DispatchQueue.main.async { self.recent.removeAll { $0.id == item.id } }
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
        // The delegate runs on AVFoundation's own queue; hop to ours to read the pending names safely.
        queue.async {
            guard let url = self.pendingPhotoURLs.removeValue(
                    forKey: photo.settings.uniqueID) else {
                if let error { self.report("拍照失败：\(error.localizedDescription)") }
                return
            }
            // Every exit path below must release the reservation, or the filename
            // is blocked forever and the map grows per failed photo.
            defer { self.releaseReservation(url) }
            if let error {
                self.report("拍照失败：\(error.localizedDescription)")
                return
            }
            guard let data = photo.fileDataRepresentation() else {
                self.report("拍照失败：无法获取照片数据")
                return
            }
            do {
                try data.write(to: url, options: .atomic)
            } catch {
                self.report("保存失败：\(error.localizedDescription)")
                return
            }
            DispatchQueue.main.async {
                self.lastSaved = url
                self.addRecent(url, isVideo: false, duration: "")
            }
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
        // The reservation bookkeeping lives on the session queue; the format is
        // snapshotted there too so the lookup below cannot race the insert.
        let format = queue.sync { () -> VideoFormat? in
            defer {
                self.releaseReservation(outputFileURL)
                self.recordingFormat.removeValue(forKey: outputFileURL)
            }
            return self.recordingFormat[outputFileURL]
        }
        DispatchQueue.main.async {
            let duration = self.elapsed
            self.timer?.invalidate()
            self.timer = nil
            self.isRecording = false
            guard succeeded else {
                if let error { self.errorMessage = "录像失败：\(error.localizedDescription)" }
                return
            }
            // MOV is what the encoder produced. Other requested formats mean
            // a conversion step: the raw .mov stays in 影像栏 until the target
            // file exists, then its entry is swapped for the converted one.
            let wanted = format ?? self.videoFormat
            if wanted == .mov {
                self.lastSaved = outputFileURL
                self.addRecent(outputFileURL, isVideo: true, duration: duration)
                return
            }
            self.addRecent(outputFileURL, isVideo: true, duration: duration)
            Task { [weak self] in
                guard let self else { return }
                let name = CoreBridge.fileName(kind: .video, format: wanted)
                let finalURL = await VideoExport.convert(source: outputFileURL, name: name, to: wanted)
                DispatchQueue.main.async {
                    // Conversion failure keeps the raw .mov in place and under
                    // its .mov name; only swap the strip entry on success.
                    if finalURL != outputFileURL {
                        self.recent.removeAll { $0.url == outputFileURL }
                        self.addRecent(finalURL, isVideo: true, duration: duration)
                    } else {
                        self.errorMessage = "转码失败，保留原始 MOV 文件。"
                    }
                    self.lastSaved = finalURL
                }
            }
        }
    }
}
