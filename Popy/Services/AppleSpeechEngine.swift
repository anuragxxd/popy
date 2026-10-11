import AVFoundation
import Foundation
import Speech

/// A transcription that consumes audio while the user is still speaking.
protocol LiveTranscription: AnyObject {
    /// Feed one captured buffer. Safe to call from the audio tap's thread.
    func append(_ buffer: AVAudioPCMBuffer)
    /// The user has stopped: wait for the last words and return the transcript.
    func finish() async throws -> String
    /// Abandon the transcription, e.g. for a silent or cancelled recording.
    func cancel()
}

/// On-device speech-to-text with Apple's SpeechAnalyzer (macOS 26+).
///
/// Used instead of Whisper wherever it runs. On the same audio it was far
/// more accurate than Whisper base.en, and macOS installs and updates the
/// model itself, so Popy has nothing to bundle or download. Audio streams in
/// during recording, so the transcript is ready ~0.2s after the user stops.
/// Intel Macs and macOS 12–25 keep Whisper (`TranscriptionService`).
enum AppleSpeechEngine {

    static var isSupported: Bool {
        if #available(macOS 26, *) {
            return SpeechTranscriber.isAvailable
        }
        return false
    }

    /// Start transcribing a new recording, or nil where only Whisper runs.
    static func makeLiveTranscription() -> LiveTranscription? {
        guard #available(macOS 26, *), SpeechTranscriber.isAvailable else { return nil }
        return AppleLiveTranscription()
    }

    /// Have macOS fetch the model before the first dictation needs it.
    /// Returns immediately when it is already installed, which is typical.
    static func installModelInBackground() {
        guard #available(macOS 26, *), SpeechTranscriber.isAvailable else { return }
        Task {
            do {
                _ = try await AppleLiveTranscription.makeTranscriber()
            } catch {
                print("Popy [Speech] could not prepare Apple's model: \(error.localizedDescription)")
            }
        }
    }
}

@available(macOS 26, *)
private final class AppleLiveTranscription: LiveTranscription {

    enum EngineError: LocalizedError {
        case unsupportedLocale
        case noAudioFormat

        var errorDescription: String? {
            switch self {
            case .unsupportedLocale:
                return "Apple's speech model does not support English on this Mac."
            case .noAudioFormat:
                return "Apple's speech model could not accept audio from this microphone."
            }
        }
    }

    private let audio: AsyncStream<AVAudioPCMBuffer>.Continuation
    private let transcript: Task<String, Error>

    init() {
        let (stream, continuation) = AsyncStream<AVAudioPCMBuffer>.makeStream()
        audio = continuation
        // Starts right away; buffers queue in the stream while the model loads.
        transcript = Task { try await Self.transcribe(stream) }
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        audio.yield(buffer)
    }

    func finish() async throws -> String {
        audio.finish()
        return try await transcript.value
    }

    func cancel() {
        audio.finish()
        transcript.cancel()
    }

    /// A transcriber for Popy's dictation locale, with its model installed.
    static func makeTranscriber() async throws -> SpeechTranscriber {
        guard let locale = await dictationLocale() else { throw EngineError.unsupportedLocale }

        // Final results only: Popy shows nothing until the user stops, and the
        // stop-to-text latency measured the same with volatile results on.
        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: []
        )
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
        return transcriber
    }

    /// Popy dictates English. Prefer the user's own variant (en-IN, en-GB…)
    /// for accent and spelling, falling back to US English.
    private static func dictationLocale() async -> Locale? {
        let current = Locale.current
        if current.language.languageCode == .english,
           let match = await SpeechTranscriber.supportedLocale(equivalentTo: current) {
            return match
        }
        return await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en-US"))
    }

    private static func transcribe(_ audio: AsyncStream<AVAudioPCMBuffer>) async throws -> String {
        let transcriber = try await makeTranscriber()
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw EngineError.noAudioFormat
        }

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let (input, feed) = AsyncStream<AnalyzerInput>.makeStream()

        // Results arrive as finalized segments, in order.
        let results = Task { () throws -> String in
            var text = ""
            for try await result in transcriber.results {
                text = join(text, String(result.text.characters))
            }
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        do {
            try await analyzer.start(inputSequence: input)
        } catch {
            results.cancel()
            throw error
        }

        // The recorder already produces 16 kHz mono Int16, which is what the
        // analyzer asks for, so this converts nothing in practice.
        var converter: AVAudioConverter?
        for await buffer in audio {
            var samples = buffer
            if buffer.format != format {
                if converter == nil {
                    converter = AVAudioConverter(from: buffer.format, to: format)
                }
                guard let converted = converter?.convertedBuffer(buffer) else { continue }
                samples = converted
            }
            feed.yield(AnalyzerInput(buffer: samples))
        }
        feed.finish()

        // `for await` also ends early when the recording is cancelled.
        if Task.isCancelled {
            await analyzer.cancelAndFinishNow()
            results.cancel()
            throw CancellationError()
        }

        try await analyzer.finalizeAndFinishThroughEndOfInput()
        return try await results.value
    }

    private static func join(_ text: String, _ segment: String) -> String {
        if text.isEmpty || text.last?.isWhitespace == true || segment.first?.isWhitespace == true {
            return text + segment
        }
        return text + " " + segment
    }
}
