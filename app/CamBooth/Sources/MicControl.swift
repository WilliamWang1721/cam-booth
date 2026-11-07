import AppKit
import AVFoundation
import CoreAudio
import Foundation

/// Microphone selection and input level, backed by CoreAudio's per-device
/// input volume (the same scalar the system's own Sound panel adjusts).
///
/// The slider writes through `AudioObjectSetPropertyData`, so it takes effect
/// before audio even reaches the capture session — no tap, no gain node, no
/// extra buffers. Devices without a settable input gain just report nil and the
/// UI hides the slider rather than faking a control that does nothing.
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

    /// Hardware input volume, 0.0–1.0. Nil when the device has no
    /// settable input gain (many USB/Bluetooth headsets report gain elsewhere).
    static func setInputGain(_ gain: Double, for deviceID: String) -> Bool {
        guard let audioID = audioDeviceID(matchingCaptureID: deviceID) else { return false }
        var volume = Float(min(1, max(0, gain)))
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyVolume,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        return AudioObjectSetPropertyData(
            audioID, &address, 0, nil, UInt32(MemoryLayout<Float>.size), &volume
        ) == noErr
    }

    static func inputGain(for deviceID: String) -> Double? {
        guard let audioID = audioDeviceID(matchingCaptureID: deviceID) else { return nil }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyVolume,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var volume: Float = 0
        var size = UInt32(MemoryLayout<Float>.size)
        guard AudioObjectGetPropertyData(
            audioID, &address, 0, nil, &size, &volume
        ) == noErr, size == UInt32(MemoryLayout<Float>.size) else { return nil }
        return Double(volume)
    }

    // MARK: - AVCaptureDevice <-> CoreAudio bridge

    /// AVCaptureDevice exposes the CoreAudio unit id in its model id parsing;
    /// rather than guess at the string format, ask the AudioServerPlugIn for
    /// the device whose UID the capture device reports.
    private static func audioDeviceID(matchingCaptureID captureID: String) -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectSystemObject, &address, 0, nil, &size) == noErr else { return nil }
        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        guard count > 0 else { return nil }
        var objects = [AudioObjectID](repeating: kAudioObjectSystemObject, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectSystemObject, &address, 0, nil, &size, &objects
        ) == noErr else { return nil }

        var uidAddress = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        for object in objects {
            var uidRef: CFString? = nil
            var uidSize = UInt32(MemoryLayout<CFString?>.size)
            guard AudioObjectGetPropertyData(object, &uidAddress, 0, nil, &uidSize, &uidRef) == noErr,
                  let uid = uidRef as String? else { continue }
            if uid == captureID { return object }
        }
        return nil
    }
}
