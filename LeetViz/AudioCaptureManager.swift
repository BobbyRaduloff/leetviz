import Accelerate
import AudioToolbox
import AVFoundation
import CoreAudio
import Foundation

protocol AudioCaptureManagerDelegate: AnyObject {
    func audioCaptureManagerNeedsPermission(_ manager: AudioCaptureManager)
    func audioCaptureManager(_ manager: AudioCaptureManager, didFailWith error: Error)
    /// Called on the main thread when capture transitions silent → audible.
    func audioCaptureManagerDidWake(_ manager: AudioCaptureManager)
}

/// Captures system audio using Core Audio Process Tap (macOS 14.2+).
///
/// Unlike the previous ScreenCaptureKit-based implementation, this does NOT
/// trigger the macOS screen-recording indicator. The user grants a separate
/// "Audio recording" permission instead.
///
/// Architecture:
///   1. Create a `CATapDescription` that taps every process' audio output
///      (stereo, mixed down).
///   2. Wrap that tap inside a private aggregate device.
///   3. Register an `AudioDeviceIOProc` callback on the aggregate device.
///   4. In the callback, downmix to mono float, push to a ring buffer, and
///      detect silent/audible transitions so the render loop can sleep.
final class AudioCaptureManager: NSObject {
    weak var delegate: AudioCaptureManagerDelegate?

    let sampleRate: Float = 48_000

    /// Peak threshold below which we consider the system silent. Cheap RMS-free
    /// detector; tune up if quiet ambient noise causes false wakes.
    var wakeThreshold: Float = 0.005

    private var tapID: AudioObjectID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateDeviceID: AudioDeviceID = AudioDeviceID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?

    private let ringLock = NSLock()
    private var ring: [Float] = []
    /// 2048 samples ≈ 43 ms at 48 kHz — enough for the 1024-sample FFT window
    /// and waveform mode with headroom.
    private let ringCapacity = 2048

    private(set) var isRunning = false
    private var wasAudible = false

