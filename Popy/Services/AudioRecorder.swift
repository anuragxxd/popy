import AVFoundation
import CoreAudio
import Foundation

/// Captures microphone audio and writes it to a temporary WAV file in the
/// exact format whisper.cpp expects: 16 kHz, mono, 16-bit signed PCM.
///
/// The hardware input node runs at its own rate (typically 44.1/48 kHz,
/// often stereo), so every buffer is pushed through an `AVAudioConverter`
/// before being written.
final class AudioRecorder {

    enum RecorderError: LocalizedError {
        case microphoneDenied
        case noInputDevice
        case converterUnavailable
        case engineFailed(String)
        case tooShort

        var errorDescription: String? {
            switch self {
            case .microphoneDenied:
                return "Popy needs Microphone access. Grant it in System Settings → Privacy & Security → Microphone."
            case .noInputDevice:
                return "No microphone input device was found."
            case .converterUnavailable:
                return "Could not configure audio conversion to 16 kHz mono."
            case .engineFailed(let detail):
                return "Audio engine failed to start: \(detail)"
            case .tooShort:
                return "Recording was too short."
            }
        }
    }

    static let shared = AudioRecorder()

    /// Whisper operates on 16 kHz mono audio.
    private static let targetSampleRate: Double = 16_000

    /// Hard ceiling so a forgotten recording cannot fill the disk.
    private let maxDuration: TimeInterval = 120

    /// Anything shorter than this is almost certainly an accidental trigger.
    private let minDuration: TimeInterval = 0.4

    /// Built fresh for each recording rather than held for the app's lifetime.
    ///
    /// A long-lived AVAudioEngine accumulates state tied to whichever input
    /// device existed when it was created. If the device changes, disappears,
    /// or is still held by a previous process, reconfiguring it raises an
    /// Objective-C exception that Swift cannot catch, and the app dies.
    private var engine: AVAudioEngine?
    private var audioFile: AVAudioFile?
    private var converter: AVAudioConverter?
    private var outputFormat: AVAudioFormat?
    private var startedAt: Date?
    private var autoStopTimer: Timer?

    private(set) var isRecording = false

    // MARK: - Speech detection

    /// Loudest normalised level seen during the current recording.
    private var peakLevel: Float = 0
    /// Number of buffers whose level cleared `voicedThreshold`.
    private var voicedBufferCount = 0

    /// A buffer above this counts as voiced. Ambient room tone measures around
    /// 0.02 on this scale; speech sits far higher.
    private static let voicedThreshold: Float = 0.15
    /// Require roughly 190ms of voiced audio (the tap fires ~15x/sec), so a
    /// cough or a door closing does not count as speech.
    private static let minVoicedBuffers = 3

    /// Whether the recording actually contained speech.
    ///
    /// Whisper hallucinates filler text on silence — "you" and "Thank you."
    /// are the classic outputs. Detecting silence from the *audio* is far more
    /// reliable than trying to pattern-match those strings afterwards, and it
    /// carries no risk of deleting something the user really said.
    var containedSpeech: Bool {
        peakLevel >= Self.voicedThreshold && voicedBufferCount >= Self.minVoicedBuffers
    }

    /// Called on the main queue if the recording self-terminates by hitting
    /// `maxDuration`, so the controller can transition out of its recording state.
    var onAutoStop: ((URL) -> Void)?

    /// Normalised input level (0...1), emitted per buffer while recording.
    /// Drives the on-screen meter so the user can see they are being heard.
    var onLevel: ((Float) -> Void)?

    private init() {}

    // MARK: - Permission

