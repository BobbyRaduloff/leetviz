import Accelerate
import AudioToolbox
import CoreMedia
import Foundation
import ScreenCaptureKit

protocol AudioCaptureManagerDelegate: AnyObject {
    func audioCaptureManagerNeedsPermission(_ manager: AudioCaptureManager)
    func audioCaptureManager(_ manager: AudioCaptureManager, didFailWith error: Error)
    /// Called on the main thread when the capture transitions from silent to
    /// audible. The render loop uses this to wake itself from idle.
    func audioCaptureManagerDidWake(_ manager: AudioCaptureManager)
}

/// Captures system audio via ScreenCaptureKit and keeps a rolling ring buffer
/// of float mono samples that the render loop can snapshot at any time.
///
/// Permission flow: SCShareableContent triggers the macOS Screen Recording prompt
/// on first launch. If the user declines, subsequent calls fail and we notify
/// the delegate so the UI can surface a "Open Settings" affordance.
final class AudioCaptureManager: NSObject, SCStreamDelegate, SCStreamOutput {
    weak var delegate: AudioCaptureManagerDelegate?

    let sampleRate: Float = 48_000

    /// Threshold below which we consider the system silent. Anything below this
    /// peak doesn't wake the render loop. Calibrated against typical music; bump
    /// it up if quiet ambient noise causes false wakes.
    var wakeThreshold: Float = 0.005

    private var stream: SCStream?
    private let sampleQueue = DispatchQueue(label: "leetviz.audio.samples")

    private let ringLock = NSLock()
    private var ring: [Float] = []
    private let ringCapacity = 4096

    private(set) var isRunning = false
    private var wasAudible = false

    func start() {
        guard !isRunning else { return }
        isRunning = true
        Task { await self.startAsync() }
    }

    func stop() {
        isRunning = false
        let s = stream
        stream = nil
        Task { try? await s?.stopCapture() }
    }

    /// Snapshot the most recent samples. Safe to call from any thread.
    func recentSamples() -> [Float] {
        ringLock.lock()
        defer { ringLock.unlock() }
        return ring
    }

    private func startAsync() async {
        NSLog("LeetViz: requesting SCShareableContent…")
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            NSLog("LeetViz: got SCShareableContent (%d displays)", content.displays.count)
            guard let display = content.displays.first else {
                await report(error: NSError(domain: "LeetViz", code: 1,
                                            userInfo: [NSLocalizedDescriptionKey: "No display available"]))
                return
            }
            let filter = SCContentFilter(display: display, excludingWindows: [])
            let config = SCStreamConfiguration()
            config.capturesAudio = true
            config.excludesCurrentProcessAudio = true
            config.sampleRate = Int(sampleRate)
            config.channelCount = 2
            // Video has to exist on the stream but we never read it; keep it tiny.
            config.width = 2
            config.height = 2
            config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

            let stream = SCStream(filter: filter, configuration: config, delegate: self)
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: sampleQueue)
            // SCStream always produces video frames — there's no audio-only mode.
            // Without an output handler for them, SCK logs "Dropping frame" per
            // frame. Register a screen handler that just discards (the callback
            // early-returns on `.screen`). Frames are 2×2 at 1fps so cost is nil.
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
            try await stream.startCapture()
            self.stream = stream
            NSLog("LeetViz: SCStream startCapture succeeded — audio flowing")
        } catch {
            NSLog("LeetViz: SCStream start failed: %@ (%@ code=%d)",
                  error.localizedDescription,
                  (error as NSError).domain,
                  (error as NSError).code)
            await report(error: error)
        }
    }

    @MainActor
    private func report(error: Error) {
        let ns = error as NSError
        // ScreenCaptureKit returns various error codes when TCC denies us;
        // detect them so we can surface a permission affordance instead of
        // just logging a cryptic failure.
        let msg = ns.localizedDescription.lowercased()
        let isPermissionIssue =
            ns.code == -3801 ||
            ns.domain == "com.apple.ScreenCaptureKit.SCStreamErrorDomain" ||
            msg.contains("permission") ||
            msg.contains("declined") ||
            msg.contains("not authorized")
        if isPermissionIssue {
            delegate?.audioCaptureManagerNeedsPermission(self)
        } else {
            delegate?.audioCaptureManager(self, didFailWith: error)
        }
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid, let pcm = sampleBuffer.toMonoFloat() else { return }

        // Cheap peak via vDSP — single pass, no allocations beyond the array
        // we already produced. Used to decide whether to wake the render loop.
        var peak: Float = 0
        pcm.withUnsafeBufferPointer { ptr in
            if let base = ptr.baseAddress, ptr.count > 0 {
                vDSP_maxmgv(base, 1, &peak, vDSP_Length(ptr.count))
            }
        }

        ringLock.lock()
        ring.append(contentsOf: pcm)
        if ring.count > ringCapacity {
            ring.removeFirst(ring.count - ringCapacity)
        }
        ringLock.unlock()

        let audible = peak >= wakeThreshold
        if audible && !wasAudible {
            wasAudible = true
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.delegate?.audioCaptureManagerDidWake(self)
            }
        } else if !audible && wasAudible {
            // Hysteresis: only flip back to "silent" when peak stays well below
            // the threshold for a moment, so we don't strobe between states on
            // quiet passages. Render loop handles its own decay tail.
            if peak < wakeThreshold * 0.5 {
                wasAudible = false
            }
        }
    }

    // MARK: - SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor in self.report(error: error) }
    }
}