    func start() {
        guard !isRunning else { return }
        isRunning = true
        // No microphone request here — that would show a misleading "wants to
        // use the microphone" prompt. The Core Audio Tap permission
        // (`kTCCServiceAudioCapture`, distinct from Microphone) is supposed to
        // be prompted by macOS the first time audio actually flows through the
        // tap. The displayed text is taken from NSAudioCaptureUsageDescription
        // in Info.plist.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.setupTap()
        }
    }

    func stop() {
        isRunning = false
        teardown()
    }

    /// Snapshot the most recent samples. Safe to call from any thread.
    func recentSamples() -> [Float] {
        ringLock.lock()
        defer { ringLock.unlock() }
        return ring
    }

    // MARK: - Setup

    private func setupTap() {
        NSLog("LeetViz: enumerating audio processes…")
        let processes = enumerateAudioProcesses()
        NSLog("LeetViz: found %d audio process objects to tap", processes.count)
        guard !processes.isEmpty else {
            NSLog("LeetViz: no audio process objects available — bailing")
            delegate?.audioCaptureManager(self, didFailWith: simpleError("No audio processes available"))
            return
        }

        NSLog("LeetViz: creating Core Audio process tap…")
        // Explicit list of processes to mix down. The "global tap excluding
        // none" initializer didn't deliver samples in practice — enumerating
        // and mixing is the pattern that actually works.
        let tapDescription = CATapDescription(stereoMixdownOfProcesses: processes)
        tapDescription.muteBehavior = .unmuted
        tapDescription.isPrivate = true
        tapDescription.isExclusive = false

        var newTapID = AudioObjectID(kAudioObjectUnknown)
        let createStatus = AudioHardwareCreateProcessTap(tapDescription, &newTapID)
        guard createStatus == noErr else {
            NSLog("LeetViz: AudioHardwareCreateProcessTap failed: %d", createStatus)
            reportError(status: createStatus, stage: "create-tap")
            return
        }
        tapID = newTapID
        NSLog("LeetViz: tap created (id=%u)", tapID)

        guard let tapUID = readTapUID(tapID: tapID) else {
            NSLog("LeetViz: couldn't read tap UID — bailing")
            teardown()
            delegate?.audioCaptureManager(self, didFailWith: simpleError("Could not read tap UID"))
            return
        }

        // The aggregate device needs a real audio device to act as the clock
        // source — without one, the tap is wired in but no samples are
        // delivered (you see Create + Start succeed but the IOProc never
        // fires). The default system output device is the right pick: it's
        // where the audio the user is hearing is going, so the tap's mix
        // naturally lines up with its clock.
        guard let outputUID = hardwareOutputDeviceUID() else {
            NSLog("LeetViz: couldn't find a hardware output device — bailing")
            teardown()
            delegate?.audioCaptureManager(self, didFailWith: simpleError("No hardware output device"))
            return
        }
        NSLog("LeetViz: anchoring aggregate to hardware output UID=%@", outputUID)

        let aggregateUID = "app.leetviz.aggregate.\(UUID().uuidString)"
        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceUIDKey: aggregateUID,
            kAudioAggregateDeviceNameKey: "LeetViz Audio Tap",
            kAudioAggregateDeviceIsPrivateKey: 1,
            kAudioAggregateDeviceIsStackedKey: 0,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: outputUID] as [String: Any]
            ],
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapUIDKey: tapUID,
                    kAudioSubTapDriftCompensationKey: 1,
                ] as [String: Any]
            ],
            kAudioAggregateDeviceTapAutoStartKey: 1,
        ]

        var newAggregateID = AudioDeviceID(kAudioObjectUnknown)
        let aggStatus = AudioHardwareCreateAggregateDevice(
            aggregateDescription as CFDictionary,
            &newAggregateID
        )
        guard aggStatus == noErr else {
            NSLog("LeetViz: AudioHardwareCreateAggregateDevice failed: %d", aggStatus)
            teardown()
            reportError(status: aggStatus, stage: "create-aggregate")
            return
        }
        aggregateDeviceID = newAggregateID
        NSLog("LeetViz: aggregate device created (id=%u)", aggregateDeviceID)

        // Register IOProc and start. The IOProc fires on Core Audio's real-time
        // thread; we pass `self` through inClientData and reverse it inside.
        let unmanagedSelf = Unmanaged.passUnretained(self).toOpaque()
        var newProcID: AudioDeviceIOProcID?
        let procStatus = AudioDeviceCreateIOProcID(
            aggregateDeviceID,
            audioIOProcCallback,
            unmanagedSelf,
            &newProcID
        )
        guard procStatus == noErr, let procID = newProcID else {
            NSLog("LeetViz: AudioDeviceCreateIOProcID failed: %d", procStatus)
            teardown()
            reportError(status: procStatus, stage: "create-ioproc")
            return
        }
        ioProcID = procID

        // Inspect the input stream format so we know what the IOProc is
        // going to deliver. If the format isn't Float32 we won't decode it
        // correctly; log it loudly so future-us isn't confused.
        var inputFormat = AudioStreamBasicDescription()
        var formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var formatAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamFormat,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: 0
        )
        let formatStatus = AudioObjectGetPropertyData(
            aggregateDeviceID, &formatAddress, 0, nil, &formatSize, &inputFormat
        )
        if formatStatus == noErr {
            let isFloat = (inputFormat.mFormatFlags & kAudioFormatFlagIsFloat) != 0
            let isNonInterleaved = (inputFormat.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
            NSLog("LeetViz: aggregate input format — sampleRate=%.0f channels=%u float=%@ nonInterleaved=%@ bytesPerFrame=%u",
                  inputFormat.mSampleRate,
                  inputFormat.mChannelsPerFrame,
                  isFloat ? "yes" : "NO",
                  isNonInterleaved ? "yes" : "no",
                  inputFormat.mBytesPerFrame)
        } else {
            NSLog("LeetViz: couldn't read aggregate input stream format (status=%d)", formatStatus)
        }

        let startStatus = AudioDeviceStart(aggregateDeviceID, procID)
        guard startStatus == noErr else {
            NSLog("LeetViz: AudioDeviceStart failed: %d", startStatus)
            teardown()
            reportError(status: startStatus, stage: "start-device")
            return
        }

        NSLog("LeetViz: Core Audio tap streaming — audio flowing")
    }

    private func teardown() {
        if let procID = ioProcID {
            AudioDeviceStop(aggregateDeviceID, procID)
            AudioDeviceDestroyIOProcID(aggregateDeviceID, procID)
            ioProcID = nil
        }
        if aggregateDeviceID != AudioObjectID(kAudioObjectUnknown) {
            AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != AudioObjectID(kAudioObjectUnknown) {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    /// Enumerate every process that has registered audio activity with
    /// CoreAudio's HAL. These are the `AudioObjectID`s the tap accepts.
    private func enumerateAudioProcesses() -> [AudioObjectID] {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        let s1 = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size
        )
        guard s1 == noErr, size > 0 else {
            NSLog("LeetViz: process list size query failed (status=%d size=%u)", s1, size)
            return []
        }
        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        var processes = [AudioObjectID](repeating: 0, count: count)
        let s2 = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &processes
        )
        guard s2 == noErr else {
            NSLog("LeetViz: process list query failed (status=%d)", s2)
            return []
        }
        return processes
    }

    /// Find a real hardware output device UID (not an aggregate). We need a
    /// hardware-backed clock for our aggregate-with-tap setup; nesting our
    /// aggregate inside another aggregate (eqMac, BlackHole, Loopback, etc.)
    /// silently breaks sample delivery.
    private func hardwareOutputDeviceUID() -> String? {
        // 1. Enumerate all audio devices.
        var listAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &listAddr, 0, nil, &size
        )
        guard status == noErr, size > 0 else { return nil }
        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        var deviceIDs = [AudioObjectID](repeating: 0, count: count)
        status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &listAddr, 0, nil, &size, &deviceIDs
        )
        guard status == noErr else { return nil }

        // 2. Pick the first device that (a) has output streams and (b) is not
        // an aggregate. Built-in speakers / headphones / actual external DACs
        // all qualify; eqMac, BlackHole, Loopback aggregates are skipped.
        for id in deviceIDs {
            if hasOutputStreams(id), !isAggregate(id), let uid = deviceUID(id) {
                NSLog("LeetViz: picked hardware output UID=%@ id=%u", uid, id)
                return uid
            }
        }
        return nil
    }

    private func hasOutputStreams(_ deviceID: AudioObjectID) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        let status = AudioObjectGetPropertyDataSize(deviceID, &addr, 0, nil, &size)
        return status == noErr && size > 0
    }

    private func isAggregate(_ deviceID: AudioObjectID) -> Bool {
        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &transport)
        return status == noErr && transport == kAudioDeviceTransportTypeAggregate
    }

    private func deviceUID(_ deviceID: AudioObjectID) -> String? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var uid: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &uid)
        guard status == noErr, let cf = uid?.takeRetainedValue() else { return nil }
        return cf as String
    }

    private func readTapUID(tapID: AudioObjectID) -> String? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var uid: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(tapID, &addr, 0, nil, &size, &uid)
        guard status == noErr, let cf = uid?.takeRetainedValue() else { return nil }
        return cf as String
    }

    private func reportError(status: OSStatus, stage: String) {
        // The tap-create call fails fast with permission-denied codes when TCC
        // hasn't granted us audio capture. Heuristic: any error during create-tap
        // is treated as "permission needed" so the UI shows the affordance.
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if stage == "create-tap" {
                self.delegate?.audioCaptureManagerNeedsPermission(self)
            } else {
                let err = self.simpleError("Audio tap \(stage) failed (status=\(status))")
                self.delegate?.audioCaptureManager(self, didFailWith: err)
            }
        }
    }

    private func simpleError(_ message: String) -> NSError {
        NSError(domain: "LeetViz", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    // MARK: - IOProc

    private var loggedFirstCallback = false
    private var loggedFirstAudible = false

    fileprivate func handleAudio(bufferList: UnsafePointer<AudioBufferList>) {
        let mutableList = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: bufferList)
        )
        guard mutableList.count > 0 else { return }

        if !loggedFirstCallback {
            loggedFirstCallback = true
            let firstBuffer = mutableList[0]
            NSLog("LeetViz: first IOProc callback — buffers=%d, ch=%u, bytes=%u",
                  mutableList.count, firstBuffer.mNumberChannels, firstBuffer.mDataByteSize)
        }

        // Downmix to mono float. The tap delivers Float32; if the layout is
        // interleaved we have one buffer with N channels, otherwise one buffer
        // per channel. Handle both.
        let mono: [Float]
        if mutableList.count == 1 {
            let buf = mutableList[0]
            let channelCount = max(1, Int(buf.mNumberChannels))
            let totalFloats = Int(buf.mDataByteSize) / MemoryLayout<Float>.size
            guard totalFloats > 0, let data = buf.mData else { return }
            let ptr = data.bindMemory(to: Float.self, capacity: totalFloats)
            if channelCount == 1 {
                mono = Array(UnsafeBufferPointer(start: ptr, count: totalFloats))
            } else {
                let frames = totalFloats / channelCount
                var out = [Float](repeating: 0, count: frames)
                for i in 0..<frames {
                    var sum: Float = 0
                    for c in 0..<channelCount { sum += ptr[i * channelCount + c] }
                    out[i] = sum / Float(channelCount)
                }
                mono = out
            }
        } else {
            // Non-interleaved: each channel in its own buffer.
            let first = mutableList[0]
            let frames = Int(first.mDataByteSize) / MemoryLayout<Float>.size
            guard frames > 0 else { return }
            var out = [Float](repeating: 0, count: frames)
            var channels = 0
            for buf in mutableList {
                guard let data = buf.mData else { continue }
                let p = data.bindMemory(to: Float.self, capacity: frames)
                for i in 0..<frames { out[i] += p[i] }
                channels += 1
            }
            if channels > 1 {
                let inv = 1.0 / Float(channels)
                for i in 0..<frames { out[i] *= inv }
            }
            mono = out
        }

        // Cheap peak for wake detection.
        var peak: Float = 0
        mono.withUnsafeBufferPointer { bp in
            if let base = bp.baseAddress, bp.count > 0 {
                vDSP_maxmgv(base, 1, &peak, vDSP_Length(bp.count))
            }
        }

        ringLock.lock()
        ring.append(contentsOf: mono)
        if ring.count > ringCapacity {
            ring.removeFirst(ring.count - ringCapacity)
        }
        ringLock.unlock()

        let audible = peak >= wakeThreshold
        if audible && !loggedFirstAudible {
            loggedFirstAudible = true
            NSLog("LeetViz: first audible audio (peak=%.4f)", peak)
        }
        if audible && !wasAudible {
            wasAudible = true
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.delegate?.audioCaptureManagerDidWake(self)
            }
        } else if !audible && wasAudible {
            // Hysteresis: only flip back to silent when peak stays well below
            // the threshold; render loop handles its own decay tail.
            if peak < wakeThreshold * 0.5 {
                wasAudible = false
            }
        }
    }
}

