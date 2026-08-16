import AVFoundation
import CommonCrypto
import Foundation

/// Runs local speech-to-text by shelling out to `whisper-cli` (whisper.cpp, MIT).
///
/// Everything happens on-device: the audio never leaves the machine and there
/// is no API key, no network call at transcription time, and no per-use cost.
/// The only network access is a one-time model download on first use.
final class TranscriptionService {

    enum TranscriptionError: LocalizedError {
        case binaryMissing
        case modelMissing
        case modelDownloadFailed(String)
        case checksumMismatch
        case launchFailed(String)
        case failed(exitCode: Int32, stderr: String)
        case emptyResult

        var errorDescription: String? {
            switch self {
            case .binaryMissing:
                return "The whisper-cli engine is missing from Popy.app. Reinstall Popy, or place a whisper-cli binary in ~/Library/Application Support/Popy/bin/."
            case .modelMissing:
                return "The speech model has not been downloaded yet."
            case .modelDownloadFailed(let detail):
                return "Could not download the speech model: \(detail)"
            case .checksumMismatch:
                return "The downloaded speech model failed its integrity check. Please try again."
            case .launchFailed(let detail):
                return "Could not start the transcription engine: \(detail)"
            case .failed(let code, let stderr):
                let detail = stderr.isEmpty ? "" : "\n\n\(stderr.suffix(400))"
                return "Transcription failed (exit \(code)).\(detail)"
            case .emptyResult:
                return "No speech was detected."
            }
        }
    }

    static let shared = TranscriptionService()

    // MARK: - Model definition

    /// ggml base.en — 142 MiB on disk, ~388 MB resident. Good accuracy for
    /// dictation at ~0.6s for a 10s clip on Apple silicon.
    private static let modelFilename = "ggml-base.en.bin"
    private static let modelURL = URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.en.bin")!
    /// SHA-1 published by the whisper.cpp project, verified against the
    /// artefact actually served by Hugging Face.
    private static let modelSHA1 = "137c40403d78fd54d454da0f9bd998f78703390c"

    private let workQueue = DispatchQueue(label: "com.popy.transcription", qos: .userInitiated)

    private init() {}

    // MARK: - Paths

