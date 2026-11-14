import AVFoundation
import CoreAudio
import Foundation

/// Captures microphone audio and writes it to a temporary WAV file in the
/// format both speech engines take: 16 kHz, mono, 16-bit signed PCM.
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

    /// Both Whisper and Apple's SpeechAnalyzer operate on 16 kHz mono audio.
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
    private var autoStopTimer: Timer?
    private var configurationObserver: NSObjectProtocol?
    private var startupTimer: Timer?
    private var receivedAudio = false
    private var tapID: UUID?

    /// A failed Bluetooth transition must not leave the HUD stuck listening.
    var onFailure: ((Error) -> Void)?

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

    /// Each buffer as it is written: 16 kHz mono Int16. Called on the audio
    /// tap's thread. Lets Apple's transcriber work while the user speaks.
    var onAudio: ((AVAudioPCMBuffer) -> Void)?

    /// Delivered on the main queue only after the first microphone buffer.
    var onReady: (() -> Void)?
    var onPreparing: (() -> Void)?

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
        self.currentURL = url

        // Reset before starting the engine: taps may arrive during start().
        peakLevel = 0
        voicedBufferCount = 0

        // 1024 frames rather than 4096: the tap callback rate is what drives
        // the on-screen level meter, and on a 16 kHz input a 4096-frame buffer
        // only fires ~4x/sec, which reads as a laggy meter. 1024 gives ~15x/sec
        // at negligible extra cost.
        // Let the input node supply its native format. Bluetooth can change
        // sample rate when it enters microphone mode; append() adapts to the
        // format of the actual buffers instead of assuming the startup format.
        receivedAudio = false
        installInputTap(on: engine, recording: url)

        // The headset's profile transition can stop AVAudioEngine after start
        // returns. Restart the existing graph without dropping the WAV or the
        // speech session. Notifications for a discarded engine are ignored.
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self, weak engine] _ in
            guard let self = self, let engine = engine,
                  self.engine === engine, self.isRecording, !engine.isRunning else { return }
            do {
                guard Self.hasUsableInputDevice() else { throw RecorderError.noInputDevice }
                engine.inputNode.removeTap(onBus: 0)
                self.installInputTap(on: engine, recording: url)
                self.armStartupTimeout()
                self.onPreparing?()
                try engine.start()
            } catch {
                self.cancel()
                self.onFailure?(RecorderError.engineFailed(error.localizedDescription))
            }
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            teardownEngine()
            try? FileManager.default.removeItem(at: url)
            cleanupState()
            throw RecorderError.engineFailed(error.localizedDescription)
        }

        isRecording = true
        armStartupTimeout()

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

        // Hardware startup time is not recorded speech.
        let duration = audioFile.map { Double($0.length) / Self.targetSampleRate } ?? 0

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

    private func armStartupTimeout() {
        startupTimer?.invalidate()
        receivedAudio = false
        startupTimer = Timer.scheduledTimer(withTimeInterval: 8, repeats: false) { [weak self] _ in
            guard let self = self, self.isRecording, !self.receivedAudio else { return }
            self.cancel()
            self.onFailure?(RecorderError.engineFailed("The microphone did not deliver audio. Try reconnecting your headphones."))
        }
    }

    private func installInputTap(on engine: AVAudioEngine, recording url: URL) {
        let id = UUID()
        tapID = id
        engine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self] buffer, _ in
            guard let self = self, self.append(buffer) else { return }
            self.reportLevel(buffer)
            DispatchQueue.main.async { [weak self] in
                guard let self = self, self.isRecording, self.currentURL == url,
                      self.tapID == id, !self.receivedAudio else { return }
                self.receivedAudio = true
                self.startupTimer?.invalidate()
                self.startupTimer = nil
                self.onReady?()
            }
        }

    }


    /// Remove the tap, stop the engine, and drop it entirely so the next
    /// recording starts from a clean AVAudioEngine bound to whatever the
    /// current input device happens to be.
    private func teardownEngine() {
        tapID = nil
        startupTimer?.invalidate()
        startupTimer = nil
        if let observer = configurationObserver {
            NotificationCenter.default.removeObserver(observer)
            configurationObserver = nil
        }
        guard let engine = engine else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        self.engine = nil
    }

    private func cleanupState() {
        isRecording = false
        audioFile = nil
        converter = nil
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
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &address, 0, nil, &size, &deviceID) == noErr,
              deviceID != AudioDeviceID(kAudioObjectUnknown) else { return false }
        return hasInputChannels(deviceID)
    }

    private static func hasInputChannels(_ deviceID: AudioDeviceID) -> Bool {
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
    @discardableResult
    private func append(_ buffer: AVAudioPCMBuffer) -> Bool {
        guard buffer.frameLength > 0, let file = audioFile else { return false }
        // Only the tap thread accesses the converter while capture is running.
        if converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: file.processingFormat)
        }
        guard let outputBuffer = converter?.convertedBuffer(buffer) else { return false }
        do {
            try file.write(from: outputBuffer)
        } catch {
            print("Popy [Audio] failed writing buffer: \(error.localizedDescription)")
            return false
        }
        onAudio?(outputBuffer)
        return true
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

extension AVAudioConverter {
    /// Convert one buffer to `outputFormat`, or nil if it produced nothing.
    func convertedBuffer(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        // Output capacity must account for the sample-rate ratio, plus a little
        // slack for the converter's internal resampling latency.
        let ratio = outputFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 1024

        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            return nil
        }

        var consumed = false
        var conversionError: NSError?

        let status = convert(to: outputBuffer, error: &conversionError) { _, statusPtr in
            // Hand the converter each input buffer exactly once; returning nil
            // afterwards tells it this batch is complete. `.noDataNow` (not
            // `.endOfStream`) keeps its resampler state for the next buffer.
            if consumed {
                statusPtr.pointee = .noDataNow
                return nil
            }
            consumed = true
            statusPtr.pointee = .haveData
            return buffer
        }

        guard status != .error, outputBuffer.frameLength > 0 else { return nil }
        return outputBuffer
    }
}
