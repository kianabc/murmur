import CoreAudio
import Foundation

/// A microphone macOS knows about.
public struct AudioInputDevice: Equatable, Hashable, Sendable, Identifiable {
    public enum Transport: String, Sendable {
        case builtIn, usb, bluetooth, thunderbolt, display, virtual, aggregate, other
    }

    public let id: AudioDeviceID
    /// Stable across unplugging and replugging; `id` is not.
    public let uid: String
    public let name: String
    public let transport: Transport
    public let inputChannels: Int
    public let sampleRate: Double

    public init(id: AudioDeviceID, uid: String, name: String, transport: Transport,
                inputChannels: Int, sampleRate: Double) {
        self.id = id; self.uid = uid; self.name = name; self.transport = transport
        self.inputChannels = inputChannels; self.sampleRate = sampleRate
    }

    /// Has something to record from. A dock's audio chip can present itself
    /// as an input with no channels or no rate, and recording from it fails.
    public var isUsable: Bool { inputChannels > 0 && sampleRate > 0 }
}

/// The microphones on this Mac, and which to use in what order.
///
/// Murmur used to take whatever macOS had as the default input, and nothing
/// else. Plugging in a dock often makes the dock's own audio chip the default —
/// frequently an input jack with nothing plugged into it — and Murmur then
/// failed to start, or recorded silence, with no way to choose otherwise.
public enum AudioDevices {
    public static func inputs() -> [AudioInputDevice] {
        allDeviceIDs().compactMap(describe).filter { $0.inputChannels > 0 }
    }

    public static func defaultInputID() -> AudioDeviceID? {
        var id = AudioDeviceID(0)
        guard read(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultInputDevice, &id) == noErr,
              id != 0 else { return nil }
        return id
    }

    /// The order to try microphones in. Pure, so every dock arrangement can be
    /// tested without owning the dock.
    ///
    ///   1. The one the user picked in Settings, if it's plugged in.
    ///   2. The macOS default — what they chose in System Settings → Sound.
    ///   3. The built-in microphone.
    ///   4. Anything else real. Virtual devices (Teams, Zoom, Loopback) are
    ///      only used when picked by hand: they're silent unless another app
    ///      is feeding them, so falling back to one just records nothing.
    public static func candidates(
        preferredUID: String?,
        defaultID: AudioDeviceID?,
        devices: [AudioInputDevice]
    ) -> [AudioInputDevice] {
        let usable = devices.filter(\.isUsable)
        var ordered: [AudioInputDevice] = []
        func add(_ device: AudioInputDevice?) {
            guard let device, !ordered.contains(where: { $0.uid == device.uid }) else { return }
            ordered.append(device)
        }
        if let preferredUID { add(usable.first { $0.uid == preferredUID }) }
        if let defaultID { add(usable.first { $0.id == defaultID }) }
        usable.filter { $0.transport == .builtIn }.forEach(add)
        usable.filter { $0.transport != .builtIn && $0.transport != .virtual && $0.transport != .aggregate }.forEach(add)
        return ordered
    }

    // MARK: - CoreAudio

    private static func allDeviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr
        else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr
        else { return [] }
        return ids
    }

    private static func describe(_ id: AudioDeviceID) -> AudioInputDevice? {
        var name: CFString = "" as CFString
        var uid: CFString = "" as CFString
        guard read(id, kAudioObjectPropertyName, &name) == noErr,
              read(id, kAudioDevicePropertyDeviceUID, &uid) == noErr else { return nil }
        var transportCode: UInt32 = 0
        _ = read(id, kAudioDevicePropertyTransportType, &transportCode)
        var rate: Float64 = 0
        _ = read(id, kAudioDevicePropertyNominalSampleRate, &rate)
        return AudioInputDevice(
            id: id, uid: uid as String, name: name as String,
            transport: transport(transportCode),
            inputChannels: inputChannelCount(id), sampleRate: rate
        )
    }

    private static func inputChannelCount(_ id: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func transport(_ code: UInt32) -> AudioInputDevice.Transport {
        switch code {
        case kAudioDeviceTransportTypeBuiltIn: .builtIn
        case kAudioDeviceTransportTypeUSB: .usb
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: .bluetooth
        case kAudioDeviceTransportTypeThunderbolt: .thunderbolt
        case kAudioDeviceTransportTypeDisplayPort, kAudioDeviceTransportTypeHDMI: .display
        case kAudioDeviceTransportTypeVirtual: .virtual
        case kAudioDeviceTransportTypeAggregate: .aggregate
        default: .other
        }
    }

    private static func read<T>(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector, _ value: inout T) -> OSStatus {
        var address = AudioObjectPropertyAddress(
            mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<T>.size)
        return AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value)
    }
}

/// The microphone picked in Settings, by UID. Nil means automatic.
public enum MicrophoneChoice {
    private static let key = "com.torimi.murmur.microphoneUID"

    public static var selectedUID: String? {
        get { UserDefaults.standard.string(forKey: key).flatMap { $0.isEmpty ? nil : $0 } }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
}
