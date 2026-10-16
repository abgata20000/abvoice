import AVFoundation
import CoreAudio
import Foundation

/// 入力デバイス 1 つ。
///
/// ⚠️ 識別子には **UID（文字列）** を使う。`AudioDeviceID` は再接続や再起動で変わるため、
///    設定に保存してよいのは UID の方。
struct AudioInputDevice: Identifiable, Hashable {
    /// CoreAudio の DeviceUID。設定に保存するのはこれ。
    var id: String
    var name: String
    var channels: Int
}

/// 入力デバイスの列挙と、AVAudioEngine への割り当て。
///
/// AVAudioEngine は既定でシステムの既定入力を使う。クラムシェルだと内蔵マイクが死ぬので、
/// ここでデバイスを明示的に差し替えられるようにする。
enum AudioDeviceManager {
    // MARK: 列挙

    static func inputDevices() -> [AudioInputDevice] {
        deviceIDs().compactMap { deviceID in
            let channels = inputChannelCount(deviceID)
            guard channels > 0 else { return nil }
            guard let uid = stringProperty(deviceID, kAudioDevicePropertyDeviceUID) else { return nil }
            let name = stringProperty(deviceID, kAudioObjectPropertyName) ?? uid
            return AudioInputDevice(id: uid, name: name, channels: channels)
        }
        .sorted { $0.name < $1.name }
    }

    /// システムの既定入力。「システム既定」を選んでいるときの表示に使う。
    static func defaultInputDevice() -> AudioInputDevice? {
        guard let deviceID = defaultInputDeviceID(),
              let uid = stringProperty(deviceID, kAudioDevicePropertyDeviceUID)
        else { return nil }
        let name = stringProperty(deviceID, kAudioObjectPropertyName) ?? uid
        return AudioInputDevice(id: uid, name: name, channels: inputChannelCount(deviceID))
    }

    static func deviceID(forUID uid: String) -> AudioDeviceID? {
        deviceIDs().first { stringProperty($0, kAudioDevicePropertyDeviceUID) == uid }
    }

    static func name(forUID uid: String) -> String? {
        deviceID(forUID: uid).flatMap { stringProperty($0, kAudioObjectPropertyName) }
    }

    // MARK: AVAudioEngine への割り当て

    enum ApplyResult {
        /// 指定したデバイスを割り当てた。
        case applied(AudioInputDevice)
        /// システム既定をそのまま使う。
        case systemDefault
        /// ⚠️ 選ばれていたデバイスが見つからない（外された）ので既定に落とした。
        case fellBackToDefault(missingUID: String)
    }

    /// エンジンの入力を指定 UID のデバイスに切り替える。
    /// ⚠️ エンジンが動いていない状態で呼ぶこと。
    @discardableResult
    static func apply(uid: String?, to engine: AVAudioEngine) -> ApplyResult {
        guard let unit = engine.inputNode.audioUnit else { return .systemDefault }

        func set(_ deviceID: AudioDeviceID) {
            var value = deviceID
            AudioUnitSetProperty(
                unit,
                kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global,
                0,
                &value,
                UInt32(MemoryLayout<AudioDeviceID>.size)
            )
        }

        guard let uid else {
            // 以前に別デバイスを割り当てている可能性があるので、既定を明示的に入れ直す。
            if let deviceID = defaultInputDeviceID() { set(deviceID) }
            return .systemDefault
        }

        guard let deviceID = deviceID(forUID: uid) else {
            if let fallback = defaultInputDeviceID() { set(fallback) }
            return .fellBackToDefault(missingUID: uid)
        }

        set(deviceID)
        let name = stringProperty(deviceID, kAudioObjectPropertyName) ?? uid
        return .applied(AudioInputDevice(id: uid, name: name, channels: inputChannelCount(deviceID)))
    }

    // MARK: CoreAudio の下回り

    private static func deviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size
        ) == noErr, size > 0 else { return [] }

        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids
        ) == noErr else { return [] }
        return ids
    }

    private static func defaultInputDeviceID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID
        ) == noErr, deviceID != 0 else { return nil }
        return deviceID
    }

    private static func inputChannelCount(_ deviceID: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr, size > 0 else {
            return 0
        }

        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, raw) == noErr else { return 0 }

        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func stringProperty(_ deviceID: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value) == noErr,
              let value else { return nil }
        return value.takeRetainedValue() as String
    }
}