    static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Popy", isDirectory: true)
    }

    static var modelPath: URL {
        supportDirectory.appendingPathComponent("models/\(modelFilename)")
    }

    /// Resolve the whisper-cli binary. Bundled copy wins; the Application
    /// Support and Homebrew locations exist so a source build can be tested
    /// without repackaging the .app.
    static func resolveBinary() -> URL? {
        var candidates: [URL] = []

        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("whisper-cli") {
            candidates.append(bundled)
        }
        candidates.append(supportDirectory.appendingPathComponent("bin/whisper-cli"))
        candidates.append(URL(fileURLWithPath: "/opt/homebrew/bin/whisper-cli"))
        candidates.append(URL(fileURLWithPath: "/usr/local/bin/whisper-cli"))

        let fm = FileManager.default
        return candidates.first { fm.isExecutableFile(atPath: $0.path) }
    }

    static var isModelInstalled: Bool {
        FileManager.default.fileExists(atPath: modelPath.path)
    }

    static var isReady: Bool {
        resolveBinary() != nil && isModelInstalled
    }

    // MARK: - Model download

    /// Download the model if it is not already present.
    /// `progress` receives 0.0...1.0 on the main queue.
    func ensureModel(
        progress: @escaping (Double) -> Void,
        completion: @escaping (Result<URL, Error>) -> Void
    ) {
        let destination = Self.modelPath

        if FileManager.default.fileExists(atPath: destination.path) {
            completion(.success(destination))
            return
        }

        workQueue.async {
            let finish: (Result<URL, Error>) -> Void = { result in
                DispatchQueue.main.async { completion(result) }
            }

            do {
                try FileManager.default.createDirectory(
                    at: destination.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
            } catch {
                finish(.failure(TranscriptionError.modelDownloadFailed(error.localizedDescription)))
                return
            }

            let delegate = DownloadProgressDelegate { fraction in
                DispatchQueue.main.async { progress(fraction) }
            }
            let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
            let semaphore = DispatchSemaphore(value: 0)
            var downloadResult: Result<URL, Error> = .failure(TranscriptionError.modelDownloadFailed("unknown"))

            let task = session.downloadTask(with: Self.modelURL) { tempURL, response, error in
                defer { semaphore.signal() }

                if let error = error {
                    downloadResult = .failure(TranscriptionError.modelDownloadFailed(error.localizedDescription))
                    return
                }
                guard let tempURL = tempURL else {
                    downloadResult = .failure(TranscriptionError.modelDownloadFailed("No data received."))
                    return
                }
                if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                    downloadResult = .failure(TranscriptionError.modelDownloadFailed("HTTP \(http.statusCode)"))
                    return
                }

                // Verify integrity before installing — a truncated or tampered
                // model would otherwise fail confusingly at inference time.
                guard let digest = Self.sha1Hex(ofFileAt: tempURL) else {
                    downloadResult = .failure(TranscriptionError.modelDownloadFailed("Could not hash the download."))
                    return
                }
                guard digest == Self.modelSHA1 else {
                    downloadResult = .failure(TranscriptionError.checksumMismatch)
                    return
                }

                do {
                    try? FileManager.default.removeItem(at: destination)
                    try FileManager.default.moveItem(at: tempURL, to: destination)
                    downloadResult = .success(destination)
                } catch {
                    downloadResult = .failure(TranscriptionError.modelDownloadFailed(error.localizedDescription))
                }
            }

            task.resume()
            semaphore.wait()
            session.invalidateAndCancel()
            finish(downloadResult)
        }
    }

    // MARK: - Transcription

    /// Transcribe a 16 kHz mono WAV file. The audio file is deleted afterwards.
    /// `completion` is delivered on the main queue.
    func transcribe(fileAt url: URL, completion: @escaping (Result<String, Error>) -> Void) {
        workQueue.async {
            defer { try? FileManager.default.removeItem(at: url) }

            let finish: (Result<String, Error>) -> Void = { result in
                DispatchQueue.main.async { completion(result) }
            }

            guard let binary = Self.resolveBinary() else {
                finish(.failure(TranscriptionError.binaryMissing))
                return
            }
            guard Self.isModelInstalled else {
                finish(.failure(TranscriptionError.modelMissing))
                return
            }

            do {
                let text = try Self.runWhisper(binary: binary, audio: url)
                let cleaned = Self.stripNonSpeechAnnotations(text)
                if cleaned.isEmpty {
                    finish(.failure(TranscriptionError.emptyResult))
                } else {
                    finish(.success(cleaned))
                }
            } catch {
                finish(.failure(error))
            }
        }
    }

    /// Run one inference pass and return raw stdout.
    ///
    /// `-nt` drops timestamps and `-np` silences the banner, so stdout is
    /// nothing but the transcript. Diagnostics go to stderr and are only
    /// surfaced when the process fails.
    private static func runWhisper(binary: URL, audio: URL) throws -> String {
        let process = Process()
        process.executableURL = binary
        process.arguments = [
            "-m", modelPath.path,
            "-f", audio.path,
            "-l", "en",
            "-nt",              // no timestamps
            "-np",              // no prints
            "-sns",             // suppress non-speech tokens ([BLANK_AUDIO] etc.)
            "-t", "\(threadCount)"
        ]

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            throw TranscriptionError.launchFailed(error.localizedDescription)
        }

        // Drain both pipes before waiting, otherwise a full 64KB pipe buffer
        // would deadlock the child process.
        let outData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let stderr = String(data: errData, encoding: .utf8) ?? ""
            throw TranscriptionError.failed(exitCode: process.terminationStatus, stderr: stderr)
        }

        return String(data: outData, encoding: .utf8) ?? ""
    }

    /// Leave the efficiency cores free so the UI stays responsive.
    private static var threadCount: Int {
        min(8, max(1, ProcessInfo.processInfo.activeProcessorCount - 2))
    }

    // MARK: - Output cleanup

    /// Remove Whisper's non-speech annotations, e.g. `[BLANK_AUDIO]`, `[MUSIC]`,
    /// `[INAUDIBLE]`.
    ///
    /// These come from the model's own token vocabulary, not from whisper-cli,
    /// so `-sns` reduces them but cannot guarantee their absence. They are
    /// artefacts describing the audio rather than anything the user said, so
    /// leaving them in would put literal "[BLANK_AUDIO]" on the clipboard.
    ///
    /// This is deliberately narrow. Only bracketed ALL-CAPS tokens are removed;
    /// real speech is never rewritten, re-punctuated, or re-cased. Dictating
    /// bracketed uppercase text is not practically possible via speech anyway,
    /// so there is nothing legitimate to collide with.
    private static func stripNonSpeechAnnotations(_ text: String) -> String {
        var result = text

        if let regex = try? NSRegularExpression(pattern: "\\[[A-Z][A-Z0-9 _'-]*\\]") {
            result = regex.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: ""
            )
        }

        // Collapse the whitespace the removal leaves behind, without touching
        // intentional line breaks.
        if let spaces = try? NSRegularExpression(pattern: "[ \\t]{2,}") {
            result = spaces.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: " "
            )
        }

        return result
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Warm-up

    private var hasWarmedUp = false

    /// The very first whisper run on a machine spends ~14s compiling Metal
    /// shaders; every run after that is well under a second because macOS
    /// caches the compiled pipeline. Burn that cost at launch against a short
    /// silent clip so the user's first real dictation is fast.
    func warmUpIfNeeded() {
        guard !hasWarmedUp, Self.isReady else { return }
        hasWarmedUp = true

        workQueue.async {
            guard let binary = Self.resolveBinary(),
                  let silence = Self.makeSilentWAV() else { return }
            defer { try? FileManager.default.removeItem(at: silence) }
            _ = try? Self.runWhisper(binary: binary, audio: silence)
        }
    }

    /// Produce a short silent 16 kHz mono WAV used purely to prime the engine.
    private static func makeSilentWAV() -> URL? {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("popy-warmup-\(UUID().uuidString).wav")

        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16_000,
            channels: 1,
            interleaved: true
        ) else { return nil }

        let frames = AVAudioFrameCount(16_000)   // 1 second
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        buffer.frameLength = frames
        // AVAudioPCMBuffer memory is already zeroed, which is digital silence.

        do {
            let file = try AVAudioFile(
                forWriting: url,
                settings: [
                    AVFormatIDKey: kAudioFormatLinearPCM,
                    AVSampleRateKey: 16_000,
                    AVNumberOfChannelsKey: 1,
                    AVLinearPCMBitDepthKey: 16,
                    AVLinearPCMIsFloatKey: false,
                    AVLinearPCMIsBigEndianKey: false,
                    AVLinearPCMIsNonInterleaved: false
                ],
                commonFormat: .pcmFormatInt16,
                interleaved: true
            )
            try file.write(from: buffer)
            return url
        } catch {
            return nil
        }
    }

    // MARK: - Hashing

    /// Stream the file through CC_SHA1 so a 142 MiB model is never fully
    /// resident just to be hashed.
    private static func sha1Hex(ofFileAt url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        var context = CC_SHA1_CTX()
        CC_SHA1_Init(&context)

        while autoreleasepool(invoking: {
            let chunk = handle.readData(ofLength: 1_048_576)
            guard !chunk.isEmpty else { return false }
            chunk.withUnsafeBytes { raw in
                _ = CC_SHA1_Update(&context, raw.baseAddress, CC_LONG(raw.count))
            }
            return true
        }) {}

        var digest = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
        CC_SHA1_Final(&digest, &context)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Download progress

private final class DownloadProgressDelegate: NSObject, URLSessionDownloadDelegate {

    private let onProgress: (Double) -> Void

    init(onProgress: @escaping (Double) -> Void) {
        self.onProgress = onProgress
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        onProgress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    // Required by the protocol; the completion-handler form of downloadTask
    // supplies the finished file, so nothing to do here.
    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {}
}
