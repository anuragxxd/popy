import AppKit

/// Owns the dictation state machine and wires together the Fn listener,
/// the recorder, and the local transcription engine.
///
///     idle ──Fn Fn──▶ recording ──Fn Fn──▶ transcribing ──▶ idle
///
/// The finished transcript is placed on the pasteboard verbatim. Nothing
/// rewrites, summarises, or "cleans up" the text.
final class VoiceInputController {

    enum State: Equatable {
        case idle
        case recording
        case transcribing
    }

    static let shared = VoiceInputController()

    private let recorder = AudioRecorder.shared
    private let transcriber = TranscriptionService.shared
    private let preferences = PreferencesManager.shared

    private(set) var state: State = .idle {
        didSet {
            guard oldValue != state else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.onStateChange?(self.state)
            }
        }
    }

    /// Fired on the main queue whenever the state machine advances, so the
    /// menu bar can reflect what is happening.
    var onStateChange: ((State) -> Void)?

    /// Fired on the main queue when the user needs to be told something —
    /// a missing permission, a missing engine, or first-run model setup.
    /// The handler is expected to be blocking (an alert), so callers must not
    /// rely on it returning promptly.
    var onNotify: ((String) -> Void)?

    private var isDownloadingModel = false

    /// True between requesting microphone access and the recorder actually
    /// starting. Guards the async gap on first run.
    private var isPreparing = false

    private init() {}

    // MARK: - Lifecycle

    func start() {
        FnKeyListener.shared.onDoubleTap = { [weak self] in
            self?.handleDoubleTap()
        }

        recorder.onAutoStop = { [weak self] url in
            guard let self = self else { return }
            SystemAudioMuter.shared.restore()
            guard self.recorder.containedSpeech else {
                try? FileManager.default.removeItem(at: url)
                self.state = .idle
                DictationHUD.shared.show(.failed("No speech detected."))
                return
            }
            self.beginTranscription(of: url)
        }

        recorder.onLevel = { level in
            DictationHUD.shared.updateLevel(level)
        }

        if preferences.voiceInputEnabled {
            FnKeyListener.shared.start()
            // Prime the Metal shader cache so the first dictation is not slow.
            transcriber.warmUpIfNeeded()
        }
    }

    func stop() {
        FnKeyListener.shared.stop()
        recorder.cancel()
        // Never leave the machine muted on the way out.
        SystemAudioMuter.shared.restore()
        state = .idle
    }

    func setEnabled(_ enabled: Bool) {
        preferences.voiceInputEnabled = enabled
        if enabled {
            FnKeyListener.shared.start()
            transcriber.warmUpIfNeeded()
        } else {
            recorder.cancel()
            SystemAudioMuter.shared.restore()
            FnKeyListener.shared.stop()
            state = .idle
        }
    }

    // MARK: - Trigger

    /// Start or stop dictation explicitly. Used by the menu so dictation is
    /// reachable without the Fn key at all — which matters on keyboards with
    /// no Fn key, and when Accessibility permission is missing (the Fn
    /// listener fails silently in that case, but this path still works).
    func toggleDictation() {
        handleDoubleTap()
    }

    private func handleDoubleTap() {
        switch state {
        case .idle:
            beginRecording()
        case .recording:
            endRecording()
        case .transcribing:
            // Ignore triggers while inference is running — it is sub-second,
            // and queuing a second recording here would race the pasteboard.
            break
        }
    }

    // MARK: - Recording

    private func beginRecording() {
        // Microphone access is asynchronous on first run, and the state stays
        // `.idle` while the system dialog is up. Without this guard a second
        // double-tap during that window would start a second recording.
        guard !isPreparing else { return }

        // Guard the whole pipeline up front so the user is never left holding
        // a recording that cannot possibly be transcribed.
        guard TranscriptionService.resolveBinary() != nil else {
            onNotify?(TranscriptionService.TranscriptionError.binaryMissing.localizedDescription)
            return
        }

        guard TranscriptionService.isModelInstalled else {
            downloadModelThenNotify()
            return
        }

        isPreparing = true
        AudioRecorder.requestMicrophoneAccess { [weak self] granted in
            guard let self = self else { return }
            defer { self.isPreparing = false }

            guard granted else {
                self.onNotify?(AudioRecorder.RecorderError.microphoneDenied.localizedDescription)
                return
            }
            do {
                try self.recorder.start()
                self.state = .recording
                DictationHUD.shared.show(.listening)

                // Silence output only once recording is actually under way, so
                // a failed start never leaves the machine muted.
                if self.preferences.muteWhileDictating {
                    SystemAudioMuter.shared.mute()
                }
            } catch {
                self.state = .idle
                DictationHUD.shared.show(.failed(error.localizedDescription))
                self.onNotify?(error.localizedDescription)
            }
        }
    }

    private func endRecording() {
        // Unmute the moment capture stops — the user should not sit through
        // transcription in silence.
        SystemAudioMuter.shared.restore()

        do {
            let url = try recorder.stop()

            // Reject silence using the audio itself rather than the transcript.
            // Whisper reliably hallucinates "you" (and similar filler) on empty
            // input, and pattern-matching those strings afterwards would risk
            // deleting words the user actually said.
            guard recorder.containedSpeech else {
                try? FileManager.default.removeItem(at: url)
                state = .idle
                DictationHUD.shared.show(.failed("No speech detected."))
                return
            }

            beginTranscription(of: url)
        } catch AudioRecorder.RecorderError.tooShort {
            // Almost certainly a stray double-tap. Say so briefly rather than
            // vanishing without explanation.
            state = .idle
            DictationHUD.shared.show(.failed("Too short — hold on and speak first."))
        } catch {
            state = .idle
            DictationHUD.shared.show(.failed(error.localizedDescription))
            onNotify?(error.localizedDescription)
        }
    }

    // MARK: - Transcription

    private func beginTranscription(of url: URL) {
        state = .transcribing
        DictationHUD.shared.show(.transcribing)

        transcriber.transcribe(fileAt: url) { [weak self] result in
            guard let self = self else { return }
            self.state = .idle

            switch result {
            case .success(let text):
                self.deliver(text)
                DictationHUD.shared.show(.copied(text))
            case .failure(TranscriptionService.TranscriptionError.emptyResult):
                // Silence or unintelligible audio. Show it in the HUD, which
                // self-dismisses, rather than interrupting with a modal alert.
                DictationHUD.shared.show(.failed("No speech detected."))
            case .failure(let error):
                DictationHUD.shared.show(.failed(error.localizedDescription))
                self.onNotify?(error.localizedDescription)
            }
        }
    }

    /// Put the transcript on the clipboard exactly as the engine produced it.
    private func deliver(_ text: String) {
        ClipboardManager.shared.copyTranscript(text)

        if preferences.soundEnabled {
            NSSound(named: .init("Tink"))?.play()
        }

        if preferences.voicePasteDirectly {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                KeyboardSimulator.simulatePaste()
            }
        }
    }

    // MARK: - Model bootstrap

    /// First run: fetch the 142 MiB model, then tell the user it is ready.
    /// We deliberately do not auto-start recording afterwards — by then the
    /// user has stopped talking.
    private func downloadModelThenNotify() {
        guard !isDownloadingModel else { return }
        isDownloadingModel = true

        // Kick the download off BEFORE notifying. `onNotify` puts up a modal
        // alert, which blocks the main thread until dismissed — if we notified
        // first, the download would not even begin until the user clicked OK.
        transcriber.ensureModel(progress: { _ in
            // Progress is intentionally not surfaced; the menu bar title
            // would thrash and this only ever happens once.
        }, completion: { [weak self] result in
            guard let self = self else { return }
            self.isDownloadingModel = false

            switch result {
            case .success:
                self.transcriber.warmUpIfNeeded()
                self.onNotify?("Voice input is ready. Press Fn twice to start dictating.")
            case .failure(let error):
                self.onNotify?(error.localizedDescription)
            }
        })

        onNotify?("Downloading the speech model (142 MB). This happens once, in the background — you'll be told when voice input is ready.")
    }
}
