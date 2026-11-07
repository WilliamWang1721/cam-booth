import AVFoundation
import AppKit
import Foundation

/// Converts finished QuickTime captures into the format the user picked,
/// using the system `avconvert` tool — the same encoder VideoToolbox already
/// used for the live recording, so converting is cheap and needs no Swift
/// re-encode. Runs off the main thread and reports back asynchronously.
///
/// The raw .mov is kept in place until conversion succeeds; only then is it
/// removed and the caller's strip entry swapped for the converted file. On
/// failure the raw clip stays under its .mov name and an error is reported.
enum VideoExport {
    /// On success returns the converted file URL (and removes the raw source).
    /// On failure returns the original source unchanged, so the caller can keep
    /// the clip under its .mov name rather than leaving a misnamed file behind.
    static func convert(source: URL, name: String, to format: VideoFormat) async -> URL {
        guard format != .mov else { return source }
        let destination = SaveLocation.uniqueURL(filename: name, in: source.deletingLastPathComponent())
        let preset = CoreBridge.avconvertPreset(for: format)
        if await runAvconvert(source: source, output: destination, preset: preset) {
            try? FileManager.default.removeItem(at: source)
            return destination
        }
        try? FileManager.default.removeItem(at: destination)
        return source
    }

    private static func runAvconvert(source: URL, output: URL, preset: String) async -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/avconvert")
        process.arguments = ["-s", source.path, "-o", output.path, "-p", preset]
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            DispatchQueue.global(qos: .utility).async {
                do {
                    try process.run()
                    process.waitUntilExit()
                    continuation.resume(returning: process.terminationStatus == 0
                        && FileManager.default.fileExists(atPath: output.path))
                } catch {
                    continuation.resume(returning: false)
                }
            }
        }
    }
}
