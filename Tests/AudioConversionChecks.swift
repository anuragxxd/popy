import AVFoundation
import Foundation

@main
struct AudioChecks {
    static func main() {
        for rate in [8_000.0, 16_000.0, 24_000.0, 44_100.0, 48_000.0] {
            for channels: AVAudioChannelCount in [1, 2] {
                let input = AVAudioFormat(standardFormatWithSampleRate: rate, channels: channels)!
                let output = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000,
                                           channels: 1, interleaved: true)!
                let converter = AVAudioConverter(from: input, to: output)!
                var frames = 0
                var peak: Int16 = 0
                for block in 0..<32 {
                    let buffer = AVAudioPCMBuffer(pcmFormat: input, frameCapacity: 1024)!
                    buffer.frameLength = 1024
                    for channel in 0..<Int(channels) {
                        for sample in 0..<1024 {
                            buffer.floatChannelData![channel][sample] = Float(sin(2 * .pi * 440 * Double(block * 1024 + sample) / rate)) * 0.25
                        }
                    }
                    guard let converted = converter.convertedBuffer(buffer) else { continue }
                    precondition(converted.format == output)
                    frames += Int(converted.frameLength)
                    for i in 0..<Int(converted.frameLength) {
                        peak = max(peak, abs(converted.int16ChannelData![0][i]))
                    }
                }
                let expected = 32 * 1024 * 16_000 / rate
                precondition(abs(Double(frames) - expected) < 128, "Wrong recording duration at \(rate)")
                precondition(peak > 4000 && peak < 12000, "Missing or distorted samples")
                print("PASS: \(Int(rate)) Hz, \(channels) channels → 16 kHz mono; \(frames) frames")
            }
        }
    }
}
