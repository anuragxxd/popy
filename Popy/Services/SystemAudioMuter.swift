import AudioToolbox
import CoreAudio
import Foundation

/// Mutes system audio output while dictation is recording, so whatever is
/// playing does not bleed into the microphone (or into the transcript).
///
/// Two safety properties matter more than the feature itself:
///
///  1. The device that was muted is remembered explicitly. The *default*
///     output can change mid-recording — headphones disconnecting is the
///     obvious case — and restoring "the current default" would then unmute
///     the wrong device and leave the original silent forever.
///
///  2. The pending restore is written to UserDefaults. If Popy is killed or
///     crashes while muted, the user is left with no audio and no idea why,
///     so the next launch puts it back.
final class SystemAudioMuter {

    static let shared = SystemAudioMuter()

    private static let pendingDeviceKey = "muterPendingDeviceUID"
    private static let pendingMuteKey = "muterPendingWasMuted"
    private static let pendingVolumeKey = "muterPendingVolume"
    private static let pendingStatesKey = "muterPendingOutputStates"

    /// What we changed, so it can be put back exactly as it was.
    private struct SavedState {
        let usedMuteProperty: Bool
        let previousMuted: UInt32
        let previousVolume: Float32
    }

    private var saved: [String: SavedState] = [:]
    private var enforcementTimer: Timer?

    private init() {}

    var isMuted: Bool { enforcementTimer != nil }

    // MARK: - Mute / restore