/// C-style IOProc trampoline. Core Audio fires this on its real-time thread;
/// we hop into the manager instance via the opaque clientData pointer.
private var ioprocFireCount: Int = 0
private let audioIOProcCallback: AudioDeviceIOProc = { (
    _ inDevice: AudioObjectID,
    _ inNow: UnsafePointer<AudioTimeStamp>,
    _ inInputData: UnsafePointer<AudioBufferList>,
    _ inInputTime: UnsafePointer<AudioTimeStamp>,
    _ outOutputData: UnsafeMutablePointer<AudioBufferList>,
    _ inOutputTime: UnsafePointer<AudioTimeStamp>,
    _ inClientData: UnsafeMutableRawPointer?
) -> OSStatus in
    // Log the first few invocations regardless of buffer state, so we can tell
    // "IOProc never fires" apart from "IOProc fires with empty buffers" apart
    // from "IOProc fires but buffers have a format we don't decode".
    ioprocFireCount += 1
    if ioprocFireCount <= 3 {
        let bl = inInputData.pointee
        let firstBufferBytes: UInt32
        let firstBufferChannels: UInt32
        if bl.mNumberBuffers > 0 {
            firstBufferBytes = bl.mBuffers.mDataByteSize
            firstBufferChannels = bl.mBuffers.mNumberChannels
        } else {
            firstBufferBytes = 0
            firstBufferChannels = 0
        }
        NSLog("LeetViz: IOProc fire #%d — numBuffers=%u firstBytes=%u firstCh=%u",
              ioprocFireCount, bl.mNumberBuffers, firstBufferBytes, firstBufferChannels)
    }
    guard let clientData = inClientData else { return noErr }
    let manager = Unmanaged<AudioCaptureManager>.fromOpaque(clientData).takeUnretainedValue()
    manager.handleAudio(bufferList: inInputData)
    return noErr
}
