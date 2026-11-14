import Foundation
import CoreAudio
import AudioToolbox

struct Output {
    var uid: String
    var volume: Float32
    var muted: UInt32 = 0
    var bluetooth = true
    var hasVolume = true
    var rejectMute = false
}
var outputs: [AudioDeviceID: Output] = [10: Output(uid: "headset", volume: 0.65)]
var defaultOutput: AudioDeviceID = 10
func fakeHasProperty(_ id: AudioObjectID, _ address: UnsafePointer<AudioObjectPropertyAddress>) -> Bool { true }
func fakeIsSettable(_ id: AudioObjectID, _ address: UnsafePointer<AudioObjectPropertyAddress>, _ result: UnsafeMutablePointer<DarwinBoolean>) -> OSStatus {
    result.pointee = DarwinBoolean(address.pointee.mSelector != kAudioHardwareServiceDeviceProperty_VirtualMainVolume || outputs[id]!.hasVolume)
    return noErr
}
func fakeGetSize(_ id: AudioObjectID, _ address: UnsafePointer<AudioObjectPropertyAddress>, _ count: UInt32, _ qualifier: UnsafeRawPointer?, _ size: UnsafeMutablePointer<UInt32>) -> OSStatus {
    size.pointee = UInt32(outputs.count * MemoryLayout<AudioDeviceID>.size)
    return noErr
}
func fakeGet(_ id: AudioObjectID, _ address: UnsafePointer<AudioObjectPropertyAddress>, _ count: UInt32, _ qualifier: UnsafeRawPointer?, _ size: UnsafeMutablePointer<UInt32>, _ data: UnsafeMutableRawPointer) -> OSStatus {
    switch address.pointee.mSelector {
    case kAudioHardwarePropertyDefaultOutputDevice: data.storeBytes(of: defaultOutput, as: AudioDeviceID.self)
    case kAudioHardwarePropertyDevices:
        for (i, key) in outputs.keys.sorted().enumerated() { data.assumingMemoryBound(to: AudioDeviceID.self)[i] = key }
    case kAudioDevicePropertyTransportType:
        data.storeBytes(of: outputs[id]!.bluetooth ? kAudioDeviceTransportTypeBluetooth : kAudioDeviceTransportTypeBuiltIn, as: UInt32.self)
    case kAudioDevicePropertyDeviceUID:
        data.assumingMemoryBound(to: CFString?.self).pointee = outputs[id]!.uid as CFString
    case kAudioDevicePropertyMute: data.storeBytes(of: outputs[id]!.muted, as: UInt32.self)
    case kAudioHardwareServiceDeviceProperty_VirtualMainVolume: data.storeBytes(of: outputs[id]!.volume, as: Float32.self)
    default: return -1
    }
    return noErr
}
func fakeSet(_ id: AudioObjectID, _ address: UnsafePointer<AudioObjectPropertyAddress>, _ count: UInt32, _ qualifier: UnsafeRawPointer?, _ size: UInt32, _ data: UnsafeRawPointer) -> OSStatus {
    switch address.pointee.mSelector {
    case kAudioDevicePropertyMute:
        if outputs[id]!.rejectMute { return -1 }
        outputs[id]!.muted = data.load(as: UInt32.self)
    case kAudioHardwareServiceDeviceProperty_VirtualMainVolume:
        outputs[id]!.volume = data.load(as: Float32.self)
    default: return -1
    }
    return noErr
}

@main struct MuterChecks {
    static func main() {
        // Isolate recovery records from the real app's preferences.
        UserDefaults.standard.removeObject(forKey: "muterPendingOutputStates")
        let muter = SystemAudioMuter.shared
        muter.mute()
        precondition(outputs[10]!.volume == 0)
        outputs[10]!.volume = 0.4 // Profile switch reset volume.
        muter.mute()
        precondition(outputs[10]!.volume == 0)
        // Same physical headset, new CoreAudio ID: do not save muted volume.
        outputs[11] = outputs.removeValue(forKey: 10)
        defaultOutput = 11
        muter.mute()
        outputs[20] = Output(uid: "speakers", volume: 0.8, bluetooth: false)
        defaultOutput = 20
        muter.mute()
        precondition(outputs[20]!.muted == 1)
        muter.restore()
        precondition(outputs[11]!.volume == 0.65)
        precondition(outputs[20]!.muted == 0)
        precondition(!muter.isMuted)
        print("PASS: Bluetooth volume mute, reassertion, ID reassignment, output switch, exact restore")

        // Devices that advertise mute but reject it must fall back to volume.
        outputs[20]!.rejectMute = true
        muter.mute()
        precondition(outputs[20]!.volume == 0)
        muter.restore()
        precondition(outputs[20]!.volume == 0.8)
        print("PASS: rejected mute falls back to volume")

        // Crash recovery must restore every output captured in the session.
        defaultOutput = 11
        muter.mute()
        defaultOutput = 20
        muter.mute()
        muter.restoreAfterUnexpectedExit()
        precondition(outputs[11]!.volume == 0.65 && outputs[20]!.volume == 0.8)
        muter.restore()
        print("PASS: multi-output crash recovery")

        outputs[11]!.hasVolume = false
        outputs[11]!.muted = 1
        defaultOutput = 11
        muter.mute()
        precondition(outputs[11]!.muted == 1)
        muter.restore()
        precondition(outputs[11]!.muted == 1)
        print("PASS: headset without volume uses mute and preserves an existing mute")

        outputs[11]!.muted = 0
        UserDefaults.standard.set("headset", forKey: "muterPendingDeviceUID")
        UserDefaults.standard.set(1, forKey: "muterPendingWasMuted")
        UserDefaults.standard.set(true, forKey: "muterPendingUsedMute")
        muter.restoreAfterUnexpectedExit()
        precondition(outputs[11]!.muted == 1)
        print("PASS: legacy crash recovery")
    }
}