    static var microphoneAuthorization: AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .audio)
    }

    /// Requests microphone access. The completion is delivered on the main queue.
    static func requestMicrophoneAccess(_ completion: @escaping (Bool) -> Void) {
        switch microphoneAuthorization {
        case .authorized:
            completion(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async { completion(granted) }
            }
        case .denied, .restricted:
            completion(false)
        @unknown default:
            completion(false)
        }
    }

    // MARK: - Recording

    /// Begin capturing to a fresh temp file. Throws if the engine or
    /// microphone is unavailable.
    func start() throws {
        guard !isRecording else { return }
        guard Self.microphoneAuthorization == .authorized else {
            throw RecorderError.microphoneDenied
        }

        // CRITICAL: check the hardware through CoreAudio *before* touching
        // AVAudioEngine.
        //
        // Accessing `engine.inputNode` calls AVAudioEngineImpl::UpdateInputNode
        // internally, which raises an Objective-C exception if the input device
        // is missing or reports an unusable format. Swift cannot catch NSException,
        // so that is an immediate, uncatchable crash — a guard placed after the
        // property access, as this code previously had, never gets to run.
        guard Self.hasUsableInputDevice() else {
            throw RecorderError.noInputDevice
        }

        let engine = AVAudioEngine()
        self.engine = engine

        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        // Belt and braces: a sample rate of 0 means a null input device slipped
        // past the CoreAudio check.
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            self.engine = nil
            throw RecorderError.noInputDevice
        }

        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: Self.targetSampleRate,
            channels: 1,
            interleaved: true
        ) else {
            self.engine = nil
            throw RecorderError.converterUnavailable
        }

        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            self.engine = nil
            throw RecorderError.converterUnavailable
        }

        let url = Self.makeTempURL()

        // Write a real .wav container with 16-bit PCM so whisper-cli can read it
        // without any transcoding step.
        let fileSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: Self.targetSampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]

        let file = try AVAudioFile(
            forWriting: url,
            settings: fileSettings,
            commonFormat: .pcmFormatInt16,
            interleaved: true
        )

        self.audioFile = file
        self.converter = converter
        self.outputFormat = targetFormat
        self.currentURL = url

        // 1024 frames rather than 4096: the tap callback rate is what drives
        // the on-screen level meter, and on a 16 kHz input a 4096-frame buffer
        // only fires ~4x/sec, which reads as a laggy meter. 1024 gives ~15x/sec
        // at negligible extra cost.
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            self?.append(buffer)
            self?.reportLevel(buffer)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            cleanupState()
            throw RecorderError.engineFailed(error.localizedDescription)
        }

        isRecording = true
        startedAt = Date()
        peakLevel = 0
        voicedBufferCount = 0

        autoStopTimer = Timer.scheduledTimer(withTimeInterval: maxDuration, repeats: false) { [weak self] _ in
            guard let self = self, self.isRecording else { return }
            if let url = try? self.stop() {
                self.onAutoStop?(url)
            }
        }
    }

    /// Stop capturing and return the finished WAV file.
    @discardableResult
    func stop() throws -> URL {
        guard isRecording, let url = currentURL else {
            throw RecorderError.tooShort
        }

        autoStopTimer?.invalidate()
        autoStopTimer = nil

        teardownEngine()

        let duration = startedAt.map { Date().timeIntervalSince($0) } ?? 0

        cleanupState()

        guard duration >= minDuration else {
            try? FileManager.default.removeItem(at: url)
            throw RecorderError.tooShort
        }

        return url
    }

    /// Abandon the in-flight recording and delete its file.
    func cancel() {
        guard isRecording else { return }
        autoStopTimer?.invalidate()
        autoStopTimer = nil
        teardownEngine()
        if let url = currentURL {
            try? FileManager.default.removeItem(at: url)
        }
        cleanupState()
    }

    // MARK: - Internals

    private var currentURL: URL?

    /// Remove the tap, stop the engine, and drop it entirely so the next
    /// recording starts from a clean AVAudioEngine bound to whatever the
    /// current input device happens to be.
    private func teardownEngine() {
        guard let engine = engine else { return }
        if engine.isRunning {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        self.engine = nil
    }

    private func cleanupState() {
        isRecording = false
        startedAt = nil
        audioFile = nil
        converter = nil
        outputFormat = nil
        currentURL = nil
    }

    // MARK: - Hardware preflight

    /// Ask CoreAudio directly whether a usable default input device exists.
    ///
    /// This deliberately avoids AVAudioEngine, because the whole point is to
    /// answer the question *before* AVAudioEngine can raise an uncatchable
    /// Objective-C exception about it.
    private static func hasUsableInputDevice() -> Bool {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var deviceAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &deviceAddress, 0, nil, &size, &deviceID
        )
        guard status == noErr, deviceID != AudioDeviceID(kAudioObjectUnknown) else {
            return false
        }

        // A default device can exist while still exposing no input channels
        // (this is what an aggregate or disconnected device looks like), which
        // is exactly the case that makes AVAudioEngine throw.
        var streamAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )

        var listSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &streamAddress, 0, nil, &listSize) == noErr,
              listSize > 0 else {
            return false
        }

        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(listSize),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { raw.deallocate() }

        guard AudioObjectGetPropertyData(deviceID, &streamAddress, 0, nil, &listSize, raw) == noErr else {
            return false
        }

        let buffers = UnsafeMutableAudioBufferListPointer(
            raw.assumingMemoryBound(to: AudioBufferList.self)
        )
        return buffers.reduce(0) { $0 + Int($1.mNumberChannels) } > 0
    }

    /// Convert one hardware buffer to 16 kHz mono Int16 and append it to the file.
    private func append(_ buffer: AVAudioPCMBuffer) {
        guard let converter = converter,
              let outputFormat = outputFormat,
              let file = audioFile else { return }

        // Output capacity must account for the sample-rate ratio, plus a little
        // slack for the converter's internal resampling latency.
        let ratio = outputFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 1024

        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            return
        }

        var consumed = false
        var conversionError: NSError?

        let status = converter.convert(to: outputBuffer, error: &conversionError) { _, statusPtr in
            // Hand the converter each input buffer exactly once; returning nil
            // afterwards tells it this batch is complete.
            if consumed {
                statusPtr.pointee = .noDataNow
                return nil
            }
            consumed = true
            statusPtr.pointee = .haveData
            return buffer
        }

        guard status != .error, outputBuffer.frameLength > 0 else { return }

        do {
            try file.write(from: outputBuffer)
        } catch {
            print("Popy [Audio] failed writing buffer: \(error.localizedDescription)")
        }
    }

    /// Compute RMS of the raw input buffer and map it onto a perceptual 0...1
    /// scale for the meter. Speech sits far below full scale, so a linear
    /// mapping would barely move; a dB scale floored at -50 reads naturally.
    private func reportLevel(_ buffer: AVAudioPCMBuffer) {
        guard let channel = buffer.floatChannelData?[0] else { return }

        let count = Int(buffer.frameLength)
        guard count > 0 else { return }

        var sum: Float = 0
        for i in 0..<count {
            let sample = channel[i]
            sum += sample * sample
        }
        let rms = (sum / Float(count)).squareRoot()

        let db = 20 * log10(max(rms, 1e-7))
        let floorDB: Float = -50
        let normalised = max(0, min(1, (db - floorDB) / -floorDB))

        // Track speech presence regardless of whether anyone is watching the
        // meter — this drives the silence rejection.
        if normalised > peakLevel { peakLevel = normalised }
        if normalised >= Self.voicedThreshold { voicedBufferCount += 1 }

        guard let handler = onLevel else { return }
        DispatchQueue.main.async { handler(normalised) }
    }

    private static func makeTempURL() -> URL {
        let name = "popy-dictation-\(UUID().uuidString).wav"
        return FileManager.default.temporaryDirectory.appendingPathComponent(name)
    }
}
