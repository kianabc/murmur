import AudioToolbox
import AVFoundation
import CoreAudio
import Foundation
import MurmurCore

/// Records from one microphone, directly, and nothing else.
///
/// This replaces AVAudioEngine's input node. AVAudioEngine is clocked by the
/// *output* device even when it only records, so with a Bluetooth headset as
/// the Mac's output — in call mode, as it is while its microphone is open —
/// every recording ran at the headset's pace whichever microphone was chosen.
/// Measured on real Pixel Buds: the built-in microphone delivered 0–1 buffers
/// in 1.5 seconds through AVAudioEngine, and 47,616 frames a second through
/// this. It also cached the first device's format, so pointing it at another
/// failed outright with -10868.
///
/// An input-only HAL unit has its output side disabled, so it is clocked by the
/// microphone and never touches the output device at all.
final class DeviceInput {
    let deviceID: AudioDeviceID
    /// What arrives: the device's own rate and channel count, as 32-bit float.
    let format: AVAudioFormat

    private var unit: AudioUnit?
    private let onBuffer: (AVAudioPCMBuffer) -> Void
    private let onChange: () -> Void
    private var listeners: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private static let listenQueue = DispatchQueue(label: "com.torimi.murmur.audio.listen")

    /// Opens and starts `deviceID`. Throws if the device won't start, which for
    /// a Bluetooth headset can simply mean it hasn't finished switching into
    /// call mode yet.
    init(
        deviceID: AudioDeviceID,
        onBuffer: @escaping (AVAudioPCMBuffer) -> Void,
        onChange: @escaping () -> Void
    ) throws {
        self.deviceID = deviceID
        self.onBuffer = onBuffer
        self.onChange = onChange

        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0, componentFlagsMask: 0
        )
        guard let component = AudioComponentFindNext(nil, &description) else {
            throw AudioError.engineUnavailable
        }
        var created: AudioUnit?
        try Self.check(AudioComponentInstanceNew(component, &created), "create")
        guard let unit = created else { throw AudioError.engineUnavailable }
        self.unit = unit

        do {
            var on: UInt32 = 1, off: UInt32 = 0
            // Element 1 is the input side, element 0 the output side.
            try Self.check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO,
                                                kAudioUnitScope_Input, 1, &on, 4), "enable input")
            try Self.check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO,
                                                kAudioUnitScope_Output, 0, &off, 4), "disable output")
            var device = deviceID
            try Self.check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                                                kAudioUnitScope_Global, 0, &device,
                                                UInt32(MemoryLayout<AudioDeviceID>.size)), "select device")

            // The hardware side of the input element is the device's real format.
            var hardware = AudioStreamBasicDescription()
            var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            try Self.check(AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat,
                                                kAudioUnitScope_Input, 1, &hardware, &size), "read format")
            guard hardware.mSampleRate > 0 else {
                throw AudioError.formatUnsupported("input reports a zero sample rate")
            }
            guard hardware.mChannelsPerFrame > 0 else {
                throw AudioError.formatUnsupported("input has no channels")
            }

            // Ask for the same rate — the input side doesn't resample — as
            // non-interleaved float, which is what AVAudioPCMBuffer holds.
            guard let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: hardware.mSampleRate,
                channels: AVAudioChannelCount(hardware.mChannelsPerFrame), interleaved: false
            ) else { throw AudioError.formatUnsupported("no float format at \(Int(hardware.mSampleRate))Hz") }
            self.format = format
            var client = format.streamDescription.pointee
            try Self.check(AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat,
                                                kAudioUnitScope_Output, 1, &client, size), "set format")

            var callback = AURenderCallbackStruct(
                inputProc: { refCon, flags, timeStamp, _, frames, _ in
                    Unmanaged<DeviceInput>.fromOpaque(refCon).takeUnretainedValue()
                        .render(flags: flags, timeStamp: timeStamp, frames: frames)
                },
                inputProcRefCon: Unmanaged.passUnretained(self).toOpaque()
            )
            try Self.check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_SetInputCallback,
                                                kAudioUnitScope_Global, 0, &callback,
                                                UInt32(MemoryLayout<AURenderCallbackStruct>.size)), "set callback")

            try Self.check(AudioUnitInitialize(unit), "initialise")
            try Self.check(AudioOutputUnitStart(unit), "start")
        } catch {
            AudioComponentInstanceDispose(unit)
            self.unit = nil
            throw error
        }

        // The device going away, or changing rate under us — a headset settling
        // into call mode, a dock unplugged — means this unit is finished. Tell
        // the owner, which decides whether to reopen.
        listen(deviceID, kAudioDevicePropertyDeviceIsAlive)
        listen(deviceID, kAudioDevicePropertyNominalSampleRate)
        listen(deviceID, kAudioDevicePropertyStreamConfiguration, scope: kAudioDevicePropertyScopeInput)
    }

    deinit { stop() }

    func stop() {
        for (object, address, block) in listeners {
            var address = address
            AudioObjectRemovePropertyListenerBlock(object, &address, Self.listenQueue, block)
        }
        listeners.removeAll()
        guard let unit else { return }
        self.unit = nil
        AudioOutputUnitStop(unit)
        AudioUnitUninitialize(unit)
        AudioComponentInstanceDispose(unit)
    }

    // MARK: - Audio thread

    private func render(
        flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
        timeStamp: UnsafePointer<AudioTimeStamp>,
        frames: UInt32
    ) -> OSStatus {
        guard let unit else { return noErr }
        // A fresh buffer every time: what's handed on may be held by the
        // recogniser, so it can't be reused for the next render.
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return noErr }
        buffer.frameLength = frames
        let status = AudioUnitRender(unit, flags, timeStamp, 1, frames, buffer.mutableAudioBufferList)
        if status == noErr { onBuffer(buffer) }
        return noErr
    }

    // MARK: - Plumbing

    private func listen(
        _ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.onChange() }
        if AudioObjectAddPropertyListenerBlock(object, &address, Self.listenQueue, block) == noErr {
            listeners.append((object, address, block))
        }
    }

    private static func check(_ status: OSStatus, _ step: String) throws {
        guard status != noErr else { return }
        throw AudioError.formatUnsupported("couldn't \(step) (\(status))")
    }
}
