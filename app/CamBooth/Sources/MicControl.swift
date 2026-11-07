import AVFoundation
import CoreAudio

/// Microphone selection and input level.
///
/// The mic picker is pure AVFoundation. The gain slider drives the device's
/// CoreAudio hardware input scalar, so it takes effect before audio even
/// reaches the capture session — no tap, no gain node, no extra buffers.
/// Devices without a settable input gain report `nil` and the UI hides the
/// slider rather than faking a control that does nothing.
enum MicControl {
    static func devices() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone],
            mediaType: .audio,
            position: .unspecified
        ).devices
    }

    static func matches(_ id: String, in devices: [AVCaptureDevice]) -> AVCaptureDevice? {
        devices.first { $0.uniqueID == id }
    }

    /// The persisted choice, or the system's current input device.
    static func resolvedID(saved: String?, devices: [AVCaptureDevice], fallback: String?) -> String? {
        if let saved, matches(saved, in: devices) != nil { return saved }
        if let fallback, matches(fallback, in: devices) != nil { return fallback }
        return devices.first?.uniqueID
    }

    /// Hardware input volume, 0.0–1.0. False when the device has no settable
    /// input gain (many USB/Bluetooth headsets expose gain elsewhere).
    static func setInputGain(_ gain: Double, for deviceID: String) -> Bool {
        guard let id = audioDeviceID(matchingCaptureID: deviceID) else { return false }
        var volume = Float(min(1, max(0, gain)))
        var address = AudioObjectPropertyAddress(
            mSelector: AudioObjectPropertySelector.hardwareVolume,
            mScope: AudioObjectPropertyScope.input,
            mElement: AudioObjectPropertyElement.main
        )
        return withUnsafeMutablePointer(to: &volume) { ptr in
            AudioObjectSetPropertyData(id, &address, 0, nil,
                                       UInt32(MemoryLayout<Float>.size), ptr) == noErr
        }
    }

    static func inputGain(for deviceID: String) -> Double? {
        guard let id = audioDeviceID(matchingCaptureID: deviceID) else { return nil }
        var address = AudioObjectPropertyAddress(
            mSelector: AudioObjectPropertySelector.hardwareVolume,
            mScope: AudioObjectPropertyScope.input,
            mElement: AudioObjectPropertyElement.main
        )
        var volume: Float = 0
        var size = UInt32(MemoryLayout<Float>.size)
        guard withUnsafeMutablePointer(to: &volume) { ptr in
            AudioObjectGetPropertyData(id, &address, 0, nil, &size, ptr) == noErr
        }, size == UInt32(MemoryLayout<Float>.size) else { return nil }
        return Double(volume)
    }

    // MARK: - AVCaptureDevice <-> CoreAudio bridge

    /// AVCaptureDevice's uniqueID is the CoreAudio device UID on macOS, so we
    /// match by asking the system object for each device's UID.
    private static func audioDeviceID(matchingCaptureID captureID: String) -> AudioObjectID? {
        let system: AudioObjectID = 1  // kAudioObjectSystemObject
        var address = AudioObjectPropertyAddress(
            mSelector: AudioObjectPropertySelector.devices,
            mScope: AudioObjectPropertyScope.global,
            mElement: AudioObjectPropertyElement.main
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return nil }
        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        guard count > 0 else { return nil }
        var objects = [AudioObjectID](repeating: system, count: count)
        guard objects.withUnsafeMutableBytes({ raw in
            AudioObjectGetPropertyData(system, &address, 0, nil, &size, raw.baseAddress!)
        }) == noErr else { return nil }

        var uidAddress = AudioObjectPropertyAddress(
            mSelector: AudioObjectPropertySelector.deviceUID,
            mScope: AudioObjectPropertyScope.global,
            mElement: AudioObjectPropertyElement.main
        )
        for object in objects {
            var uidRef: CFString? = nil
            var uidSize = UInt32(MemoryLayout<CFString?>.size)
            guard withUnsafeMutablePointer(to: &uidRef) { ptr in
                AudioObjectGetPropertyData(object, &uidAddress, 0, nil, &uidSize, ptr) == noErr
            }, let uid = uidRef as String? else { continue }
            if uid == captureID { return object }
        }
        return nil
    }
}