    func mute() {
        if enforcementTimer == nil {
            // A Bluetooth profile switch can reset volume or replace the
            // default output after the initial mute. Keep enforcing silence
            // until capture ends, remembering every device we actually alter.
            let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
                self?.enforceMute()
            }
            enforcementTimer = timer
            RunLoop.main.add(timer, forMode: .common)
        }
        enforceMute()
    }

    private func enforceMute() {
        guard let device = Self.defaultOutputDevice(), let uid = Self.uid(of: device) else { return }
        if let state = saved[uid] {
            // CoreAudio IDs can change during a reconnect/profile switch.
            // Keep the original level for this UID rather than snapshotting 0.
            if state.usedMuteProperty {
                if Self.getUInt32(device, kAudioDevicePropertyMute) != 1 {
                    _ = Self.setUInt32(device, kAudioDevicePropertyMute, 1)
                }
            } else {
                let selector = kAudioHardwareServiceDeviceProperty_VirtualMainVolume
                if Self.getFloat32(device, selector) != 0 {
                    _ = Self.setFloat32(device, selector, 0)
                }
            }
            return
        }

        // Use output volume on Bluetooth so silencing playback does not
        // depend on the headset's implementation of hardware mute.
        var transportAddress = Self.address(kAudioDevicePropertyTransportType,
                                            scope: kAudioObjectPropertyScopeGlobal)
        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        _ = AudioObjectGetPropertyData(device, &transportAddress, 0, nil, &size, &transport)
        let bluetooth = transport == kAudioDeviceTransportTypeBluetooth ||
                        transport == kAudioDeviceTransportTypeBluetoothLE
        if bluetooth, muteUsingVolume(device) { return }

        // A device may advertise a writable property but reject the write.
        // Keep trying the volume fallback rather than returning unmuted.
        if Self.isSettable(device, kAudioDevicePropertyMute),
           let previous = Self.getUInt32(device, kAudioDevicePropertyMute),
           Self.setUInt32(device, kAudioDevicePropertyMute, 1) {
            saved[uid] = SavedState(usedMuteProperty: true,
                               previousMuted: previous, previousVolume: 0)
            persistPending()
            return
        }
        if !muteUsingVolume(device) {
            print("Popy [Audio] output device has no working mute or volume control")
        }
    }

    @discardableResult
    private func muteUsingVolume(_ device: AudioDeviceID) -> Bool {
        let selector = kAudioHardwareServiceDeviceProperty_VirtualMainVolume
        guard let uid = Self.uid(of: device),
              Self.isSettable(device, selector),
              let previous = Self.getFloat32(device, selector),
              Self.setFloat32(device, selector, 0) else { return false }
        saved[uid] = SavedState(usedMuteProperty: false,
                           previousMuted: 0, previousVolume: previous)
        persistPending()
        return true
    }

    func restore() {
        enforcementTimer?.invalidate()
        enforcementTimer = nil
        let states = saved
        saved.removeAll()
        for (uid, state) in states {
            guard let device = Self.device(matchingUID: uid) else { continue }
            if state.usedMuteProperty {
                _ = Self.setUInt32(device, kAudioDevicePropertyMute, state.previousMuted)
            } else {
                _ = Self.setFloat32(device,
                                    kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                                    state.previousVolume)
            }
        }
        clearPending()
    }

    // MARK: - Crash recovery

    /// Undo a mute left behind by a previous run that did not exit cleanly.
    /// Call once at launch.
    func restoreAfterUnexpectedExit() {
        let defaults = UserDefaults.standard
        // New sessions can span several outputs during a profile switch.
        if let states = defaults.array(forKey: Self.pendingStatesKey) as? [[String: Any]] {
            for state in states {
                guard let uid = state["uid"] as? String,
                      let device = Self.device(matchingUID: uid) else { continue }
                if state["usedMute"] as? Bool == true {
                    let value = (state["muted"] as? NSNumber)?.uint32Value ?? 0
                    _ = Self.setUInt32(device, kAudioDevicePropertyMute, value)
                } else if let volume = state["volume"] as? NSNumber {
                    _ = Self.setFloat32(device, kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                                        volume.floatValue)
                }
            }
            clearPending()
            return
        }
        // Recover settings written by older Popy versions, too.
        guard let uid = defaults.string(forKey: Self.pendingDeviceKey) else { return }
        defer { clearPending() }

        guard let device = Self.device(matchingUID: uid) else { return }

        if defaults.object(forKey: Self.pendingVolumeKey) != nil,
           defaults.bool(forKey: "muterPendingUsedMute") == false {
            let volume = Float32(defaults.double(forKey: Self.pendingVolumeKey))
            _ = Self.setFloat32(device, kAudioHardwareServiceDeviceProperty_VirtualMainVolume, volume)
        } else {
            let wasMuted = UInt32(defaults.integer(forKey: Self.pendingMuteKey))
            _ = Self.setUInt32(device, kAudioDevicePropertyMute, wasMuted)
        }
    }

    private func persistPending() {
        let states: [[String: Any]] = saved.map { uid, state in
            return ["uid": uid, "usedMute": state.usedMuteProperty,
                    "muted": Int(state.previousMuted), "volume": Double(state.previousVolume)]
        }
        UserDefaults.standard.set(states, forKey: Self.pendingStatesKey)
    }

    private func clearPending() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: Self.pendingStatesKey)
        defaults.removeObject(forKey: Self.pendingDeviceKey)
        defaults.removeObject(forKey: Self.pendingMuteKey)
        defaults.removeObject(forKey: Self.pendingVolumeKey)
        defaults.removeObject(forKey: "muterPendingUsedMute")
    }

    // MARK: - CoreAudio helpers

    private static func address(_ selector: AudioObjectPropertySelector,
                                scope: AudioObjectPropertyScope = kAudioDevicePropertyScopeOutput)
    -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector,
                                   mScope: scope,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    private static func defaultOutputDevice() -> AudioDeviceID? {
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = address(kAudioHardwarePropertyDefaultOutputDevice,
                           scope: kAudioObjectPropertyScopeGlobal)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &addr, 0, nil, &size, &device) == noErr,
              device != AudioDeviceID(kAudioObjectUnknown) else { return nil }
        return device
    }

    private static func isSettable(_ device: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> Bool {
        var addr = address(selector)
        guard AudioObjectHasProperty(device, &addr) else { return false }
        var settable = DarwinBoolean(false)
        guard AudioObjectIsPropertySettable(device, &addr, &settable) == noErr else { return false }
        return settable.boolValue
    }

    private static func getUInt32(_ device: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> UInt32? {
        var addr = address(selector)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    @discardableResult
    private static func setUInt32(_ device: AudioDeviceID, _ selector: AudioObjectPropertySelector, _ value: UInt32) -> Bool {
        var addr = address(selector)
        var v = value
        return AudioObjectSetPropertyData(device, &addr, 0, nil,
                                          UInt32(MemoryLayout<UInt32>.size), &v) == noErr
    }

    private static func getFloat32(_ device: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> Float32? {
        var addr = address(selector)
        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    @discardableResult
    private static func setFloat32(_ device: AudioDeviceID, _ selector: AudioObjectPropertySelector, _ value: Float32) -> Bool {
        var addr = address(selector)
        var v = value
        return AudioObjectSetPropertyData(device, &addr, 0, nil,
                                          UInt32(MemoryLayout<Float32>.size), &v) == noErr
    }

    /// Device UIDs are stable across reboots and reconnects; raw AudioDeviceIDs
    /// are not, so the UID is what gets persisted.
    private static func uid(of device: AudioDeviceID) -> String? {
        var addr = address(kAudioDevicePropertyDeviceUID, scope: kAudioObjectPropertyScopeGlobal)
        var cfString: CFString? = nil
        var size = UInt32(MemoryLayout<CFString?>.size)
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &cfString) == noErr,
              let result = cfString else { return nil }
        return result as String
    }

    private static func device(matchingUID uid: String) -> AudioDeviceID? {
        var addr = address(kAudioHardwarePropertyDevices, scope: kAudioObjectPropertyScopeGlobal)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject),
                                             &addr, 0, nil, &size) == noErr, size > 0 else { return nil }

        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var devices = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &addr, 0, nil, &size, &devices) == noErr else { return nil }

        return devices.first { self.uid(of: $0) == uid }
    }
}
