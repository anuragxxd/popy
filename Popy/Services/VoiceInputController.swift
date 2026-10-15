import AppKit
import os

/// Owns the dictation state machine and wires together the Fn listener,
/// the recorder, and the on-device transcription engine: Apple's
/// SpeechAnalyzer where the Mac supports it, Whisper everywhere else.
///
///     idle ──Fn Fn──▶ recording ──Fn Fn──▶ transcribing ──▶ idle
///     idle ──hold Fn──▶ recording ──release──▶ transcribing ──▶ idle
///                       recording ──Esc──▶ idle
///
/// The finished transcript is copied, pasted, or both, exactly as the engine
/// produced it, apart from the user's own `Vocabulary`. Nothing rewrites,
/// summarises, or "cleans up" the text.
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
                // Esc belongs to the user's app except while recording. Tied
                // to the state itself, so no exit path can leave it held.
                HotkeyManager.shared.setEscapeEnabled(self.state == .recording)
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

    /// Apple's transcription of the recording in progress. Nil when this Mac
    /// uses Whisper, which only starts once recording has stopped.
    private var liveTranscription: LiveTranscription?

    /// True between requesting microphone access and the recorder actually
    /// starting. Guards the async gap on first run.
    private var isPreparing = false

    /// The current recording was started by holding Fn, so releasing Fn ends it.
    private var recordingStartedByHold = false

    /// Identifies the transcription in flight, so a result that arrives after
    /// the timeout gave up on it is ignored rather than delivered late.
    private var transcriptionID = 0

    /// Longest a transcription may run before Popy gives up on it. Typical is
    /// well under a second; without a limit, an engine that never returned
    /// left the state stuck in `.transcribing`, where every Fn Fn is ignored.
    private static let transcriptionTimeout: TimeInterval = 30

    private init() {}

    // MARK: - Lifecycle

    func start() {
        FnKeyListener.shared.onDoubleTap = { [weak self] in
            self?.handleDoubleTap()
        }
        FnKeyListener.shared.onHoldStart = { [weak self] in
            self?.handleHoldStart()
        }
        FnKeyListener.shared.onHoldEnd = { [weak self] cancelled in
            self?.handleHoldEnd(cancelled: cancelled)
        }
        FnKeyListener.shared.holdToTalkEnabled = preferences.holdToTalkEnabled

        HotkeyManager.shared.onEscape = { [weak self] in
            self?.cancelRecording()
        }

        recorder.onAutoStop = { [weak self] url in
            guard let self = self else { return }
            SystemAudioMuter.shared.restore()
            self.handleFinishedRecording(at: url)
        }

        recorder.onLevel = { level in
            DictationHUD.shared.updateLevel(level)
        }

        if preferences.voiceInputEnabled {
            FnKeyListener.shared.start()
            warmUpEngine()
        }
    }

    func stop() {
        FnKeyListener.shared.stop()
        recorder.cancel()
        discardLiveTranscription()
        // Never leave the machine muted on the way out.
        SystemAudioMuter.shared.restore()
        state = .idle
    }

    func setHoldToTalk(_ enabled: Bool) {
        preferences.holdToTalkEnabled = enabled
        FnKeyListener.shared.holdToTalkEnabled = enabled
    }

    func setEnabled(_ enabled: Bool) {
        preferences.voiceInputEnabled = enabled
        if enabled {
            FnKeyListener.shared.start()
            warmUpEngine()
        } else {
            recorder.cancel()
            discardLiveTranscription()
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
        Log.dictation.notice("Trigger in state \(String(describing: self.state), privacy: .public)")
        switch state {
        case .idle:
            beginRecording()
        case .recording:
            endRecording()
        case .transcribing:
            // Ignore triggers while inference is running — it is sub-second,
            // and queuing a second recording here would race the pasteboard.
            // Say so, though: ignoring it silently looks like Fn Fn is broken.
            DictationHUD.shared.show(.transcribing)
        }
    }

    private func handleHoldStart() {
        guard state == .idle else { return }
        recordingStartedByHold = true
        beginRecording()
    }

    private func handleHoldEnd(cancelled: Bool) {
        guard recordingStartedByHold else { return }
        recordingStartedByHold = false
        guard state == .recording else { return }

        if cancelled {
            // Fn was a modifier for another key after all. Not the user's
            // mistake, so leave quietly rather than flash a "Cancelled".
            cancelRecording(quietly: true)
        } else {
            endRecording(fromHold: true)
        }
    }

    /// Throw the recording away: Esc, or a hold that turned out not to be one.
    func cancelRecording(quietly: Bool = false) {
        guard state == .recording else { return }
        Log.dictation.notice("Recording cancelled")
        recordingStartedByHold = false
        recorder.cancel()
        discardLiveTranscription()
        SystemAudioMuter.shared.restore()
        state = .idle
        if quietly {
            DictationHUD.shared.hide()
        } else {
            DictationHUD.shared.show(.cancelled)
        }
    }

    // MARK: - Recording

    private func beginRecording() {
        // Microphone access is asynchronous on first run, and the state stays
        // `.idle` while the system dialog is up. Without this guard a second
        // double-tap during that window would start a second recording.
        guard !isPreparing else { return }

        // Guard the whole pipeline up front so the user is never left holding
        // a recording that cannot possibly be transcribed. Apple's engine
        // needs nothing from Popy; Whisper needs its binary and model.
        if !AppleSpeechEngine.isSupported {
            guard TranscriptionService.resolveBinary() != nil else {
                onNotify?(TranscriptionService.TranscriptionError.binaryMissing.localizedDescription)
                return
            }

            guard TranscriptionService.isModelInstalled else {
                downloadModelThenNotify()
                return
            }
        }

        isPreparing = true
        AudioRecorder.requestMicrophoneAccess { [weak self] granted in
            guard let self = self else { return }
            defer { self.isPreparing = false }

            guard granted else {
                self.onNotify?(AudioRecorder.RecorderError.microphoneDenied.localizedDescription)
                return
            }

            // A hold released while the microphone prompt was up.
            if self.recordingStartedByHold, !FnKeyListener.shared.isHolding {
                self.recordingStartedByHold = false
                return
            }

            // Apple transcribes while the user speaks, so connect it before
            // the first buffer arrives.
            if let live = AppleSpeechEngine.makeLiveTranscription() {
                self.liveTranscription = live
                self.recorder.onAudio = { live.append($0) }
            }

            do {
                try self.recorder.start()
                self.state = .recording
                DictationHUD.shared.show(.listening(byHold: self.recordingStartedByHold))

                // Silence output only once recording is actually under way, so
                // a failed start never leaves the machine muted.
                if self.preferences.muteWhileDictating {
                    SystemAudioMuter.shared.mute()
                }
            } catch {
                Log.dictation.error("Recorder failed to start: \(error.localizedDescription, privacy: .public)")
                self.recordingStartedByHold = false
                self.discardLiveTranscription()
                self.state = .idle
                DictationHUD.shared.show(.failed(error.localizedDescription))
                self.onNotify?(error.localizedDescription)
            }
        }
    }

    private func endRecording(fromHold: Bool = false) {
        recordingStartedByHold = false
        // Unmute the moment capture stops — the user should not sit through
        // transcription in silence.
        SystemAudioMuter.shared.restore()

        do {
            let url = try recorder.stop()
            handleFinishedRecording(at: url)
        } catch AudioRecorder.RecorderError.tooShort {
            discardLiveTranscription()
            state = .idle
            if fromHold {
                // A brief hold is an accidental one; there is nothing to explain.
                DictationHUD.shared.hide()
            } else {
                // Almost certainly a stray double-tap. Say so briefly rather
                // than vanishing without explanation.
                DictationHUD.shared.show(.failed("Too short — hold on and speak first."))
            }
        } catch {
            discardLiveTranscription()
            state = .idle
            DictationHUD.shared.show(.failed(error.localizedDescription))
            onNotify?(error.localizedDescription)
        }
    }

    /// Shared by a manual stop and the max-duration auto-stop.
    private func handleFinishedRecording(at url: URL) {
        recordingStartedByHold = false
        let live = liveTranscription
        liveTranscription = nil
        recorder.onAudio = nil

        // Reject silence using the audio itself rather than the transcript.
        // Whisper reliably hallucinates "you" (and similar filler) on empty
        // input, and pattern-matching those strings afterwards would risk
        // deleting words the user actually said.
        guard recorder.containedSpeech else {
            live?.cancel()
            try? FileManager.default.removeItem(at: url)
            state = .idle
            DictationHUD.shared.show(.failed("No speech detected."))
            return
        }

        if let live = live {
            finishLiveTranscription(live, recording: url)
        } else {
            beginTranscription(of: url)
        }
    }

    /// Drop Apple's in-flight transcription when its recording is abandoned.
    private func discardLiveTranscription() {
        recorder.onAudio = nil
        liveTranscription?.cancel()
        liveTranscription = nil
    }

    // MARK: - Transcription

    /// Apple has transcribed most of the recording by now; this waits for the
    /// last words. The WAV is kept until then so that if Apple's engine fails,
    /// Whisper (when set up) can still transcribe it rather than the dictation
    /// being lost.
    private func finishLiveTranscription(_ live: LiveTranscription, recording url: URL) {
        let id = beginTranscribingState {
            live.cancel()
            try? FileManager.default.removeItem(at: url)
        }

        Task { @MainActor [weak self] in
            let result: Result<String, Error>
            do {
                result = .success(try await live.finish())
            } catch {
                result = .failure(error)
            }
            guard let self = self, self.transcriptionID == id else { return }
            self.completeLiveTranscription(result, recording: url)
        }
    }

    /// Enter `.transcribing` and arm the timeout. Returns the ID that the
    /// eventual result must still match to be delivered.
    private func beginTranscribingState(onTimeout abandon: @escaping () -> Void) -> Int {
        transcriptionID &+= 1
        let id = transcriptionID
        state = .transcribing
        DictationHUD.shared.show(.transcribing)

        DispatchQueue.main.asyncAfter(deadline: .now() + Self.transcriptionTimeout) { [weak self] in
            guard let self = self, self.transcriptionID == id, self.state == .transcribing else { return }
            Log.dictation.error("Transcription timed out")
            self.transcriptionID &+= 1
            abandon()
            self.state = .idle
            DictationHUD.shared.show(.failed("Transcription took too long. Try again."))
        }
        return id
    }

    private func completeLiveTranscription(_ result: Result<String, Error>, recording url: URL) {
        if case .failure(let error) = result, TranscriptionService.isReady {
            print("Popy [Speech] Apple transcription failed, using Whisper: \(error.localizedDescription)")
            beginTranscription(of: url)  // deletes the recording when done
            return
        }

        try? FileManager.default.removeItem(at: url)
        state = .idle

        switch result {
        case .success(let text) where !text.isEmpty:
            deliver(text)
        case .success:
            DictationHUD.shared.show(.failed("No speech detected."))
        case .failure(let error):
            DictationHUD.shared.show(.failed(error.localizedDescription))
            onNotify?(error.localizedDescription)
        }
    }

    private func beginTranscription(of url: URL) {
        // Whisper's process cannot be cut short; on timeout its result is
        // simply ignored, and it deletes the recording itself when done.
        let id = beginTranscribingState(onTimeout: {})

        transcriber.transcribe(fileAt: url) { [weak self] result in
            guard let self = self, self.transcriptionID == id else { return }
            self.state = .idle

            switch result {
            case .success(let text):
                self.deliver(text)
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

    /// How long a transcript sits on the clipboard when it is only there to
    /// be pasted. Wispr Flow restores after about half a second; this gives
    /// slower apps more room to act on the Cmd+V.
    private static let pasteRestoreDelay: TimeInterval = 1.0

    /// Hand the transcript over exactly as the engine produced it, and show
    /// where it went. It always goes into the history too, so a paste that
    /// missed its target can still be recovered from the menu.
    private func deliver(_ transcript: String) {
        let text = Vocabulary.current.apply(to: transcript)
        guard !text.isEmpty else {
            DictationHUD.shared.show(.failed("No speech detected."))
            return
        }

        let clipboard = ClipboardManager.shared
        let paste = preferences.voicePasteDirectly
        let canPaste = paste && KeyboardSimulator.hasAccessibilityPermission

        let status: String
        if canPaste && !preferences.voiceCopyToClipboard {
            clipboard.copyTranscriptBriefly(text, restoringAfter: Self.pasteRestoreDelay)
            status = "Pasted"
        } else if preferences.voiceCopyToClipboard || paste {
            // Without Accessibility the simulated Cmd+V silently does
            // nothing, so the transcript stays on the clipboard to paste.
            clipboard.copyTranscript(text)
            status = canPaste ? "Pasted" : "Copied"
        } else {
            clipboard.saveTranscript(text)
            status = "Saved to history"
        }

        if preferences.soundEnabled {
            NSSound(named: .init("Tink"))?.play()
        }

        if paste {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                KeyboardSimulator.simulatePaste()
            }
        }

        DictationHUD.shared.show(.delivered(text, status: status))
    }

    // MARK: - Model bootstrap

    /// Apple's engine only needs macOS to have its model. Whisper's first run
    /// compiles Metal shaders, so pay that at launch, not on first dictation.
    private func warmUpEngine() {
        if AppleSpeechEngine.isSupported {
            AppleSpeechEngine.installModelInBackground()
        } else {
            transcriber.warmUpIfNeeded()
        }
    }

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
