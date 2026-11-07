import AVFoundation
import Foundation

/// The countdown audio, synthesised in memory so the app ships no sound assets: a short beep on
/// every remaining second and a longer, higher one when the shutter actually fires (Photo Booth's
/// shape). Players are cached and reused so a tick never stutters on first use.
@MainActor
enum CountdownSound {
    enum Kind {
        case tick
        case go

        var frequency: Double { self == .tick ? 880 : 1_320 }
        var milliseconds: Int { self == .tick ? 90 : 220 }
    }

    private static var players: [Int: AVAudioPlayer] = [:]

    static func play(_ kind: Kind) {
        let key = Int(kind.frequency)
        if let player = players[key] {
            player.currentTime = 0
            player.play()
            return
        }
        guard let player = try? AVAudioPlayer(data: wav(kind)) else { return }
        player.prepareToPlay()
        players[key] = player
        player.play()
    }

    /// 16-bit mono PCM WAV with a short fade at both ends to avoid clicks.
    private static func wav(_ kind: Kind) -> Data {
        let sampleRate = 44_100
        let frames = sampleRate * kind.milliseconds / 1000
        let fade = max(1, sampleRate / 120)
        var samples = Data(capacity: frames * 2)
        for index in 0..<frames {
            let t = Double(index) / Double(sampleRate)
            let envelope = min(1, Double(index) / Double(fade)) * min(1, Double(frames - index) / Double(fade))
            let value = Int16(sin(2 * .pi * kind.frequency * t) * envelope * 0.55 * Double(Int16.max))
            let bits = UInt16(bitPattern: value)
            samples.append(UInt8(bits & 0xFF))
            samples.append(UInt8(bits >> 8))
        }

        var data = Data(capacity: 44 + samples.count)
        data.append(ascii: "RIFF")
        data.append(uint32: UInt32(36 + samples.count))
        data.append(ascii: "WAVE")
        data.append(ascii: "fmt ")
        data.append(uint32: 16)
        data.append(uint16: 1)                                   // PCM
        data.append(uint16: 1)                                   // mono
        data.append(uint32: UInt32(sampleRate))
        data.append(uint32: UInt32(sampleRate * 2))              // byte rate
        data.append(uint16: 2)                                   // block align
        data.append(uint16: 16)                                  // bits per sample
        data.append(ascii: "data")
        data.append(uint32: UInt32(samples.count))
        data.append(samples)
        return data
    }
}

private extension Data {
    mutating func append(ascii string: String) { append(contentsOf: Array(string.utf8)) }

    mutating func append(uint16 value: UInt16) {
        append(UInt8(value & 0xFF))
        append(UInt8(value >> 8))
    }

    mutating func append(uint32 value: UInt32) {
        for shift in stride(from: 0, through: 24, by: 8) {
            append(UInt8((value >> UInt32(shift)) & 0xFF))
        }
    }
}
