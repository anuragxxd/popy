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

    /// What we changed, so it can be put back exactly as it was.
    private struct SavedState {
        let device: AudioDeviceID
        let usedMuteProperty: Bool
        let previousMuted: UInt32
        let previousVolume: Float32
    }

    private var saved: SavedState?

    private init() {}

    var isMuted: Bool { saved != nil }

    // MARK: - Mute / restore

    func mute() {
        guard saved == nil, let device = Self.defaultOutputDevice() else { return }

        // Prefer the dedicated mute property: it preserves the user's volume
        // setting, so restoring cannot drift the level.
        if Self.isSettable(device, kAudioDevicePropertyMute),
           let previous = Self.getUInt32(device, kAudioDevicePropertyMute) {
            guard Self.setUInt32(device, kAudioDevicePropertyMute, 1) else { return }
            saved = SavedState(device: device, usedMuteProperty: true,
                               previousMuted: previous, previousVolume: 0)
            persistPending(device: device, wasMuted: previous, volume: 0, usedMute: true)
            return
        }

        // Fallback for devices with no mute control (many USB interfaces):
        // drop the virtual main volume to zero and restore it afterwards.
        if Self.isSettable(device, kAudioHardwareServiceDeviceProperty_VirtualMainVolume),
           let previous = Self.getFloat32(device, kAudioHardwareServiceDeviceProperty_VirtualMainVolume) {
            guard Self.setFloat32(device, kAudioHardwareServiceDeviceProperty_VirtualMainVolume, 0) else { return }
            saved = SavedState(device: device, usedMuteProperty: false,
                               previousMuted: 0, previousVolume: previous)
            persistPending(device: device, wasMuted: 0, volume: previous, usedMute: false)
        }
    }

    func restore() {
        defer { clearPending() }
        guard let state = saved else { return }
        saved = nil

        if state.usedMuteProperty {
            _ = Self.setUInt32(state.device, kAudioDevicePropertyMute, state.previousMuted)
        } else {
            _ = Self.setFloat32(state.device,
                                kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                                state.previousVolume)
        }
    }

    // MARK: - Crash recovery

    /// Undo a mute left behind by a previous run that did not exit cleanly.
    /// Call once at launch.
    func restoreAfterUnexpectedExit() {
        let defaults = UserDefaults.standard
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

    private func persistPending(device: AudioDeviceID, wasMuted: UInt32, volume: Float32, usedMute: Bool) {
        guard let uid = Self.uid(of: device) else { return }
        let defaults = UserDefaults.standard
        defaults.set(uid, forKey: Self.pendingDeviceKey)
        defaults.set(Int(wasMuted), forKey: Self.pendingMuteKey)
        defaults.set(Double(volume), forKey: Self.pendingVolumeKey)
        defaults.set(usedMute, forKey: "muterPendingUsedMute")
    }

    private func clearPending() {
        let defaults = UserDefaults.standard
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