// MARK: - CMSampleBuffer → mono Float

private extension CMSampleBuffer {
    func toMonoFloat() -> [Float]? {
        guard let formatDesc = CMSampleBufferGetFormatDescription(self),
              let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) else { return nil }
        let asbd = asbdPtr.pointee
        guard (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0 else { return nil }

        let isInterleaved = (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) == 0
        let channelCount = Int(asbd.mChannelsPerFrame)

        var sizeNeeded = 0
        CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            self,
            bufferListSizeNeededOut: &sizeNeeded,
            bufferListOut: nil,
            bufferListSize: 0,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: 0,
            blockBufferOut: nil
        )
        guard sizeNeeded > 0 else { return nil }
        let listRaw = UnsafeMutableRawPointer.allocate(
            byteCount: sizeNeeded,
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { listRaw.deallocate() }
        let listPtr = listRaw.bindMemory(to: AudioBufferList.self, capacity: 1)

        var blockBuffer: CMBlockBuffer?
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            self,
            bufferListSizeNeededOut: nil,
            bufferListOut: listPtr,
            bufferListSize: sizeNeeded,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard status == noErr else { return nil }
        _ = blockBuffer

        let buffers = UnsafeMutableAudioBufferListPointer(listPtr)

        if isInterleaved {
            guard let buf = buffers.first, let raw = buf.mData else { return nil }
            let totalFloats = Int(buf.mDataByteSize) / MemoryLayout<Float>.size
            let ptr = raw.bindMemory(to: Float.self, capacity: totalFloats)
            if channelCount <= 1 {
                return Array(UnsafeBufferPointer(start: ptr, count: totalFloats))
            }
            let frames = totalFloats / channelCount
            var mono = [Float](repeating: 0, count: frames)
            for i in 0..<frames {
                var sum: Float = 0
                for c in 0..<channelCount { sum += ptr[i * channelCount + c] }
                mono[i] = sum / Float(channelCount)
            }
            return mono
        } else {
            // Non-interleaved: each channel is its own AudioBuffer.
            guard let first = buffers.first else { return nil }
            let frames = Int(first.mDataByteSize) / MemoryLayout<Float>.size
            var mono = [Float](repeating: 0, count: frames)
            var channels = 0
            for b in buffers {
                guard let data = b.mData else { continue }
                let p = data.bindMemory(to: Float.self, capacity: frames)
                for i in 0..<frames { mono[i] += p[i] }
                channels += 1
            }
            if channels > 1 {
                let inv = 1.0 / Float(channels)
                for i in 0..<frames { mono[i] *= inv }
            }
            return mono
        }
    }
}
